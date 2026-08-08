import Foundation
import Combine
import WidgetKit

/// 宿主 App 的大脑：轮询 Music 状态 → 写进 App Group → 通知小组件刷新；
/// 同时接住小组件按钮发来的指令，转成 Apple Event 打给 Music.app。
@MainActor
final class Coordinator: ObservableObject {
    static let shared = Coordinator()

    @Published private(set) var state = PlayerState()
    @Published private(set) var lyrics = Lyrics()
    @Published private(set) var permissionDenied = false

    // 这两个要在后台队列里用，所以刻意不跟着 Coordinator 一起被 MainActor 隔离
    private nonisolated let bridge = MusicBridge.shared
    private nonisolated let poll = DispatchQueue(label: "com.xiaoxiang.musicwidget.poll", qos: .utility)

    private var timer: Timer?
    private var commandWatcher: DispatchSourceFileSystemObject?
    private var lyricsTask: Task<Void, Never>?
    /// 已经查过歌词的曲目，避免同一首歌反复请求
    private var lyricsFetchedFor = ""

    private init() {}

    // MARK: - 启动

    func start() {
        SharedStore.prepare()
        observeMusicNotifications()
        observeCommands()
        refresh(force: true)
        scheduleTimer(interval: 2)
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // .common 让菜单弹开时定时器照常走
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Music.app 换歌 / 起停时会广播这个通知，比轮询快得多
    private func observeMusicNotifications() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(force: true)
                // Music 广播时进度往往还没稳定，稍后再补一次
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.refresh(force: true)
            }
        }
    }

    // MARK: - 采样

    func refresh(force: Bool = false) {
        poll.async { [weak self] in
            guard let self else { return }
            let fresh = self.bridge.fetchState()
            let denied = self.bridge.authorizationDenied
            Task { @MainActor in
                self.apply(fresh, denied: denied, force: force)
            }
        }
    }

    private func apply(_ fresh: PlayerState, denied: Bool, force: Bool) {
        permissionDenied = denied

        var next = fresh
        let trackChanged = !next.isSameTrack(as: state)

        // 封面只在换歌时取一次
        if next.hasTrack {
            if trackChanged || state.artworkFile == nil {
                fetchArtwork(for: next)
            } else {
                next.artworkFile = state.artworkFile
                next.artworkColor = state.artworkColor
            }
        }

        let significant = force
            || trackChanged
            || next.kind != state.kind
            || next.loved != state.loved
            || abs(next.position(at: next.sampledAt) - state.position(at: next.sampledAt)) > 1.5

        state = next

        if trackChanged {
            // 歌换了，先把旧歌词清掉，别让上一首的词继续挂着
            lyrics = Lyrics(trackID: next.trackID)
            SharedStore.save(lyrics: lyrics)
            fetchLyricsIfNeeded()
        }

        if significant {
            persist(next)
            reloadWidgets()
        } else if Date().timeIntervalSince(lastPersist) > 20 {
            // 平静期也隔一会儿落一次盘：小组件靠 sampledAt 判断宿主 App 还在不在跑
            persist(next)
        }

        // 没在播的时候把轮询放慢，省点电
        let wanted: TimeInterval = next.isPlaying ? 2 : 6
        if timer?.timeInterval != wanted { scheduleTimer(interval: wanted) }
    }

    // MARK: - 封面

    /// 两级：本地文件曲目 AppleScript 直接能取到原图；
    /// 流媒体曲目取不到，退回 iTunes 官方接口按时长匹配同一首歌的封面。
    private func fetchArtwork(for target: PlayerState) {
        let trackID = target.trackID
        guard !trackID.isEmpty else { return }

        poll.async { [weak self] in
            guard let self else { return }
            if let local = self.bridge.fetchArtwork(for: trackID,
                                                    artist: target.artist,
                                                    album: target.album) {
                Task { @MainActor in self.applyArtwork(local.file, color: local.color, for: trackID) }
                return
            }
            Task {
                guard let remote = await ArtworkService.fetch(
                    title: target.title, artist: target.artist, album: target.album,
                    duration: target.duration, trackID: trackID
                ) else { return }
                await MainActor.run { self.applyArtwork(remote.file, color: remote.color, for: trackID) }
            }
        }
    }

    private func applyArtwork(_ file: String, color: [Double]?, for trackID: String) {
        guard state.trackID == trackID else { return }   // 已经换歌了就丢弃
        state.artworkFile = file
        state.artworkColor = color
        persist(state)
        reloadWidgets()
    }

    // MARK: - 歌词

    private func fetchLyricsIfNeeded() {
        let target = state
        guard target.hasTrack, !target.title.isEmpty else { return }
        guard lyricsFetchedFor != target.trackID else { return }
        lyricsFetchedFor = target.trackID

        lyricsTask?.cancel()
        lyricsTask = Task { [weak self] in
            let found = await LyricsService.fetch(
                title: target.title,
                artist: target.artist,
                album: target.album,
                duration: target.duration
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.state.trackID == target.trackID else { return }
                var result = found ?? Lyrics(trackID: target.trackID, source: "", missing: true)
                result.trackID = target.trackID
                if found == nil { result.missing = true }
                self.lyrics = result
                SharedStore.save(lyrics: result)
                self.reloadWidgets()
            }
        }
    }

    func refetchLyrics() {
        lyricsFetchedFor = ""
        fetchLyricsIfNeeded()
    }

    // MARK: - 小组件指令

    /// 小组件按钮走两条路通知过来：分布式通知（快）+ 文件监听（保险）。
    /// 沙箱里通知的 userInfo 会被系统丢掉，所以指令内容始终放在文件里。
    private func observeCommands() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(Shared.commandNotification),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.drainCommands() }
        }

        guard let dir = SharedStore.commandsURL else { return }
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.drainCommands() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        commandWatcher = source
    }

    private func drainCommands() {
        let pending = SharedStore.drainCommands()
        guard !pending.isEmpty else { return }
        poll.async { [weak self] in
            guard let self else { return }
            for envelope in pending {
                self.bridge.perform(envelope.command)
            }
            // 给 Music 一点反应时间再采样，否则读到的还是旧状态
            Thread.sleep(forTimeInterval: 0.35)
            let fresh = self.bridge.fetchState()
            let denied = self.bridge.authorizationDenied
            Task { @MainActor in
                self.apply(fresh, denied: denied, force: true)
            }
        }
    }

    func perform(_ command: MusicCommand) {
        poll.async { [weak self] in
            guard let self else { return }
            self.bridge.perform(command)
            Thread.sleep(forTimeInterval: 0.35)
            let fresh = self.bridge.fetchState()
            let denied = self.bridge.authorizationDenied
            Task { @MainActor in self.apply(fresh, denied: denied, force: true) }
        }
    }

    // MARK: - 落盘 / 刷新小组件

    private var lastPersist = Date.distantPast

    private func persist(_ state: PlayerState) {
        lastPersist = Date()
        SharedStore.save(state: state)
    }

    private var lastReload = Date.distantPast
    func reloadWidgets() {
        // 从宿主 App 主动触发的刷新不占系统预算，但也别刷得太密
        guard Date().timeIntervalSince(lastReload) > 0.4 else { return }
        lastReload = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: Shared.widgetKind)
    }
}

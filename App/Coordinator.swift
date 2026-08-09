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
    /// 每首歌查歌词的尝试次数。
    ///
    /// 记次数而不是「查过就不再查」：网络抖一下、超时一次，那首歌就被永久
    /// 标记成查过了，再也不会重试 —— 表现就是这首歌一直没歌词，直到你切走再切回来。
    /// 曲库里明明有，纯粹是一次性失败被当成了最终结论。
    private var lyricsAttempts: [String: Int] = [:]
    private let maxLyricsAttempts = 3
    /// 正在查歌词的那首曲目。
    ///
    /// 有它才能避免把自己的任务掐死：换歌时 Music 的 playerInfo 通知会触发两次
    /// refresh（隔 400ms，第二次用来补准进度），而第一次的 state 还没写回，
    /// 第二次仍判定为「换歌」—— 于是无条件 cancel 掉正在跑的那个查询。
    /// 被取消的任务既不重试也不标记失败，界面就永远停在「正在查找歌词…」。
    private var lyricsFetchingFor: String?

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

        // 封面只在换歌时发起一次，失败由 fetchArtwork 自己延迟重试。
        //
        // 这里千万不能写成「artworkFile 还是空就再抓」—— 轮询每 2 秒跑一遍 apply，
        // 那等于封面一旦抓不到就每 2 秒发一次请求、永不停止，很快会被接口限流；
        // 而歌词走的是同一批出口，会被一起拖下水，表现就是封面和歌词同时消失。
        if next.hasTrack {
            if trackChanged {
                fetchArtwork(for: next)
            } else {
                next.artworkFile = state.artworkFile
                next.artworkColor = state.artworkColor
            }
        }

        let significant = force
            || trackChanged
            || next.kind != state.kind
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
    private func fetchArtwork(for target: PlayerState, attempt: Int = 0) {
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
                let remote = await ArtworkService.fetch(
                    title: target.title, artist: target.artist, album: target.album,
                    duration: target.duration, trackID: trackID
                )
                await MainActor.run {
                    if let remote {
                        self.applyArtwork(remote.file, color: remote.color, for: trackID)
                        return
                    }
                    // 没拿到就退避重试，间隔翻倍；用完就作罢，等下次换歌再说。
                    // 重试必须由这里发起而不是靠轮询，否则就变成每 2 秒一次的死循环。
                    guard attempt < 2, self.state.trackID == trackID else { return }
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(3 + attempt * 5) * 1_000_000_000)
                        await MainActor.run { self?.fetchArtwork(for: target, attempt: attempt + 1) }
                    }
                }
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
        // 已经拿到这首的歌词就不用再查
        guard !(lyrics.trackID == target.trackID && !lyrics.isEmpty) else { return }
        let attempts = lyricsAttempts[target.trackID] ?? 0
        guard attempts < maxLyricsAttempts else { return }
        // 这首正在查就让它查完，别重复发起、更别把它掐掉
        guard lyricsFetchingFor != target.trackID else { return }
        lyricsAttempts[target.trackID] = attempts + 1

        lyricsTask?.cancel()          // 只有换歌了才轮得到这一句
        lyricsFetchingFor = target.trackID
        lyricsTask = Task { [weak self] in
            let found = await LyricsService.fetch(
                title: target.title,
                artist: target.artist,
                album: target.album,
                duration: target.duration
            )
            await MainActor.run {
                guard let self else { return }
                self.lyricsFetchingFor = nil
                guard self.state.trackID == target.trackID else { return }

                if var result = found {
                    result.trackID = target.trackID
                    self.lyrics = result
                    SharedStore.save(lyrics: result)
                    self.reloadWidgets()
                    return
                }

                // 没查到。还有重试机会就过几秒再来一次 —— 多数失败是网络抖动，
                // 而不是曲库真的没有；只有把机会用完了才敢下「没有歌词」的结论。
                let used = self.lyricsAttempts[target.trackID] ?? 0
                if used < self.maxLyricsAttempts {
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        await MainActor.run { self?.fetchLyricsIfNeeded() }
                    }
                } else {
                    self.lyrics = Lyrics(trackID: target.trackID, source: "", missing: true)
                    SharedStore.save(lyrics: self.lyrics)
                    self.reloadWidgets()
                }
            }
        }
    }

    func refetchLyrics() {
        lyricsAttempts.removeValue(forKey: state.trackID)
        lyrics = Lyrics(trackID: state.trackID)
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
    private var pendingReload: Task<Void, Never>?
    private let reloadInterval: TimeInterval = 0.4

    /// 通知小组件重绘。太密的话**延后合并**，绝不能直接丢弃。
    ///
    /// 丢弃过一次，代价是这样的：换歌时刷新会连着触发好几轮（状态变了一次、
    /// 封面到了一次），而歌词往往是最后才到的那个，正好撞进节流窗口被丢掉 ——
    /// 于是歌词明明已经写进共享容器，小组件却从没被叫醒去读它，界面一直停在
    /// 「正在查找歌词…」。直到下次换歌才闪现一帧，随即被新歌覆盖。
    func reloadWidgets() {
        let gap = Date().timeIntervalSince(lastReload)
        if gap >= reloadInterval {
            pendingReload?.cancel()
            pendingReload = nil
            lastReload = Date()
            WidgetCenter.shared.reloadTimelines(ofKind: Shared.widgetKind)
            return
        }
        // 已经排了一次就不用再排，反正合并成同一次
        guard pendingReload == nil else { return }
        pendingReload = Task { [weak self] in
            guard let self else { return }
            let wait = self.reloadInterval - gap + 0.05
            try? await Task.sleep(nanoseconds: UInt64(max(wait, 0.05) * 1_000_000_000))
            await MainActor.run {
                self.pendingReload = nil
                self.lastReload = Date()
                WidgetCenter.shared.reloadTimelines(ofKind: Shared.widgetKind)
            }
        }
    }
}

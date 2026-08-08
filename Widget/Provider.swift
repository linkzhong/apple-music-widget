import WidgetKit
import SwiftUI

struct MusicEntry: TimelineEntry {
    var date: Date
    var state: PlayerState

    /// 这一刻要显示的歌词窗口。只放窗口而不是整首歌 ——
    /// 时间线会预排上百个 entry，每个都拷一份完整歌词的话存储和内存都撑不住。
    var lyricWindow: [String] = []
    /// 窗口里哪一行是当前行
    var currentInWindow: Int?
    /// 窗口第一行在整首歌里的行号。
    /// 靠它给每一行算出**稳定的身份** —— 窗口往下滑时，同一句歌词的 id 不变，
    /// 系统才会把它的位移补成动画（丝滑上滚）；用窗口内下标当 id 的话身份会错位，
    /// 只能得到整块淡入淡出。
    var windowStart: Int = 0
    /// 当前这句的中文译文（英文歌才有）
    var currentTranslation: String?
    /// 查过了但确实没有歌词
    var lyricsMissing = false

    /// 宿主 App 还活着吗
    var hostAlive = true
    /// 封面图的完整路径。放在 entry 里而不是让视图去查 App Group，
    /// 这样离屏预览工具能塞别的图进来。
    var artworkPath: String?

    var hasLyrics: Bool { !lyricWindow.isEmpty }
}

struct MusicProvider: TimelineProvider {

    /// 大尺寸一屏放得下的歌词行数
    private let windowSize = 7
    /// 没有歌词时的兜底刷新间隔 —— 有歌词的话每句本身就是一个时间点，够密了
    private let tickInterval = 12.0
    private let maxEntries = 90

    /// 歌词的提前量。
    /// 系统在 entry 的时间点重绘不是即时的，实测会晚半秒到一秒，歌词就总慢半拍。
    /// 所以把换行的时间点整体往前挪，判断当前行时也用同样的偏移 —— 两边必须一致，
    /// 否则会出现「entry 触发了但内容还是上一行」。
    private let lyricsLead = 0.6

    func placeholder(in context: Context) -> MusicEntry {
        entry(at: Date(), state: .sample, lyrics: .sample, alive: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (MusicEntry) -> Void) {
        let state = SharedStore.loadState()
        completion(entry(at: Date(), state: state, lyrics: matchedLyrics(for: state), alive: isHostAlive(state)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MusicEntry>) -> Void) {
        let now = Date()
        let state = SharedStore.loadState()
        let lyrics = matchedLyrics(for: state)
        let alive = isHostAlive(state)

        var entries = [entry(at: now, state: state, lyrics: lyrics, alive: alive)]

        if state.isPlaying, alive {
            // 两组时间点合到一起：每句歌词的起点（换行）+ 稀疏的兜底刻度
            let trackStart = state.trackStartDate
            var moments: [Date] = lyrics.lines.map {
                trackStart.addingTimeInterval($0.time - lyricsLead)
            }

            let endOfTrack = state.duration > 0 ? trackStart.addingTimeInterval(state.duration) : now.addingTimeInterval(600)
            var tick = now.addingTimeInterval(tickInterval)
            while tick < endOfTrack, moments.count < maxEntries * 2 {
                moments.append(tick)
                tick = tick.addingTimeInterval(tickInterval)
            }

            let future = moments
                .filter { $0 > now.addingTimeInterval(0.4) && $0 < endOfTrack }
                .sorted()
                .prefix(maxEntries - 1)

            for moment in future {
                entries.append(entry(at: moment, state: state, lyrics: lyrics, alive: true))
            }
        }

        completion(Timeline(entries: entries, policy: policy(state, now: now, alive: alive, lastEntry: entries.last?.date)))
    }

    // MARK: - 组装单个 entry

    private func entry(at date: Date, state: PlayerState, lyrics: Lyrics, alive: Bool) -> MusicEntry {
        let position = state.position(at: date)
        var result = MusicEntry(date: date, state: state)
        result.hostAlive = alive
        result.lyricsMissing = lyrics.missing
        result.artworkPath = state.artworkFile.flatMap { SharedStore.artworkPath($0)?.path }

        guard !lyrics.isEmpty else { return result }

        // 和上面把换行时间点提前保持一致
        let current = lyrics.index(at: position + lyricsLead)
        // 当前行上面留一行，剩下往下铺
        var start = max(0, (current ?? 0) - 1)
        if start + windowSize > lyrics.lines.count {
            start = max(0, lyrics.lines.count - windowSize)
        }
        let range = start..<min(lyrics.lines.count, start + windowSize)

        result.lyricWindow = range.map { lyrics.lines[$0].text }
        result.currentInWindow = current.map { $0 - start }
        result.windowStart = start
        if let current { result.currentTranslation = lyrics.lines[current].translation }
        return result
    }

    // MARK: - 辅助

    /// 歌词文件可能还停在上一首上，对不上就当没有
    private func matchedLyrics(for state: PlayerState) -> Lyrics {
        let lyrics = SharedStore.loadLyrics()
        guard !state.trackID.isEmpty, lyrics.trackID == state.trackID else { return Lyrics() }
        return lyrics
    }

    /// 宿主 App 每隔几秒会刷新一次采样时间，太久没动就说明它没在跑
    private func isHostAlive(_ state: PlayerState) -> Bool {
        Date().timeIntervalSince(state.sampledAt) < 120
    }

    private func policy(_ state: PlayerState, now: Date, alive: Bool, lastEntry: Date?) -> TimelineReloadPolicy {
        guard alive else { return .after(now.addingTimeInterval(60)) }
        if state.isPlaying {
            let next = lastEntry ?? now.addingTimeInterval(30)
            return .after(max(next, now.addingTimeInterval(5)))
        }
        return .after(now.addingTimeInterval(300))
    }
}

// MARK: - 预览用假数据

extension PlayerState {
    static var sample: PlayerState {
        var s = PlayerState()
        s.kind = .playing
        s.title = "到处不存在的我"
        s.artist = "小人"
        s.album = "小人国"
        s.duration = 230
        s.position = 43
        s.sampledAt = Date()
        s.trackID = "sample"
        s.artworkColor = [0.72, 0.28, 0.34]
        return s
    }
}

extension Lyrics {
    static var sample: Lyrics {
        Lyrics(trackID: "sample", lines: [
            LyricLine(time: 34, text: "我用电联车的速度搭自强号"),
            LyricLine(time: 38, text: "乘客的声音是强暴"),
            LyricLine(time: 42, text: "I heard that you're settled down, that you found a girl",
                      translation: "听说你已安定下来 已经找到了心仪的姑娘"),
            LyricLine(time: 46, text: "手贴着大腿那是我世界的面积"),
            LyricLine(time: 50, text: "我在后座有她的机车被吐出排气管"),
        ], source: "网易云")
    }
}

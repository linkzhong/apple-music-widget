import Foundation

// MARK: - 常量

enum Shared {
    /// App Group —— 宿主 App 与小组件之间唯一的数据通道。
    /// macOS 要求 group id 以 Team ID 开头。
    static let appGroup = "T4GCDZULTU.group.com.xiaoxiang.musicwidget"

    static let widgetKind = "AppleMusicNowPlaying"

    /// 小组件按钮 -> 宿主 App 的即时唤醒信号（沙箱里 userInfo 会被丢弃，
    /// 所以指令本身写在文件里，通知只用来「叫醒」宿主 App）。
    static let commandNotification = "com.xiaoxiang.musicwidget.command"
}

// MARK: - 播放状态

/// 宿主 App 采样一次 Music.app 的结果，序列化后放进 App Group 供小组件读取。
struct PlayerState: Codable, Equatable {
    enum Kind: String, Codable {
        case notRunning   // Music.app 没开
        case stopped      // 开着但没在播
        case playing
        case paused
    }

    var kind: Kind = .notRunning
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    /// 曲目总长（秒）
    var duration: Double = 0
    /// 采样瞬间的播放进度（秒）
    var position: Double = 0
    /// 采样时刻 —— 小组件靠它把 position 外推到「现在」
    var sampledAt: Date = .distantPast
    /// Music 里的 persistent ID，用来判断是否换歌
    var trackID: String = ""
    /// App Group 容器内的封面文件名（artwork/xxx.png）
    var artworkFile: String?
    /// 从封面里取的主色 [r, g, b]，给小组件当背景氛围色
    var artworkColor: [Double]?
    var loved: Bool = false

    var isPlaying: Bool { kind == .playing }
    var hasTrack: Bool { kind == .playing || kind == .paused }

    /// 把采样点外推到指定时刻的播放进度
    func position(at date: Date) -> Double {
        guard isPlaying else { return position }
        let elapsed = date.timeIntervalSince(sampledAt)
        return min(max(position + elapsed, 0), max(duration, 0))
    }

    /// 当前曲目「第 0 秒」对应的绝对时间，用于 ProgressView(timerInterval:)
    var trackStartDate: Date { sampledAt.addingTimeInterval(-position) }

    /// 判断是不是同一首歌的同一次播放（换歌 / 拖进度都算变化）
    func isSameTrack(as other: PlayerState) -> Bool {
        trackID == other.trackID && title == other.title
    }
}

// MARK: - 歌词

struct LyricLine: Codable, Equatable {
    var time: Double   // 秒
    var text: String
}

struct Lyrics: Codable, Equatable {
    /// 对应的曲目标识，避免歌词和歌曲串台
    var trackID: String = ""
    var lines: [LyricLine] = []
    /// 歌词来源，显示在小组件角落
    var source: String = ""
    /// 已经查过但确实没有歌词 —— 避免反复请求
    var missing: Bool = false

    var isEmpty: Bool { lines.isEmpty }

    /// 给定播放进度，返回当前应高亮的行号
    func index(at seconds: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        var result: Int?
        for (i, line) in lines.enumerated() {
            if line.time <= seconds + 0.05 { result = i } else { break }
        }
        return result
    }

    /// 第 i 行唱完的时间点（最后一行没有下一行，给它留一段固定时长）
    func endTime(of index: Int) -> Double {
        guard lines.indices.contains(index) else { return 0 }
        if index + 1 < lines.count { return lines[index + 1].time }
        return lines[index].time + 6
    }
}

// MARK: - 指令

enum MusicCommand: String, Codable, CaseIterable {
    case playPause
    case next
    case previous
    case toggleLove
    /// 打开 Music.app 并前置
    case activateMusic
}

/// 写进 App Group 的指令信封（带序号防止重复执行）
struct CommandEnvelope: Codable {
    var command: MusicCommand
    var issuedAt: Date
    var nonce: String
}

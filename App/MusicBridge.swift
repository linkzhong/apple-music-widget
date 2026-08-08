import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 通过 AppleScript 和 Music.app 对话：读状态、控制播放、取封面。
///
/// NSAppleScript 不是线程安全的，所有调用都压在同一条串行队列上；
/// 内部可变状态也一律只在这条队列里碰，因此对外可以当 Sendable 用。
final class MusicBridge: @unchecked Sendable {
    static let shared = MusicBridge()

    private let queue = DispatchQueue(label: "com.xiaoxiang.musicwidget.applescript")
    private var compiled: [String: NSAppleScript] = [:]
    private var deniedFlag = false

    /// 上一次 Apple Event 是否因为没授权而失败
    var authorizationDenied: Bool { queue.sync { deniedFlag } }

    private init() {}

    // MARK: - 读状态

    /// 用一个分隔符拼接的字符串一次拿回所有字段，省得来回多次 Apple Event。
    private static let stateScript = """
    tell application "Music"
        if it is not running then return "NOTRUNNING"
        if player state is stopped then return "STOPPED"
        set tr to current track
        set lovedFlag to false
        try
            set lovedFlag to (loved of tr)
        end try
        set playFlag to (player state is playing)
        set artFlag to false
        try
            set artFlag to (exists artwork 1 of tr)
        end try
        -- 电台之类的曲目这两个字段可能是 missing value，
        -- 不兜住的话 `as text` 会整条脚本报错，状态就全读不到了
        set posValue to 0
        try
            set posValue to (player position) as real
        end try
        set durValue to 0
        try
            set durValue to (duration of tr) as real
        end try
        return (playFlag as text) & "\u{1F}" & (name of tr) & "\u{1F}" & (artist of tr) & "\u{1F}" ¬
            & (album of tr) & "\u{1F}" & (durValue as text) & "\u{1F}" ¬
            & (posValue as text) & "\u{1F}" & (persistent ID of tr) & "\u{1F}" ¬
            & (lovedFlag as text) & "\u{1F}" & (artFlag as text)
    end tell
    """

    func fetchState() -> PlayerState {
        // Music.app 没开就别用 AppleScript 去戳它 —— 那会把 Music 启动起来。
        guard isMusicRunning() else {
            var s = PlayerState()
            s.kind = .notRunning
            s.sampledAt = Date()
            return s
        }

        var state = PlayerState()
        state.sampledAt = Date()

        guard let raw = run(Self.stateScript)?.stringValue else {
            state.kind = .notRunning
            return state
        }

        if raw == "NOTRUNNING" { state.kind = .notRunning; return state }
        if raw == "STOPPED" { state.kind = .stopped; return state }

        let parts = raw.components(separatedBy: "\u{1F}")
        guard parts.count >= 9 else { state.kind = .stopped; return state }

        state.kind = (parts[0] == "true") ? .playing : .paused
        state.title = parts[1]
        state.artist = parts[2]
        state.album = parts[3]
        state.duration = Double(parts[4]) ?? 0
        state.position = Double(parts[5]) ?? 0
        state.trackID = parts[6]
        state.loved = (parts[7] == "true")
        // parts[8] 是有没有封面，交给 fetchArtwork 处理
        // 采样时间点用「脚本返回之后」更准一点：AppleScript 往返本身有几毫秒
        state.sampledAt = Date()
        return state
    }

    func isMusicRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    // MARK: - 封面

    /// 取当前曲目封面存进 App Group，返回文件名。
    ///
    /// 只有本地导入的音频文件能走通：Apple Music 的流媒体曲目会报
    /// 「Can't get raw data of artwork 1」，那种情况返回 nil，交给 ArtworkService 走网络。
    func fetchArtwork(for trackID: String, artist: String = "", album: String = "") -> (file: String, color: [Double]?)? {
        let script = """
        tell application "Music"
            if it is not running then return missing value
            if player state is stopped then return missing value
            try
                return raw data of artwork 1 of current track
            on error
                return missing value
            end try
        end tell
        """
        guard let desc = run(script) else { return nil }
        guard let data = desc.data as Data?, !data.isEmpty else { return nil }
        // Music 给回来的可能是 JPEG / PNG / TIFF，统一压到 320 边长再转 PNG
        guard let png = ArtworkService.downscaledPNG(from: data, maxSide: 320) else { return nil }
        let name = ArtworkService.cacheName(artist: artist, album: album, trackID: trackID)
        guard let saved = ArtworkService.save(png, as: name) else { return nil }
        return (saved, ArtworkService.dominantColor(from: png))
    }

    // MARK: - 控制

    func perform(_ command: MusicCommand) {
        switch command {
        case .playPause:
            // Music 没在跑的话 playpause 会把它启动起来，这符合直觉
            _ = run(#"tell application "Music" to playpause"#)
        case .next:
            _ = run(#"tell application "Music" to next track"#)
        case .previous:
            // 播放超过 3 秒时按「上一首」先回到本曲开头，和大多数播放器一致
            _ = run("""
            tell application "Music"
                if player position > 3 then
                    set player position to 0
                else
                    previous track
                end if
            end tell
            """)
        case .toggleLove:
            _ = run("""
            tell application "Music"
                if player state is stopped then return
                set tr to current track
                try
                    set loved of tr to (not (loved of tr))
                end try
            end tell
            """)
        case .activateMusic:
            _ = run(#"tell application "Music" to activate"#)
        }
    }

    // MARK: - 执行

    @discardableResult
    private func run(_ source: String) -> NSAppleEventDescriptor? {
        queue.sync {
            let script: NSAppleScript
            if let cached = compiled[source] {
                script = cached
            } else {
                guard let fresh = NSAppleScript(source: source) else { return nil }
                compiled[source] = fresh
                script = fresh
            }
            var error: NSDictionary?
            let result: NSAppleEventDescriptor? = script.executeAndReturnError(&error)
            if let error {
                let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                // -1743 = 用户没给「自动化」权限；-600 = 目标 App 没运行
                if code == -1743 { deniedFlag = true }
                if code != -1743 && code != -600 {
                    NSLog("[MusicWidget] AppleScript 出错 \(code): \(error[NSAppleScript.errorMessage] ?? "")")
                }
                return nil
            }
            deniedFlag = false
            return result
        }
    }

    /// 主动触发一次授权弹窗（首次运行时用）
    func requestAutomationPermission() {
        _ = run(#"tell application "Music" to return name"#)
    }
}

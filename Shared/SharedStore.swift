import Foundation

/// App Group 容器的读写封装。宿主 App（写）和小组件（读）共用这一份。
enum SharedStore {
    private static let stateFile = "state.json"
    private static let lyricsFile = "lyrics.json"
    private static let commandsDir = "commands"
    private static let artworkDir = "artwork"

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Shared.appGroup)
    }

    /// 宿主 App 不在沙箱里，group 容器不会被系统自动建出来，这里补上。
    @discardableResult
    static func prepare() -> URL? {
        guard let root = container else { return nil }
        let fm = FileManager.default
        for dir in [root, root.appendingPathComponent(commandsDir), root.appendingPathComponent(artworkDir)] {
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        return root
    }

    static var commandsURL: URL? { container?.appendingPathComponent(commandsDir) }
    static var artworkURL: URL? { container?.appendingPathComponent(artworkDir) }

    // MARK: - 播放状态

    static func save(state: PlayerState) { write(state, to: stateFile) }
    static func loadState() -> PlayerState { read(PlayerState.self, from: stateFile) ?? PlayerState() }

    // MARK: - 歌词

    static func save(lyrics: Lyrics) { write(lyrics, to: lyricsFile) }
    static func loadLyrics() -> Lyrics { read(Lyrics.self, from: lyricsFile) ?? Lyrics() }

    // MARK: - 封面

    static func artworkPath(_ name: String) -> URL? {
        artworkURL?.appendingPathComponent(name)
    }

    /// 留最近下过的若干张当缓存，多出来的按修改时间删掉
    static func pruneArtwork(keepingNewest limit: Int) {
        guard let dir = artworkURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        guard files.count > limit else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for url in sorted.dropFirst(limit) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 指令队列
    //
    // 小组件按钮（沙箱进程）没法直接给 Music.app 发 Apple Event，
    // 于是把指令落成文件，由宿主 App 取走执行。

    static func enqueue(_ command: MusicCommand) {
        guard let dir = commandsURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let nonce = UUID().uuidString
        let envelope = CommandEnvelope(command: command, issuedAt: Date(), nonce: nonce)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        // 文件名带时间戳前缀，宿主 App 好按顺序执行
        let name = String(format: "%.6f-%@.json", Date().timeIntervalSince1970, nonce)
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    /// 取出并清空所有待执行指令（宿主 App 侧调用）
    static func drainCommands() -> [CommandEnvelope] {
        guard let dir = commandsURL,
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var result: [CommandEnvelope] = []
        for name in files.sorted() where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let env = try? JSONDecoder().decode(CommandEnvelope.self, from: data) else { continue }
            // 超过 10 秒的指令视为过期（比如宿主 App 当时没运行），丢掉免得突然乱跳
            guard Date().timeIntervalSince(env.issuedAt) < 10 else { continue }
            result.append(env)
        }
        return result
    }

    // MARK: - 底层

    private static func write<T: Encodable>(_ value: T, to file: String) {
        guard let root = prepare() else { return }
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: root.appendingPathComponent(file), options: .atomic)
    }

    private static func read<T: Decodable>(_ type: T.Type, from file: String) -> T? {
        guard let root = container else { return nil }
        guard let data = try? Data(contentsOf: root.appendingPathComponent(file)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

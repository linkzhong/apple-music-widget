import Foundation

/// 歌词获取。
///
/// Apple Music 流媒体曲目的歌词属于授权内容，AppleScript 的 `lyrics` 字段永远是空的
/// （实测返回 missing value），MusicKit 也不开放。所以只能拿 Music.app 给出的
/// 「歌名 + 歌手 + 时长」去公共歌词库里匹配同一首歌。
enum LyricsService {

    static func fetch(title: String, artist: String, album: String, duration: Double) async -> Lyrics? {
        guard !title.isEmpty else { return nil }

        // 一律先问网易云：中文曲库本来就它最全，而英文歌它还带官方中文译文 ——
        // LRCLIB 只有原文。网易云没有的再退回 LRCLIB。
        let providers: [() async -> Lyrics?] = [
            { await netease(title, artist, duration) },
            { await lrclib(title, artist, album, duration) },
        ]

        for provider in providers {
            if let result = await provider(), !result.isEmpty {
                return result
            }
        }
        return nil
    }

    // MARK: - LRCLIB（开源歌词库，无需 key）

    private static func lrclib(_ title: String, _ artist: String, _ album: String, _ duration: Double) async -> Lyrics? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.queryItems = [
            .init(name: "track_name", value: title),
            .init(name: "artist_name", value: artist),
            .init(name: "album_name", value: album),
            .init(name: "duration", value: String(Int(duration.rounded()))),
        ]
        if let hit = await lrclibRequest(comps.url, title: title, artist: artist, duration: duration) {
            return hit
        }

        // 精确匹配没中，退回模糊搜索
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [
            .init(name: "track_name", value: title),
            .init(name: "artist_name", value: artist),
        ]
        guard let url = search.url, let data = await get(url, headers: ["User-Agent": userAgent]) else { return nil }
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        // 和网易云一样按同一套规则打分，光看"时长最接近"会挑到别的录音版本
        let scored: [(Double, String)] = items.compactMap { item in
            guard let synced = item["syncedLyrics"] as? String, !synced.isEmpty else { return nil }
            let score = matchScore(
                candidateTitle: item["trackName"] as? String ?? "",
                candidateArtists: [item["artistName"] as? String ?? ""],
                candidateDuration: item["duration"] as? Double ?? 0,
                title: title, artist: artist, duration: duration
            )
            return (score, synced)
        }
        guard let best = scored.max(by: { $0.0 < $1.0 }), best.0 >= matchThreshold else { return nil }

        let lines = parseLRC(best.1)
        return lines.isEmpty ? nil : Lyrics(lines: lines, source: "LRCLIB")
    }

    private static func lrclibRequest(_ url: URL?, title: String, artist: String,
                                      duration: Double) async -> Lyrics? {
        guard let url, let data = await get(url, headers: ["User-Agent": userAgent]) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let synced = obj["syncedLyrics"] as? String, !synced.isEmpty else { return nil }
        // 精确查询也要复核一遍返回的是不是同一个录音
        let score = matchScore(
            candidateTitle: obj["trackName"] as? String ?? title,
            candidateArtists: [obj["artistName"] as? String ?? artist],
            candidateDuration: obj["duration"] as? Double ?? duration,
            title: title, artist: artist, duration: duration
        )
        guard score >= matchThreshold else { return nil }
        let lines = parseLRC(synced)
        return lines.isEmpty ? nil : Lyrics(lines: lines, source: "LRCLIB")
    }

    // MARK: - 网易云（中文曲库）

    private static func netease(_ title: String, _ artist: String, _ duration: Double) async -> Lyrics? {
        let headers = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
            "Referer": "https://music.163.com",
        ]

        var comps = URLComponents(string: "https://music.163.com/api/search/get/web")!
        comps.queryItems = [
            .init(name: "s", value: "\(title) \(artist)"),
            .init(name: "type", value: "1"),
            .init(name: "limit", value: "12"),
        ]
        guard let url = comps.url, let data = await get(url, headers: headers) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else { return nil }

        // 网易云的搜索排序不看时长也不看版本，得自己挑
        var bestID: Int?
        var bestScore = -Double.infinity
        for song in songs {
            guard let id = song["id"] as? Int,
                  let name = song["name"] as? String else { continue }
            let secs = (song["duration"] as? Double ?? 0) / 1000
            let artists = (song["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []

            let score = matchScore(candidateTitle: name, candidateArtists: artists,
                                   candidateDuration: secs,
                                   title: title, artist: artist, duration: duration)
            if score > bestScore { bestScore = score; bestID = id }
        }

        // 分数不够说明只是碰巧搜到点东西，宁可不显示也别挂错的
        guard let songID = bestID, bestScore >= matchThreshold else { return nil }

        var lyricComps = URLComponents(string: "https://music.163.com/api/song/lyric")!
        lyricComps.queryItems = [
            .init(name: "id", value: String(songID)),
            .init(name: "lv", value: "1"),
            .init(name: "kv", value: "1"),
            .init(name: "tv", value: "-1"),
        ]
        guard let lyricURL = lyricComps.url, let lyricData = await get(lyricURL, headers: headers) else { return nil }
        guard let lyricObj = try? JSONSerialization.jsonObject(with: lyricData) as? [String: Any],
              let lrc = (lyricObj["lrc"] as? [String: Any])?["lyric"] as? String else { return nil }

        var lines = parseLRC(lrc)
        guard !lines.isEmpty else { return nil }

        // 同一个响应里就带着官方中文译文，顺手贴上
        if let tlyric = (lyricObj["tlyric"] as? [String: Any])?["lyric"] as? String, !tlyric.isEmpty {
            lines = attach(translation: parseLRC(tlyric), to: lines)
        }
        return Lyrics(lines: lines, source: "网易云")
    }

    // MARK: - LRC 解析

    /// `[mm:ss.xx]文本`，一行可能挂多个时间标签
    static func parseLRC(_ raw: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let pattern = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)

        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let pattern else { continue }

            let ns = line as NSString
            let matches = pattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }   // [ar:] [ti:] 这类元数据行没有时间戳，自动跳过

            // 时间标签之后剩下的才是文本
            let textStart = matches.last!.range.location + matches.last!.range.length
            let text = ns.substring(from: textStart).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var fraction = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let digits = ns.substring(with: m.range(at: 3))
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                out.append(LyricLine(time: minutes * 60 + seconds + fraction, text: text))
            }
        }

        var lines = out.sorted { $0.time < $1.time }
        // 署名永远排在最前面，所以只从头往下剥，碰到正经歌词就停 ——
        // 这样「最后一曲：…」这种正文里带冒号的句子不会被误伤
        while let first = lines.first, lines.count > 1, isCreditLine(first.text) {
            lines.removeFirst()
        }
        return lines
    }

    /// 把译文按时间戳贴回原文行。
    /// 网易云的 tlyric 和原文时间戳基本对齐，偶尔有零点几秒出入，所以取最近的一条。
    private static func attach(translation: [LyricLine], to lines: [LyricLine]) -> [LyricLine] {
        guard !translation.isEmpty else { return lines }
        var result = lines
        for i in result.indices {
            let t = result[i].time
            guard let match = translation.min(by: { abs($0.time - t) < abs($1.time - t) }),
                  abs(match.time - t) < 0.6,
                  !match.text.isEmpty else { continue }
            result[i].translation = match.text
        }
        return result
    }

    /// 网易云的 LRC 开头会带一串制作人员署名，而且**同样带时间戳**，
    /// 不滤掉的话小组件会把「作曲 : 某某」当成第一句歌词高亮出来。
    private static let creditKeywords = [
        "作词", "作曲", "编曲", "制作人", "制作", "监制", "出品", "发行", "录音",
        "混音", "母带", "吉他", "贝斯", "鼓", "键盘", "和声", "弦乐", "策划",
        "统筹", "企划", "词", "曲", "op", "sp", "producer", "composer",
        "lyricist", "arranger", "mixed", "mastered", "recorded", "written",
    ]

    private static func isCreditLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let sep = trimmed.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        // 冒号前面那截必须很短才算署名 —— 否则「他说：…」这种正经歌词会被误伤
        let head = trimmed[trimmed.startIndex..<sep].trimmingCharacters(in: .whitespaces)
        guard head.count <= 8 else { return false }
        return creditKeywords.contains { head == $0 || head.hasSuffix($0) }
    }

    // MARK: - 工具

    /// 从曲名里认出这是哪一版录音。
    ///
    /// 这件事必须单独判：同一首歌的现场版和录音室版能差几十秒，而歌词的时间戳
    /// 是跟着**具体那次录音**走的 —— 版本认错，整首歌从头到尾都对不上。
    private static func versionTags(_ s: String) -> Set<String> {
        let t = s.lowercased()
        var tags: Set<String> = []
        let table: [(String, [String])] = [
            ("live", ["live", "现场", "現場", "演唱会", "演唱會"]),
            ("acoustic", ["acoustic", "不插电", "不插電"]),
            ("remix", ["remix", "remixed", "混音"]),
            ("instrumental", ["instrumental", "伴奏", "karaoke"]),
            ("cover", ["cover", "翻自", "翻唱"]),
        ]
        for (tag, keys) in table where keys.contains(where: { t.contains($0) }) {
            tags.insert(tag)
        }
        return tags
    }

    /// 判断候选和当前曲目是不是同一个录音。够分才认，否则宁可不显示。
    private static func matchScore(candidateTitle: String, candidateArtists: [String],
                                   candidateDuration: Double,
                                   title: String, artist: String, duration: Double) -> Double {
        // 时长是最硬的判据：对不上就是另一个录音，后面再像也没意义
        let delta = abs(candidateDuration - duration)
        guard delta < 8 else { return -100 }

        var score = 0.0
        if delta < 1.5 { score += 4 } else if delta < 4 { score += 2 }

        let a = normalize(candidateTitle), b = normalize(title)
        if a == b { score += 3 } else if a.contains(b) || b.contains(a) { score += 1.5 }

        let arts = candidateArtists.map(normalize)
        let target = normalize(artist)
        if arts.contains(target) { score += 2 }
        else if arts.contains(where: { $0.contains(target) || target.contains($0) }) { score += 1 }

        // 版本标记必须完全一致，差一个就基本判死
        score += (versionTags(title) == versionTags(candidateTitle)) ? 1 : -4
        return score
    }

    /// 认定为同一录音的分数线
    private static let matchThreshold = 6.0

    private static let userAgent = "AppleMusicWidget/1.0 (macOS; personal use)"

    private static func get(_ url: URL, headers: [String: String]) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// 比较用的归一化：小写、去空白、去掉括号里的一切修饰。
    /// 版本差异不靠这里区分，交给 `versionTags` —— 那是个独立且更硬的判据。
    private static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: #"[\(（\[【].*?[\)）\]】]"#, with: "",
                                   options: .regularExpression)
        for marker in [" - single", " - ep", " feat.", " ft."] {
            if let r = t.range(of: marker) { t = String(t[t.startIndex..<r.lowerBound]) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
    }
}

extension String {
    var containsCJK: Bool {
        unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)      // 常用汉字
            || (0x3400...0x4DBF).contains($0.value)   // 扩展 A
            || (0x3040...0x30FF).contains($0.value)   // 日文假名
            || (0xAC00...0xD7AF).contains($0.value)   // 谚文
        }
    }
}

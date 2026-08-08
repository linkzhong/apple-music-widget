import Foundation
import AppKit
import ImageIO

/// 封面获取。
///
/// Apple Music 的流媒体曲目和歌词一样，封面也不给 AppleScript 读
/// （`raw data` 报 Can't get、`data` 报 Parameter error），只有本地导入的文件能直接取到。
/// 所以流媒体曲目走 iTunes Search —— 这是 Apple 自己的公开接口，
/// 拿到的就是 Apple Music 里的同一张图。
enum ArtworkService {

    /// 缓存文件名。
    ///
    /// 按**专辑**存而不是按曲目：同一张专辑的每首歌本来就是同一张封面，
    /// 按曲目存的话连着听一张专辑，每换一首都要重新跑一趟网络，
    /// 封面就总是慢半拍才出来。
    static func cacheName(artist: String, album: String, trackID: String) -> String {
        let base = "\(artist)|\(album)".trimmingCharacters(in: .whitespaces)
        guard base.count > 1 else { return "\(trackID).png" }
        // 用固定算法而不是 hashValue —— 后者带随机种子，每次启动都变，缓存全废
        var hash: UInt64 = 5381
        for byte in base.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return "al\(String(hash, radix: 36)).png"
    }

    /// 下载并落盘，返回 App Group 里的文件名和封面主色
    static func fetch(title: String, artist: String, album: String,
                      duration: Double, trackID: String) async -> (file: String, color: [Double]?)? {
        let name = cacheName(artist: artist, album: album, trackID: trackID)
        // 之前下过就别再跑一趟网络
        if let url = SharedStore.artworkPath(name),
           let cached = try? Data(contentsOf: url) {
            return (name, dominantColor(from: cached))
        }
        guard let remote = await lookupArtworkURL(title: title, artist: artist, duration: duration) else {
            return nil
        }
        guard let (data, _) = try? await URLSession.shared.data(from: remote) else { return nil }
        guard let png = downscaledPNG(from: data, maxSide: 320) else { return nil }
        guard let saved = save(png, as: name) else { return nil }
        return (saved, dominantColor(from: png))
    }

    /// 在 iTunes 曲库里找这首歌，用时长兜底避免匹配到翻唱/现场版
    private static func lookupArtworkURL(title: String, artist: String, duration: Double) async -> URL? {
        guard duration > 0 else { return nil }

        // Apple Music 的简繁体和 feat. 署名常和 iTunes 元数据对不上，
        // 所以名字只用来缩小范围，最终由时长拍板。
        let queries = ["\(title) \(artist)", title]
        // iTunes Search 默认只查美区，中国区独占的歌在那儿搜不到，按曲目语言决定先问谁
        let countries = (title.containsCJK || artist.containsCJK) ? ["cn", "us"] : ["us", "cn"]

        // 最可能命中的两个组合并发发出去，省掉一次串行等待 ——
        // 封面晚出来一秒都很明显
        async let first = search(query: queries[0], country: countries[0], duration: duration)
        async let second = search(query: queries[0], country: countries[1], duration: duration)
        if let hit = await first { return hit }
        if let hit = await second { return hit }

        // 带歌手搜不到，再退回只用歌名
        for country in countries {
            if let hit = await search(query: queries[1], country: country, duration: duration) {
                return hit
            }
        }

        // iTunes 里确实没有（国内独占的歌居多），退回网易云
        return await neteaseArtwork(title: title, artist: artist, duration: duration)
    }

    /// 网易云兜底。
    ///
    /// 不拿它当主源有两个原因：一是 iTunes 返回的就是 Apple Music 里的**同一张**封面，
    /// 网易云可能是另一个发行版；二是实测网易云要多一次请求才能拿到图片地址
    /// （搜索结果里只有 picId，拼不出 URL），把国内 CDN 的速度优势吃掉了大半。
    /// 但 iTunes 搜不到的歌，有它总比没有强。
    private static func neteaseArtwork(title: String, artist: String, duration: Double) async -> URL? {
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
        guard let url = comps.url, let data = await get(url, headers: headers),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else { return nil }

        // 同样拿时长当判据，差太多就是另一个录音，封面也会跟着错
        var bestID: Int?
        var bestDelta = Double.infinity
        for song in songs {
            guard let id = song["id"] as? Int else { continue }
            let delta = abs((song["duration"] as? Double ?? 0) / 1000 - duration)
            if delta < bestDelta { bestDelta = delta; bestID = id }
        }
        guard let songID = bestID, bestDelta < 3 else { return nil }

        guard let detailURL = URL(string: "https://music.163.com/api/song/detail?ids=[\(songID)]"),
              let detailData = await get(detailURL, headers: headers),
              let detail = try? JSONSerialization.jsonObject(with: detailData) as? [String: Any],
              let list = detail["songs"] as? [[String: Any]],
              let album = list.first?["album"] as? [String: Any],
              let pic = album["picUrl"] as? String else { return nil }

        // 网易云的图链支持指定尺寸，不加参数会拿到 100 多 KB 的原图
        return URL(string: "\(pic)?param=320y320")
    }

    private static func get(_ url: URL, headers: [String: String]) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    private static func search(query: String, country: String, duration: Double) async -> URL? {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            .init(name: "term", value: query),
            .init(name: "entity", value: "song"),
            .init(name: "country", value: country),
            .init(name: "limit", value: "12"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return nil }

        let candidates = results.compactMap { item -> (Double, String)? in
            guard let art = item["artworkUrl100"] as? String else { return nil }
            let secs = (item["trackTimeMillis"] as? Double ?? 0) / 1000
            return (abs(secs - duration), art)
        }

        // 时长差 3 秒以内才认，否则宁可不显示也别挂错封面
        guard let best = candidates.min(by: { $0.0 < $1.0 }), best.0 < 3 else { return nil }
        return URL(string: preferredSize(best.1))
    }

    /// mzstatic 的地址把尺寸段换掉就能取别的分辨率。
    ///
    /// 取 300 而不是 600：小组件最大也就 155pt，@2x 屏上是 310 像素，600 的图纯属浪费 ——
    /// 体积大概是 300 的四倍，换歌后要多等好几秒封面才出得来。
    private static func preferredSize(_ urlString: String) -> String {
        urlString.replacingOccurrences(of: "/100x100bb.", with: "/300x300bb.")
    }

    // MARK: - 落盘

    static func save(_ png: Data, as name: String) -> String? {
        SharedStore.prepare()
        guard let url = SharedStore.artworkPath(name) else { return nil }
        do {
            try png.write(to: url, options: .atomic)
            SharedStore.pruneArtwork(keepingNewest: 30)
            return name
        } catch {
            return nil
        }
    }

    // MARK: - 主色

    /// 取封面的代表色，给小组件当背景氛围用。
    /// 按饱和度加权，并且把过暗、过亮的像素排除掉 —— 否则整张会平均成一坨灰。
    static func dominantColor(from data: Data) -> [Double]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        var rSum = 0.0, gSum = 0.0, bSum = 0.0, weight = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let luma = 0.299 * r + 0.587 * g + 0.114 * b
            guard luma > 0.12, luma < 0.94 else { continue }
            let maxC = max(r, g, b), minC = min(r, g, b)
            let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
            let w = 0.2 + saturation * 1.6      // 越鲜艳越有代表性
            rSum += r * w; gSum += g * w; bSum += b * w; weight += w
        }
        guard weight > 0 else { return nil }
        return [rSum / weight, gSum / weight, bSum / weight]
    }

    /// 用 ImageIO 直接出缩略图，比先解码整张原图省内存 ——
    /// 小组件进程的内存额度很小，塞原图会被系统直接杀掉。
    static func downscaledPNG(from data: Data, maxSide: CGFloat) -> Data? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            }
        }
        // ImageIO 认不出来的老格式退回 NSImage
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

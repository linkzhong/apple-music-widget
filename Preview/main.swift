// 离屏预览：拿小组件真正在用的那份视图代码，渲染成 PNG。
// 这样调视觉不用反复往桌面上加删小组件。
//
// 用法：MusicWidgetPreview <输出目录> [封面图路径]
import AppKit
import SwiftUI
import WidgetKit

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "."
let artworkPath: String? = args.count > 2 ? args[2] : nil

// macOS 小组件的实际点尺寸
let sizes: [(name: String, family: WidgetFamily, size: CGSize)] = [
    ("small", .systemSmall, CGSize(width: 155, height: 155)),
    ("medium", .systemMedium, CGSize(width: 329, height: 155)),
]

func makeEntry(at seconds: Double) -> MusicEntry {
    var state = PlayerState.sample
    state.position = seconds
    state.sampledAt = Date()
    if let artworkPath, let data = try? Data(contentsOf: URL(fileURLWithPath: artworkPath)) {
        state.artworkColor = ArtworkPreviewColor.dominant(from: data)
    }

    let lyrics = Lyrics.sample
    var entry = MusicEntry(date: Date(), state: state)
    entry.artworkPath = artworkPath

    let current = lyrics.index(at: seconds)
    var start = max(0, (current ?? 0) - 1)
    if start + 7 > lyrics.lines.count { start = max(0, lyrics.lines.count - 7) }
    let range = start..<min(lyrics.lines.count, start + 7)
    entry.lyricWindow = range.map { lyrics.lines[$0].text }
    entry.currentInWindow = current.map { $0 - start }
    if let current { entry.currentTranslation = lyrics.lines[current].translation }
    return entry
}

@MainActor
func render(_ item: (name: String, family: WidgetFamily, size: CGSize), entry: MusicEntry) {
    // 不补 padding —— 小组件那边已经用 contentMarginsDisabled 关掉系统边距，
    // 留白由各个布局自己控制
    let view = NowPlayingWidgetView(entry: entry, familyOverride: item.family)
        .frame(width: item.size.width, height: item.size.height)
        .clipShape(RoundedRectangle(cornerRadius: item.size.width * 0.11, style: .continuous))

    let renderer = ImageRenderer(content: view)
    renderer.scale = 3
    guard let cg = renderer.cgImage else {
        FileHandle.standardError.write("渲染失败: \(item.name)\n".data(using: .utf8)!)
        return
    }
    let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("preview_\(item.name).png")
    try? png?.write(to: url)
    print(url.path)
}

// 用三种歌名各渲染一次，专门验证按钮位置会不会跟着歌名变
let titles = [("short", "Die For You"),
              ("long", "Running Up That Hill (A Deal With God)"),
              ("cjk", "到处不存在的我")]
for (tag, t) in titles {
    var e = makeEntry(at: 43)
    e.state.title = t
    MainActor.assumeIsolated {
        let view = NowPlayingWidgetView(entry: e, familyOverride: .systemSmall)
            .frame(width: 155, height: 155)
        let r = ImageRenderer(content: view)
        r.scale = 3
        if let cg = r.cgImage {
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            let u = URL(fileURLWithPath: outDir).appendingPathComponent("btn_\(tag).png")
            try? png?.write(to: u)
            print(u.path)
        }
    }
}

// 取 43 秒这个点：正好落在第三句歌词上
let entry = makeEntry(at: 43)
for item in sizes {
    MainActor.assumeIsolated { render(item, entry: entry) }
}

/// 预览工具自己算一份主色 —— 它读不到 App Group（那是宿主 App 写的）
enum ArtworkPreviewColor {
    static func dominant(from data: Data) -> [Double]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 32,
              ] as CFDictionary) else { return nil }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var r = 0.0, g = 0.0, b = 0.0, w = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let pr = Double(pixels[i]) / 255, pg = Double(pixels[i + 1]) / 255, pb = Double(pixels[i + 2]) / 255
            let luma = 0.299 * pr + 0.587 * pg + 0.114 * pb
            guard luma > 0.12, luma < 0.94 else { continue }
            let maxC = max(pr, pg, pb), minC = min(pr, pg, pb)
            let sat = maxC > 0 ? (maxC - minC) / maxC : 0
            let weight = 0.2 + sat * 1.6
            r += pr * weight; g += pg * weight; b += pb * weight; w += weight
        }
        guard w > 0 else { return nil }
        return [r / w, g / w, b / w]
    }
}

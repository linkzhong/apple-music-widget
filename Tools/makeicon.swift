// 生成 App 图标：Apple Music 风格的红粉渐变圆角方 + 白色音符
// 用法：swift Tools/makeicon.swift <输出目录>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let side: CGFloat = 1024

let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()

// macOS 图标四周留白，图形本体约占 82%
let inset = side * 0.09
let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let radius = rect.width * 0.2237   // Apple 的 squircle 近似值

NSGraphicsContext.current?.saveGraphicsState()
let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
shape.addClip()

NSGradient(colors: [
    NSColor(srgbRed: 0.99, green: 0.35, blue: 0.47, alpha: 1),
    NSColor(srgbRed: 0.95, green: 0.13, blue: 0.31, alpha: 1),
])!.draw(in: rect, angle: -90)

// 左上角一道柔光，避免整块死板
NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
    .draw(in: rect, relativeCenterPosition: NSPoint(x: -0.35, y: 0.6))

NSGraphicsContext.current?.restoreGraphicsState()

// 中间的音符
let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.52, weight: .medium)
if let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    NSColor.white.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceOver)
    symbol.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
    tinted.unlockFocus()

    let target = NSRect(
        x: rect.midX - tinted.size.width / 2,
        y: rect.midY - tinted.size.height / 2,
        width: tinted.size.width,
        height: tinted.size.height
    )
    // 音符下方带点阴影，和背景拉开层次
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.shadowBlurRadius = rect.width * 0.05
    shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.015)
    shadow.set()
    tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.current?.restoreGraphicsState()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("图标渲染失败\n".data(using: .utf8)!)
    exit(1)
}

let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon_1024.png")
try! png.write(to: url)
print(url.path)

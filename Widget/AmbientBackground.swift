import SwiftUI

/// Apple Music 那种流动色场背景。
///
/// 做法是照着 Apple Music 本体的思路来的：它并**不是**从封面里提取几个主色再排成渐变，
/// 而是把封面本身复制好几份、各自缩放旋转叠在一起，最后统一强模糊 + 过饱和 ——
/// 让封面自己糊成一片色场。这样什么封面都不会失手，比取色方案自然得多。
///
/// 各层的角度是**写死的常数**，不跟播放进度走。
/// 试过让它慢慢流动，但小组件只能在时间线推进时重绘，几秒一跳的"流动"
/// 在边缘会被眼睛抓成一条抖动的竖带 —— 与其动得不优雅，不如干脆定住。
struct AmbientBackground: View {
    let artwork: Image?
    /// 没有封面时的兜底色
    let accent: Color
    /// 上面压多重的黑，纯歌词那种大字需要更暗的底才压得住
    var dimming: Double = 0.55

    var body: some View {
        GeometryReader { geo in
            // 模糊半径必须跟着尺寸走。小组件才 329×155，固定用大半径会把整块糊成
            // 一个平均色，色块层次全丢了。
            let blurRadius = min(geo.size.width, geo.size.height) * 0.19
            // 先在四周放出一圈再模糊，最后裁回来。
            // `blur(opaque:)` 会把内容边缘的像素往外拉，图层要是正好裁在容器边上，
            // 四边就会各留一条色带 —— 而且图层角度一变，那条带跟着动。
            let bleed = blurRadius * 2.4
            let canvas = CGSize(width: geo.size.width + bleed * 2,
                                height: geo.size.height + bleed * 2)

            ZStack {
                if let artwork {
                    Color.black
                    layers(artwork, in: canvas)
                        .frame(width: canvas.width, height: canvas.height)
                        .blur(radius: blurRadius, opaque: true)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .saturation(1.7)      // Apple Music 也会把封面调得更艳
                } else {
                    LinearGradient(colors: [accent.mixedWithBlack(0.3), accent.mixedWithBlack(0.7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }

                LinearGradient(colors: [.black.opacity(dimming * 0.4), .black.opacity(dimming)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    /// 主层不旋转、铺满，负责定住整体色调 —— 副本再怎么转都不会把颜色带跑偏；
    /// 上面两层旋转的副本只是加点色彩流动。
    private func layers(_ image: Image, in size: CGSize) -> some View {
        ZStack {
            copy(image, in: size, scale: 1.7, rotation: 0, x: 0, y: 0, opacity: 1)
            copy(image, in: size, scale: 1.1, rotation: 135, x: -0.2, y: 0.16, opacity: 0.5)
            copy(image, in: size, scale: 0.75, rotation: -55, x: 0.22, y: -0.18, opacity: 0.42)
        }
    }

    private func copy(_ image: Image, in size: CGSize, scale: CGFloat, rotation: Double,
                      x: CGFloat, y: CGFloat, opacity: Double) -> some View {
        let side = max(size.width, size.height)
        return image
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: side * scale, height: side * scale)
            .rotationEffect(.degrees(rotation))
            .offset(x: size.width * x, y: size.height * y)
            .opacity(opacity)
            // 收回容器尺寸再裁掉，免得旋转后的空角混进模糊里带出脏色
            .frame(width: size.width, height: size.height)
            .clipped()
    }
}

extension Color {
    /// 往黑里调 —— 主色直接铺满会太艳，白字压不住
    func mixedWithBlack(_ amount: Double) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return Color(red: Double(ns.redComponent) * (1 - amount),
                     green: Double(ns.greenComponent) * (1 - amount),
                     blue: Double(ns.blueComponent) * (1 - amount))
    }
}

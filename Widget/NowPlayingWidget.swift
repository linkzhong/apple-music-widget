import WidgetKit
import SwiftUI
import AppIntents
import AppKit

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Shared.widgetKind, provider: MusicProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Apple Music")
        .description("小尺寸是封面加播放控制，中尺寸是整块歌词。")
        .supportedFamilies([.systemSmall, .systemMedium])
        // 关掉系统默认的内容边距，封面才能真正铺满到边；各布局自己控制留白
        .contentMarginsDisabled()
    }
}

// MARK: - 主视图

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    let entry: MusicEntry
    /// 只有离屏预览工具会传 —— `\.widgetFamily` 是只读环境值，没法从外面塞
    var familyOverride: WidgetFamily?

    private var family: WidgetFamily { familyOverride ?? environmentFamily }
    private var state: PlayerState { entry.state }
    /// 离屏预览时为 false —— ImageRenderer 渲染不了 timerInterval 那类自更新视图
    private var usesLiveTimers: Bool { familyOverride == nil }

    var body: some View {
        if usesLiveTimers {
            content.containerBackground(for: .widget) { background }
        } else {
            // 离屏预览拿不到小组件容器，直接铺同一份背景
            content.background(background)
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if !entry.hostAlive {
                MessageView(symbol: "bolt.horizontal.circle", title: "后台没在运行",
                            detail: "打开「Apple Music 小组件」App 后就会恢复")
            } else if !state.hasTrack {
                MessageView(symbol: "music.note",
                            title: state.kind == .notRunning ? "「音乐」未运行" : "没有正在播放",
                            detail: "点一下打开「音乐」")
            } else if family == .systemSmall {
                coverSmall
            } else {
                lyricsOnly
            }
        }
        .widgetURL(URL(string: "musicwidget://open"))
    }

    // MARK: 小尺寸 —— 整张专辑封面铺到边，底部压暗放歌名和控制键

    /// 尺寸全部按容器高度取百分比，不写死点数。
    /// 小组件的实际画布并不等于文档上的 155×155（各系统版本、各摆放位置都可能不同），
    /// 写死点数的话留白和按钮的比例就会跟着画布漂 —— 之前按钮贴底就是这么来的。
    private var coverSmall: some View {
        GeometryReader { geo in
            let u = geo.size.height        // 基准单位

            ZStack(alignment: .bottom) {
                Group {
                    if let artwork {
                        artwork.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Rectangle().fill(.white.opacity(0.08))
                            Image(systemName: "music.note")
                                .font(.system(size: u * 0.22))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()

            // 压得够狠白字才站得住 —— 浅色封面上尤其明显。
            // 起点压到 0.38 之后，封面的主体部分基本不受影响。
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.34),
                    .init(color: .black.opacity(0.36), location: 0.54),
                    .init(color: .black.opacity(0.78), location: 0.74),
                    .init(color: .black.opacity(0.94), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )

                VStack(spacing: u * 0.055) {
                    Text(state.title)
                        .font(.system(size: u * 0.098, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.55), radius: u * 0.02, y: u * 0.007)
                        .frame(maxWidth: .infinity)
                    controlRow(unit: u)
                }
                .padding(.horizontal, u * 0.07)
                // 底部留白约等于 2/3 个「下一首」键 —— 再多按钮就显得往上飘了
                .padding(.bottom, u * 0.13)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func controlRow(unit u: CGFloat) -> some View {
        HStack(spacing: u * 0.07) {
            ControlButton(intent: PreviousTrackIntent(), symbol: "backward.fill",
                          diameter: u * 0.19, glyph: u * 0.079)
            ControlButton(intent: PlayPauseIntent(),
                          symbol: state.isPlaying ? "pause.fill" : "play.fill",
                          diameter: u * 0.245, glyph: u * 0.105, prominent: true)
            ControlButton(intent: NextTrackIntent(), symbol: "forward.fill",
                          diameter: u * 0.19, glyph: u * 0.079)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 中尺寸 —— 只有歌词

    private var lyricsOnly: some View {
        GeometryReader { geo in
            let u = geo.size.height        // 同样按容器取比例，不写死点数

            Group {
                if entry.hasLyrics {
                    scrollingLyrics(unit: u, width: geo.size.width)
                } else {
                    VStack(spacing: 0) {
                        Text(entry.lyricsMissing ? "没找到这首的歌词" : "正在查找歌词…")
                            .font(.system(size: u * 0.09))
                            .foregroundStyle(.white.opacity(0.35))
                        Text(state.title)
                            .font(.system(size: u * 0.078))
                            .foregroundStyle(.white.opacity(0.22))
                            .lineLimit(1)
                            .padding(.top, u * 0.026)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// 会滚动的歌词。
    ///
    /// 每一行都常驻在 ZStack 里，位置用 offset 表达 —— 当前行永远在 y=0，
    /// 其余按行距上下排开。换句时只有 `current` 变了，于是所有行的 offset、
    /// 字号、透明度一起变，系统在时间线切换的瞬间把这些变化补成动画，
    /// 看到的就是整块歌词平滑上滚。
    ///
    /// 关键是 **id 必须用全曲行号**（`windowStart + i`）：窗口往下滑一格时，
    /// 同一句歌词的身份不能变，否则系统认不出"这句从下面移上来了"，
    /// 只会把整块内容淡入淡出掉。
    private func scrollingLyrics(unit u: CGFloat, width: CGFloat) -> some View {
        let current = entry.currentInWindow ?? 0
        let started = entry.currentInWindow != nil
        let hasTranslation = entry.currentTranslation != nil
        // 译文自己占一行，下面就少铺一句
        let below = hasTranslation ? 1 : 2
        let lower = max(0, current - 1)
        let upper = min(entry.lyricWindow.count - 1, current + below)
        // 用 VStack 让高度自己排 —— 当前句可能占两行，固定槽位会压到上一句头上
        let rows = (lower...max(lower, upper)).map {
            (id: entry.windowStart + $0, distance: $0 - current, text: entry.lyricWindow[$0])
        }

        // 所有行共用一个基础字号，主次靠缩放区分。
        // 不能用 .font() 的大小差别 —— **字号不是可动画属性**，SwiftUI 不会补间，
        // 那句从下面推上来时位置在平滑移动、字号却「啪」地跳一下，
        // 看着就像旧的消失、新的凭空出现。scaleEffect 才补得出「边推边长大」。
        let baseSize = u * (hasTranslation ? 0.138 : 0.145)
        let shrink = 0.66

        return VStack(spacing: u * (hasTranslation ? 0.03 : 0.036)) {
            ForEach(rows, id: \.id) { row in
                let isCurrent = started && row.distance == 0

                VStack(spacing: u * 0.022) {
                    Text(row.text)
                        // 所有行共用一个字重。weight 和 size 一样不可动画，
                        // 当前句切过来时它补不出过渡，会在动画跑完那一刻硬粗一下。
                        // 主次已经由缩放和不透明度表达，不差这一档。
                        .font(.system(size: baseSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(opacity(forDistance: row.distance, started: started)))
                        .lineLimit(isCurrent ? 2 : 1)
                        .minimumScaleFactor(0.5)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if isCurrent, let translation = entry.currentTranslation {
                        Text(translation)
                            .font(.system(size: baseSize * 0.68, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .multilineTextAlignment(.center)
                    }
                }
                .scaleEffect(isCurrent ? 1 : shrink, anchor: .center)
                // 缩放不改变布局占位，多出来的空隙用负 padding 收回来
                .padding(.vertical, isCurrent ? 0 : -baseSize * (1 - shrink) * 0.62)
                .frame(maxWidth: .infinity)
                // 只有真正新进/移出窗口的那句才走 transition，
                // 留在窗口里的靠上面的位移和缩放动画
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: u * 0.14)),
                    removal: .opacity.combined(with: .offset(y: -u * 0.14))
                ))
            }
        }
        .padding(.horizontal, u * 0.08)
        .frame(width: width, height: u, alignment: .center)
        .clipped()
        // 时间线推进导致 current 变化时，让系统把这些变化补成动画。
        // 靠的是上面 ForEach 用全曲行号当 id：窗口滑动时留下来的那几句身份不变，
        // 系统才认得出"这句从下面移上来了"，而不是把整块重画一遍。
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: entry.windowStart + current)
    }

    /// 离当前句越远越淡；还没开唱时整体压暗，只把第一句提亮一点
    private func opacity(forDistance distance: Int, started: Bool) -> Double {
        guard started else { return distance == 0 ? 0.44 : 0.2 }
        switch abs(distance) {
        case 0: return 1
        case 1: return 0.36
        case 2: return 0.2
        default: return 0.1
        }
    }

    // MARK: - 封面与背景

    private var artwork: Image? {
        guard let path = entry.artworkPath,
              let image = NSImage(contentsOfFile: path) else { return nil }
        return Image(nsImage: image)
    }

    /// 封面主色，宿主 App 算好放在状态里；没有就退回一个中性的酒红。
    /// 会把饱和度提一提 —— 灰扑扑的封面直接拿来铺背景就是一团脏灰。
    private var accentColor: Color {
        guard let rgb = state.artworkColor, rgb.count == 3,
              let base = NSColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
                  .usingColorSpace(.sRGB) else {
            return Color(red: 0.62, green: 0.22, blue: 0.28)
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(NSColor(hue: h,
                             saturation: min(max(s * 1.55, 0.42), 0.86),
                             brightness: min(max(b, 0.46), 0.72),
                             alpha: 1))
    }

    /// 纯歌词那一屏字最大，底要压得更狠才读得清。
    /// 封面版小尺寸自己就铺满了封面，底不用再画。
    private var background: some View {
        AmbientBackground(
            artwork: artwork,
            accent: accentColor,
            dimming: family == .systemMedium ? 0.62 : 0.5
        )
    }
}

// MARK: - 控制按钮

private struct ControlButton<I: AppIntent>: View {
    let intent: I
    let symbol: String
    var diameter: CGFloat = 28
    var glyph: CGFloat = 12
    var prominent: Bool = false
    var tint: Color = .white

    var body: some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: diameter, height: diameter)
                .background { glass }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// 手绘的玻璃质感。
    ///
    /// 没用 macOS 26 的 `glassEffect` —— 那个 API 要实时采样背后的画面才能折射，
    /// 而小组件是离屏静态渲染的，拿不到 backdrop：实测下来不但玻璃没出现，
    /// 连它底下的填充都被一起吃掉，按钮只剩一个裸图标。
    ///
    /// 所以这里按玻璃的成分自己画：半透明的体积 + 上亮下暗的边（玻璃厚度）
    /// + 顶部一道高光（光源反射）+ 一点外阴影（浮在封面上方）。
    private var glass: some View {
        Circle()
            .fill(.white.opacity(prominent ? 0.26 : 0.17))
            .overlay(
                // 上缘受光、下缘背光，这条边是"有厚度"的关键
                Circle().strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.62), location: 0.0),
                            .init(color: .white.opacity(0.18), location: 0.45),
                            .init(color: .white.opacity(0.30), location: 1.0),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: max(0.6, diameter * 0.024)
                )
            )
            .overlay(
                // 顶部那道反光
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.38), .clear],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: diameter * 0.58, height: diameter * 0.28)
                    .offset(y: -diameter * 0.23)
                    .blur(radius: diameter * 0.05)
            )
            .shadow(color: .black.opacity(0.28), radius: diameter * 0.1, y: diameter * 0.045)
    }
}

// MARK: - 空状态

private struct MessageView: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.55))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

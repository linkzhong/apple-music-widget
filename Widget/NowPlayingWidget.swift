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

            VStack(spacing: 0) {
                if entry.hasLyrics, let current = entry.currentInWindow {
                    // 上一句 + 当前句（放大）+ 未来两句
                    if let above = line(at: current - 1) {
                        lyricLine(above, size: u * 0.095, opacity: 0.32)
                            .padding(.bottom, u * 0.042)
                    }

                    // 有译文时原文让出一点字号，给下面那行中文腾地方
                    let translation = entry.currentTranslation
                    Text(line(at: current) ?? "")
                        .font(.system(size: u * (translation == nil ? 0.145 : 0.126), weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        // 换句时让系统做个淡入淡出，别硬切
                        .id(current)
                        .transition(.opacity)

                    if let translation {
                        Text(translation)
                            .font(.system(size: u * 0.088, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, u * 0.024)
                    }

                    if let next1 = line(at: current + 1) {
                        lyricLine(next1, size: u * 0.095, opacity: 0.36)
                            .padding(.top, u * 0.042)
                    }
                    // 译文占掉一行，再摆第四句就挤了
                    if translation == nil, let next2 = line(at: current + 2) {
                        lyricLine(next2, size: u * 0.095, opacity: 0.22)
                            .padding(.top, u * 0.03)
                    }
                } else if entry.hasLyrics {
                    // 前奏，还没唱到第一句。
                    // 这里要把开头几句都摆出来 —— 只显示一句暗字的话，
                    // 遇上《山海》那种二十几秒的前奏，看着就像没匹配到歌词。
                    ForEach(Array(entry.lyricWindow.prefix(3).enumerated()), id: \.offset) { i, text in
                        lyricLine(text, size: u * 0.095, opacity: i == 0 ? 0.44 : 0.24)
                            .padding(.top, i == 0 ? 0 : u * 0.04)
                    }
                } else {
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
            // 四边留一样的边距，整块在正中间
            .padding(u * 0.1)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func lyricLine(_ text: String, size: CGFloat, opacity: Double) -> some View {
        Text(text)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white.opacity(opacity))
            .lineLimit(1)
            .truncationMode(.tail)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private func line(at index: Int) -> String? {
        entry.lyricWindow.indices.contains(index) ? entry.lyricWindow[index] : nil
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

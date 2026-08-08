# Apple Music 小组件（macOS）

Apple 在 macOS 上给 Podcast 做了小组件，却没给「音乐」做。这个项目补上。

| | |
|:--|:--|
| <img src="docs/preview_small.png" width="300"> | <img src="docs/preview_medium.png" width="620"> |
| **小尺寸**：整张专辑封面铺到边，底部放歌名和播放控制 | **中尺寸**：只有歌词。上一句 + 当前句（放大）+ 未来两句 |

- 播放状态、封面、进度、播放控制全部来自 **Apple Music 本体**
- 歌词跟着播放走，自动匹配
- 封面来自 Apple 官方的 iTunes 接口，和 Apple Music 里是同一张

## 安装

需要 macOS 14+、Xcode、以及 [xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

```bash
git clone <这个仓库>
cd apple-music-widget

# 换成你自己的 Apple Developer Team ID
Tools/set-team-id.sh ABCDE12345

xcodegen generate
xcodebuild -project AppleMusicWidget.xcodeproj -scheme MusicWidgetHost \
  -configuration Release -derivedDataPath build build

cp -R build/Build/Products/Release/MusicWidgetHost.app "/Applications/Apple Music 小组件.app"
open "/Applications/Apple Music 小组件.app"
```

必须装到 `/Applications`，系统才扫得到里面的小组件。首次运行会请求「控制"音乐"」的权限，必须允许。

然后在桌面空白处点右键 →「编辑小组件」→ 找到「Apple Music」→ 拖到桌面上。

**菜单栏那个 App 要一直开着**，关掉小组件就停在最后状态不再更新。建议在它菜单里打开「开机时自动启动」。

## 为什么需要一个后台 App

小组件必须跑在沙箱里，沙箱进程不能给「音乐」发 Apple Event —— 读不到播放状态，更控制不了播放。所以是这个结构：

```
  Music.app
     ↑ Apple Event（读状态 / 控制播放）
  宿主 App（菜单栏，非沙箱）
     ↓ 写 state.json / lyrics.json / 封面
  App Group 共享容器  ← 只有这里能穿透沙箱
     ↓ 读
  小组件（沙箱）
     ↓ 按钮：把指令写回共享容器 + 发通知叫醒宿主 App
```

## 数据从哪来

| 数据 | 来源 |
|---|---|
| 播放状态、歌名、歌手、专辑、进度、喜欢 | Music.app（AppleScript） |
| 播放控制 | Music.app（AppleScript） |
| 封面（本地文件曲目） | Music.app，`raw data of artwork` 直接读 |
| 封面（流媒体曲目） | iTunes Search API（Apple 官方），网易云兜底 |
| 歌词 | 网易云 / LRCLIB |

### 歌词和流媒体封面为什么要外部来源

Apple Music 的歌词和流媒体曲目封面都是**授权内容**，Apple 不通过任何公开接口开放：

- `lyrics` 属性在 AppleScript 字典里存在，但对流媒体曲目返回 `missing value`
  （只有自己导入的 mp3/m4a 的 ID3 歌词标签才有值）
- `raw data of artwork` 对流媒体曲目报 `Can't get…`，`data` 报 `Parameter error`

所以只能拿 Music 给出的**歌名 + 歌手 + 时长**去公共库匹配同一首歌。

**匹配必须认版本，不能只看名字像不像。** 同一首歌的现场版和录音室版能差几十秒，而歌词时间戳是跟着**具体那次录音**走的，版本认错整首都对不上。所以规则是：时长差 8 秒以上直接否决；从曲名认出 live / 不插电 / 混音 / 伴奏 / 翻唱等标记，原曲和候选必须完全一致。分数不够就宁可不显示 —— 挂一整首对不上的歌词比空着更糟。

## 一些实现上的取舍

**关掉系统内容边距**（`.contentMarginsDisabled()`）。否则封面铺不到边，四周留一圈。留白改由各布局自己控制。

**尺寸全部按容器高度取百分比，不写死点数。** 小组件的实际画布并不等于文档上的 155×155，写死点数的话留白和按钮的比例会跟着画布漂 —— 表现就是按钮贴底。

**背景是封面自己糊出来的。** 照 Apple Music 本体的思路：不提取主色排渐变，而是把封面复制几份各自缩放旋转叠起来，强模糊 + 过饱和。取色方案遇到灰调封面会糊成一坨脏灰，这个不会。两个细节：模糊半径按尺寸自适应（写死会把整块糊成一个平均色）；模糊前要在四周放出一圈再裁回来，否则 `blur(opaque:)` 会把内容边缘的像素往外拉，四边各留一条色带。

**背景各层的角度是写死的常数，不跟播放进度走。** 试过让它流动，但小组件只能在时间线推进时重绘，几秒一跳的"流动"在边缘会被眼睛抓成一条抖动的竖带。

**歌词时间线整体提前 0.6 秒。** 系统在时间点到了之后重绘不是即时的，实测会晚半秒到一秒。判断"当前是第几句"时用同样的偏移，两边必须一致。

**封面按专辑缓存，不按曲目。** 同一张专辑的每首歌本来就是同一张封面，按曲目存的话连着听一张专辑每换一首都要重新跑网络。哈希用固定算法而不是 `hashValue` —— 后者带随机种子，每次启动都变，缓存全废。

**封面只下 300×300。** 小组件最大 155pt，@2x 屏上是 310 像素，600 的图体积是四倍，纯粹让人多等。

**按钮点下去先乐观更新。** 指令绕一圈回来约 300ms，先让界面自己变，真实状态回来后覆盖。

**指令走双通道**：分布式通知（快）+ 共享目录文件监听（保险）。沙箱会丢掉通知的 userInfo，所以指令内容始终放在文件里。

**署名行要从歌词里剥掉。** 网易云的 LRC 开头那几行制作人员信息**同样带时间戳**，不滤会被当成第一句歌词高亮出来。只从开头连续地剥，碰到正经歌词就停，免得误伤正文里带冒号的句子。

## 为什么没有黑胶唱片

做过，最后删了，原因值得记下来。

**小组件里做不出连续动画。** WidgetKit 的小组件不是持续渲染的视图，而是「静态快照 + 定时替换」—— 渲染完一帧进程就被挂起。`.repeatForever`、`withAnimation`、`TimelineView(.animation)` 统统不跑；唯一能动的 `Text(timerInterval:)` / `ProgressView(timerInterval:)` 只能驱动文字和进度条，绑不到 `rotationEffect` 上。靠时间线硬推的话每 3 秒重绘一次，唱片就是一格一格跳。

这不是能力问题：这个品类做得最好的 [Vinyl for Mac](https://www.vinylformac.com/) 是悬浮窗 App；App Store 上那些黑胶小组件（MD Vinyl、VinylPod、MS Vinyl）的旋转全发生在**打开 App 之后**的界面里，连收费做到品类第一的 MD Vinyl 都有用户反馈「点开 App 能看到唱片转，但小组件本身不转」。

中途试过改成悬浮窗，`TimelineView(.animation)` 确实能 60fps 真转，但浮在桌面上会和图标、壁纸搅在一起，显得乱、没有秩序感；小组件在系统的格子里排列，整体性好得多。于是退回小组件、接受不能动。

而不能动的黑胶就没有存在理由了：155pt 的画布里唱片直径只剩 92pt、中心封面 34pt，认不出是哪张专辑，沟槽和唱臂的质感在这个尺寸下也看不清 —— 等于把细节全做进了一个看不见细节的画布。换成整张封面铺满，反而是把唱片公司设计好的作品完整呈现出来。

## 关于液态玻璃

小组件能不能是半透明的玻璃？能，但开关不在代码里 —— 在**系统设置 → 外观 → 「图标与小组件样式」→「透明」**。那是全局设置，会一起影响所有图标和小组件。

代码这边要配合的是：**不要画自己的不透明背景**，否则会盖掉系统给的玻璃。macOS 26 的 `glassEffect` API 在这里靠不住 —— 它要实时采样背后的画面才能折射，而小组件是离屏静态渲染的，拿不到 backdrop：实测不但玻璃没出现，连它底下的填充都被一起吃掉，按钮只剩一个裸图标。控制键的玻璃质感因此是手绘的：半透明的体积 + 上亮下暗的描边（玻璃厚度）+ 顶部反光 + 外阴影。

## 调视觉用的离屏预览

改样式最烦的是看不见效果 —— 得反复往桌面上加删小组件。项目里带了个预览工具，用**小组件同一份视图代码**把两个尺寸渲染成 PNG：

```bash
xcodebuild -project AppleMusicWidget.xcodeproj -scheme MusicWidgetPreview \
  -configuration Release -derivedDataPath build build
./build/Build/Products/Release/MusicWidgetPreview <输出目录> [封面图路径]
```

两个已知差异，都只影响预览、不影响真实小组件：

- `containerBackground` 是 WidgetKit 专有的，预览里改用普通 `.background`
- `ProgressView` / `Text` 的 `timerInterval` 版本底层是 AppKit 控件，`ImageRenderer` 渲染不出来（会画成一条黄色警示条），预览里换成自绘的静态条

视图靠 `familyOverride` 区分这两种场景：真实小组件不传，预览工具传。

**调深浅两种封面很重要** —— 底部那层压暗的渐变必须在浅色封面（白字容易糊）和深色封面（容易压成一团黑）两个极端下都成立。

## 改完小组件看不到变化？

`chronod`（macOS 渲染桌面小组件的进程）会缓存旧的 extension，光替换 App 不生效：

```bash
lsregister -f "/Applications/Apple Music 小组件.app"
pkill -f MusicWidgetExtension
killall chronod
```

`lsregister` 的完整路径在
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/`。

## 已知限制

- 后台 App 不运行时小组件不更新（会显示提示，点一下能把它拉起来）
- 冷门歌、或者 Apple Music 独有的现场版本，可能匹配不到歌词或封面
- 歌词有固定偏移时无法自动对齐：LRC 的时间戳是按公共曲库那版音频打的，和 Apple Music 的版本如果开头静音长度不同，会整首差一个固定值
- 桌面被全屏窗口盖住时小组件不刷新，这是 macOS 的行为

## License

MIT

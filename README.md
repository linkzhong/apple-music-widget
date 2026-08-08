# Apple Music Widget for macOS

[English](README.md) · [简体中文](README.zh-CN.md)

Apple ships a Podcasts widget on macOS but never made one for Music. This fills the gap —
and is **the first to make lyrics scroll smoothly inside a real WidgetKit widget**, something
widgets are widely believed to be incapable of.

<img src="docs/demo.gif" width="820">

| | |
|:--|:--|
| <img src="docs/preview_small.png" width="300"> | <img src="docs/preview_medium.png" width="620"> |
| **Small** — full-bleed album art, title and transport controls | **Medium** — lyrics only, current line scaled up, with Chinese translation for English songs |

## What it does

- **Smoothly scrolling synced lyrics** — lines glide up and scale into place, at full frame
  rate, in a native desktop widget
- **Chinese translation for English songs**, rendered under the original line
- **Real-time playback state** — title, artist, album, artwork, all straight from Music.app
- **Playback controls** in the widget — previous / play-pause / next, no app switch
- **Artwork from Apple's own iTunes endpoint**, so it's the exact image Apple Music shows

### On the scrolling

Plenty of projects show synced lyrics on macOS. Every one we could find renders them **in a
window**, not in a widget:

| Project | Form | Where the scrolling happens |
|---|---|---|
| [Canopy](https://github.com/6gx42o/Canopy) | notch media player | custom SwiftUI window |
| [LyricGlow](https://github.com/ateymoori/lyricglow) | Electron | always-on-top window |
| [Vinyl for Mac](https://www.vinylformac.com/) | floating turntable | window |
| [Lyrics-Widget](https://github.com/hamedafra/Lyrics-Widget) | Notification Center | legacy widget |

That's not a coincidence. The received wisdom is that widgets can't animate, so everyone who
wanted motion built a window instead — this project went down that road too, and came back.

(If you know of a WidgetKit widget that does this, open an issue and the claim gets corrected.)

The received wisdom is half right. Widgets genuinely cannot run *continuous* animation — the
process is suspended after each frame. But when the timeline advances, the system **does**
interpolate between the old and new state at full frame rate. Lyric scrolling has a natural
trigger on every line, so it fits that second category exactly. Two things make it work, and
both are easy to get wrong — details in [Notes from building this](#notes-from-building-this).

Everything about playback comes from Music.app itself. Only lyrics and streaming-track
artwork come from elsewhere, and there's a hard reason for that — see below.

## Install

Requires macOS 14+, Xcode, and [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
git clone https://github.com/linkzhong/apple-music-widget
cd apple-music-widget

# Set your own Apple Developer Team ID
Tools/set-team-id.sh ABCDE12345

xcodegen generate
xcodebuild -project AppleMusicWidget.xcodeproj -scheme MusicWidgetHost \
  -configuration Release -derivedDataPath build build

cp -R build/Build/Products/Release/MusicWidgetHost.app "/Applications/Apple Music Widget.app"
open "/Applications/Apple Music Widget.app"
```

It **must** live in `/Applications` — that's where the system scans for widget extensions.
On first launch it asks for permission to control Music; you have to allow it.

Then right-click the desktop → **Edit Widgets** → find **Apple Music** → drop it on the desktop.

**Keep the menu bar app running.** Close it and the widget freezes on its last state.
Turn on "Launch at login" from its menu.

## Why there's a background app

Widgets are sandboxed, and a sandboxed process cannot send Apple Events to Music.app —
it can't read playback state, let alone control it. Hence this shape:

```
  Music.app
     ↑ Apple Events (read state / control playback)
  Host app (menu bar, non-sandboxed)
     ↓ writes state.json / lyrics.json / artwork
  App Group container   ← the only thing that crosses the sandbox
     ↓ reads
  Widget (sandboxed)
     ↓ buttons: write command back to the container + post a notification to wake the host
```

## Where the data comes from

| Data | Source |
|---|---|
| Playback state, title, artist, album, progress | Music.app (AppleScript) |
| Playback control | Music.app (AppleScript) |
| Artwork — local files | Music.app, `raw data of artwork` |
| Artwork — streaming tracks | iTunes Search API (Apple's own), NetEase as fallback |
| Lyrics | NetEase Cloud Music / LRCLIB |

### Why lyrics and streaming artwork need an outside source

Apple Music's lyrics and streaming-track artwork are **licensed content**, and Apple exposes
neither through any public interface:

- The `lyrics` property exists in Music's AppleScript dictionary but returns `missing value`
  for streaming tracks (it only carries ID3 lyrics from files you imported yourself)
- `raw data of artwork` fails with `Can't get…` on streaming tracks, and `data` returns
  `Parameter error`

So the only path is to take the **title + artist + duration** that Music does give us and
match the same song against public catalogues.

**Matching must identify the recording, not just the name.** A live version and a studio
version of the same song differ by tens of seconds, and lyric timestamps are tied to
*that specific recording* — get the version wrong and the whole song is out of sync. The rules:
a duration gap of 8s or more is an outright reject; version tags parsed from the title
(live / acoustic / remix / instrumental / cover) must match exactly. If the score doesn't
clear the bar, nothing is shown — a full song of wrong lyrics is worse than none.

## Notes from building this

The non-obvious things, kept here because they cost real time to find.

**Widgets can't do continuous animation, but they *can* do transitions.** A widget isn't a
continuously rendering view — it's "static snapshot + scheduled replacement", and the process
is suspended after each frame. `.repeatForever`, `withAnimation` and `TimelineView(.animation)`
simply don't run. But when the timeline advances, the system **does** interpolate between the
old and new state at full frame rate. Lyric scrolling lives in that second category, which is
why it's smooth.

**To get the scroll, every line needs a stable identity across the window.** Use the
song-wide line number as the `ForEach` id — not the index within the visible window. When the
window slides down by one, the lines that stay must keep the same id, otherwise the system
can't tell "this line moved up from below" and falls back to cross-fading the whole block.

**Font size and weight are not animatable.** Making the current line bigger via `.font()`
produces a hard jump mid-transition — position glides while the type snaps, which reads as
"the old line vanished and a new one appeared". Emphasis has to come from `scaleEffect` and
`opacity`, both of which interpolate. This bites twice: size first, then weight, showing up as
a "it gets slightly bolder half a second later" artifact.

**Size everything as a fraction of the container, never in fixed points.** The real widget
canvas is not the documented 155×155, so hardcoded padding drifts relative to the artwork —
the symptom is controls sitting flush against the bottom edge.

**The background is the artwork blurring itself.** Following what Apple Music actually does:
not extracting dominant colours into a gradient, but layering several scaled and rotated copies
of the cover, then heavily blurring and oversaturating. Colour-extraction turns muddy on
desaturated covers; this doesn't. Two details: the blur radius must scale with the container
(a fixed radius flattens the whole thing into one average colour), and the layers need to bleed
past the edges before blurring, or `blur(opaque:)` drags edge pixels outward and leaves a band
along all four sides.

**Shift the lyric timeline 0.6s early.** The system doesn't repaint exactly at the entry's
timestamp — measured lag is half a second to a second. Apply the same offset when deciding
which line is current; the two must agree.

**Cache artwork per album, not per track.** Every track on an album shares one cover; keying by
track means re-fetching for every song. Use a fixed hash algorithm, not `hashValue` — that one
is seeded randomly per launch and silently invalidates the whole cache.

**Fetch 300×300 artwork.** The widget is 155pt at most — 310 pixels on a 2× display. A 600px
image is four times the bytes for zero visible gain.

**Strip credit lines from lyrics.** NetEase's LRC files open with composer/arranger credits that
**also carry timestamps**, so they get treated as the first line of the song. Strip only
consecutively from the top and stop at the first real lyric, or you'll catch legitimate lines
that happen to contain a colon.

**Show several lines during a long intro.** Some songs don't start singing for 25 seconds.
Rendering a single dim line during that window looks exactly like "no lyrics found".

## Why there's no spinning vinyl

It was built, then removed. Worth recording why.

A vinyl record can't actually spin in a widget — see the animation note above. Driving it from
the timeline means repainting every 3 seconds, which reads as stepping, not spinning.

This isn't a skill issue. The best product in that category,
[Vinyl for Mac](https://www.vinylformac.com/), is a floating window app. The vinyl widgets on
the App Store (MD Vinyl, VinylPod, MS Vinyl) all do their spinning **inside the app** after you
open it — MD Vinyl, the paid category leader, has users reporting exactly that: the record spins
in the app but not in the widget.

A floating-window version was built too. `TimelineView(.animation)` genuinely gives 60fps there,
but a window floating over the desktop tangles with icons and wallpaper — it looks cluttered,
while widgets sit in the system's grid and stay tidy. So: back to a widget, accept no motion.

And a vinyl that doesn't spin has no reason to exist at 155pt — the disc is only 92pt across,
the centre label 34pt, too small to recognise the album, and the groove and tonearm detail is
invisible at that size. Full-bleed artwork puts the label's own design on screen instead.

## About Liquid Glass

Can the widget be translucent glass? Yes, but the switch isn't in the code — it's in
**System Settings → Appearance → "Icon & widget style" → Clear**. That's a global setting that
affects every icon and widget.

What the code must do is **not paint an opaque background of its own**, or it covers the glass
the system provides. macOS 26's `glassEffect` API is not usable here: it needs to sample what's
behind it in real time, and a widget renders offscreen with no backdrop. In practice not only
does the glass fail to appear, the fill underneath it gets eaten too, leaving a bare icon. The
glass look on the transport buttons is therefore hand-drawn: translucent body, light-to-dark rim
(that rim is what sells the thickness), a highlight along the top, and an outer shadow.

## Offscreen preview tool

Iterating on widget visuals is miserable — you have to keep adding and removing it from the
desktop. There's a preview tool that renders both sizes to PNG using **the widget's own view code**:

```bash
xcodebuild -project AppleMusicWidget.xcodeproj -scheme MusicWidgetPreview \
  -configuration Release -derivedDataPath build build
./build/Build/Products/Release/MusicWidgetPreview <output-dir> [cover-image]
```

Two known differences, both preview-only:

- `containerBackground` is WidgetKit-specific; the preview uses a plain `.background`
- The `timerInterval` flavours of `ProgressView` / `Text` are AppKit-backed and
  `ImageRenderer` can't draw them (you get a yellow warning bar) — the preview substitutes a
  hand-drawn static bar

The view distinguishes the two via `familyOverride`: unset in the real widget, set by the tool.

**Test against both a light and a dark cover** — the bottom scrim has to hold up when white text
sits on a pale sky and when a dark cover risks going pitch black.

## Widget not updating after a rebuild?

`chronod` (the process that renders desktop widgets) caches the old extension; replacing the app
isn't enough:

```bash
lsregister -f "/Applications/Apple Music Widget.app"
pkill -f MusicWidgetExtension
killall chronod
```

`lsregister` lives in
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/`.

## Limitations

- The widget stops updating when the host app isn't running (it says so, and clicking it brings
  the app back)
- Obscure tracks, or live versions unique to Apple Music, may match no lyrics or artwork
- A constant lyric offset can't be corrected automatically: LRC timestamps follow the public
  catalogue's master, and if Apple Music's version has a different amount of leading silence,
  the whole song is off by a fixed amount
- Widgets don't refresh while the desktop is covered by a fullscreen window — that's macOS

## Related projects

Same itch, different shapes — all of them windows rather than widgets, which is exactly the
point made at the top:

- [Canopy](https://github.com/6gx42o/Canopy) — notch media player with synced lyrics, rendered
  in a custom SwiftUI window
- [LyricGlow](https://github.com/ateymoori/lyricglow) — Electron always-on-top lyric window
- [Vinyl for Mac](https://www.vinylformac.com/) — photorealistic turntable, floating window
- [Lyrics-Widget](https://github.com/hamedafra/Lyrics-Widget) — Notification Center widget

This one is a native WidgetKit desktop widget with smooth scrolling, prioritises Chinese
catalogues for lyrics, and carries Chinese translations for English songs.

## License

MIT

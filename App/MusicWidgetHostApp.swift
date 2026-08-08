import SwiftUI
import AppKit
import ServiceManagement
import WidgetKit

@main
struct MusicWidgetHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var coordinator = Coordinator.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(coordinator: coordinator)
        } label: {
            // 播放时图标带声波，一眼能看出后台在不在跑
            Image(systemName: coordinator.state.isPlaying ? "music.note.list" : "music.note")
        }
        .menuBarExtraStyle(.menu)

        Window("使用说明", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - 菜单

private struct MenuContent: View {
    @ObservedObject var coordinator: Coordinator
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        if coordinator.permissionDenied {
            Text("⚠️ 未获得控制「音乐」的权限")
            Button("打开系统设置授权…") { LoginItem.openAutomationSettings() }
            Divider()
        } else {
            Text(statusLine)
            if !coordinator.state.artist.isEmpty {
                Text(coordinator.state.artist)
            }
            Divider()
        }

        Button(coordinator.state.isPlaying ? "暂停" : "播放") { coordinator.perform(.playPause) }
        Button("下一首") { coordinator.perform(.next) }
        Button("上一首") { coordinator.perform(.previous) }
        Divider()

        Button("打开「音乐」") { coordinator.perform(.activateMusic) }
        Button(lyricsMenuTitle) { coordinator.refetchLyrics() }
        Button("刷新小组件") {
            coordinator.refresh(force: true)
            WidgetCenter.shared.reloadAllTimelines()
        }
        Divider()

        Toggle("开机时自动启动", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, value in LoginItem.set(value) }
        Button("怎么把小组件放到桌面…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "help")
        }
        Divider()

        Button("退出") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch coordinator.state.kind {
        case .notRunning: return "「音乐」未运行"
        case .stopped: return "没有正在播放的曲目"
        case .playing, .paused:
            let mark = coordinator.state.isPlaying ? "▶︎" : "❚❚"
            return "\(mark) \(coordinator.state.title)"
        }
    }

    private var lyricsMenuTitle: String {
        if coordinator.lyrics.missing { return "重新查找歌词（这首没找到）" }
        if coordinator.lyrics.isEmpty { return "查找歌词" }
        return "重新查找歌词（来源：\(coordinator.lyrics.source)）"
    }
}

// MARK: - 使用说明

private struct HelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("把小组件放到桌面")
                .font(.title2.bold())

            step("1", "让这个 App 保持在菜单栏运行（关掉它小组件就不会更新了）")
            step("2", "在桌面空白处点右键 → 选「编辑小组件」")
            step("3", "在左侧列表里找到「Apple Music 小组件」")
            step("4", "把它拖到桌面上，或者直接点一下")

            Divider()

            Text("也可以放在通知中心：点菜单栏右上角的时间打开通知中心，拉到最底下点「编辑小组件」。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("三种尺寸：小 = 黑胶唱片；中 = 整块歌词；大 = 完整播放器加滚动歌词。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("打开桌面小组件设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n)
                .font(.caption.bold())
                .frame(width: 18, height: 18)
                .background(Circle().fill(.tint.opacity(0.18)))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 登录项

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("[MusicWidget] 设置登录项失败: \(error.localizedDescription)")
        }
    }

    static func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏 App，不进 Dock、不抢焦点
        NSApp.setActivationPolicy(.accessory)
        SharedStore.prepare()
        // 首次运行在这里触发「自动化」授权弹窗
        MusicBridge.shared.requestAutomationPermission()
        Coordinator.shared.start()
    }

    /// 小组件上非按钮区域点下去会打开 musicwidget://open，
    /// 顺带也保证了宿主 App 没运行时点一下就能把它拉起来。
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "musicwidget" }) else { return }
        Coordinator.shared.perform(.activateMusic)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

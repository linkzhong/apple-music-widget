import AppIntents
import Foundation

/// 小组件跑在沙箱进程里，没法直接给 Music.app 发 Apple Event，
/// 所以按钮做的事是：把指令写进 App Group，再敲一下宿主 App 让它立刻来取。
enum WidgetCommandSender {
    static func send(_ command: MusicCommand) {
        SharedStore.enqueue(command)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(Shared.commandNotification),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        applyOptimistic(command)
    }

    /// 指令绕一圈回来大概 300ms，这段时间先让界面自己变，不然点下去像没反应。
    /// 宿主 App 采到真实状态后会覆盖掉这里的猜测。
    private static func applyOptimistic(_ command: MusicCommand) {
        var state = SharedStore.loadState()
        guard state.hasTrack else { return }
        let now = Date()
        switch command {
        case .playPause:
            state.position = state.position(at: now)
            state.sampledAt = now
            state.kind = state.isPlaying ? .paused : .playing
        case .toggleLove:
            state.loved.toggle()
        default:
            return   // 上/下一首猜不出结果，老实等真实状态
        }
        SharedStore.save(state: state)
    }
}

struct PlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "播放或暂停"
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        WidgetCommandSender.send(.playPause)
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "下一首"
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        WidgetCommandSender.send(.next)
        return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "上一首"
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        WidgetCommandSender.send(.previous)
        return .result()
    }
}

struct ToggleLoveIntent: AppIntent {
    static var title: LocalizedStringResource = "喜欢"
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        WidgetCommandSender.send(.toggleLove)
        return .result()
    }
}

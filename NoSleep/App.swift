import SwiftUI

@main
struct NoSleepApp: App {
    @StateObject private var sleepManager = SleepManager()

    init() {
        Self.configureDefaultMenuBarPositionIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(sleepManager: sleepManager)
        } label: {
            MenuBarStatusLabel(sleepManager: sleepManager)
        }
        .menuBarExtraStyle(.window)
    }

    /// 首次启动未手动拖拽图标时，将 SwiftUI MenuBarExtra 默认状态项（Item-0）
    /// 的首选位置设置在靠近右侧系统图标的区域（距右边缘约 150pt）。
    /// 用户之后通过 ⌘ + 拖动 自定义的位置会自动覆盖并持久保留。
    private static func configureDefaultMenuBarPositionIfNeeded() {
        let key = "NSStatusItem Preferred Position Item-0"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(150.0, forKey: key)
        }
    }
}

private struct MenuBarStatusLabel: View {
    @ObservedObject var sleepManager: SleepManager

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: sleepManager.currentSymbolName)
            if let text = sleepManager.menuBarText {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(sleepManager.isActive ? "NoSleep 已启用防休眠" : "NoSleep 未启用")
    }
}

import SwiftUI

@main
struct NoSleepApp: App {
    @StateObject private var sleepManager = SleepManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(sleepManager: sleepManager)
        } label: {
            MenuBarStatusLabel(sleepManager: sleepManager)
        }
        .menuBarExtraStyle(.window)
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

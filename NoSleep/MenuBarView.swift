import AppKit
import SwiftUI

/// 菜单栏弹出面板视图，紧凑布局并消除重复设置项，全部交互均在沙盒内原生生效。
struct MenuBarView: View {
    @ObservedObject var sleepManager: SleepManager

    private enum PanelPage {
        case main
        case about
    }

    private enum ExpandedSection {
        case minutes
        case hours
        case custom
        case preferences
    }

    @State private var currentPage: PanelPage = .main
    @State private var expandedSection: ExpandedSection?

    @State private var customInputMode: Int = 0 // 0: 按时长, 1: 直到指定时间
    @State private var customHours: Int = 0
    @State private var customMinutes: Int = 45
    @State private var targetTime: Date = Date().addingTimeInterval(3600)

    private static let minutePresets: [(label: String, duration: SleepDuration)] = [
        ("5 分钟", .seconds(5 * 60)),
        ("15 分钟", .fifteenMinutes),
        ("30 分钟", .thirtyMinutes),
        ("45 分钟", .seconds(45 * 60))
    ]

    private static let hourPresets: [(label: String, duration: SleepDuration)] = [
        ("1 小时", .oneHour),
        ("2 小时", .twoHours),
        ("4 小时", .seconds(4 * 3600)),
        ("8 小时", .seconds(8 * 3600))
    ]

    var body: some View {
        Group {
            switch currentPage {
            case .main:
                mainPanel
            case .about:
                aboutPanel
            }
        }
        .frame(width: 276)
        .padding(.vertical, 5)
        .onAppear {
            sleepManager.refreshLaunchAtLoginStatus()
        }
    }

    // MARK: - 主面板

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionDetailsSection
            sectionDivider
            newSessionSection
            sectionDivider
            preferencesSection
            sectionDivider
            footerSection
        }
    }

    private var sessionDetailsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("当前会话详细信息:")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(sleepManager.sessionStatusText)
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(sleepManager.isActive ? .primary : .secondary)

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusIndicatorColor)
                        .frame(width: 6, height: 6)
                    Text(sleepManager.isActive ? sleepManager.mode.title : "空闲 · 系统按电源设置正常休眠")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 10)

            Toggle("在菜单栏显示倒计时", isOn: $sleepManager.showCountdownInMenuBar)
                .toggleStyle(MacCheckboxToggleStyle())
                .padding(.leading, 10)
                .padding(.top, 1)

            Button {
                if sleepManager.isActive {
                    sleepManager.stop()
                } else {
                    sleepManager.start(duration: .indefinite)
                }
            } label: {
                Text(sleepManager.isActive ? "结束当前会话" : "开启无限期会话")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(SessionActionButtonStyle(isActive: sleepManager.isActive))
            .padding(.leading, 10)
            .padding(.top, 1)

            if let errorMessage = sleepManager.lastErrorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.leading, 10)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var newSessionSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("开启新会话:")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 1)

            MenuActionRow(
                title: "无限期",
                shortcutText: "⌘I",
                isIndented: true
            ) {
                startSession(.indefinite)
            }
            .keyboardShortcut("i", modifiers: .command)

            MenuActionRow(
                title: "分钟",
                trailingSymbol: expandedSection == .minutes ? "chevron.down" : "play.fill",
                isIndented: true,
                isExpanded: expandedSection == .minutes
            ) {
                toggleExpanded(.minutes)
            }

            if expandedSection == .minutes {
                presetSubmenu(items: Self.minutePresets)
            }

            MenuActionRow(
                title: "小时",
                trailingSymbol: expandedSection == .hours ? "chevron.down" : "play.fill",
                isIndented: true,
                isExpanded: expandedSection == .hours
            ) {
                toggleExpanded(.hours)
            }

            if expandedSection == .hours {
                presetSubmenu(items: Self.hourPresets)
            }

            MenuActionRow(
                title: "其他时间/直到...",
                shortcutText: "⌘O",
                isIndented: true,
                isExpanded: expandedSection == .custom
            ) {
                toggleExpanded(.custom)
            }
            .keyboardShortcut("o", modifiers: .command)

            if expandedSection == .custom {
                customTimerCard
            }
        }
        .padding(.vertical, 1)
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            MenuActionRow(
                title: "偏好设置",
                trailingSymbol: expandedSection == .preferences ? "chevron.down" : "play.fill",
                isExpanded: expandedSection == .preferences
            ) {
                toggleExpanded(.preferences)
            }

            if expandedSection == .preferences {
                preferencesCard
            }
        }
        .padding(.vertical, 1)
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            MenuActionRow(title: "关于 NoSleep") {
                expandedSection = nil
                currentPage = .about
            }

            sectionDivider

            MenuActionRow(title: "关闭 NoSleep", shortcutText: "⌘Q") {
                sleepManager.stop()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.vertical, 1)
    }

    // MARK: - 内联子菜单与偏好设置面板

    private func presetSubmenu(items: [(label: String, duration: SleepDuration)]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(items, id: \.label) { item in
                MenuActionRow(
                    title: item.label,
                    isCheckmarked: sleepManager.isActive && sleepManager.activeDuration == item.duration,
                    leadingPadding: 34
                ) {
                    startSession(item.duration)
                }
            }
        }
        .padding(.vertical, 1)
    }

    private var customTimerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $customInputMode) {
                Text("指定时长").tag(0)
                Text("直到时间").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if customInputMode == 0 {
                HStack(spacing: 10) {
                    Stepper("\(customHours) 时", value: $customHours, in: 0...24)
                    Stepper("\(customMinutes) 分", value: $customMinutes, in: 0...59)
                }
                .font(.system(size: 12))
            } else {
                HStack {
                    Text("结束时刻:")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    DatePicker("", selection: $targetTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
            }

            HStack {
                Spacer()
                Button("开启定时会话") {
                    startCustomSession()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(customInputMode == 0 && customHours == 0 && customMinutes == 0)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private var preferencesCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 3) {
                Text("防休眠级别")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker(
                    "",
                    selection: Binding(
                        get: { sleepManager.mode },
                        set: { sleepManager.setMode($0) }
                    )
                ) {
                    ForEach(SleepPreventionMode.allCases) { mode in
                        Text(mode.shortTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("菜单栏图标")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: $sleepManager.iconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Toggle(
                    "开机自启动",
                    isOn: Binding(
                        get: { sleepManager.isLaunchAtLoginEnabled },
                        set: { sleepManager.setLaunchAtLogin($0) }
                    )
                )
                .toggleStyle(MacCheckboxToggleStyle())

                if sleepManager.launchAtLoginStatus == .requiresApproval {
                    Button {
                        sleepManager.openLoginItemsSettings()
                    } label: {
                        Text("需在「系统设置 → 登录项」中允许 ↗")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 22)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    // MARK: - 关于页面

    private var aboutPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    currentPage = .main
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("返回")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Spacer()

                Text("关于 NoSleep")
                    .font(.system(size: 12.5, weight: .semibold))

                Spacer()

                Color.clear.frame(width: 40, height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Image(systemName: sleepManager.iconStyle.activeSymbol)
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.accentColor.opacity(0.14))
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text("NoSleep")
                            .font(.system(size: 14, weight: .bold))
                        Text("v\(appVersion) · SwiftUI + IOKit.pwr_mgt")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 3) {
                    Text("底层电源管理状态")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("断言状态: \(sleepManager.isActive ? "已激活" : "未激活")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("断言类型: \(sleepManager.mode.assertionType as String)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let assertionID = sleepManager.activeAssertionID {
                        Text("IOPMAssertionID: \(assertionID)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("菜单栏提示: 按住 ⌘ 可自由拖动图标位置")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }

    // MARK: - 辅助方法

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.1"
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.vertical, 2)
    }

    private var statusIndicatorColor: Color {
        guard sleepManager.isActive else { return .secondary.opacity(0.6) }
        return sleepManager.allowDisplaySleep ? .orange : .green
    }

    private func toggleExpanded(_ section: ExpandedSection) {
        if expandedSection == section {
            expandedSection = nil
        } else {
            if section == .custom {
                targetTime = Date().addingTimeInterval(3600)
            }
            if section == .preferences {
                sleepManager.refreshLaunchAtLoginStatus()
            }
            expandedSection = section
        }
    }

    private func startSession(_ duration: SleepDuration) {
        sleepManager.start(duration: duration)
        expandedSection = nil
    }

    private func startCustomSession() {
        if customInputMode == 0 {
            let totalSeconds = customHours * 3600 + customMinutes * 60
            guard totalSeconds > 0 else { return }
            startSession(.seconds(totalSeconds))
        } else {
            let components = Calendar.current.dateComponents([.hour, .minute], from: targetTime)
            guard let hour = components.hour,
                  let minute = components.minute,
                  let duration = SleepDuration.until(hour: hour, minute: minute) else {
                return
            }
            startSession(duration)
        }
    }
}

// MARK: - 自定义菜单行与控件样式

private struct MenuActionRow: View {
    let title: String
    var shortcutText: String? = nil
    var trailingSymbol: String? = nil
    var isCheckmarked: Bool = false
    var isIndented: Bool = false
    var isExpanded: Bool = false
    var leadingPadding: CGFloat? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isCheckmarked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 11)
                }

                Text(title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)

                Spacer()

                if let shortcutText {
                    Text(shortcutText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(isHovered ? Color.white.opacity(0.85) : Color.secondary)
                }

                if let trailingSymbol {
                    Image(systemName: trailingSymbol)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(isHovered ? Color.white.opacity(0.9) : Color.secondary)
                }
            }
            .foregroundStyle(isHovered ? Color.white : Color.primary)
            .padding(.leading, resolvedLeadingPadding)
            .padding(.trailing, 12)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(rowBackground)
                    .padding(.horizontal, 5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var resolvedLeadingPadding: CGFloat {
        if let leadingPadding {
            return leadingPadding
        }
        return isIndented ? 22 : 12
    }

    private var rowBackground: Color {
        if isHovered {
            return Color.accentColor
        }
        if isExpanded {
            return Color.primary.opacity(0.08)
        }
        return .clear
    }
}

private struct MacCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .strokeBorder(
                                    configuration.isOn ? Color.accentColor : Color.primary.opacity(0.25),
                                    lineWidth: 1
                                )
                        )
                        .frame(width: 13, height: 13)

                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                configuration.label
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SessionActionButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isActive ? Color.primary : Color.white)
            .background(
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(isActive ? 0.16 : 0), lineWidth: 1)
                    )
            )
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isActive {
            return Color.primary.opacity(isPressed ? 0.22 : 0.14)
        }
        return Color.accentColor.opacity(isPressed ? 0.8 : 0.95)
    }
}

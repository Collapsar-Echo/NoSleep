import AppKit
import Foundation
import IOKit.pwr_mgt

/// 防休眠断言级别，对应 IOKit 电源管理断言类型。
enum SleepPreventionMode: String, CaseIterable, Identifiable, Sendable {
    /// 保持屏幕常亮：同时阻止显示器息屏与系统自动休眠。
    case keepDisplayAwake
    /// 仅保持系统运行：允许显示器按系统设置息屏，但阻止系统进入空闲休眠。
    case keepSystemAwake

    var id: String { rawValue }

    /// 对应的 IOKit 断言类型常量。
    var assertionType: CFString {
        switch self {
        case .keepDisplayAwake:
            return kIOPMAssertionTypeNoDisplaySleep as CFString
        case .keepSystemAwake:
            return kIOPMAssertionTypeNoIdleSleep as CFString
        }
    }

    var title: String {
        switch self {
        case .keepDisplayAwake:
            return "保持屏幕常亮"
        case .keepSystemAwake:
            return "仅保持系统运行（允许息屏）"
        }
    }

    var shortTitle: String {
        switch self {
        case .keepDisplayAwake:
            return "保持屏幕常亮"
        case .keepSystemAwake:
            return "允许显示器睡眠"
        }
    }

    var subtitle: String {
        switch self {
        case .keepDisplayAwake:
            return "阻止显示器关闭与系统自动休眠"
        case .keepSystemAwake:
            return "允许显示器息屏，保持后台任务运行"
        }
    }
}

/// 定时防休眠会话时长。
enum SleepDuration: Equatable, Hashable, Sendable {
    case indefinite
    case seconds(Int)

    static let fifteenMinutes = SleepDuration.seconds(15 * 60)
    static let thirtyMinutes = SleepDuration.seconds(30 * 60)
    static let oneHour = SleepDuration.seconds(60 * 60)
    static let twoHours = SleepDuration.seconds(2 * 60 * 60)

    /// 计算从当前时刻到目标时钟时间（时:分）的持续时长。
    /// 若目标时间早于或等于当前时间，则顺延至次日同一时刻。
    static func until(hour: Int, minute: Int, from now: Date = Date(), calendar: Calendar = .current) -> SleepDuration? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard var targetDate = calendar.date(from: components) else { return nil }
        if targetDate <= now {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: targetDate) else { return nil }
            targetDate = nextDay
        }
        let interval = Int(ceil(targetDate.timeIntervalSince(now)))
        return interval > 0 ? .seconds(interval) : nil
    }
}

/// 菜单栏状态图标风格。
enum MenuBarIconStyle: String, CaseIterable, Identifiable, Sendable {
    case bolt
    case coffee

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bolt:
            return "闪电图标"
        case .coffee:
            return "咖啡杯图标"
        }
    }

    var activeSymbol: String {
        switch self {
        case .bolt:
            return "bolt.fill"
        case .coffee:
            return "cup.and.saucer.fill"
        }
    }

    var inactiveSymbol: String {
        switch self {
        case .bolt:
            return "bolt.slash"
        case .coffee:
            return "cup.and.saucer"
        }
    }
}

/// IOKit 电源断言操作失败错误。
struct PowerAssertionError: Error, Equatable, Sendable {
    let code: IOReturn
}

/// 电源断言底层提供者协议，便于生产调用 IOKit 与单元测试注入 Mock。
protocol PowerAssertionProviding: Sendable {
    func createAssertion(type: CFString, name: CFString) -> Result<IOPMAssertionID, PowerAssertionError>
    func releaseAssertion(id: IOPMAssertionID) -> IOReturn
}

/// 基于 IOKit.pwr_mgt 的原生电源断言实现。
struct IOKitPowerAssertionProvider: PowerAssertionProviding {
    func createAssertion(type: CFString, name: CFString) -> Result<IOPMAssertionID, PowerAssertionError> {
        var assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        let status = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name,
            &assertionID
        )
        if status == kIOReturnSuccess {
            return .success(assertionID)
        }
        return .failure(PowerAssertionError(code: status))
    }

    func releaseAssertion(id: IOPMAssertionID) -> IOReturn {
        IOPMAssertionRelease(id)
    }
}

/// 线程安全的 IOPMAssertionID 守卫容器。
/// 所有断言的创建、替换与释放都在 NSLock 保护下原子完成，
/// 可在主线程、通知回调或 nonisolated deinit 中安全调用，防止电源断言泄漏或重复释放。
private final class AssertionGuard: @unchecked Sendable {
    private let lock = NSLock()
    private let provider: PowerAssertionProviding
    private var assertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)

    init(provider: PowerAssertionProviding) {
        self.provider = provider
    }

    func replaceAssertion(type: CFString, name: CFString) -> Result<IOPMAssertionID, PowerAssertionError> {
        lock.lock()
        defer { lock.unlock() }

        releaseLocked()

        switch provider.createAssertion(type: type, name: name) {
        case .success(let newID):
            assertionID = newID
            return .success(newID)
        case .failure(let error):
            assertionID = IOPMAssertionID(kIOPMNullAssertionID)
            return .failure(error)
        }
    }

    @discardableResult
    func releaseIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return releaseLocked()
    }

    var currentID: IOPMAssertionID? {
        lock.lock()
        defer { lock.unlock() }
        return assertionID == IOPMAssertionID(kIOPMNullAssertionID) ? nil : assertionID
    }

    @discardableResult
    private func releaseLocked() -> Bool {
        let nullID = IOPMAssertionID(kIOPMNullAssertionID)
        guard assertionID != nullID else { return false }
        let idToRelease = assertionID
        assertionID = nullID
        _ = provider.releaseAssertion(id: idToRelease)
        return true
    }
}

/// 核心防休眠状态机与 IOKit 电源断言管理器。
@MainActor
final class SleepManager: ObservableObject {
    private enum DefaultsKey {
        static let mode = "NoSleep.preventionMode"
        static let showCountdownInMenuBar = "NoSleep.showCountdownInMenuBar"
        static let iconStyle = "NoSleep.iconStyle"
    }

    private static let assertionName: CFString = "com.minglixiang.NoSleep.KeepAwake" as CFString

    @Published private(set) var isActive: Bool = false
    @Published private(set) var mode: SleepPreventionMode
    @Published private(set) var activeDuration: SleepDuration?
    @Published private(set) var endDate: Date?
    @Published private(set) var remainingSeconds: Int?
    @Published private(set) var activeAssertionID: IOPMAssertionID?
    @Published private(set) var lastErrorMessage: String?

    @Published var showCountdownInMenuBar: Bool {
        didSet {
            userDefaults.set(showCountdownInMenuBar, forKey: DefaultsKey.showCountdownInMenuBar)
        }
    }

    @Published var iconStyle: MenuBarIconStyle {
        didSet {
            userDefaults.set(iconStyle.rawValue, forKey: DefaultsKey.iconStyle)
        }
    }

    private let assertionGuard: AssertionGuard
    private let userDefaults: UserDefaults
    private let now: @Sendable () -> Date
    private var countdownTimer: Timer?
    private nonisolated(unsafe) var terminationObserver: NSObjectProtocol?

    init(
        provider: PowerAssertionProviding = IOKitPowerAssertionProvider(),
        userDefaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.assertionGuard = AssertionGuard(provider: provider)
        self.userDefaults = userDefaults
        self.now = now

        if let rawMode = userDefaults.string(forKey: DefaultsKey.mode),
           let savedMode = SleepPreventionMode(rawValue: rawMode) {
            self.mode = savedMode
        } else {
            self.mode = .keepDisplayAwake
        }

        if userDefaults.object(forKey: DefaultsKey.showCountdownInMenuBar) != nil {
            self.showCountdownInMenuBar = userDefaults.bool(forKey: DefaultsKey.showCountdownInMenuBar)
        } else {
            self.showCountdownInMenuBar = true
        }

        if let rawStyle = userDefaults.string(forKey: DefaultsKey.iconStyle),
           let savedStyle = MenuBarIconStyle(rawValue: rawStyle) {
            self.iconStyle = savedStyle
        } else {
            self.iconStyle = .bolt
        }

        let guardRef = self.assertionGuard
        self.terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            guardRef.releaseIfNeeded()
        }
    }

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        assertionGuard.releaseIfNeeded()
    }

    /// 当前是否允许显示器睡眠（对应 `kIOPMAssertionTypeNoIdleSleep`）。
    var allowDisplaySleep: Bool {
        mode == .keepSystemAwake
    }

    /// 当前菜单栏应显示的 SF Symbol 名称。
    var currentSymbolName: String {
        isActive ? iconStyle.activeSymbol : iconStyle.inactiveSymbol
    }

    /// 菜单栏图标旁可选显示的文本；未开启或隐藏倒计时时返回 nil。
    var menuBarText: String? {
        guard isActive, showCountdownInMenuBar else { return nil }
        if let remainingSeconds {
            return Self.formatDuration(remainingSeconds)
        }
        return "∞"
    }

    /// 面板顶部显示的会话状态 / 剩余倒计时文本。
    var sessionStatusText: String {
        guard isActive else {
            return "当前未开启防休眠"
        }
        if let remainingSeconds {
            return Self.formatDuration(remainingSeconds)
        }
        return "剩余时间不确定"
    }

    /// 开启或重启防休眠会话。重新开启时会先安全释放旧的 IOPMAssertionID。
    func start(duration: SleepDuration, mode overrideMode: SleepPreventionMode? = nil) {
        if let overrideMode {
            setStoredMode(overrideMode)
        }

        if case .seconds(let seconds) = duration, seconds <= 0 {
            stop()
            return
        }

        invalidateTimer()

        switch assertionGuard.replaceAssertion(type: mode.assertionType, name: Self.assertionName) {
        case .success(let newID):
            lastErrorMessage = nil
            activeAssertionID = newID
            isActive = true
            activeDuration = duration

            switch duration {
            case .indefinite:
                endDate = nil
                remainingSeconds = nil
            case .seconds(let seconds):
                let target = now().addingTimeInterval(TimeInterval(seconds))
                endDate = target
                remainingSeconds = seconds
                startTimer()
            }

        case .failure(let error):
            resetSessionState()
            lastErrorMessage = "无法创建 IOKit 电源断言（IOReturn: \(error.code)）"
        }
    }

    /// 结束当前防休眠会话并释放 IOKit 电源断言。
    func stop() {
        invalidateTimer()
        assertionGuard.releaseIfNeeded()
        resetSessionState()
    }

    /// 切换防休眠模式。若会话处于激活状态，会先释放旧断言再创建新模式对应的断言，同时保留剩余定时。
    func setMode(_ newMode: SleepPreventionMode) {
        guard mode != newMode else { return }
        setStoredMode(newMode)

        guard isActive else { return }

        switch assertionGuard.replaceAssertion(type: newMode.assertionType, name: Self.assertionName) {
        case .success(let newID):
            lastErrorMessage = nil
            activeAssertionID = newID
        case .failure(let error):
            invalidateTimer()
            resetSessionState()
            lastErrorMessage = "切换防休眠模式失败（IOReturn: \(error.code)）"
        }
    }

    /// 便捷切换“允许显示器睡眠”状态。
    func setAllowDisplaySleep(_ allow: Bool) {
        setMode(allow ? .keepSystemAwake : .keepDisplayAwake)
    }

    /// 根据目标结束时间刷新剩余秒数，倒计时归零自动释放断言。
    func tick() {
        guard isActive, let endDate else { return }
        let remaining = Int(ceil(endDate.timeIntervalSince(now())))
        if remaining <= 0 {
            stop()
        } else if remaining != remainingSeconds {
            remainingSeconds = remaining
        }
    }

    /// 将秒数格式化为 `HH:MM:SS`。
    nonisolated static func formatDuration(_ totalSeconds: Int) -> String {
        let clamped = max(0, totalSeconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let seconds = clamped % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func setStoredMode(_ newMode: SleepPreventionMode) {
        mode = newMode
        userDefaults.set(newMode.rawValue, forKey: DefaultsKey.mode)
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func invalidateTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private func resetSessionState() {
        isActive = false
        activeAssertionID = nil
        activeDuration = nil
        endDate = nil
        remainingSeconds = nil
    }
}

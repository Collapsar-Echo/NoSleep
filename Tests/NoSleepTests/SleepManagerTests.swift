import AppKit
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import NoSleep

private enum AssertionEvent: Equatable, Sendable {
    case create(type: String, id: IOPMAssertionID)
    case release(id: IOPMAssertionID)
}

private final class MockPowerAssertionProvider: PowerAssertionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: IOPMAssertionID = 100
    var events: [AssertionEvent] = []
    var failureCodeOnCreate: IOReturn?

    func createAssertion(type: CFString, name: CFString) -> Result<IOPMAssertionID, PowerAssertionError> {
        lock.lock()
        defer { lock.unlock() }

        if let failureCodeOnCreate {
            return .failure(PowerAssertionError(code: failureCodeOnCreate))
        }

        nextID += 1
        let assignedID = nextID
        events.append(.create(type: type as String, id: assignedID))
        return .success(assignedID)
    }

    func releaseAssertion(id: IOPMAssertionID) -> IOReturn {
        lock.lock()
        defer { lock.unlock() }

        events.append(.release(id: id))
        return kIOReturnSuccess
    }

    func snapshotEvents() -> [AssertionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class MockLaunchAtLoginProvider: LaunchAtLoginProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var currentStatus: LaunchAtLoginStatus = .disabled
    var errorToThrow: Error?
    var nextEnableStatus: LaunchAtLoginStatus = .enabled
    var openedSettingsCount = 0

    var status: LaunchAtLoginStatus {
        lock.lock()
        defer { lock.unlock() }
        return currentStatus
    }

    func setEnabled(_ enabled: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        if let errorToThrow {
            throw errorToThrow
        }
        currentStatus = enabled ? nextEnableStatus : .disabled
    }

    func openSystemSettings() {
        lock.lock()
        defer { lock.unlock() }
        openedSettingsCount += 1
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) {
        self.current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

@MainActor
private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "com.minglixiang.NoSleep.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@MainActor
private func makeManager(
    provider: MockPowerAssertionProvider = MockPowerAssertionProvider(),
    launchAtLogin: MockLaunchAtLoginProvider = MockLaunchAtLoginProvider(),
    now: @escaping @Sendable () -> Date = Date.init
) -> SleepManager {
    SleepManager(
        provider: provider,
        launchAtLoginProvider: launchAtLogin,
        userDefaults: makeIsolatedDefaults(),
        now: now
    )
}

@Suite("SleepManager 状态机与电源断言测试")
struct SleepManagerTests {
    @Test("初始状态为空闲且无活动断言")
    @MainActor
    func initialIdleState() {
        let provider = MockPowerAssertionProvider()
        let manager = makeManager(provider: provider)

        #expect(!manager.isActive)
        #expect(manager.mode == .keepDisplayAwake)
        #expect(manager.activeAssertionID == nil)
        #expect(manager.remainingSeconds == nil)
        #expect(manager.menuBarText == nil)
        #expect(manager.currentSymbolName == "bolt.slash")
        #expect(manager.sessionStatusText == "当前未开启防休眠")
        #expect(!manager.isLaunchAtLoginEnabled)
        #expect(provider.snapshotEvents().isEmpty)
    }

    @Test("开启无限期防休眠并切换模式时先释放旧断言")
    @MainActor
    func startAndSwitchModeReleasesPreviousAssertionFirst() {
        let provider = MockPowerAssertionProvider()
        let manager = makeManager(provider: provider)

        manager.start(duration: .indefinite)
        #expect(manager.isActive)
        #expect(manager.activeAssertionID == 101)
        #expect(manager.sessionStatusText == "剩余时间不确定")
        #expect(manager.menuBarText == "∞")
        #expect(manager.currentSymbolName == "bolt.fill")

        manager.setAllowDisplaySleep(true)
        #expect(manager.isActive)
        #expect(manager.mode == .keepSystemAwake)
        #expect(manager.activeAssertionID == 102)

        #expect(provider.snapshotEvents() == [
            .create(type: "NoDisplaySleepAssertion", id: 101),
            .release(id: 101),
            .create(type: "NoIdleSleepAssertion", id: 102)
        ])
    }

    @Test("定时防休眠倒计时更新、模式切换保留剩余时长、归零自动释放")
    @MainActor
    func countdownTicksAndAutoReleasesAtZero() {
        let provider = MockPowerAssertionProvider()
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let manager = makeManager(provider: provider, now: { clock.now() })

        manager.start(duration: .fifteenMinutes)
        #expect(manager.isActive)
        #expect(manager.remainingSeconds == 900)
        #expect(manager.sessionStatusText == "00:15:00")
        #expect(manager.menuBarText == "00:15:00")

        clock.advance(by: 65)
        manager.tick()
        #expect(manager.remainingSeconds == 835)
        #expect(manager.sessionStatusText == "00:13:55")

        // 切换模式时应先释放旧断言并保留剩余倒计时
        manager.setMode(.keepSystemAwake)
        #expect(manager.isActive)
        #expect(manager.remainingSeconds == 835)
        #expect(manager.activeAssertionID == 102)

        // 倒计时归零自动释放并恢复空闲
        clock.advance(by: 835)
        manager.tick()
        #expect(!manager.isActive)
        #expect(manager.activeAssertionID == nil)
        #expect(manager.remainingSeconds == nil)
        #expect(manager.menuBarText == nil)

        #expect(provider.snapshotEvents() == [
            .create(type: "NoDisplaySleepAssertion", id: 101),
            .release(id: 101),
            .create(type: "NoIdleSleepAssertion", id: 102),
            .release(id: 102)
        ])
    }

    @Test("重新开启会话时先释放旧断言防止泄漏")
    @MainActor
    func restartSessionReleasesOldAssertion() {
        let provider = MockPowerAssertionProvider()
        let manager = makeManager(provider: provider)

        manager.start(duration: .thirtyMinutes)
        manager.start(duration: .twoHours)

        #expect(manager.isActive)
        #expect(manager.remainingSeconds == 7200)
        #expect(manager.activeAssertionID == 102)
        #expect(provider.snapshotEvents() == [
            .create(type: "NoDisplaySleepAssertion", id: 101),
            .release(id: 101),
            .create(type: "NoDisplaySleepAssertion", id: 102)
        ])
    }

    @Test("创建断言失败时安全回退空闲状态并记录错误信息")
    @MainActor
    func creationFailureCleansUpState() {
        let provider = MockPowerAssertionProvider()
        let manager = makeManager(provider: provider)

        manager.start(duration: .oneHour)
        #expect(manager.isActive)

        provider.failureCodeOnCreate = kIOReturnError
        manager.setMode(.keepSystemAwake)

        #expect(!manager.isActive)
        #expect(manager.activeAssertionID == nil)
        #expect(manager.lastErrorMessage != nil)
        #expect(provider.snapshotEvents() == [
            .create(type: "NoDisplaySleepAssertion", id: 101),
            .release(id: 101)
        ])
    }

    @Test("deinit 兜底自动释放活动电源断言与倒计时定时器")
    @MainActor
    func deinitReleasesActiveAssertion() {
        let provider = MockPowerAssertionProvider()

        do {
            let manager = makeManager(provider: provider)
            manager.start(duration: .fifteenMinutes)
            #expect(manager.isActive)
            #expect(manager.isCountdownTimerRunning)
        }

        #expect(provider.snapshotEvents() == [
            .create(type: "NoDisplaySleepAssertion", id: 101),
            .release(id: 101)
        ])

        let box = CountdownTimerBox()
        box.schedule(interval: 1.0) {}
        #expect(box.isRunning)
        box.cancel()
        #expect(!box.isRunning)
    }

    @Test("收到应用退出通知时强制释放断言并停止倒计时定时器")
    @MainActor
    func terminationNotificationReleasesActiveAssertion() async {
        let provider = MockPowerAssertionProvider()
        let manager = makeManager(provider: provider)

        manager.start(duration: .fifteenMinutes)
        #expect(manager.isCountdownTimerRunning)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        await Task.yield()

        #expect(!manager.isCountdownTimerRunning)
        #expect(provider.snapshotEvents() == [
            .create(type: "NoDisplaySleepAssertion", id: 101),
            .release(id: 101)
        ])
    }

    @Test("时间格式化与直到指定时刻计算正确")
    func formattingAndUntilTargetCalculation() {
        #expect(SleepManager.formatDuration(0) == "00:00:00")
        #expect(SleepManager.formatDuration(900) == "00:15:00")
        #expect(SleepManager.formatDuration(7265) == "02:01:05")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 14, minute: 30))!

        // 同一天稍后时刻：16:00 -> 90 分钟
        #expect(SleepDuration.until(hour: 16, minute: 0, from: now, calendar: calendar) == .seconds(5400))
        // 早于当前时刻：次日 02:00 -> 11.5 小时
        #expect(SleepDuration.until(hour: 2, minute: 0, from: now, calendar: calendar) == .seconds(11 * 3600 + 1800))
    }

    @Test("菜单栏图标风格与倒计时显示开关生效")
    @MainActor
    func menuBarVisualPreferences() {
        let manager = makeManager()

        manager.iconStyle = .coffee
        #expect(manager.currentSymbolName == "cup.and.saucer")

        manager.start(duration: .oneHour)
        #expect(manager.currentSymbolName == "cup.and.saucer.fill")
        #expect(manager.menuBarText == "01:00:00")

        manager.showCountdownInMenuBar = false
        #expect(manager.menuBarText == nil)
    }

    @Test("开机自启动状态切换与待授权提示生效")
    @MainActor
    func launchAtLoginTransitions() {
        let loginProvider = MockLaunchAtLoginProvider()
        let manager = makeManager(launchAtLogin: loginProvider)

        #expect(manager.launchAtLoginStatus == .disabled)
        #expect(!manager.isLaunchAtLoginEnabled)

        manager.setLaunchAtLogin(true)
        #expect(manager.launchAtLoginStatus == .enabled)
        #expect(manager.isLaunchAtLoginEnabled)
        #expect(manager.lastErrorMessage == nil)

        manager.setLaunchAtLogin(false)
        #expect(manager.launchAtLoginStatus == .disabled)
        #expect(!manager.isLaunchAtLoginEnabled)

        loginProvider.nextEnableStatus = .requiresApproval
        manager.setLaunchAtLogin(true)
        #expect(manager.launchAtLoginStatus == .requiresApproval)
        #expect(manager.isLaunchAtLoginEnabled)

        manager.openLoginItemsSettings()
        #expect(loginProvider.openedSettingsCount == 1)

        loginProvider.errorToThrow = NSError(domain: "NoSleepTest", code: 1)
        manager.setLaunchAtLogin(false)
        #expect(manager.lastErrorMessage != nil)

        // 系统设置中状态变化后刷新应自动清除开机自启动错误提示
        loginProvider.errorToThrow = nil
        try? loginProvider.setEnabled(false)
        manager.refreshLaunchAtLoginStatus()
        #expect(manager.launchAtLoginStatus == .disabled)
        #expect(manager.lastErrorMessage == nil)

        // stop() 也应清空残留错误提示
        loginProvider.errorToThrow = NSError(domain: "NoSleepTest", code: 2)
        manager.setLaunchAtLogin(true)
        #expect(manager.lastErrorMessage != nil)
        manager.stop()
        #expect(manager.lastErrorMessage == nil)
    }
}

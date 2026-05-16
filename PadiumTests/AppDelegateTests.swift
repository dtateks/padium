import Testing
@testable import Padium
import AppKit
import Foundation

@MainActor
struct AppDelegateTests {
    @Test func applicationStaysAliveAfterLastWindowCloses() {
        let delegate = AppDelegate()
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) == false)
    }

    @Test func applicationDidFinishLaunchingRemembersFrontmostApplicationBeforeOpeningSettingsWindow() {
        let delegate = AppDelegate()
        let launchAtLoginController = RecordingLaunchAtLoginController()
        var rememberCount = 0
        var openCount = 0
        var closeStartupWindowsCount = 0
        delegate.launchAtLoginController = launchAtLoginController
        delegate.rememberFrontmostApplicationHandler = { rememberCount += 1 }
        delegate.showSettingsWindow = { openCount += 1 }
        delegate.closeStartupWindowsHandler = { closeStartupWindowsCount += 1 }

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        #expect(launchAtLoginController.ensureEnabledCallCount == 1)
        #expect(rememberCount == 1)
        #expect(openCount == 1)
        #expect(closeStartupWindowsCount == 0)
    }

    @Test func applicationDidFinishLaunchingSkipsSettingsWindowWhenLaunchedAtLogin() {
        let delegate = AppDelegate()
        let launchAtLoginController = RecordingLaunchAtLoginController()
        launchAtLoginController.wasLaunchedAtLogin = true
        var closeStartupWindowsCount = 0
        delegate.launchAtLoginController = launchAtLoginController
        delegate.closeStartupWindowsHandler = { closeStartupWindowsCount += 1 }

        var openCount = 0
        delegate.showSettingsWindow = { openCount += 1 }

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        #expect(launchAtLoginController.ensureEnabledCallCount == 1)
        #expect(openCount == 0)
        #expect(closeStartupWindowsCount == 1)
    }

    @Test func applicationDidFinishLaunchingOpensSystemSettingsWhenLaunchAtLoginNeedsApproval() {
        let delegate = AppDelegate()
        let launchAtLoginController = RecordingLaunchAtLoginController()
        launchAtLoginController.ensureEnabledResult = .requiresApproval
        delegate.launchAtLoginController = launchAtLoginController

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        #expect(launchAtLoginController.openSystemSettingsCallCount == 1)
    }

    @Test func applicationDidFinishLaunchingDefersSystemSettingsWhenLoginLaunchNeedsApproval() {
        let delegate = AppDelegate()
        let launchAtLoginController = RecordingLaunchAtLoginController()
        launchAtLoginController.wasLaunchedAtLogin = true
        launchAtLoginController.ensureEnabledResult = .requiresApproval
        delegate.launchAtLoginController = launchAtLoginController

        var openCount = 0
        delegate.showSettingsWindow = { openCount += 1 }

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        #expect(launchAtLoginController.openSystemSettingsCallCount == 0)
        #expect(openCount == 0)
    }

    @Test func appIsAgentOnlyWithoutDockIcon() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true)
    }

    @Test func applicationShouldHandleReopenRequestsSettingsWindow() {
        let delegate = AppDelegate()
        var openCount = 0
        delegate.showSettingsWindow = { openCount += 1 }

        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false) == false)
        #expect(openCount == 1)
    }

    @Test func applicationShouldHandleReopenDoesNotRequestDuplicateWindowWhenSettingsWindowExists() {
        let delegate = AppDelegate()
        let window = NSWindow()
        var openCount = 0
        var focusedWindow: NSWindow?
        delegate.showSettingsWindow = { openCount += 1 }
        delegate.focusSettingsWindowHandler = { focusedWindow = $0 }

        delegate.observeSettingsWindow(window)

        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true) == false)
        #expect(openCount == 0)
        #expect(focusedWindow === window)
    }

    @Test func applicationDidBecomeActiveRequestsSettingsWindowWhenHidden() {
        let delegate = AppDelegate()
        let state = AppState(
            permissionChecker: MockPermissionChecker(),
            gestureEngine: RecordingGestureRuntime(),
            scrollSuppressor: RecordingPhysicalClickCoordinator()
        )
        state.isSettingsPresented = false
        delegate.appState = state

        var openCount = 0
        delegate.showSettingsWindow = { openCount += 1 }

        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        #expect(openCount == 1)
    }

    @Test func applicationDidBecomeActiveDoesNotRequestSettingsWindowAfterLaunchAtLogin() {
        let delegate = AppDelegate()
        let launchAtLoginController = RecordingLaunchAtLoginController()
        launchAtLoginController.wasLaunchedAtLogin = true
        let state = AppState(
            permissionChecker: MockPermissionChecker(),
            gestureEngine: RecordingGestureRuntime(),
            scrollSuppressor: RecordingPhysicalClickCoordinator()
        )
        state.isSettingsPresented = false
        delegate.appState = state
        delegate.launchAtLoginController = launchAtLoginController

        var openCount = 0
        delegate.showSettingsWindow = { openCount += 1 }

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

        #expect(openCount == 0)
    }

    @Test func applicationDidBecomeActiveKeepsDeferredApprovalBackgroundedAfterLoginLaunch() {
        let delegate = AppDelegate()
        let launchAtLoginController = RecordingLaunchAtLoginController()
        launchAtLoginController.wasLaunchedAtLogin = true
        launchAtLoginController.ensureEnabledResult = .requiresApproval
        let state = AppState(
            permissionChecker: MockPermissionChecker(),
            gestureEngine: RecordingGestureRuntime(),
            scrollSuppressor: RecordingPhysicalClickCoordinator()
        )
        state.isSettingsPresented = false
        delegate.appState = state
        delegate.launchAtLoginController = launchAtLoginController

        var openCount = 0
        delegate.showSettingsWindow = { openCount += 1 }

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

        #expect(launchAtLoginController.openSystemSettingsCallCount == 0)
        #expect(openCount == 0)
    }

    @Test func applicationShouldHandleReopenConsumesDeferredApprovalAfterLoginLaunch() {
        let delegate = AppDelegate()
        let launchAtLoginController = RecordingLaunchAtLoginController()
        launchAtLoginController.wasLaunchedAtLogin = true
        launchAtLoginController.ensureEnabledResult = .requiresApproval
        delegate.launchAtLoginController = launchAtLoginController

        var openCount = 0
        delegate.showSettingsWindow = { openCount += 1 }

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false) == false)

        #expect(launchAtLoginController.openSystemSettingsCallCount == 1)
        #expect(openCount == 1)
    }

    @Test func applicationDidBecomeActiveDoesNotRequestSettingsWindowWhenAlreadyPresented() {
        let delegate = AppDelegate()
        let state = AppState(
            permissionChecker: MockPermissionChecker(),
            gestureEngine: RecordingGestureRuntime(),
            scrollSuppressor: RecordingPhysicalClickCoordinator()
        )
        state.isSettingsPresented = true
        delegate.appState = state

        var openCount = 0
        delegate.showSettingsWindow = { openCount += 1 }

        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        #expect(openCount == 0)
    }

    @Test func observedSettingsWindowRestoresPreviousApplicationOnClose() {
        let delegate = AppDelegate()
        let window = NSWindow()
        var restoreCount = 0
        delegate.restorePreviousApplicationHandler = { restoreCount += 1 }

        delegate.observeSettingsWindow(window)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)

        #expect(restoreCount == 1)
    }

    @Test func configurationChangeNotificationRestoresPreviousApplication() {
        let delegate = AppDelegate()
        var restoreCount = 0
        delegate.restorePreviousApplicationHandler = { restoreCount += 1 }

        NotificationCenter.default.post(name: PadiumNotification.configurationDidChange, object: nil)

        #expect(restoreCount == 1)
    }

    @Test @MainActor func observedSettingsWindowTracksAppInteractionFromKeyState() {
        let delegate = AppDelegate()
        let suppressor = RecordingPhysicalClickCoordinator()
        let state = AppState(
            permissionChecker: MockPermissionChecker(),
            gestureEngine: RecordingGestureRuntime(),
            scrollSuppressor: suppressor
        )
        let window = NSWindow()
        delegate.appState = state

        delegate.observeSettingsWindow(window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)

        #expect(suppressor.appInteractionStates == [true, false])
    }

    @Test @MainActor func configurationChangeDropsAppInteractionWhileSettingsWindowStaysOpen() {
        let delegate = AppDelegate()
        let suppressor = RecordingPhysicalClickCoordinator()
        let state = AppState(
            permissionChecker: MockPermissionChecker(),
            gestureEngine: RecordingGestureRuntime(),
            scrollSuppressor: suppressor
        )
        let window = NSWindow()
        var restoreCount = 0
        delegate.appState = state
        delegate.restorePreviousApplicationHandler = { restoreCount += 1 }

        delegate.observeSettingsWindow(window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: PadiumNotification.configurationDidChange, object: nil)

        #expect(restoreCount == 1)
        #expect(suppressor.appInteractionStates == [true, false])
    }
}

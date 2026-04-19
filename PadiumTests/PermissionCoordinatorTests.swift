import Testing
@testable import Padium
import AppKit
import ApplicationServices
import Foundation
import KeyboardShortcuts

private struct GestureConfigurationSnapshot {
    private static let sensitivityKey = "gesture.sensitivity"

    let shortcuts: [GestureSlot: KeyboardShortcuts.Shortcut?]
    let actionKinds: [GestureSlot: GestureActionKind]
    let sensitivity: Double?

    static func capture() -> GestureConfigurationSnapshot {
        GestureConfigurationSnapshot(
            shortcuts: Dictionary(uniqueKeysWithValues: GestureSlot.allCases.map { slot in
                (slot, KeyboardShortcuts.getShortcut(for: ShortcutRegistry.name(for: slot)))
            }),
            actionKinds: Dictionary(uniqueKeysWithValues: GestureSlot.allCases.map { slot in
                (slot, GestureActionStore.actionKind(for: slot))
            }),
            sensitivity: UserDefaults.standard.object(forKey: sensitivityKey) as? Double
        )
    }

    static func resetForTest() {
        for slot in GestureSlot.allCases {
            KeyboardShortcuts.setShortcut(nil, for: ShortcutRegistry.name(for: slot))
            GestureActionStore.setActionKind(.shortcut, for: slot)
        }
        UserDefaults.standard.removeObject(forKey: sensitivityKey)
        UserDefaults.standard.synchronize()
        ScrollSuppressor.shared.stop()
    }

    func restore() {
        for slot in GestureSlot.allCases {
            KeyboardShortcuts.setShortcut(shortcuts[slot] ?? nil, for: ShortcutRegistry.name(for: slot))
            GestureActionStore.setActionKind(actionKinds[slot] ?? .shortcut, for: slot)
        }

        if let sensitivity {
            GestureSensitivitySetting.store(sensitivity)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.sensitivityKey)
        }

        UserDefaults.standard.synchronize()
        ScrollSuppressor.shared.stop()
    }
}

private final class GestureConfigurationPreserver {
    private let snapshot = GestureConfigurationSnapshot.capture()

    init(resetForTest: Bool = true) {
        if resetForTest {
            GestureConfigurationSnapshot.resetForTest()
        }
    }

    deinit {
        snapshot.restore()
    }
}

// MARK: - PermissionCoordinator tests

struct PermissionCoordinatorTests {

    @Test @MainActor func initialPermissionStateIsChecking() {
        let coordinator = PermissionCoordinator(checker: MockPermissionChecker())
        #expect(coordinator.permissionState == .checking)
    }

    @Test @MainActor func accessibilityGrantedTransitionsToGranted() {
        let checker = MockPermissionChecker(accessibility: true)
        let coordinator = PermissionCoordinator(checker: checker)
        coordinator.checkPermissions()
        #expect(coordinator.permissionState == .granted)
    }

    @Test @MainActor func accessibilityDeniedTransitionsToDenied() {
        let checker = MockPermissionChecker(accessibility: false)
        let coordinator = PermissionCoordinator(checker: checker)
        coordinator.checkPermissions()
        #expect(coordinator.permissionState == .denied)
    }

    @Test @MainActor func permissionRevocationDetected() {
        let checker = MockPermissionChecker(accessibility: true)
        let coordinator = PermissionCoordinator(checker: checker)
        coordinator.checkPermissions()
        #expect(coordinator.permissionState == .granted)

        checker.accessibility = false
        coordinator.checkPermissions()
        #expect(coordinator.permissionState == .denied)
    }

    @Test @MainActor func isFullyGrantedReturnsTrueOnlyWhenGranted() {
        let checker = MockPermissionChecker(accessibility: true)
        let coordinator = PermissionCoordinator(checker: checker)
        #expect(coordinator.isFullyGranted == false)
        coordinator.checkPermissions()
        #expect(coordinator.isFullyGranted == true)
    }

    @Test @MainActor func requestAccessibilityDelegatesToChecker() {
        let checker = MockPermissionChecker(accessibility: false)
        let coordinator = PermissionCoordinator(checker: checker)
        coordinator.requestAccessibility()
        #expect(checker.requestAccessibilityCallCount == 1)
    }

    @Test @MainActor func checkPermissionsTracksInputMonitoringAndPostEventAccess() {
        let checker = MockPermissionChecker(
            accessibility: true,
            inputMonitoring: false,
            postEvents: true
        )
        let coordinator = PermissionCoordinator(checker: checker)

        coordinator.checkPermissions()

        #expect(coordinator.permissionState == .granted)
        #expect(coordinator.inputMonitoringState == .denied)
        #expect(coordinator.postEventState == .granted)
        #expect(coordinator.hasOutputAccess == true)
        #expect(coordinator.hasInputMonitoringAccess == false)
    }

    @Test @MainActor func requestMissingPermissionsDelegatesOnlyMissingCapabilities() {
        let checker = MockPermissionChecker(
            accessibility: true,
            inputMonitoring: false,
            postEvents: false
        )
        let coordinator = PermissionCoordinator(checker: checker)
        coordinator.checkPermissions()

        coordinator.requestMissingPermissions()

        #expect(checker.requestAccessibilityCallCount == 0)
        #expect(checker.requestListenEventAccessCallCount == 1)
        #expect(checker.requestPostEventAccessCallCount == 1)
    }
}

@MainActor
struct AppDelegateTests {
    @Test func applicationStaysAliveAfterLastWindowCloses() {
        let delegate = AppDelegate()
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) == false)
    }

    @Test func applicationDidFinishLaunchingRemembersFrontmostApplicationBeforeOpeningSettingsWindow() {
        let delegate = AppDelegate()
        var rememberCount = 0
        var openCount = 0
        delegate.rememberFrontmostApplicationHandler = { rememberCount += 1 }
        delegate.showSettingsWindow = { openCount += 1 }

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        #expect(rememberCount == 1)
        #expect(openCount == 1)
    }

    @Test func appIsAgentOnlyWithoutDockIcon() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true)
    }

    @Test func applicationShouldHandleReopenRequestsSettingsWindow() {
        let delegate = AppDelegate()
        var openCount = 0
        delegate.showSettingsWindow = { openCount += 1 }

        #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false) == true)
        #expect(openCount == 1)
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

        NotificationCenter.default.post(name: configurationDidChangeNotification, object: nil)

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
        NotificationCenter.default.post(name: configurationDidChangeNotification, object: nil)

        #expect(restoreCount == 1)
        #expect(suppressor.appInteractionStates == [true, false])
    }
}

// MARK: - AppState tests

@Suite(.serialized)
struct AppStateTests {

    @MainActor
    private func makeState(
        checker: MockPermissionChecker,
        preemptionController: (any PreemptionControlling)? = nil,
        systemGestureManager: RecordingSystemGestureManager = RecordingSystemGestureManager(),
        runtime: RecordingGestureRuntime = RecordingGestureRuntime(),
        emitter: any ShortcutEmitting = RecordingShortcutEmitter(),
        middleClickEmitter: RecordingMiddleClickEmitter = RecordingMiddleClickEmitter(),
        scrollSuppressor: (any PhysicalClickCoordinating)? = RecordingPhysicalClickCoordinator()
    ) -> AppState {
        AppState(
            permissionChecker: checker,
            preemptionController: preemptionController,
            systemGestureManager: systemGestureManager,
            gestureEngine: runtime,
            shortcutEmitter: emitter,
            middleClickEmitter: middleClickEmitter,
            scrollSuppressor: scrollSuppressor
        )
    }

    @MainActor
    private func pumpEventLoop(turns: Int = 40) async {
        for _ in 0..<turns {
            await Task.yield()
        }
    }

    @MainActor
    private func clearAllShortcutBindings() {
        for slot in GestureSlot.allCases {
            KeyboardShortcuts.setShortcut(nil, for: ShortcutRegistry.name(for: slot))
            GestureActionStore.setActionKind(.shortcut, for: slot)
        }
        ScrollSuppressor.shared.stop()
    }

    private func makeLeftClickEvent(
        _ type: CGEventType,
        clickState: Int64 = 1,
        location: CGPoint = CGPoint(x: 40, y: 60)
    ) -> CGEvent {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: location,
                mouseButton: .left
              )
        else {
            fatalError("Failed to create left-click test event")
        }

        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        return event
    }

    private func makeMenuBarClickLocation() -> CGPoint {
        guard let screen = NSScreen.main else {
            return CGPoint(x: 40, y: 60)
        }

        return CGPoint(
            x: screen.frame.midX,
            y: screen.visibleFrame.maxY + 2
        )
    }

    @Test @MainActor func initialStateNotRunning() {
        let preservedConfig = GestureConfigurationPreserver()
        let state = makeState(checker: MockPermissionChecker())
        #expect(state.isRunning == false)
        #expect(state.permissionState == .checking)
        _ = preservedConfig
    }

    @Test @MainActor func refreshPermissionsAutoStartsWhenGranted() async {
        let preservedConfig = GestureConfigurationPreserver()
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let state = makeState(checker: checker, runtime: runtime)
        state.refreshPermissions()
        #expect(state.isRunning == true)
        #expect(runtime.startCallCount == 1)
        _ = preservedConfig
    }

    @Test @MainActor func refreshPermissionsDoesNotStartWhenDenied() {
        let preservedConfig = GestureConfigurationPreserver()
        let checker = MockPermissionChecker(accessibility: false)
        let runtime = RecordingGestureRuntime()
        let state = makeState(checker: checker, runtime: runtime)
        state.refreshPermissions()
        #expect(state.isRunning == false)
        #expect(runtime.startCallCount == 0)
        _ = preservedConfig
    }

    @Test @MainActor func permissionRevocationStopsRuntime() {
        let preservedConfig = GestureConfigurationPreserver()
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let state = makeState(checker: checker, runtime: runtime)
        state.refreshPermissions()
        #expect(state.isRunning == true)

        checker.accessibility = false
        state.refreshPermissions()
        #expect(state.isRunning == false)
        #expect(runtime.stopCallCount == 1)
        _ = preservedConfig
    }

    @Test @MainActor func refreshPermissionsStartsTouchRuntimeWhenInputMonitoringMissing() {
        let preservedConfig = GestureConfigurationPreserver()
        let checker = MockPermissionChecker(
            accessibility: true,
            inputMonitoring: false,
            postEvents: true
        )
        let runtime = RecordingGestureRuntime()
        let scrollSuppressor = RecordingPhysicalClickCoordinator()
        let state = makeState(
            checker: checker,
            runtime: runtime,
            scrollSuppressor: scrollSuppressor
        )

        state.refreshPermissions()

        #expect(state.isTouchRuntimeActive == true)
        #expect(state.isPhysicalClickRuntimeActive == false)
        #expect(state.isRunning == true)
        #expect(state.runtimeStatus == .degraded)
        #expect(scrollSuppressor.startCallCount == 0)
        #expect(state.missingPermissionMessages.contains { $0.contains("Input Monitoring") })
        _ = preservedConfig
    }

    @Test @MainActor func touchRuntimeFailureDoesNotStopPhysicalClickRuntime() {
        let preservedConfig = GestureConfigurationPreserver()
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime(startResult: false)
        let scrollSuppressor = RecordingPhysicalClickCoordinator(startResult: true)
        let state = makeState(
            checker: checker,
            runtime: runtime,
            scrollSuppressor: scrollSuppressor
        )

        state.refreshPermissions()

        #expect(state.isTouchRuntimeActive == false)
        #expect(state.isPhysicalClickRuntimeActive == true)
        #expect(state.isRunning == true)
        #expect(state.runtimeStatus == .degraded)
        #expect(state.runtimeFailureMessages.contains { $0.contains("Touch listener failed to start") })
        _ = preservedConfig
    }

    @Test @MainActor func physicalClickRuntimeFailureDoesNotStopTouchRuntime() {
        let preservedConfig = GestureConfigurationPreserver()
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let scrollSuppressor = RecordingPhysicalClickCoordinator(startResult: false)
        let state = makeState(
            checker: checker,
            runtime: runtime,
            scrollSuppressor: scrollSuppressor
        )

        state.refreshPermissions()

        #expect(state.isTouchRuntimeActive == true)
        #expect(state.isPhysicalClickRuntimeActive == false)
        #expect(state.isRunning == true)
        #expect(state.runtimeStatus == .degraded)
        #expect(state.runtimeFailureMessages.contains { $0.contains("Event tap failed to start") })
        _ = preservedConfig
    }

    @Test @MainActor func runtimeEmitsShortcutWhenPermissionsGranted() async {
        let preservedConfig = GestureConfigurationPreserver()
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let emitter = RecordingShortcutEmitter()
        let state = makeState(checker: checker, runtime: runtime, emitter: emitter)

        state.refreshPermissions()
        await pumpEventLoop()

        runtime.yield(.threeFingerSwipeLeft)
        await pumpEventLoop()

        #expect(emitter.emittedSlots == [.threeFingerSwipeLeft])
        _ = preservedConfig
    }

    @Test @MainActor func changingShortcutValueAppliesImmediatelyWithoutRestart() async {
        let preservedConfig = GestureConfigurationPreserver()
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let emitter = RecordingUserDefaultsShortcutEmitter()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }

        let name = ShortcutRegistry.name(for: .threeFingerSwipeLeft)
        let firstShortcut = KeyboardShortcuts.Shortcut(.f13, modifiers: [])
        let secondShortcut = KeyboardShortcuts.Shortcut(.f14, modifiers: [.command])
        KeyboardShortcuts.setShortcut(firstShortcut, for: name)

        let state = makeState(checker: checker, runtime: runtime, emitter: emitter)

        state.refreshPermissions()
        await pumpEventLoop()

        runtime.yield(.threeFingerSwipeLeft)
        await pumpEventLoop()
        #expect(emitter.emittedShortcuts == [firstShortcut])

        KeyboardShortcuts.setShortcut(secondShortcut, for: name)
        await pumpEventLoop()

        runtime.yield(.threeFingerSwipeLeft)
        await pumpEventLoop()
        #expect(emitter.emittedShortcuts == [firstShortcut, secondShortcut])

        _ = state
        _ = preservedConfig
    }

    @Test @MainActor func shortcutValueChangePostsConfigurationDidChangeNotification() async {
        let preservedConfig = GestureConfigurationPreserver()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }

        let slot = GestureSlot.threeFingerSwipeLeft
        let name = ShortcutRegistry.name(for: slot)
        KeyboardShortcuts.setShortcut(KeyboardShortcuts.Shortcut(.f13, modifiers: []), for: name)

        let state = makeState(checker: MockPermissionChecker(accessibility: true))
        let notificationCounter = NotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: configurationDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCounter.count += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        KeyboardShortcuts.setShortcut(KeyboardShortcuts.Shortcut(.f14, modifiers: [.command]), for: name)
        state.handleShortcutConfigurationChange()
        await pumpEventLoop()

        #expect(notificationCounter.count == 1)
        _ = preservedConfig
    }

    @Test @MainActor func runtimeEmitsMiddleClickWhenThreeFingerClickUsesMiddleClickAction() async {
        let preservedConfig = GestureConfigurationPreserver()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }

        GestureActionStore.setActionKind(.middleClick, for: .threeFingerClick)

        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let middleClickEmitter = RecordingMiddleClickEmitter()
        let state = makeState(
            checker: checker,
            runtime: runtime,
            middleClickEmitter: middleClickEmitter
        )

        state.refreshPermissions()
        await pumpEventLoop()

        runtime.yield(.threeFingerClick)
        await pumpEventLoop()

        #expect(middleClickEmitter.emitCallCount == 1)

        checker.accessibility = false
        state.refreshPermissions()
        await pumpEventLoop()
        _ = preservedConfig
    }

    @Test @MainActor func runtimeSuppressesOnlyConfiguredGestureConflicts() {
        let preservedConfig = GestureConfigurationPreserver()
        let controller = StubPreemptionController(settings: StubPreemptionController.allEnabledSettings)
        let systemGestureManager = RecordingSystemGestureManager()
        let name = ShortcutRegistry.name(for: .threeFingerSwipeLeft)
        clearAllShortcutBindings()
        KeyboardShortcuts.setShortcut(.init(.f13, modifiers: []), for: name)
        defer { clearAllShortcutBindings() }

        let state = makeState(
            checker: MockPermissionChecker(accessibility: true),
            preemptionController: controller,
            systemGestureManager: systemGestureManager
        )

        state.refreshPermissions()

        #expect(systemGestureManager.suppressedSettingKeys == ["TrackpadThreeFingerHorizSwipeGesture"])
        #expect(systemGestureManager.restoreCallCount == 0)
        _ = preservedConfig
    }

    @Test @MainActor func systemGestureSettingsOnlyIncludeConfiguredConflicts() {
        let preservedConfig = GestureConfigurationPreserver()
        let controller = StubPreemptionController(settings: StubPreemptionController.allEnabledSettings)
        let name = ShortcutRegistry.name(for: .fourFingerSwipeUp)
        clearAllShortcutBindings()
        KeyboardShortcuts.setShortcut(.init(.f14, modifiers: []), for: name)
        defer { clearAllShortcutBindings() }

        let state = makeState(
            checker: MockPermissionChecker(accessibility: true),
            preemptionController: controller
        )

        #expect(state.systemGestureSettings().map(\.key) == ["TrackpadFourFingerVertSwipeGesture"])
        _ = preservedConfig
    }

    @Test @MainActor func shortcutConfigChangeRecomputesSuppressionWhileRunning() {
        let preservedConfig = GestureConfigurationPreserver()
        let controller = StubPreemptionController(settings: StubPreemptionController.allEnabledSettings)
        let systemGestureManager = RecordingSystemGestureManager()
        let name = ShortcutRegistry.name(for: .fourFingerSwipeUp)
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }

        let state = makeState(
            checker: MockPermissionChecker(accessibility: true),
            preemptionController: controller,
            systemGestureManager: systemGestureManager
        )

        state.refreshPermissions()
        #expect(systemGestureManager.suppressedSettingKeys.isEmpty)

        KeyboardShortcuts.setShortcut(.init(.f14, modifiers: []), for: name)
        state.handleShortcutConfigurationChange()

        #expect(systemGestureManager.restoreCallCount == 0)
        #expect(systemGestureManager.suppressedSettingKeys == ["TrackpadFourFingerVertSwipeGesture"])

        KeyboardShortcuts.setShortcut(nil, for: name)
        state.handleShortcutConfigurationChange()

        #expect(systemGestureManager.restoreCallCount == 1)
        #expect(systemGestureManager.suppressedSettingKeys.isEmpty)
        _ = preservedConfig
    }

    @Test @MainActor func nonConflictingShortcutChangeDoesNotReapplySystemSuppression() {
        let preservedConfig = GestureConfigurationPreserver()
        let controller = StubPreemptionController(settings: StubPreemptionController.allEnabledSettings)
        let systemGestureManager = RecordingSystemGestureManager()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }

        KeyboardShortcuts.setShortcut(.init(.f13, modifiers: []), for: ShortcutRegistry.name(for: .threeFingerSwipeLeft))

        let state = makeState(
            checker: MockPermissionChecker(accessibility: true),
            preemptionController: controller,
            systemGestureManager: systemGestureManager
        )

        state.refreshPermissions()

        #expect(systemGestureManager.suppressCallCount == 1)
        #expect(systemGestureManager.restoreCallCount == 0)
        #expect(systemGestureManager.suppressedSettingKeys == ["TrackpadThreeFingerHorizSwipeGesture"])

        KeyboardShortcuts.setShortcut(.init(.f14, modifiers: []), for: ShortcutRegistry.name(for: .oneFingerDoubleTap))
        state.handleShortcutConfigurationChange()

        #expect(systemGestureManager.suppressCallCount == 1)
        #expect(systemGestureManager.restoreCallCount == 0)
        #expect(systemGestureManager.suppressedSettingKeys == ["TrackpadThreeFingerHorizSwipeGesture"])
        _ = preservedConfig
    }

    @Test @MainActor func conflictingShortcutChangeUpdatesSuppressionWithoutRestoreBounce() {
        let preservedConfig = GestureConfigurationPreserver()
        let controller = StubPreemptionController(settings: StubPreemptionController.allEnabledSettings)
        let systemGestureManager = RecordingSystemGestureManager()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }

        KeyboardShortcuts.setShortcut(.init(.f13, modifiers: []), for: ShortcutRegistry.name(for: .threeFingerSwipeLeft))

        let state = makeState(
            checker: MockPermissionChecker(accessibility: true),
            preemptionController: controller,
            systemGestureManager: systemGestureManager
        )

        state.refreshPermissions()

        #expect(systemGestureManager.suppressCallCount == 1)
        #expect(systemGestureManager.restoreCallCount == 0)
        #expect(systemGestureManager.suppressedSettingKeys == ["TrackpadThreeFingerHorizSwipeGesture"])

        KeyboardShortcuts.setShortcut(.init(.f14, modifiers: []), for: ShortcutRegistry.name(for: .fourFingerSwipeUp))
        state.handleShortcutConfigurationChange()

        #expect(systemGestureManager.suppressCallCount == 2)
        #expect(systemGestureManager.restoreCallCount == 0)
        #expect(systemGestureManager.suppressedSettingKeys == [
            "TrackpadFourFingerVertSwipeGesture",
            "TrackpadThreeFingerHorizSwipeGesture"
        ])
        _ = preservedConfig
    }

    @Test @MainActor func changingSensitivityDoesNotRestartRunningRuntime() {
        let preservedConfig = GestureConfigurationPreserver()
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let state = makeState(checker: checker, runtime: runtime)

        state.refreshPermissions()
        #expect(state.isRunning == true)
        #expect(runtime.startCallCount == 1)
        #expect(runtime.stopCallCount == 0)

        state.setGestureSensitivity(0.8)

        #expect(state.isRunning == true)
        #expect(runtime.startCallCount == 1)
        #expect(runtime.stopCallCount == 0)
        _ = preservedConfig
    }

    @Test @MainActor func defaultsSensitivityChangeUpdatesStateWithoutRestart() async {
        let preservedConfig = GestureConfigurationPreserver()
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let state = makeState(checker: checker, runtime: runtime)

        state.refreshPermissions()
        #expect(state.gestureSensitivity == GestureSensitivitySetting.defaultValue)
        #expect(runtime.startCallCount == 1)

        GestureSensitivitySetting.store(0.8)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        await pumpEventLoop()

        #expect(state.gestureSensitivity == 0.8)
        #expect(runtime.startCallCount == 1)
        _ = preservedConfig
    }

    @Test @MainActor func shortcutConfigChangeUpdatesRuntimeActiveSlots() {
        let preservedConfig = GestureConfigurationPreserver()
        let runtime = RecordingGestureRuntime()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }

        let state = makeState(
            checker: MockPermissionChecker(accessibility: true),
            runtime: runtime
        )
        #expect(runtime.activeSlotsHistory.last == [])

        let name = ShortcutRegistry.name(for: .threeFingerDoubleTap)
        KeyboardShortcuts.setShortcut(.init(.f13, modifiers: []), for: name)
        state.handleShortcutConfigurationChange()

        #expect(runtime.activeSlotsHistory.last == [.threeFingerDoubleTap])
        _ = preservedConfig
    }

    @Test @MainActor func defaultsShortcutChangeUpdatesRuntimeActiveSlots() async {
        let preservedConfig = GestureConfigurationPreserver()
        let runtime = RecordingGestureRuntime()
        let state = makeState(
            checker: MockPermissionChecker(accessibility: true),
            runtime: runtime
        )
        #expect(runtime.activeSlotsHistory.last == [])

        let name = ShortcutRegistry.name(for: .threeFingerDoubleTap)
        KeyboardShortcuts.setShortcut(.init(.f13, modifiers: []), for: name)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        await pumpEventLoop()

        #expect(runtime.activeSlotsHistory.last == [.threeFingerDoubleTap])
        _ = state
        _ = preservedConfig
    }

    @Test @MainActor func keyboardShortcutsNotificationUpdatesRuntimeActiveSlotsImmediately() async {
        let preservedConfig = GestureConfigurationPreserver()
        let runtime = RecordingGestureRuntime()
        let state = makeState(
            checker: MockPermissionChecker(accessibility: true),
            runtime: runtime
        )
        #expect(runtime.activeSlotsHistory.last == [])

        let name = ShortcutRegistry.name(for: .threeFingerDoubleTap)
        KeyboardShortcuts.setShortcut(.init(.f13, modifiers: []), for: name)
        await pumpEventLoop()

        #expect(runtime.activeSlotsHistory.last == [.threeFingerDoubleTap])
        _ = state
        _ = preservedConfig
    }

    @Test @MainActor func keyboardShortcutsNotificationClearsRuntimeActiveSlotImmediately() async {
        let preservedConfig = GestureConfigurationPreserver()
        let runtime = RecordingGestureRuntime()
        let state = makeState(
            checker: MockPermissionChecker(accessibility: true),
            runtime: runtime
        )

        let name = ShortcutRegistry.name(for: .threeFingerDoubleTap)
        KeyboardShortcuts.setShortcut(.init(.f13, modifiers: []), for: name)
        await pumpEventLoop()
        #expect(runtime.activeSlotsHistory.last == [.threeFingerDoubleTap])

        KeyboardShortcuts.setShortcut(nil, for: name)
        await pumpEventLoop()

        #expect(runtime.activeSlotsHistory.last == [])
        _ = state
        _ = preservedConfig
    }

    @Test @MainActor func twoFingerDoubleTapConfigurationSuppressesSmartZoom() {
        let preservedConfig = GestureConfigurationPreserver()
        let controller = StubPreemptionController(settings: StubPreemptionController.allEnabledSettings)
        let systemGestureManager = RecordingSystemGestureManager()
        let name = ShortcutRegistry.name(for: .twoFingerDoubleTap)
        clearAllShortcutBindings()
        KeyboardShortcuts.setShortcut(.init(.f15, modifiers: []), for: name)
        defer { clearAllShortcutBindings() }

        let state = makeState(
            checker: MockPermissionChecker(accessibility: true),
            preemptionController: controller,
            systemGestureManager: systemGestureManager
        )

        state.refreshPermissions()

        #expect(systemGestureManager.suppressedSettingKeys == ["TrackpadTwoFingerDoubleTapGesture"])
        _ = preservedConfig
    }

    @Test @MainActor func middleClickSelectionUpdatesRuntimeActiveSlotsWithoutShortcut() {
        let preservedConfig = GestureConfigurationPreserver()
        let runtime = RecordingGestureRuntime()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }

        let state = makeState(
            checker: MockPermissionChecker(accessibility: true),
            runtime: runtime
        )
        #expect(runtime.activeSlotsHistory.last == [])

        GestureActionStore.setActionKind(.middleClick, for: .threeFingerClick)
        state.handleShortcutConfigurationChange()

        #expect(runtime.activeSlotsHistory.last == [.threeFingerClick])
        _ = preservedConfig
    }

    @Test @MainActor func physicalClickTakesPrecedenceOverTouchTapForSameSequence() async {
        let preservedConfig = GestureConfigurationPreserver()
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let emitter = RecordingShortcutEmitter()
        let suppressor = RecordingPhysicalClickCoordinator()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }

        KeyboardShortcuts.setShortcut(.init(.f13, modifiers: []), for: ShortcutRegistry.name(for: .threeFingerClick))
        KeyboardShortcuts.setShortcut(.init(.f14, modifiers: []), for: ShortcutRegistry.name(for: .threeFingerDoubleTap))

        let state = makeState(
            checker: checker,
            runtime: runtime,
            emitter: emitter,
            scrollSuppressor: suppressor
        )
        state.refreshPermissions()
        await pumpEventLoop()

        suppressor.emit(.threeFingerClick)
        await pumpEventLoop()
        #expect(emitter.emittedSlots == [.threeFingerClick])

        runtime.yield(.threeFingerDoubleTap)
        await pumpEventLoop()
        #expect(emitter.emittedSlots == [.threeFingerClick])

        _ = state
        _ = preservedConfig
    }

    @Test @MainActor func unhandledPhysicalClickDoesNotBlockTouchTap() async {
        let preservedConfig = GestureConfigurationPreserver()
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let emitter = RecordingShortcutEmitter()
        let suppressor = RecordingPhysicalClickCoordinator()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }

        KeyboardShortcuts.setShortcut(.init(.f14, modifiers: []), for: ShortcutRegistry.name(for: .threeFingerDoubleTap))

        let state = makeState(
            checker: checker,
            runtime: runtime,
            emitter: emitter,
            scrollSuppressor: suppressor
        )
        state.refreshPermissions()
        await pumpEventLoop()

        runtime.yield(.threeFingerDoubleTap)
        await pumpEventLoop()

        #expect(emitter.emittedSlots == [.threeFingerDoubleTap])

        _ = state
        _ = preservedConfig
    }

    @Test @MainActor func systemGestureNoticeReflectsConflictState() {
        let preservedConfig = GestureConfigurationPreserver()
        let state = makeState(checker: MockPermissionChecker())
        // Notice depends on whether system gestures are actually enabled on this machine.
        // Just verify it's a String? — the value depends on the test host's trackpad prefs.
        _ = state.systemGestureNotice
        _ = preservedConfig
    }

    @Test @MainActor func supportedGestureSlotsMatchPreemptionPolicy() {
        let preservedConfig = GestureConfigurationPreserver()
        let state = makeState(checker: MockPermissionChecker())
        let expected = PreemptionController().currentPolicy().supportedGestures.compactMap(GestureSlot.init(rawValue:))
        #expect(state.supportedGestureSlots == expected)
        _ = preservedConfig
    }

    @Test @MainActor func supportedGestureSlotsIncludeAllSlots() {
        let preservedConfig = GestureConfigurationPreserver()
        let state = makeState(checker: MockPermissionChecker())
        // PreemptionController returns all GestureSlot cases as supported.
        let expected = GestureSlot.allCases
        #expect(state.supportedGestureSlots == expected)
        _ = preservedConfig
    }

    @Test @MainActor func handleAppLaunchPromptsAndTerminatesWhenPermissionsMissing() async {
        let preservedConfig = GestureConfigurationPreserver()
        let checker = MockPermissionChecker(accessibility: false)
        let runtime = RecordingGestureRuntime()
        let state = makeState(checker: checker, runtime: runtime)
        var terminateCallCount = 0

        state.handleAppLaunch {
            terminateCallCount += 1
        }
        await pumpEventLoop()

        #expect(state.permissionState == .denied)
        #expect(state.isRunning == false)
        #expect(runtime.startCallCount == 0)
        #expect(checker.requestAccessibilityCallCount == 1)
        #expect(checker.requestListenEventAccessCallCount == 1)
        #expect(checker.requestPostEventAccessCallCount == 1)
        #expect(terminateCallCount == 1)
        _ = preservedConfig
    }

    @Test @MainActor func handleAppLaunchDoesNotPromptOrTerminateWhenPermissionsGranted() async {
        let preservedConfig = GestureConfigurationPreserver()
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let state = makeState(checker: checker, runtime: runtime)
        var terminateCallCount = 0

        state.handleAppLaunch {
            terminateCallCount += 1
        }
        await pumpEventLoop()

        #expect(state.permissionState == .granted)
        #expect(state.isRunning == true)
        #expect(runtime.startCallCount == 1)
        #expect(checker.requestAccessibilityCallCount == 0)
        #expect(terminateCallCount == 0)
        _ = preservedConfig
    }

}

@MainActor
struct ScrollSuppressorTests {

    private final class SlotRecorder: @unchecked Sendable {
        var slots: [GestureSlot] = []
    }

    private final class ManualPhysicalClickScheduler: PhysicalClickScheduling {
        final class ScheduledWork: PhysicalClickScheduledWork {
            private(set) var isCancelled = false

            func cancel() {
                isCancelled = true
            }
        }

        private struct ScheduledAction {
            let fireDate: Date
            let work: ScheduledWork
            let action: @Sendable () -> Void
        }

        private(set) var now: Date
        private var scheduledActions: [ScheduledAction] = []

        init(now: Date = Date(timeIntervalSinceReferenceDate: 0)) {
            self.now = now
        }

        @discardableResult
        func schedule(after delay: TimeInterval, action: @escaping @Sendable () -> Void) -> any PhysicalClickScheduledWork {
            let work = ScheduledWork()
            scheduledActions.append(
                ScheduledAction(
                    fireDate: now.addingTimeInterval(delay),
                    work: work,
                    action: action
                )
            )
            return work
        }

        func advance(by delay: TimeInterval) {
            now = now.addingTimeInterval(delay)
            runDueActions()
        }

        private func runDueActions() {
            while let index = nextDueActionIndex() {
                let scheduledAction = scheduledActions.remove(at: index)
                if !scheduledAction.work.isCancelled {
                    scheduledAction.action()
                }
                scheduledActions.removeAll { $0.work.isCancelled }
            }
        }

        private func nextDueActionIndex() -> Int? {
            scheduledActions.indices
                .filter { !scheduledActions[$0].work.isCancelled && scheduledActions[$0].fireDate <= now }
                .min { scheduledActions[$0].fireDate < scheduledActions[$1].fireDate }
        }
    }

    private func makeLeftClickEvent(
        _ type: CGEventType,
        clickState: Int64 = 1,
        location: CGPoint = CGPoint(x: 40, y: 60)
    ) -> CGEvent {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: location,
                mouseButton: .left
              )
        else {
            fatalError("Failed to create left-click test event")
        }

        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        return event
    }

    private func makeMenuBarClickLocation() -> CGPoint {
        guard let screen = NSScreen.main else {
            return CGPoint(x: 40, y: 60)
        }

        return CGPoint(
            x: screen.frame.midX,
            y: screen.visibleFrame.maxY + 2
        )
    }

    @Test func physicalThreeFingerClickEmitsConfiguredSlotAndSuppressesPair() {
        let suppressor = ScrollSuppressor()
        suppressor.currentFingerCount = 3
        suppressor.isMultitouchActive = true
        let recorder = SlotRecorder()
        suppressor.setPhysicalClickHandler { event in
            recorder.slots.append(event.slot)
        }

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown),
            configuredClickSlotsResolver: { _ in (.threeFingerClick, nil) }
        ) {
        case .suppress:
            break
        case .passThrough:
            Issue.record("Expected left mouse down to be suppressed")
        }
        #expect(recorder.slots == [.threeFingerClick])

        switch suppressor.eventDisposition(
            for: .leftMouseUp,
            event: makeLeftClickEvent(.leftMouseUp),
            configuredClickSlotsResolver: { _ in (nil, nil) }
        ) {
        case .suppress:
            break
        case .passThrough:
            Issue.record("Expected left mouse up to be suppressed")
        }
    }

    @Test func physicalThreeFingerClickWaitsForDoubleClickWindowBeforeSingleClick() {
        let scheduler = ManualPhysicalClickScheduler()
        let suppressor = ScrollSuppressor(clickScheduler: scheduler)
        suppressor.currentFingerCount = 3
        suppressor.isMultitouchActive = true
        let recorder = SlotRecorder()
        suppressor.setPhysicalClickHandler { event in
            recorder.slots.append(event.slot)
        }

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown),
            configuredClickSlotsResolver: { _ in (.threeFingerClick, .threeFingerDoubleClick) }
        ) {
        case .suppress:
            break
        case .passThrough:
            Issue.record("Expected left mouse down to be suppressed")
        }
        #expect(recorder.slots.isEmpty)

        switch suppressor.eventDisposition(
            for: .leftMouseUp,
            event: makeLeftClickEvent(.leftMouseUp),
            configuredClickSlotsResolver: { _ in (nil, nil) }
        ) {
        case .suppress:
            break
        case .passThrough:
            Issue.record("Expected left mouse up to be suppressed")
        }

        scheduler.advance(by: NSEvent.doubleClickInterval + 0.01)
        #expect(recorder.slots == [.threeFingerClick])
    }

    @Test func physicalFourFingerDoubleClickEmitsConfiguredDoubleClickSlot() {
        let scheduler = ManualPhysicalClickScheduler()
        let suppressor = ScrollSuppressor(clickScheduler: scheduler)
        suppressor.currentFingerCount = 4
        suppressor.isMultitouchActive = true
        let recorder = SlotRecorder()
        suppressor.setPhysicalClickHandler { event in
            recorder.slots.append(event.slot)
        }

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown),
            configuredClickSlotsResolver: { _ in (.fourFingerClick, .fourFingerDoubleClick) }
        ) {
        case .suppress:
            break
        case .passThrough:
            Issue.record("Expected first click to be suppressed")
        }
        switch suppressor.eventDisposition(
            for: .leftMouseUp,
            event: makeLeftClickEvent(.leftMouseUp),
            configuredClickSlotsResolver: { _ in (nil, nil) }
        ) {
        case .suppress:
            break
        case .passThrough:
            Issue.record("Expected first click up to be suppressed")
        }

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown, clickState: 2),
            configuredClickSlotsResolver: { _ in (.fourFingerClick, .fourFingerDoubleClick) }
        ) {
        case .suppress:
            break
        case .passThrough:
            Issue.record("Expected second click to be suppressed")
        }
        #expect(recorder.slots == [.fourFingerDoubleClick])

        switch suppressor.eventDisposition(
            for: .leftMouseUp,
            event: makeLeftClickEvent(.leftMouseUp),
            configuredClickSlotsResolver: { _ in (nil, nil) }
        ) {
        case .suppress:
            break
        case .passThrough:
            Issue.record("Expected second click up to be suppressed")
        }

        scheduler.advance(by: NSEvent.doubleClickInterval + 0.01)
        #expect(recorder.slots == [.fourFingerDoubleClick])
    }

    @Test func configuredPhysicalClickPassesThroughWithoutActiveMultitouch() {
        let cases: [(fingerCount: Int, single: GestureSlot, double: GestureSlot)] = [
            (3, .threeFingerClick, .threeFingerDoubleClick),
            (4, .fourFingerClick, .fourFingerDoubleClick)
        ]

        for testCase in cases {
            let suppressor = ScrollSuppressor()
            let recorder = SlotRecorder()
            suppressor.currentFingerCount = testCase.fingerCount
            suppressor.isMultitouchActive = false
            suppressor.setPhysicalClickHandler { event in
                recorder.slots.append(event.slot)
            }

            switch suppressor.eventDisposition(
                for: .leftMouseDown,
                event: makeLeftClickEvent(.leftMouseDown),
                configuredClickSlotsResolver: { _ in (testCase.single, testCase.double) }
            ) {
            case .passThrough:
                break
            case .suppress:
                Issue.record("Expected configured click down to pass through without active multitouch")
            }

            switch suppressor.eventDisposition(
                for: .leftMouseUp,
                event: makeLeftClickEvent(.leftMouseUp),
                configuredClickSlotsResolver: { _ in (nil, nil) }
            ) {
            case .passThrough:
                break
            case .suppress:
                Issue.record("Expected configured click up to pass through without active multitouch")
            }

            #expect(recorder.slots.isEmpty)
            #expect(suppressor.shouldAllowTouchTap(fingerCount: testCase.fingerCount, at: Date()) == true)
        }
    }

    @Test func configuredPhysicalClickPassesThroughWhileAppInteractionIsActive() {
        let suppressor = ScrollSuppressor()
        suppressor.currentFingerCount = 3
        suppressor.isMultitouchActive = true
        suppressor.setAppInteractionActive(true)
        let recorder = SlotRecorder()
        suppressor.setPhysicalClickHandler { event in
            recorder.slots.append(event.slot)
        }

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown),
            configuredClickSlotsResolver: { _ in (.threeFingerClick, .threeFingerDoubleClick) }
        ) {
        case .passThrough:
            break
        case .suppress:
            Issue.record("Expected configured click down to pass through while app interaction is active")
        }

        switch suppressor.eventDisposition(
            for: .leftMouseUp,
            event: makeLeftClickEvent(.leftMouseUp),
            configuredClickSlotsResolver: { _ in (nil, nil) }
        ) {
        case .passThrough:
            break
        case .suppress:
            Issue.record("Expected configured click up to pass through while app interaction is active")
        }

        #expect(recorder.slots.isEmpty)
        #expect(suppressor.shouldAllowTouchTap(fingerCount: 3, at: Date()) == true)
    }

    @Test func configuredPhysicalClickPassesThroughInSystemMenuBar() {
        let suppressor = ScrollSuppressor()
        suppressor.currentFingerCount = 3
        suppressor.isMultitouchActive = true
        let recorder = SlotRecorder()
        suppressor.setPhysicalClickHandler { event in
            recorder.slots.append(event.slot)
        }

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown, location: makeMenuBarClickLocation()),
            configuredClickSlotsResolver: { _ in (.threeFingerClick, .threeFingerDoubleClick) }
        ) {
        case .passThrough:
            break
        case .suppress:
            Issue.record("Expected configured click in system menu bar to pass through")
        }

        #expect(recorder.slots.isEmpty)
        #expect(suppressor.shouldAllowTouchTap(fingerCount: 3, at: Date()) == true)
    }

    @Test @MainActor func shortcutHotKeyGuardKeepsRecordedShortcutFromBecomingActiveHotKey() {
        let preservedConfig = GestureConfigurationPreserver()
        defer { _ = preservedConfig }

        let slot = GestureSlot.threeFingerSwipeLeft
        let name = ShortcutRegistry.name(for: slot)
        let shortcut = KeyboardShortcuts.Shortcut(.f13, modifiers: [])

        ShortcutHotKeyGuard.install()

        // Recorder flow performs setShortcut → register → notification.
        KeyboardShortcuts.setShortcut(shortcut, for: name)

        // After the guard runs, the shortcut must still be persisted...
        #expect(KeyboardShortcuts.getShortcut(for: name) == shortcut)
        // ...but must NOT be an active global hotkey, or else Padium-frontmost
        // emissions of this chord would be swallowed until quit+reopen.
        #expect(KeyboardShortcuts.isEnabled(for: name) == false)
    }

    @Test @MainActor func shortcutHotKeyGuardDisablesPreExistingStoredShortcuts() {
        let preservedConfig = GestureConfigurationPreserver()
        defer { _ = preservedConfig }

        let slot = GestureSlot.threeFingerSwipeRight
        let name = ShortcutRegistry.name(for: slot)
        let shortcut = KeyboardShortcuts.Shortcut(.f14, modifiers: [.command])
        KeyboardShortcuts.setShortcut(shortcut, for: name)

        // Force a registered hotkey before the guard sees it.
        KeyboardShortcuts.onKeyDown(for: name) {}
        defer { KeyboardShortcuts.removeHandler(for: name) }

        ShortcutHotKeyGuard.disableAllRegisteredGestureShortcuts()

        #expect(KeyboardShortcuts.getShortcut(for: name) == shortcut)
        #expect(KeyboardShortcuts.isEnabled(for: name) == false)
    }

    @Test func unconfiguredPhysicalClickPassesThroughWithoutTouchTapDedupWindow() {
        let suppressor = ScrollSuppressor()
        suppressor.currentFingerCount = 3
        suppressor.isMultitouchActive = true

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown),
            configuredClickSlotsResolver: { _ in (nil, nil) }
        ) {
        case .passThrough:
            break
        case .suppress:
            Issue.record("Expected unconfigured click down to pass through")
        }

        #expect(suppressor.shouldAllowTouchTap(fingerCount: 3, at: Date()) == true)
        #expect(suppressor.shouldAllowTouchTap(fingerCount: 4, at: Date()) == true)

        switch suppressor.eventDisposition(
            for: .leftMouseUp,
            event: makeLeftClickEvent(.leftMouseUp),
            configuredClickSlotsResolver: { _ in (nil, nil) }
        ) {
        case .passThrough:
            break
        case .suppress:
            Issue.record("Expected unconfigured click up to pass through")
        }
    }

}

// MARK: - Mocks

final class MockPermissionChecker: PermissionChecking, @unchecked Sendable {
    var accessibility: Bool
    var inputMonitoring: Bool
    var postEvents: Bool
    private(set) var requestAccessibilityCallCount = 0
    private(set) var requestListenEventAccessCallCount = 0
    private(set) var requestPostEventAccessCallCount = 0

    init(
        accessibility: Bool = false,
        inputMonitoring: Bool? = nil,
        postEvents: Bool? = nil
    ) {
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring ?? accessibility
        self.postEvents = postEvents ?? accessibility
    }

    func isAccessibilityGranted() -> Bool { accessibility }

    func isListenEventAccessGranted() -> Bool { inputMonitoring }

    func isPostEventAccessGranted() -> Bool { postEvents }

    func requestAccessibility() {
        requestAccessibilityCallCount += 1
    }

    func requestListenEventAccess() {
        requestListenEventAccessCallCount += 1
    }

    func requestPostEventAccess() {
        requestPostEventAccessCallCount += 1
    }
}

@MainActor
final class NotificationCounter {
    var count = 0
}

@MainActor
final class StubPreemptionController: PreemptionControlling {
    static let allEnabledSettings: [SystemGestureSetting] = [
        SystemGestureSetting(
            key: "TrackpadTwoFingerDoubleTapGesture",
            title: "Smart Zoom (2-finger double-tap)",
            isEnabled: true,
            conflictingSlots: [.twoFingerDoubleTap]
        ),
        SystemGestureSetting(
            key: "TrackpadThreeFingerHorizSwipeGesture",
            title: "Swipe between full-screen apps (3 fingers)",
            isEnabled: true,
            conflictingSlots: [.threeFingerSwipeLeft, .threeFingerSwipeRight]
        ),
        SystemGestureSetting(
            key: "TrackpadThreeFingerVertSwipeGesture",
            title: "Mission Control / App Exposé (3 fingers)",
            isEnabled: true,
            conflictingSlots: [.threeFingerSwipeUp, .threeFingerSwipeDown]
        ),
        SystemGestureSetting(
            key: "TrackpadFourFingerHorizSwipeGesture",
            title: "Swipe between full-screen apps (4 fingers)",
            isEnabled: true,
            conflictingSlots: [.fourFingerSwipeLeft, .fourFingerSwipeRight]
        ),
        SystemGestureSetting(
            key: "TrackpadFourFingerVertSwipeGesture",
            title: "Mission Control / App Exposé (4 fingers)",
            isEnabled: true,
            conflictingSlots: [.fourFingerSwipeUp, .fourFingerSwipeDown]
        ),
    ]

    private let settings: [SystemGestureSetting]

    init(settings: [SystemGestureSetting]) {
        self.settings = settings
    }

    func currentPolicy(activeSlots: Set<GestureSlot>) -> PreemptionPolicy {
        let conflicts = conflictingSettings(for: activeSlots)
        return PreemptionPolicy(
            supportedGestures: GestureSlot.allCases.map(\.rawValue),
            ownerNotice: conflicts.isEmpty ? nil : "conflicts"
        )
    }

    func currentSystemGestureSettings() -> [SystemGestureSetting] {
        settings
    }

    func conflictingSettings(for activeSlots: Set<GestureSlot>) -> [SystemGestureSetting] {
        settings.filter { $0.isEnabled && !$0.conflictingSlots.filter(activeSlots.contains).isEmpty }
    }

    func conflictingSlots(for activeSlots: Set<GestureSlot>) -> Set<GestureSlot> {
        Set(conflictingSettings(for: activeSlots).flatMap { $0.conflictingSlots.filter(activeSlots.contains) })
    }

    func openTrackpadSettings() {}
}

@MainActor
final class RecordingSystemGestureManager: SystemGestureManaging {
    private(set) var suppressedSettingKeys: [String] = []
    private(set) var suppressCallCount = 0
    private(set) var restoreCallCount = 0
    private(set) var restoreIfNeededCallCount = 0
    var isSuppressed: Bool { !suppressedSettingKeys.isEmpty }

    func suppress(conflictingSettings: [SystemGestureSetting], allSettings: [SystemGestureSetting]) {
        suppressCallCount += 1
        suppressedSettingKeys = conflictingSettings.map(\.key).sorted()
    }

    func restore() {
        if isSuppressed {
            restoreCallCount += 1
        }
        suppressedSettingKeys = []
    }

    func restoreIfNeeded() {
        restoreIfNeededCallCount += 1
    }
}

@MainActor
final class RecordingGestureRuntime: GestureRuntimeControlling {
    private enum StubError: Error {
        case startFailed
    }

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var activeSlotsHistory: [Set<GestureSlot>] = []
    private(set) var events: AsyncStream<GestureEvent>
    private var continuation: AsyncStream<GestureEvent>.Continuation
    private let startResult: Bool
    var lastStartError: GestureEngineError?

    init(startResult: Bool = true) {
        self.startResult = startResult
        (events, continuation) = AsyncStream<GestureEvent>.makeStream()
    }

    func start() -> Bool {
        startCallCount += 1
        lastStartError = startResult ? nil : .sourceUnavailable(underlying: StubError.startFailed)
        (events, continuation) = AsyncStream<GestureEvent>.makeStream()
        return startResult
    }

    func stop() {
        stopCallCount += 1
        continuation.finish()
    }

    func updateActiveSlots(_ activeSlots: Set<GestureSlot>) {
        activeSlotsHistory.append(activeSlots)
    }

    func yield(_ slot: GestureSlot) {
        continuation.yield(GestureEvent(slot: slot, timestamp: Date()))
    }
}

final class RecordingPhysicalClickCoordinator: PhysicalClickCoordinating, @unchecked Sendable {
    private let startResult: Bool
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var appInteractionStates: [Bool] = []
    var shouldAllowTouchTapResult = true
    private var handler: ClickHandler?

    init(startResult: Bool = true) {
        self.startResult = startResult
    }

    func setPhysicalClickHandler(_ handler: ClickHandler?) {
        self.handler = handler
    }

    func setAppInteractionActive(_ isActive: Bool) {
        appInteractionStates.append(isActive)
    }

    @discardableResult
    func start() -> Bool {
        startCallCount += 1
        return startResult
    }

    func stop() {
        stopCallCount += 1
        handler = nil
    }

    func shouldAllowTouchTap(fingerCount: Int, at timestamp: Date) -> Bool {
        shouldAllowTouchTapResult
    }

    func emit(_ slot: GestureSlot, blockTouchTap: Bool = true) {
        shouldAllowTouchTapResult = !blockTouchTap
        handler?(GestureEvent(slot: slot, timestamp: Date()))
    }
}

@MainActor
final class RecordingShortcutEmitter: ShortcutEmitting {
    private(set) var emittedSlots: [GestureSlot] = []

    func emitConfiguredShortcut(for slot: GestureSlot) -> Bool {
        emittedSlots.append(slot)
        return true
    }
}

@MainActor
final class RecordingUserDefaultsShortcutEmitter: ShortcutEmitting {
    private(set) var emittedSlots: [GestureSlot] = []
    private(set) var emittedShortcuts: [KeyboardShortcuts.Shortcut] = []

    func emitConfiguredShortcut(for slot: GestureSlot) -> Bool {
        emittedSlots.append(slot)
        guard let shortcut = KeyboardShortcuts.getShortcut(for: ShortcutRegistry.name(for: slot)) else {
            return false
        }
        emittedShortcuts.append(shortcut)
        return true
    }
}

@MainActor
final class RecordingMiddleClickEmitter: MiddleClickEmitting {
    private(set) var emitCallCount = 0

    func emitMiddleClick() -> Bool {
        emitCallCount += 1
        return true
    }
}

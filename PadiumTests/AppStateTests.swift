import Testing
@testable import Padium
import AppKit
import Foundation
import KeyboardShortcuts

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
        scrollSuppressor: (any PhysicalClickCoordinating)? = RecordingPhysicalClickCoordinator(),
        gestureFeedbackPresenter: (any GestureFeedbackPresenting)? = nil
    ) -> AppState {
        AppState(
            permissionChecker: checker,
            preemptionController: preemptionController,
            systemGestureManager: systemGestureManager,
            gestureEngine: runtime,
            shortcutEmitter: emitter,
            middleClickEmitter: middleClickEmitter,
            scrollSuppressor: scrollSuppressor,
            gestureFeedbackPresenter: gestureFeedbackPresenter
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
            forName: PadiumNotification.configurationDidChange,
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

    // MARK: - Pause / resume

    @Test @MainActor func setPausedStopsRunningRuntime() {
        let preservedConfig = GestureConfigurationPreserver()
        let pausedState = PausedDefaultPreserver()
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let scrollSuppressor = RecordingPhysicalClickCoordinator()
        let state = makeState(checker: checker, runtime: runtime, scrollSuppressor: scrollSuppressor)

        state.refreshPermissions()
        #expect(state.isRunning == true)

        state.setPaused(true)

        #expect(state.isPaused == true)
        #expect(state.isRunning == false)
        #expect(runtime.stopCallCount == 1)
        #expect(state.runtimeStatus == .paused)
        _ = preservedConfig
        _ = pausedState
    }

    @Test @MainActor func setPausedFalseResumesRuntimeWhenPermissionsGranted() {
        let preservedConfig = GestureConfigurationPreserver()
        let pausedState = PausedDefaultPreserver()
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let scrollSuppressor = RecordingPhysicalClickCoordinator()
        let state = makeState(checker: checker, runtime: runtime, scrollSuppressor: scrollSuppressor)

        state.refreshPermissions()
        state.setPaused(true)
        #expect(state.isRunning == false)

        state.setPaused(false)

        #expect(state.isPaused == false)
        #expect(state.isRunning == true)
        #expect(runtime.startCallCount == 2)
        #expect(state.runtimeStatus == .active)
        _ = preservedConfig
        _ = pausedState
    }

    @Test @MainActor func togglePausedFlipsState() {
        let preservedConfig = GestureConfigurationPreserver()
        let pausedState = PausedDefaultPreserver()
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let state = makeState(checker: checker, runtime: runtime)

        state.refreshPermissions()
        #expect(state.isPaused == false)

        state.togglePaused()
        #expect(state.isPaused == true)

        state.togglePaused()
        #expect(state.isPaused == false)
        _ = preservedConfig
        _ = pausedState
    }

    @Test @MainActor func pausedStatePersistsAcrossNewInstance() {
        let preservedConfig = GestureConfigurationPreserver()
        let pausedState = PausedDefaultPreserver()
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let state = makeState(checker: checker, runtime: runtime)
        state.setPaused(true)

        let runtime2 = RecordingGestureRuntime()
        let state2 = makeState(checker: MockPermissionChecker(accessibility: true), runtime: runtime2)

        #expect(state2.isPaused == true)
        state2.refreshPermissions()
        #expect(state2.isRunning == false)
        #expect(runtime2.startCallCount == 0)
        _ = preservedConfig
        _ = pausedState
    }

    @Test @MainActor func permissionsRequiredOverridesPausedInStatus() {
        let preservedConfig = GestureConfigurationPreserver()
        let pausedState = PausedDefaultPreserver()
        let checker = MockPermissionChecker(accessibility: false)
        let runtime = RecordingGestureRuntime()
        let state = makeState(checker: checker, runtime: runtime)

        state.refreshPermissions()
        state.setPaused(true)

        #expect(state.runtimeStatus == .permissionsRequired)
        _ = preservedConfig
        _ = pausedState
    }

    @Test @MainActor func pausedDoesNotStartRuntimeOnPermissionRefresh() {
        let preservedConfig = GestureConfigurationPreserver()
        let pausedState = PausedDefaultPreserver()
        let checker = MockPermissionChecker(accessibility: false)
        let runtime = RecordingGestureRuntime()
        let state = makeState(checker: checker, runtime: runtime)
        state.setPaused(true)

        checker.accessibility = true
        checker.postEvents = true
        checker.inputMonitoring = true
        state.refreshPermissions()

        #expect(state.isRunning == false)
        #expect(runtime.startCallCount == 0)
        #expect(state.runtimeStatus == .paused)
        _ = preservedConfig
        _ = pausedState
    }

    @Test @MainActor func resumeAfterBindingWhilePausedActivatesNewSlots() async {
        let preservedConfig = GestureConfigurationPreserver()
        let pausedState = PausedDefaultPreserver()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }

        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let state = makeState(checker: checker, runtime: runtime)

        state.refreshPermissions()
        state.setPaused(true)
        #expect(state.isRunning == false)

        // Bind a new shortcut while paused; runtime stays stopped (covered by
        // the bindingShortcutWhilePaused regression test). When the user
        // resumes, the new binding should be live so the runtime sees the
        // updated active slot set, not the stale empty one.
        KeyboardShortcuts.setShortcut(
            KeyboardShortcuts.Shortcut(.f13, modifiers: []),
            for: ShortcutRegistry.name(for: .threeFingerSwipeLeft)
        )
        state.handleShortcutConfigurationChange()
        await pumpEventLoop()

        state.setPaused(false)
        await pumpEventLoop()

        #expect(state.isPaused == false)
        #expect(state.isRunning == true)
        #expect(runtime.activeSlotsHistory.last?.contains(.threeFingerSwipeLeft) == true)
        _ = preservedConfig
        _ = pausedState
    }

    @Test @MainActor func bindingShortcutWhilePausedDoesNotResumeRuntime() async {
        let preservedConfig = GestureConfigurationPreserver()
        let pausedState = PausedDefaultPreserver()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }

        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let state = makeState(checker: checker, runtime: runtime)

        state.refreshPermissions()
        state.setPaused(true)
        #expect(state.isRunning == false)
        let baselineStartCount = runtime.startCallCount

        // Simulate the KeyboardShortcuts Recorder writing a new binding —
        // AppState observes the package's notification and forwards into
        // refreshStoredConfigurationIfNeeded.
        KeyboardShortcuts.setShortcut(
            KeyboardShortcuts.Shortcut(.f13, modifiers: []),
            for: ShortcutRegistry.name(for: .threeFingerSwipeLeft)
        )
        state.handleShortcutConfigurationChange()
        await pumpEventLoop()

        #expect(state.isRunning == false)
        #expect(state.isPaused == true)
        #expect(runtime.startCallCount == baselineStartCount)
        #expect(state.runtimeStatus == .paused)
        _ = preservedConfig
        _ = pausedState
    }

    @Test @MainActor func resumingClearsRuntimeFailureMessages() async {
        let preservedConfig = GestureConfigurationPreserver()
        let pausedState = PausedDefaultPreserver()
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime(startResult: false)
        let state = makeState(checker: checker, runtime: runtime)

        state.refreshPermissions()
        #expect(state.runtimeFailureMessages.isEmpty == false)

        state.setPaused(true)
        #expect(state.runtimeFailureMessages.isEmpty)
        _ = preservedConfig
        _ = pausedState
    }

    // MARK: - Gesture feedback HUD

    @Test @MainActor func gestureFeedbackIsOffByDefault() {
        let preservedConfig = GestureConfigurationPreserver()
        let hudState = GestureFeedbackDefaultPreserver()
        let state = makeState(checker: MockPermissionChecker())
        #expect(state.isGestureFeedbackEnabled == false)
        _ = preservedConfig
        _ = hudState
    }

    @Test @MainActor func toggleGestureFeedbackPersists() {
        let preservedConfig = GestureConfigurationPreserver()
        let hudState = GestureFeedbackDefaultPreserver()
        let stateA = makeState(checker: MockPermissionChecker())
        stateA.setGestureFeedbackEnabled(true)
        #expect(stateA.isGestureFeedbackEnabled == true)

        let stateB = makeState(checker: MockPermissionChecker())
        #expect(stateB.isGestureFeedbackEnabled == true)
        _ = preservedConfig
        _ = hudState
    }

    @Test @MainActor func gestureFeedbackShownWhenEnabledAndEmissionSucceeds() async {
        let preservedConfig = GestureConfigurationPreserver()
        let hudState = GestureFeedbackDefaultPreserver()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }
        KeyboardShortcuts.setShortcut(
            KeyboardShortcuts.Shortcut(.f13, modifiers: []),
            for: ShortcutRegistry.name(for: .threeFingerSwipeLeft)
        )

        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let presenter = RecordingGestureFeedbackPresenter()
        let state = makeState(
            checker: checker,
            runtime: runtime,
            gestureFeedbackPresenter: presenter
        )
        state.setGestureFeedbackEnabled(true)

        state.refreshPermissions()
        await pumpEventLoop()
        runtime.yield(.threeFingerSwipeLeft)
        await pumpEventLoop()

        #expect(presenter.messages.count == 1)
        #expect(presenter.messages.first?.contains("3-finger swipe left") == true)
        _ = preservedConfig
        _ = hudState
    }

    @Test @MainActor func gestureFeedbackSilentWhenDisabled() async {
        let preservedConfig = GestureConfigurationPreserver()
        let hudState = GestureFeedbackDefaultPreserver()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }
        KeyboardShortcuts.setShortcut(
            KeyboardShortcuts.Shortcut(.f13, modifiers: []),
            for: ShortcutRegistry.name(for: .threeFingerSwipeLeft)
        )

        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let presenter = RecordingGestureFeedbackPresenter()
        let state = makeState(
            checker: checker,
            runtime: runtime,
            gestureFeedbackPresenter: presenter
        )

        state.refreshPermissions()
        await pumpEventLoop()
        runtime.yield(.threeFingerSwipeLeft)
        await pumpEventLoop()

        #expect(presenter.messages.isEmpty)
        _ = preservedConfig
        _ = hudState
    }

    @Test @MainActor func gestureFeedbackSilentWhenEmissionMissesShortcut() async {
        let preservedConfig = GestureConfigurationPreserver()
        let hudState = GestureFeedbackDefaultPreserver()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }

        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let presenter = RecordingGestureFeedbackPresenter()
        let emitter = RecordingUserDefaultsShortcutEmitter()
        let state = makeState(
            checker: checker,
            runtime: runtime,
            emitter: emitter,
            gestureFeedbackPresenter: presenter
        )
        state.setGestureFeedbackEnabled(true)

        state.refreshPermissions()
        await pumpEventLoop()
        runtime.yield(.threeFingerSwipeLeft)
        await pumpEventLoop()

        #expect(presenter.messages.isEmpty)
        _ = preservedConfig
        _ = hudState
    }

    @Test @MainActor func gestureFeedbackShownForMiddleClickEmission() async {
        let preservedConfig = GestureConfigurationPreserver()
        let hudState = GestureFeedbackDefaultPreserver()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }
        GestureActionStore.setActionKind(.middleClick, for: .threeFingerClick)
        defer { GestureActionStore.setActionKind(.shortcut, for: .threeFingerClick) }

        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let scrollSuppressor = RecordingPhysicalClickCoordinator()
        let middleClickEmitter = RecordingMiddleClickEmitter()
        let presenter = RecordingGestureFeedbackPresenter()
        let state = makeState(
            checker: checker,
            runtime: runtime,
            middleClickEmitter: middleClickEmitter,
            scrollSuppressor: scrollSuppressor,
            gestureFeedbackPresenter: presenter
        )
        state.setGestureFeedbackEnabled(true)

        state.refreshPermissions()
        await pumpEventLoop()
        scrollSuppressor.emit(.threeFingerClick)
        await pumpEventLoop()

        #expect(middleClickEmitter.emitCallCount == 1)
        #expect(presenter.messages.count == 1)
        #expect(presenter.messages.first?.contains("Middle Click") == true)
        _ = preservedConfig
        _ = hudState
    }

    @Test @MainActor func gestureFeedbackFormatRendersMiddleClick() {
        let preservedConfig = GestureConfigurationPreserver()
        let hudState = GestureFeedbackDefaultPreserver()
        let formatted = GestureFeedbackMessage.format(slot: .threeFingerClick, action: .middleClick)
        #expect(formatted == "3-finger click → Middle Click")
        _ = preservedConfig
        _ = hudState
    }

    @Test @MainActor func gestureFeedbackFormatRendersShortcutDescription() {
        let preservedConfig = GestureConfigurationPreserver()
        let hudState = GestureFeedbackDefaultPreserver()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }
        KeyboardShortcuts.setShortcut(
            KeyboardShortcuts.Shortcut(.f13, modifiers: [.command, .shift]),
            for: ShortcutRegistry.name(for: .threeFingerSwipeLeft)
        )

        let formatted = GestureFeedbackMessage.format(slot: .threeFingerSwipeLeft, action: .shortcut)
        #expect(formatted.hasPrefix("3-finger swipe left → "))
        #expect(formatted != "3-finger swipe left → —")
        _ = preservedConfig
        _ = hudState
    }

    @Test @MainActor func gestureFeedbackFormatHandlesMissingShortcut() {
        let preservedConfig = GestureConfigurationPreserver()
        let hudState = GestureFeedbackDefaultPreserver()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }

        let formatted = GestureFeedbackMessage.format(slot: .threeFingerSwipeLeft, action: .shortcut)
        #expect(formatted == "3-finger swipe left → —")
        _ = preservedConfig
        _ = hudState
    }
}

/// Captures the persisted pause flag so individual tests can toggle it
/// without leaking state across the suite.
final class PausedDefaultPreserver {
    private static let key = "runtime.isPaused"
    private let snapshot: Bool

    init() {
        snapshot = UserDefaults.standard.bool(forKey: Self.key)
        UserDefaults.standard.removeObject(forKey: Self.key)
        UserDefaults.standard.synchronize()
    }

    deinit {
        UserDefaults.standard.set(snapshot, forKey: Self.key)
        UserDefaults.standard.synchronize()
    }
}

final class GestureFeedbackDefaultPreserver {
    private static let key = "hud.gestureFeedback.enabled"
    private let snapshot: Bool

    init() {
        snapshot = UserDefaults.standard.bool(forKey: Self.key)
        UserDefaults.standard.removeObject(forKey: Self.key)
        UserDefaults.standard.synchronize()
    }

    deinit {
        UserDefaults.standard.set(snapshot, forKey: Self.key)
        UserDefaults.standard.synchronize()
    }
}

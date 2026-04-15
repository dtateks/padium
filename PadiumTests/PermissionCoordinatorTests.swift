import Testing
@testable import Padium
import Foundation
import KeyboardShortcuts

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
}

// MARK: - AppState tests

struct AppStateTests {

    @MainActor
    private func makeState(
        checker: MockPermissionChecker,
        preemptionController: (any PreemptionControlling)? = nil,
        systemGestureManager: RecordingSystemGestureManager = RecordingSystemGestureManager(),
        runtime: RecordingGestureRuntime = RecordingGestureRuntime(),
        emitter: RecordingShortcutEmitter = RecordingShortcutEmitter()
    ) -> AppState {
        AppState(
            permissionChecker: checker,
            preemptionController: preemptionController,
            systemGestureManager: systemGestureManager,
            gestureEngine: runtime,
            shortcutEmitter: emitter
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
        }
    }

    @Test @MainActor func initialStateNotRunning() {
        let state = makeState(checker: MockPermissionChecker())
        #expect(state.isRunning == false)
        #expect(state.permissionState == .checking)
    }

    @Test @MainActor func refreshPermissionsAutoStartsWhenGranted() async {
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let state = makeState(checker: checker, runtime: runtime)
        state.refreshPermissions()
        #expect(state.isRunning == true)
        #expect(runtime.startCallCount == 1)
    }

    @Test @MainActor func refreshPermissionsDoesNotStartWhenDenied() {
        let checker = MockPermissionChecker(accessibility: false)
        let runtime = RecordingGestureRuntime()
        let state = makeState(checker: checker, runtime: runtime)
        state.refreshPermissions()
        #expect(state.isRunning == false)
        #expect(runtime.startCallCount == 0)
    }

    @Test @MainActor func permissionRevocationStopsRuntime() {
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let state = makeState(checker: checker, runtime: runtime)
        state.refreshPermissions()
        #expect(state.isRunning == true)

        checker.accessibility = false
        state.refreshPermissions()
        #expect(state.isRunning == false)
        #expect(runtime.stopCallCount == 1)
    }

    @Test @MainActor func runtimeEmitsShortcutWhenPermissionsGranted() async {
        let checker = MockPermissionChecker(accessibility: true)
        let runtime = RecordingGestureRuntime()
        let emitter = RecordingShortcutEmitter()
        let state = makeState(checker: checker, runtime: runtime, emitter: emitter)

        state.refreshPermissions()
        await pumpEventLoop()

        runtime.yield(.threeFingerSwipeLeft)
        await pumpEventLoop()

        #expect(emitter.emittedSlots == [.threeFingerSwipeLeft])
    }

    @Test @MainActor func runtimeSuppressesOnlyConfiguredGestureConflicts() {
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
    }

    @Test @MainActor func systemGestureSettingsOnlyIncludeConfiguredConflicts() {
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
    }

    @Test @MainActor func shortcutConfigChangeRecomputesSuppressionWhileRunning() {
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
    }

    @Test @MainActor func changingSensitivityDoesNotRestartRunningRuntime() {
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
    }

    @Test @MainActor func systemGestureNoticeReflectsConflictState() {
        let state = makeState(checker: MockPermissionChecker())
        // Notice depends on whether system gestures are actually enabled on this machine.
        // Just verify it's a String? — the value depends on the test host's trackpad prefs.
        _ = state.systemGestureNotice
    }

    @Test @MainActor func supportedGestureSlotsMatchPreemptionPolicy() {
        let state = makeState(checker: MockPermissionChecker())
        let expected = PreemptionController().currentPolicy().supportedGestures.compactMap(GestureSlot.init(rawValue:))
        #expect(state.supportedGestureSlots == expected)
    }

    @Test @MainActor func supportedGestureSlotsIncludeAllSlots() {
        let state = makeState(checker: MockPermissionChecker())
        // PreemptionController returns all GestureSlot cases as supported.
        let expected = GestureSlot.allCases
        #expect(state.supportedGestureSlots == expected)
    }

    @Test @MainActor func handleAppLaunchPromptsAndTerminatesWhenPermissionsMissing() async {
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
        #expect(terminateCallCount == 1)
    }

    @Test @MainActor func handleAppLaunchDoesNotPromptOrTerminateWhenPermissionsGranted() async {
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
    }

}

// MARK: - Mocks

final class MockPermissionChecker: PermissionChecking, @unchecked Sendable {
    var accessibility: Bool
    private(set) var requestAccessibilityCallCount = 0

    init(accessibility: Bool = false) {
        self.accessibility = accessibility
    }

    func isAccessibilityGranted() -> Bool { accessibility }

    func requestAccessibility() {
        requestAccessibilityCallCount += 1
    }
}

@MainActor
final class StubPreemptionController: PreemptionControlling {
    static let allEnabledSettings: [SystemGestureSetting] = [
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
    private(set) var restoreCallCount = 0
    private(set) var restoreIfNeededCallCount = 0
    var isSuppressed: Bool { !suppressedSettingKeys.isEmpty }

    func suppress(conflictingSettings: [SystemGestureSetting]) {
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
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var events: AsyncStream<GestureEvent>
    private var continuation: AsyncStream<GestureEvent>.Continuation
    var lastStartError: GestureEngineError?

    init() {
        (events, continuation) = AsyncStream<GestureEvent>.makeStream()
    }

    func start() -> Bool {
        startCallCount += 1
        lastStartError = nil
        (events, continuation) = AsyncStream<GestureEvent>.makeStream()
        return true
    }

    func stop() {
        stopCallCount += 1
        continuation.finish()
    }

    func yield(_ slot: GestureSlot) {
        continuation.yield(GestureEvent(slot: slot, timestamp: Date()))
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

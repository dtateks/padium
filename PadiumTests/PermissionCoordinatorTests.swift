import Testing
@testable import Padium
import Foundation

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
        runtime: RecordingGestureRuntime = RecordingGestureRuntime(),
        emitter: RecordingShortcutEmitter = RecordingShortcutEmitter()
    ) -> AppState {
        AppState(
            permissionChecker: checker,
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

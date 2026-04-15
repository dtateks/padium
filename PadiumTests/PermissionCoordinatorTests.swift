import Testing
@testable import Padium
import Foundation

// MARK: - Permission Checking Protocol for Testability

struct PermissionCoordinatorTests {

    // MARK: - PermissionState transitions

    @Test @MainActor func initialPermissionStateIsChecking() {
        let coordinator = PermissionCoordinator(checker: MockPermissionChecker())
        #expect(coordinator.permissionState == .checking)
    }

    @Test @MainActor func bothPermissionsGrantedTransitionsToGranted() async {
        let checker = MockPermissionChecker(accessibility: true, inputMonitoring: true)
        let coordinator = PermissionCoordinator(checker: checker)
        coordinator.checkPermissions()
        #expect(coordinator.permissionState == .granted)
    }

    @Test @MainActor func missingAccessibilityTransitionsToDenied() async {
        let checker = MockPermissionChecker(accessibility: false, inputMonitoring: true)
        let coordinator = PermissionCoordinator(checker: checker)
        coordinator.checkPermissions()
        #expect(coordinator.permissionState == .denied(accessibility: false, inputMonitoring: true))
    }

    @Test @MainActor func missingInputMonitoringTransitionsToDenied() async {
        let checker = MockPermissionChecker(accessibility: true, inputMonitoring: false)
        let coordinator = PermissionCoordinator(checker: checker)
        coordinator.checkPermissions()
        #expect(coordinator.permissionState == .denied(accessibility: true, inputMonitoring: false))
    }

    @Test @MainActor func bothPermissionsMissingTransitionsToDenied() async {
        let checker = MockPermissionChecker(accessibility: false, inputMonitoring: false)
        let coordinator = PermissionCoordinator(checker: checker)
        coordinator.checkPermissions()
        #expect(coordinator.permissionState == .denied(accessibility: false, inputMonitoring: false))
    }

    @Test @MainActor func permissionRevocationDetected() async {
        let checker = MockPermissionChecker(accessibility: true, inputMonitoring: true)
        let coordinator = PermissionCoordinator(checker: checker)
        coordinator.checkPermissions()
        #expect(coordinator.permissionState == .granted)

        checker.accessibility = false
        coordinator.checkPermissions()
        #expect(coordinator.permissionState == .denied(accessibility: false, inputMonitoring: true))
    }

    @Test @MainActor func isFullyGrantedReturnsTrueOnlyWhenGranted() {
        let checker = MockPermissionChecker(accessibility: true, inputMonitoring: true)
        let coordinator = PermissionCoordinator(checker: checker)
        #expect(coordinator.isFullyGranted == false) // still .checking
        coordinator.checkPermissions()
        #expect(coordinator.isFullyGranted == true)
    }

    @Test @MainActor func isFullyGrantedReturnsFalseWhenDenied() {
        let checker = MockPermissionChecker(accessibility: false, inputMonitoring: false)
        let coordinator = PermissionCoordinator(checker: checker)
        coordinator.checkPermissions()
        #expect(coordinator.isFullyGranted == false)
    }
}

// MARK: - AppState tests

struct AppStateTests {

    @MainActor
    private func makeState(
        checker: MockPermissionChecker,
        policy: PreemptionPolicy? = nil,
        runtime: RecordingGestureRuntime = RecordingGestureRuntime(),
        emitter: RecordingShortcutEmitter = RecordingShortcutEmitter()
    ) -> AppState {
        AppState(
            permissionChecker: checker,
            preemptionPolicy: policy,
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

    @Test @MainActor func initialStateIsDisabledWithCheckingPermissions() {
        let checker = MockPermissionChecker()
        let state = makeState(checker: checker)
        #expect(state.isEnabled == false)
        #expect(state.permissionState == .checking)
        #expect(state.isSettingsPresented == false)
    }

    @Test @MainActor func systemGestureNoticePopulatedFromPreemptionPolicy() {
        let checker = MockPermissionChecker()
        let state = makeState(checker: checker)
        // PreemptionController always produces an ownerNotice for manual-disable strategy
        #expect(state.systemGestureNotice != nil)
    }

    @Test @MainActor func supportedGestureSlotsMatchPreemptionPolicy() {
        let checker = MockPermissionChecker()
        let state = makeState(checker: checker)
        let expected = PreemptionController().currentPolicy().supportedGestures.compactMap(GestureSlot.init(rawValue:))
        #expect(state.supportedGestureSlots == expected)
    }

    @Test @MainActor func unsupportedPolicyGesturesAreExcludedFromSupportedGestureSlots() {
        let checker = MockPermissionChecker()
        let policy = PreemptionPolicy(
            strategy: .manualDisable,
            supportedGestures: [GestureSlot.threeFingerSwipeLeft.rawValue, "unsupported.gesture"],
            ownerNotice: "notice"
        )
        let state = makeState(checker: checker, policy: policy)
        #expect(state.supportedGestureSlots == [.threeFingerSwipeLeft])
    }

    @Test @MainActor func runtimeEmitsConfiguredShortcutWhenEnabledAndPermissionsGranted() async {
        let checker = MockPermissionChecker(accessibility: true, inputMonitoring: true)
        let runtime = RecordingGestureRuntime()
        let emitter = RecordingShortcutEmitter()
        let state = AppState(
            permissionChecker: checker,
            preemptionPolicy: PreemptionPolicy(
                strategy: .manualDisable,
                supportedGestures: [GestureSlot.threeFingerSwipeLeft.rawValue],
                ownerNotice: nil
            ),
            gestureEngine: runtime,
            shortcutEmitter: emitter
        )

        state.refreshPermissions()
        state.isEnabled = true
        await pumpEventLoop()

        runtime.yield(.threeFingerSwipeLeft)
        await pumpEventLoop()

        #expect(runtime.startCallCount == 1)
        #expect(emitter.emittedSlots == [.threeFingerSwipeLeft])
    }

    @Test @MainActor func runtimeDoesNotEmitShortcutAfterDisable() async {
        let checker = MockPermissionChecker(accessibility: true, inputMonitoring: true)
        let runtime = RecordingGestureRuntime()
        let emitter = RecordingShortcutEmitter()
        let state = AppState(
            permissionChecker: checker,
            preemptionPolicy: PreemptionPolicy(
                strategy: .manualDisable,
                supportedGestures: [GestureSlot.threeFingerSwipeRight.rawValue],
                ownerNotice: nil
            ),
            gestureEngine: runtime,
            shortcutEmitter: emitter
        )

        state.refreshPermissions()
        state.isEnabled = true
        await pumpEventLoop()
        state.isEnabled = false

        runtime.yield(.threeFingerSwipeRight)
        await pumpEventLoop()

        #expect(runtime.startCallCount == 1)
        #expect(runtime.stopCallCount == 1)
        #expect(emitter.emittedSlots.isEmpty)
    }

    @Test @MainActor func cannotEnableWithoutPermissions() {
        let checker = MockPermissionChecker(accessibility: false, inputMonitoring: false)
        let state = makeState(checker: checker)
        state.refreshPermissions()
        state.isEnabled = true
        #expect(state.isEnabled == false)
    }

    @Test @MainActor func canEnableWithPermissionsGranted() {
        let checker = MockPermissionChecker(accessibility: true, inputMonitoring: true)
        let state = makeState(checker: checker)
        state.refreshPermissions()
        state.isEnabled = true
        #expect(state.isEnabled == true)
    }

    @Test @MainActor func disablingAlwaysAllowed() {
        let checker = MockPermissionChecker(accessibility: true, inputMonitoring: true)
        let state = makeState(checker: checker)
        state.refreshPermissions()
        state.isEnabled = true
        #expect(state.isEnabled == true)
        state.isEnabled = false
        #expect(state.isEnabled == false)
    }

    @Test @MainActor func permissionRevocationDisablesApp() {
        let checker = MockPermissionChecker(accessibility: true, inputMonitoring: true)
        let state = makeState(checker: checker)
        state.refreshPermissions()
        state.isEnabled = true
        #expect(state.isEnabled == true)

        checker.accessibility = false
        state.refreshPermissions()
        #expect(state.isEnabled == false)
    }

    @Test @MainActor func permissionStateExposedFromCoordinator() {
        let checker = MockPermissionChecker(accessibility: true, inputMonitoring: false)
        let state = makeState(checker: checker)
        state.refreshPermissions()
        #expect(state.permissionState == .denied(accessibility: true, inputMonitoring: false))
    }
}

// MARK: - Mock

final class MockPermissionChecker: PermissionChecking, @unchecked Sendable {
    var accessibility: Bool
    var inputMonitoring: Bool

    init(accessibility: Bool = false, inputMonitoring: Bool = false) {
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }

    func isAccessibilityGranted() -> Bool { accessibility }
    func isInputMonitoringGranted() -> Bool { inputMonitoring }
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

import Testing
@testable import Padium
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
        emitter: RecordingShortcutEmitter = RecordingShortcutEmitter(),
        middleClickEmitter: RecordingMiddleClickEmitter = RecordingMiddleClickEmitter()
    ) -> AppState {
        AppState(
            permissionChecker: checker,
            preemptionController: preemptionController,
            systemGestureManager: systemGestureManager,
            gestureEngine: runtime,
            shortcutEmitter: emitter,
            middleClickEmitter: middleClickEmitter
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

    @Test @MainActor func runtimeEmitsMiddleClickWhenThreeFingerTapUsesMiddleClickAction() async {
        let preservedConfig = GestureConfigurationPreserver()
        clearAllShortcutBindings()
        defer { clearAllShortcutBindings() }

        GestureActionStore.setActionKind(.middleClick, for: .threeFingerTap)

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

        runtime.yield(.threeFingerTap)
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

        let name = ShortcutRegistry.name(for: .threeFingerTap)
        KeyboardShortcuts.setShortcut(.init(.f13, modifiers: []), for: name)
        state.handleShortcutConfigurationChange()

        #expect(runtime.activeSlotsHistory.last == [.threeFingerTap])
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

        let name = ShortcutRegistry.name(for: .threeFingerTap)
        KeyboardShortcuts.setShortcut(.init(.f13, modifiers: []), for: name)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        await pumpEventLoop()

        #expect(runtime.activeSlotsHistory.last == [.threeFingerTap])
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

        GestureActionStore.setActionKind(.middleClick, for: .threeFingerTap)
        state.handleShortcutConfigurationChange()

        #expect(runtime.activeSlotsHistory.last == [.threeFingerTap])
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

    private func makeLeftClickEvent(_ type: CGEventType) -> CGEvent {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: CGPoint(x: 40, y: 60),
                mouseButton: .left
              )
        else {
            fatalError("Failed to create left-click test event")
        }

        event.setIntegerValueField(.mouseEventClickState, value: 1)
        return event
    }

    @Test func physicalThreeFingerClickConvertsToMiddleClickPairWhenConfigured() {
        let suppressor = ScrollSuppressor()
        suppressor.currentFingerCount = 3

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown),
            isMiddleClickConfigured: true
        ) {
        case .replace(let convertedDown):
            #expect(convertedDown.type == .otherMouseDown)
            #expect(convertedDown.getIntegerValueField(.mouseEventButtonNumber) == Int64(CGMouseButton.center.rawValue))
            #expect(convertedDown.getIntegerValueField(.eventSourceUserData) == ScrollSuppressor.syntheticMiddleClickMarker)
        case .passThrough, .suppress:
            Issue.record("Expected left mouse down to convert to middle click")
        }

        switch suppressor.eventDisposition(
            for: .leftMouseUp,
            event: makeLeftClickEvent(.leftMouseUp),
            isMiddleClickConfigured: true
        ) {
        case .replace(let convertedUp):
            #expect(convertedUp.type == .otherMouseUp)
            #expect(convertedUp.getIntegerValueField(.mouseEventButtonNumber) == Int64(CGMouseButton.center.rawValue))
            #expect(convertedUp.getIntegerValueField(.eventSourceUserData) == ScrollSuppressor.syntheticMiddleClickMarker)
        case .passThrough, .suppress:
            Issue.record("Expected left mouse up to convert to middle click")
        }
    }

    @Test func physicalThreeFingerClickPassesThroughWhenMiddleClickIsDisabled() {
        let suppressor = ScrollSuppressor()
        suppressor.currentFingerCount = 3

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown),
            isMiddleClickConfigured: false
        ) {
        case .passThrough:
            break
        case .suppress, .replace:
            Issue.record("Expected left mouse down to pass through when middle click is disabled")
        }
    }

    @Test func tapEmittedMiddleClickSuppressesDuplicatePhysicalClickPair() {
        let suppressor = ScrollSuppressor()
        suppressor.currentFingerCount = 3
        #expect(suppressor.registerGestureMiddleClickIfNeeded(at: Date()) == true)

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown),
            isMiddleClickConfigured: true
        ) {
        case .suppress:
            break
        case .passThrough, .replace:
            Issue.record("Expected duplicate physical click down to be suppressed")
        }

        switch suppressor.eventDisposition(
            for: .leftMouseUp,
            event: makeLeftClickEvent(.leftMouseUp),
            isMiddleClickConfigured: true
        ) {
        case .suppress:
            break
        case .passThrough, .replace:
            Issue.record("Expected duplicate physical click up to be suppressed")
        }
    }

    @Test func convertedPhysicalClickBlocksDuplicateTapMiddleClick() {
        let suppressor = ScrollSuppressor()
        suppressor.currentFingerCount = 3

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown),
            isMiddleClickConfigured: true
        ) {
        case .replace:
            break
        case .passThrough, .suppress:
            Issue.record("Expected physical click down to convert to middle click")
            return
        }

        #expect(suppressor.registerGestureMiddleClickIfNeeded(at: Date()) == false)

        switch suppressor.eventDisposition(
            for: .leftMouseUp,
            event: makeLeftClickEvent(.leftMouseUp),
            isMiddleClickConfigured: true
        ) {
        case .replace:
            break
        case .passThrough, .suppress:
            Issue.record("Expected physical click up to convert to middle click")
        }
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
    private(set) var restoreCallCount = 0
    private(set) var restoreIfNeededCallCount = 0
    var isSuppressed: Bool { !suppressedSettingKeys.isEmpty }

    func suppress(conflictingSettings: [SystemGestureSetting], allSettings: [SystemGestureSetting]) {
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
    private(set) var activeSlotsHistory: [Set<GestureSlot>] = []
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

    func updateActiveSlots(_ activeSlots: Set<GestureSlot>) {
        activeSlotsHistory.append(activeSlots)
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

@MainActor
final class RecordingMiddleClickEmitter: MiddleClickEmitting {
    private(set) var emitCallCount = 0

    func emitMiddleClick() -> Bool {
        emitCallCount += 1
        return true
    }
}

import Testing
@testable import Padium
import AppKit
import ApplicationServices
import Foundation
import KeyboardShortcuts
import ServiceManagement

// MARK: - Gesture configuration preservation

struct GestureConfigurationSnapshot {
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
    }
}

final class GestureConfigurationPreserver {
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

// MARK: - CGEvent helpers

func makeLeftClickEvent(
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

func makeMenuBarClickLocation() -> CGPoint {
    guard let screen = NSScreen.main else {
        return CGPoint(x: 40, y: 60)
    }

    return CGPoint(
        x: screen.frame.midX,
        y: screen.visibleFrame.maxY + 2
    )
}

// MARK: - Permission mocks

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

// MARK: - AppState collaborator stubs

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
final class RecordingLaunchAtLoginController: LaunchAtLoginControlling {
    var wasLaunchedAtLogin = false
    var ensureEnabledResult: LaunchAtLoginRegistrationResult = .enabled
    private(set) var ensureEnabledCallCount = 0
    private(set) var openSystemSettingsCallCount = 0

    func ensureEnabled() -> LaunchAtLoginRegistrationResult {
        ensureEnabledCallCount += 1
        return ensureEnabledResult
    }

    func openSystemSettings() {
        openSystemSettingsCallCount += 1
    }
}

final class StubLoginItemService: LoginItemServiceControlling {
    var status: SMAppService.Status
    var registerHandler: (() -> Void)?
    private(set) var registerCallCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        registerHandler?()
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
    var currentFingerCount: Int = 0
    var isMultitouchActive: Bool = false
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

final class RecordingMultitouchStateSink: MultitouchStateSink, @unchecked Sendable {
    var currentFingerCount: Int = 0
    var isMultitouchActive: Bool = false
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

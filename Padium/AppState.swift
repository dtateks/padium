import ApplicationServices
import Foundation
import KeyboardShortcuts
import os

@MainActor
protocol GestureRuntimeControlling: AnyObject {
    var events: AsyncStream<GestureEvent> { get }
    var lastStartError: GestureEngineError? { get }
    @discardableResult func start() -> Bool
    func stop()
    func updateActiveSlots(_ activeSlots: Set<GestureSlot>)
}

@MainActor
protocol ShortcutEmitting: AnyObject {
    @discardableResult func emitConfiguredShortcut(for slot: GestureSlot) -> Bool
}

@MainActor
protocol MiddleClickEmitting: AnyObject {
    @discardableResult func emitMiddleClick() -> Bool
}

extension GestureEngine: GestureRuntimeControlling {}
extension ShortcutEmitter: ShortcutEmitting {}

@MainActor
final class MiddleClickEmitter: MiddleClickEmitting {
    @discardableResult
    func emitMiddleClick() -> Bool {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return false }
        let position = CGEvent(source: nil)?.location ?? .zero
        guard let down = CGEvent(mouseEventSource: src, mouseType: .otherMouseDown, mouseCursorPosition: position, mouseButton: .center),
              let up = CGEvent(mouseEventSource: src, mouseType: .otherMouseUp, mouseCursorPosition: position, mouseButton: .center)
        else {
            return false
        }

        ScrollSuppressor.configureMiddleClickEvent(down, clickState: 1)
        ScrollSuppressor.configureMiddleClickEvent(up, clickState: 1)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

@MainActor
protocol PreemptionControlling: AnyObject {
    func currentPolicy(activeSlots: Set<GestureSlot>) -> PreemptionPolicy
    func currentSystemGestureSettings() -> [SystemGestureSetting]
    func conflictingSettings(for activeSlots: Set<GestureSlot>) -> [SystemGestureSetting]
    func conflictingSlots(for activeSlots: Set<GestureSlot>) -> Set<GestureSlot>
    func openTrackpadSettings()
}

@MainActor
protocol SystemGestureManaging: AnyObject {
    var isSuppressed: Bool { get }
    func suppress(conflictingSettings: [SystemGestureSetting], allSettings: [SystemGestureSetting])
    func restore()
    func restoreIfNeeded()
}

extension PreemptionController: PreemptionControlling {}
extension SystemGestureManager: SystemGestureManaging {}

@MainActor @Observable
final class AppState {
    var permissionState: PermissionState { coordinator.permissionState }
    var isRunning: Bool { runtimeTask != nil }
    var systemGestureNotice: String?
    var conflictingSlots: Set<GestureSlot> = []
    let supportedGestureSlots: [GestureSlot]
    var gestureSensitivity: Double
    var isSettingsPresented: Bool = false

    private let coordinator: PermissionCoordinator
    private let preemptionController: any PreemptionControlling
    private let systemGestureManager: any SystemGestureManaging
    private let gestureEngine: any GestureRuntimeControlling
    private let shortcutEmitter: any ShortcutEmitting
    private let middleClickEmitter: any MiddleClickEmitting
    private var runtimeTask: Task<Void, Never>?

    init(
        permissionChecker: PermissionChecking = SystemPermissionChecker(),
        preemptionController: (any PreemptionControlling)? = nil,
        systemGestureManager: (any SystemGestureManaging)? = nil,
        gestureEngine: (any GestureRuntimeControlling)? = nil,
        shortcutEmitter: (any ShortcutEmitting)? = nil,
        middleClickEmitter: (any MiddleClickEmitting)? = nil
    ) {
        self.coordinator = PermissionCoordinator(checker: permissionChecker)

        let controller = preemptionController ?? PreemptionController()
        self.preemptionController = controller
        let policy = controller.currentPolicy(activeSlots: Set(GestureSlot.allCases))
        let supportedGestureSlots = Self.resolveSupportedGestureSlots(from: policy)
        self.supportedGestureSlots = supportedGestureSlots
        self.gestureSensitivity = GestureSensitivitySetting.storedValue()
        self.systemGestureManager = systemGestureManager ?? SystemGestureManager.shared
        self.systemGestureNotice = nil
        self.conflictingSlots = []

        if let gestureEngine {
            self.gestureEngine = gestureEngine
        } else {
            self.gestureEngine = GestureEngine(source: OMSGestureSource(), supportedSlots: Set(supportedGestureSlots))
        }

        self.shortcutEmitter = shortcutEmitter ?? ShortcutEmitter()
        self.middleClickEmitter = middleClickEmitter ?? MiddleClickEmitter()
        self.gestureEngine.updateActiveSlots(configuredGestureSlots())
        refreshSystemGestureConflicts()
    }

    /// Check permissions and auto-start runtime if granted. Also refreshes system gesture conflicts.
    func refreshPermissions() {
        coordinator.checkPermissions()

        if coordinator.isFullyGranted {
            startRuntimeIfNeeded()
        } else {
            stopRuntime()
        }

        refreshSystemGestureConflicts()
    }

    func requestAccessibility() {
        coordinator.requestAccessibility()
    }

    func refreshSystemGestureConflicts() {
        let configuredSlots = configuredGestureSlots()
        let policy = preemptionController.currentPolicy(activeSlots: configuredSlots)
        systemGestureNotice = policy.ownerNotice
        conflictingSlots = preemptionController.conflictingSlots(for: configuredSlots)
    }

    func openTrackpadSettings() {
        preemptionController.openTrackpadSettings()
    }

    func systemGestureSettings() -> [SystemGestureSetting] {
        preemptionController.conflictingSettings(for: configuredGestureSlots())
    }

    func handleAppLaunch(onMissingPermissions: @escaping @MainActor () -> Void) {
        // If a previous session crashed without restoring system gestures, restore now.
        systemGestureManager.restoreIfNeeded()

        startPermissionPolling()
        refreshPermissions()

        guard !coordinator.isFullyGranted else { return }

        PadiumLogger.permission.notice("Accessibility missing at launch; prompting then terminating")
        requestAccessibility()
        stopPermissionPolling()

        Task { @MainActor in
            await Task.yield()
            onMissingPermissions()
        }
    }

    func startPermissionPolling() {
        coordinator.startPolling { [weak self] in
            self?.refreshPermissions()
        }
    }

    func stopPermissionPolling() {
        coordinator.stopPolling()
    }

    func setGestureSensitivity(_ value: Double) {
        let clamped = GestureSensitivitySetting.clamp(value)
        guard gestureSensitivity != clamped else { return }
        gestureSensitivity = clamped
        GestureSensitivitySetting.store(clamped)
    }

    private func startRuntimeIfNeeded() {
        gestureEngine.updateActiveSlots(configuredGestureSlots())
        guard runtimeTask == nil else { return }

        applySystemGestureSuppression()
        ScrollSuppressor.shared.start()

        guard gestureEngine.start() else {
            if let startError = gestureEngine.lastStartError {
                PadiumLogger.gesture.error("Gesture engine failed to start: \(String(describing: startError), privacy: .public)")
            }
            ScrollSuppressor.shared.stop()
            systemGestureManager.restore()
            return
        }

        runtimeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.gestureEngine.events {
                guard self.coordinator.isFullyGranted else { continue }
                switch GestureActionStore.actionKind(for: event.slot) {
                case .shortcut:
                    _ = self.shortcutEmitter.emitConfiguredShortcut(for: event.slot)
                case .middleClick:
                    guard self.shouldEmitMiddleClick(for: event) else { continue }
                    PadiumLogger.gesture.debug("TAP-DIAG: emitting middle click for \(event.slot.rawValue, privacy: .public)")
                    _ = self.middleClickEmitter.emitMiddleClick()
                }
            }
        }
    }

    private func stopRuntime() {
        gestureEngine.stop()
        runtimeTask?.cancel()
        runtimeTask = nil
        ScrollSuppressor.shared.stop()
        systemGestureManager.restore()
    }

    func handleShortcutConfigurationChange() {
        // Flush shortcut/action-kind changes to disk immediately so they survive
        // unexpected termination or rebuild-kill sequences.
        UserDefaults.standard.synchronize()

        gestureEngine.updateActiveSlots(configuredGestureSlots())
        if isRunning {
            applySystemGestureSuppression()
        } else if coordinator.isFullyGranted {
            // Runtime may have failed to start on first launch (e.g., OMS not yet available).
            // Retry now that the user changed config.
            startRuntimeIfNeeded()
        }
        refreshSystemGestureConflicts()
    }

    private func applySystemGestureSuppression() {
        if systemGestureManager.isSuppressed {
            systemGestureManager.restore()
        }

        let configuredSlots = configuredGestureSlots()
        let allSettings = preemptionController.currentSystemGestureSettings()
        let conflictingSettings = preemptionController.conflictingSettings(for: configuredSlots)
        guard !conflictingSettings.isEmpty else { return }

        systemGestureManager.suppress(conflictingSettings: conflictingSettings, allSettings: allSettings)
    }

    private func configuredGestureSlots() -> Set<GestureSlot> {
        Set(supportedGestureSlots.filter(\.isConfigured))
    }

    private func shouldEmitMiddleClick(for event: GestureEvent) -> Bool {
        guard event.slot == .threeFingerTap else { return true }
        guard ScrollSuppressor.shared.registerGestureMiddleClickIfNeeded(at: event.timestamp) else {
            PadiumLogger.gesture.debug("TAP-DIAG: suppressing duplicate tap middle click for \(event.slot.rawValue, privacy: .public)")
            return false
        }
        return true
    }
}

private extension AppState {
    static func resolveSupportedGestureSlots(from policy: PreemptionPolicy) -> [GestureSlot] {
        let supportedSlots = policy.supportedGestures.compactMap(GestureSlot.init(rawValue:))
        let unsupportedGestureIdentifiers = policy.supportedGestures.filter { GestureSlot(rawValue: $0) == nil }
        if !unsupportedGestureIdentifiers.isEmpty {
            let unsupportedList = unsupportedGestureIdentifiers.joined(separator: ",")
            PadiumLogger.gesture.warning("Ignoring unsupported policy gestures: \(unsupportedList, privacy: .public)")
        }
        return supportedSlots
    }
}

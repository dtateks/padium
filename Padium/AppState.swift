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
}

@MainActor
protocol ShortcutEmitting: AnyObject {
    @discardableResult func emitConfiguredShortcut(for slot: GestureSlot) -> Bool
}

extension GestureEngine: GestureRuntimeControlling {}
extension ShortcutEmitter: ShortcutEmitting {}

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
    func suppress(conflictingSettings: [SystemGestureSetting])
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
    private var runtimeTask: Task<Void, Never>?

    init(
        permissionChecker: PermissionChecking = SystemPermissionChecker(),
        preemptionController: (any PreemptionControlling)? = nil,
        systemGestureManager: (any SystemGestureManaging)? = nil,
        gestureEngine: (any GestureRuntimeControlling)? = nil,
        shortcutEmitter: (any ShortcutEmitting)? = nil
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
                _ = self.shortcutEmitter.emitConfiguredShortcut(for: event.slot)
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
        if isRunning {
            applySystemGestureSuppression()
        }
        refreshSystemGestureConflicts()
    }

    private func applySystemGestureSuppression() {
        if systemGestureManager.isSuppressed {
            systemGestureManager.restore()
        }

        let configuredSlots = configuredGestureSlots()
        let conflictingSettings = preemptionController.conflictingSettings(for: configuredSlots)
        guard !conflictingSettings.isEmpty else { return }

        systemGestureManager.suppress(conflictingSettings: conflictingSettings)
    }

    private func configuredGestureSlots() -> Set<GestureSlot> {
        Set(
            supportedGestureSlots.filter {
                KeyboardShortcuts.getShortcut(for: ShortcutRegistry.name(for: $0)) != nil
            }
        )
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

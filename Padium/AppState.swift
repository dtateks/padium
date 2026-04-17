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
    private enum GestureEventSource {
        case touch
        case physicalClick
    }

    private struct StoredConfiguration: Equatable {
        let configuredSlots: Set<GestureSlot>
        let gestureSensitivity: Double
    }

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
    private let scrollSuppressor: any PhysicalClickCoordinating
    private var runtimeTask: Task<Void, Never>?
    private var observedConfiguration: StoredConfiguration
    private var defaultsObserver: NSObjectProtocol?

    init(
        permissionChecker: PermissionChecking = SystemPermissionChecker(),
        preemptionController: (any PreemptionControlling)? = nil,
        systemGestureManager: (any SystemGestureManaging)? = nil,
        gestureEngine: (any GestureRuntimeControlling)? = nil,
        shortcutEmitter: (any ShortcutEmitting)? = nil,
        middleClickEmitter: (any MiddleClickEmitting)? = nil,
        scrollSuppressor: (any PhysicalClickCoordinating)? = nil
    ) {
        self.coordinator = PermissionCoordinator(checker: permissionChecker)

        let controller = preemptionController ?? PreemptionController()
        self.preemptionController = controller
        let policy = controller.currentPolicy(activeSlots: Set(GestureSlot.allCases))
        let supportedGestureSlots = Self.resolveSupportedGestureSlots(from: policy)
        let initialGestureSensitivity = GestureSensitivitySetting.storedValue()
        let initialConfiguredSlots = Self.configuredGestureSlots(from: supportedGestureSlots)
        self.supportedGestureSlots = supportedGestureSlots
        self.gestureSensitivity = initialGestureSensitivity
        self.systemGestureManager = systemGestureManager ?? SystemGestureManager.shared
        self.systemGestureNotice = nil
        self.conflictingSlots = []
        self.observedConfiguration = StoredConfiguration(
            configuredSlots: initialConfiguredSlots,
            gestureSensitivity: initialGestureSensitivity
        )
        self.defaultsObserver = nil

        if let gestureEngine {
            self.gestureEngine = gestureEngine
        } else {
            self.gestureEngine = GestureEngine(
                source: OMSGestureSource(),
                supportedSlots: Set(supportedGestureSlots)
            )
        }

        self.shortcutEmitter = shortcutEmitter ?? ShortcutEmitter()
        self.middleClickEmitter = middleClickEmitter ?? MiddleClickEmitter()
        self.scrollSuppressor = scrollSuppressor ?? ScrollSuppressor.shared
        self.gestureEngine.updateActiveSlots(configuredGestureSlots())
        refreshSystemGestureConflicts()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStoredConfigurationIfNeeded()
            }
        }
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

    func setAppInteractionActive(_ isActive: Bool) {
        scrollSuppressor.setAppInteractionActive(isActive)
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
        GestureSensitivitySetting.store(clamped)
        UserDefaults.standard.synchronize()
        refreshStoredConfigurationIfNeeded()
    }

    private func startRuntimeIfNeeded() {
        gestureEngine.updateActiveSlots(configuredGestureSlots())
        guard runtimeTask == nil else { return }

        scrollSuppressor.setPhysicalClickHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleGestureEvent(event, source: .physicalClick)
            }
        }
        applySystemGestureSuppression()
        scrollSuppressor.start()

        guard gestureEngine.start() else {
            if let startError = gestureEngine.lastStartError {
                PadiumLogger.gesture.error("Gesture engine failed to start: \(String(describing: startError), privacy: .public)")
            }
            scrollSuppressor.setPhysicalClickHandler(nil)
            scrollSuppressor.stop()
            systemGestureManager.restore()
            return
        }

        runtimeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.gestureEngine.events {
                self.handleGestureEvent(event, source: .touch)
            }
        }
    }

    private func stopRuntime() {
        gestureEngine.stop()
        runtimeTask?.cancel()
        runtimeTask = nil
        scrollSuppressor.setPhysicalClickHandler(nil)
        scrollSuppressor.stop()
        systemGestureManager.restore()
    }

    func handleShortcutConfigurationChange() {
        // Flush shortcut/action-kind changes to disk immediately so they survive
        // unexpected termination or rebuild-kill sequences.
        UserDefaults.standard.synchronize()
        refreshStoredConfigurationIfNeeded()
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
        Self.configuredGestureSlots(from: supportedGestureSlots)
    }

    private func refreshStoredConfigurationIfNeeded() {
        let currentConfiguration = currentStoredConfiguration()
        let previousConfiguration = observedConfiguration
        guard currentConfiguration != previousConfiguration else { return }

        observedConfiguration = currentConfiguration

        if currentConfiguration.gestureSensitivity != gestureSensitivity {
            gestureSensitivity = currentConfiguration.gestureSensitivity
        }

        guard currentConfiguration.configuredSlots != previousConfiguration.configuredSlots else {
            return
        }

        gestureEngine.updateActiveSlots(currentConfiguration.configuredSlots)
        if isRunning {
            applySystemGestureSuppression()
        } else if coordinator.isFullyGranted {
            startRuntimeIfNeeded()
        }
        refreshSystemGestureConflicts()
    }

    private func currentStoredConfiguration() -> StoredConfiguration {
        StoredConfiguration(
            configuredSlots: configuredGestureSlots(),
            gestureSensitivity: GestureSensitivitySetting.storedValue()
        )
    }

    private func handleGestureEvent(_ event: GestureEvent, source: GestureEventSource) {
        guard coordinator.isFullyGranted else { return }

        if source == .touch, !shouldHandleTouchEvent(event) {
            return
        }

        switch actionKind(for: event.slot) {
        case .shortcut:
            _ = shortcutEmitter.emitConfiguredShortcut(for: event.slot)
        case .middleClick:
            PadiumLogger.gesture.debug("TAP-DIAG: emitting middle click for \(event.slot.rawValue, privacy: .public)")
            _ = middleClickEmitter.emitMiddleClick()
        }
    }

    private func shouldHandleTouchEvent(_ event: GestureEvent) -> Bool {
        guard event.slot.isTouchTapGesture else { return true }
        guard scrollSuppressor.shouldAllowTouchTap(
            fingerCount: event.slot.fingerCount,
            at: event.timestamp
        ) else {
            PadiumLogger.gesture.debug("TAP-DIAG: suppressing touch tap after physical click for \(event.slot.rawValue, privacy: .public)")
            return false
        }
        return true
    }

    private func actionKind(for slot: GestureSlot) -> GestureActionKind {
        guard slot.supportsActionKindChoice else { return .shortcut }
        return GestureActionStore.actionKind(for: slot)
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

    static func configuredGestureSlots(from supportedSlots: [GestureSlot]) -> Set<GestureSlot> {
        Set(supportedSlots.filter(\.isConfigured))
    }
}

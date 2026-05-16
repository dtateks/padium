import AppKit
import ApplicationServices
import Foundation
import KeyboardShortcuts
import os

enum PadiumNotification {
    static let configurationDidChange = Notification.Name("Padium_configurationDidChange")
    // Mirrors KeyboardShortcuts' private notification name. Kept as a literal
    // string because the package does not expose it publicly; changes there
    // need a matching update here.
    static let keyboardShortcutDidChange = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")
}

enum RuntimeStatus: Equatable, Sendable {
    case checking
    case permissionsRequired
    case paused
    case degraded
    case active
}

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
    var inputMonitoringState: PermissionState { coordinator.inputMonitoringState }
    var postEventState: PermissionState { coordinator.postEventState }
    var hasOutputAccess: Bool { coordinator.hasOutputAccess }
    var hasInputMonitoringAccess: Bool { coordinator.hasInputMonitoringAccess }
    var isTouchRuntimeActive: Bool { runtimeTask != nil }
    var isPhysicalClickRuntimeActive: Bool { physicalClickRuntimeActive }
    var isRunning: Bool { isTouchRuntimeActive || isPhysicalClickRuntimeActive }
    var runtimeStatus: RuntimeStatus {
        if permissionState == .checking || inputMonitoringState == .checking || postEventState == .checking {
            return .checking
        }
        if !hasOutputAccess {
            return .permissionsRequired
        }
        if isPaused {
            return .paused
        }
        if !hasInputMonitoringAccess || touchRuntimeFailure != nil || physicalClickRuntimeFailure != nil {
            return .degraded
        }
        return .active
    }
    var missingPermissionMessages: [String] {
        var messages: [String] = []

        if permissionState != .granted {
            messages.append("Allow Accessibility so Padium can control other apps.")
        }
        if postEventState != .granted {
            messages.append("Allow Padium to send shortcuts and middle-clicks to other apps.")
        }
        if inputMonitoringState != .granted {
            messages.append("Allow Input Monitoring so Padium can capture physical clicks and suppress scroll during gestures.")
        }

        return messages
    }
    var runtimeFailureMessages: [String] {
        [touchRuntimeFailure, physicalClickRuntimeFailure].compactMap { $0 }
    }
    var systemGestureNotice: String?
    var conflictingSlots: Set<GestureSlot> = []
    let supportedGestureSlots: [GestureSlot]
    var gestureSensitivity: Double
    var isSettingsPresented: Bool = false
    private(set) var isPaused: Bool
    private(set) var isGestureFeedbackEnabled: Bool

    private static let isPausedDefaultsKey = "runtime.isPaused"
    private static let gestureFeedbackEnabledKey = "hud.gestureFeedback.enabled"

    private let coordinator: PermissionCoordinator
    private let preemptionController: any PreemptionControlling
    private let systemGestureManager: any SystemGestureManaging
    private let gestureEngine: any GestureRuntimeControlling
    private let shortcutEmitter: any ShortcutEmitting
    private let middleClickEmitter: any MiddleClickEmitting
    private let scrollSuppressor: any PhysicalClickCoordinating
    private let gestureFeedbackPresenter: any GestureFeedbackPresenting
    private var runtimeTask: Task<Void, Never>?
    private var physicalClickRuntimeActive = false
    private var isAppInteractionActive = false
    private var touchRuntimeFailure: String?
    private var physicalClickRuntimeFailure: String?
    private var observedConfiguration: StoredConfiguration
    private var defaultsObserver: NSObjectProtocol?
    private var shortcutObserver: NSObjectProtocol?

    init(
        permissionChecker: PermissionChecking = SystemPermissionChecker(),
        preemptionController: (any PreemptionControlling)? = nil,
        systemGestureManager: (any SystemGestureManaging)? = nil,
        gestureEngine: (any GestureRuntimeControlling)? = nil,
        shortcutEmitter: (any ShortcutEmitting)? = nil,
        middleClickEmitter: (any MiddleClickEmitting)? = nil,
        scrollSuppressor: (any PhysicalClickCoordinating)? = nil,
        gestureFeedbackPresenter: (any GestureFeedbackPresenting)? = nil
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
        self.isPaused = UserDefaults.standard.bool(forKey: Self.isPausedDefaultsKey)
        self.isGestureFeedbackEnabled = UserDefaults.standard.bool(forKey: Self.gestureFeedbackEnabledKey)
        self.gestureFeedbackPresenter = gestureFeedbackPresenter ?? GestureFeedbackHUD()
        self.systemGestureManager = systemGestureManager ?? SystemGestureManager.shared
        self.systemGestureNotice = nil
        self.conflictingSlots = []
        self.observedConfiguration = StoredConfiguration(
            configuredSlots: initialConfiguredSlots,
            gestureSensitivity: initialGestureSensitivity
        )
        self.defaultsObserver = nil
        self.shortcutObserver = nil

        // Single multitouch state object is the shared seam between the
        // gesture pipeline (writes per-frame finger count + activity) and the
        // scroll suppressor's CGEventTap (reads to gate scroll + physical
        // clicks). Threading the same instance into both makes the dependency
        // explicit instead of relying on a protocol-composition identity trick.
        let multitouchState = MultitouchState()
        let resolvedScrollSuppressor = scrollSuppressor ?? ScrollSuppressor(multitouchState: multitouchState)
        self.scrollSuppressor = resolvedScrollSuppressor

        if let gestureEngine {
            self.gestureEngine = gestureEngine
        } else {
            self.gestureEngine = GestureEngine(
                source: MultitouchGestureSource(),
                supportedSlots: Set(supportedGestureSlots),
                multitouchSink: multitouchState
            )
        }

        self.shortcutEmitter = shortcutEmitter ?? ShortcutEmitter()
        self.middleClickEmitter = middleClickEmitter ?? MiddleClickEmitter()
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
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: PadiumNotification.keyboardShortcutDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                UserDefaults.standard.synchronize()
                self?.refreshStoredConfigurationIfNeeded()
            }
        }
    }

    /// Check permissions and auto-start runtime if granted. Also refreshes system gesture conflicts.
    func refreshPermissions() {
        coordinator.checkPermissions()

        if coordinator.hasOutputAccess && !isPaused {
            startRuntimeIfNeeded()
        } else {
            stopRuntime()
        }

        refreshSystemGestureConflicts()
    }

    /// User-driven pause. While paused both runtimes are stopped, system
    /// gestures are restored, and permission/activation refresh hooks will
    /// not auto-start until the user resumes.
    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        UserDefaults.standard.set(paused, forKey: Self.isPausedDefaultsKey)

        if paused {
            stopRuntime()
        } else if coordinator.hasOutputAccess {
            startRuntimeIfNeeded()
        }
    }

    func togglePaused() {
        setPaused(!isPaused)
    }

    /// Toggle the on-screen confirmation HUD shown each time Padium emits
    /// a gesture-driven shortcut or middle-click. Off by default; the
    /// preference is persisted under UserDefaults.
    func setGestureFeedbackEnabled(_ enabled: Bool) {
        guard isGestureFeedbackEnabled != enabled else { return }
        isGestureFeedbackEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.gestureFeedbackEnabledKey)
    }

    func toggleGestureFeedback() {
        setGestureFeedbackEnabled(!isGestureFeedbackEnabled)
    }

    func requestAccessibility() {
        coordinator.requestAccessibility()
    }

    func requestMissingPermissions() {
        coordinator.requestMissingPermissions()
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
        isAppInteractionActive = isActive
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

        guard coordinator.hasOutputAccess else {
            PadiumLogger.permission.notice("Required output permissions missing at launch; prompting then terminating")
            requestMissingPermissions()
            stopPermissionPolling()

            Task { @MainActor in
                await Task.yield()
                onMissingPermissions()
            }
            return
        }

        if !coordinator.hasInputMonitoringAccess {
            requestMissingPermissions()
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
        if refreshStoredConfigurationIfNeeded() {
            NotificationCenter.default.post(name: PadiumNotification.configurationDidChange, object: nil)
        }
    }

    private func startRuntimeIfNeeded() {
        gestureEngine.updateActiveSlots(configuredGestureSlots())

        startTouchRuntimeIfNeeded()

        if coordinator.hasInputMonitoringAccess {
            startPhysicalClickRuntimeIfNeeded()
        } else {
            stopPhysicalClickRuntime()
            physicalClickRuntimeFailure = hasOutputAccess
                ? "Input Monitoring is missing. Physical 3/4-finger click gestures and scroll suppression are unavailable."
                : nil
        }
    }

    private func startTouchRuntimeIfNeeded() {
        guard runtimeTask == nil else { return }

        guard gestureEngine.start() else {
            touchRuntimeFailure = touchRuntimeFailureMessage()
            systemGestureManager.restore()
            return
        }

        touchRuntimeFailure = nil
        applySystemGestureSuppression()

        runtimeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.gestureEngine.events {
                self.handleGestureEvent(event, source: .touch)
            }
        }
    }

    private func startPhysicalClickRuntimeIfNeeded() {
        guard !physicalClickRuntimeActive else {
            physicalClickRuntimeFailure = nil
            scrollSuppressor.setAppInteractionActive(isAppInteractionActive)
            return
        }

        scrollSuppressor.setPhysicalClickHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleGestureEvent(event, source: .physicalClick)
            }
        }

        guard scrollSuppressor.start() else {
            scrollSuppressor.setPhysicalClickHandler(nil)
            physicalClickRuntimeFailure = "Event tap failed to start. Physical 3/4-finger click gestures and scroll suppression are unavailable."
            PadiumLogger.gesture.notice(
                "TAP-DIAG: physical click runtime failed to start output=\(self.hasOutputAccess) input=\(self.hasInputMonitoringAccess) appInteraction=\(self.isAppInteractionActive)"
            )
            return
        }

        scrollSuppressor.setAppInteractionActive(isAppInteractionActive)
        physicalClickRuntimeActive = true
        physicalClickRuntimeFailure = nil
        PadiumLogger.gesture.notice(
            "TAP-DIAG: physical click runtime active output=\(self.hasOutputAccess) input=\(self.hasInputMonitoringAccess) appInteraction=\(self.isAppInteractionActive)"
        )
    }

    private func stopRuntime() {
        stopTouchRuntime()
        stopPhysicalClickRuntime()
        touchRuntimeFailure = nil
        physicalClickRuntimeFailure = nil
    }

    private func stopTouchRuntime() {
        gestureEngine.stop()
        runtimeTask?.cancel()
        runtimeTask = nil
        systemGestureManager.restore()
    }

    private func stopPhysicalClickRuntime() {
        scrollSuppressor.setPhysicalClickHandler(nil)
        scrollSuppressor.stop()
        physicalClickRuntimeActive = false
    }

    func handleShortcutConfigurationChange() {
        // Flush shortcut/action-kind changes to disk immediately so they survive
        // unexpected termination or rebuild-kill sequences.
        UserDefaults.standard.synchronize()
        refreshStoredConfigurationIfNeeded()
        NotificationCenter.default.post(name: PadiumNotification.configurationDidChange, object: nil)
    }

    private func applySystemGestureSuppression() {
        let configuredSlots = configuredGestureSlots()
        let allSettings = preemptionController.currentSystemGestureSettings()
        let conflictingSettings = preemptionController.conflictingSettings(for: configuredSlots)
        guard !conflictingSettings.isEmpty else {
            if systemGestureManager.isSuppressed {
                systemGestureManager.restore()
            }
            return
        }

        systemGestureManager.suppress(conflictingSettings: conflictingSettings, allSettings: allSettings)
    }

    private func configuredGestureSlots() -> Set<GestureSlot> {
        Self.configuredGestureSlots(from: supportedGestureSlots)
    }

    @discardableResult
    private func refreshStoredConfigurationIfNeeded() -> Bool {
        let currentConfiguration = currentStoredConfiguration()
        let previousConfiguration = observedConfiguration
        guard currentConfiguration != previousConfiguration else { return false }

        let currentConflictingSettingKeys = Set(
            preemptionController.conflictingSettings(for: currentConfiguration.configuredSlots).map(\.key)
        )
        let previousConflictingSettingKeys = Set(
            preemptionController.conflictingSettings(for: previousConfiguration.configuredSlots).map(\.key)
        )
        let systemGestureSuppressionChanged = currentConflictingSettingKeys != previousConflictingSettingKeys

        observedConfiguration = currentConfiguration

        if currentConfiguration.gestureSensitivity != gestureSensitivity {
            gestureSensitivity = currentConfiguration.gestureSensitivity
        }

        guard currentConfiguration.configuredSlots != previousConfiguration.configuredSlots else {
            return true
        }

        gestureEngine.updateActiveSlots(currentConfiguration.configuredSlots)
        if isTouchRuntimeActive, systemGestureSuppressionChanged {
            applySystemGestureSuppression()
        } else if coordinator.hasOutputAccess {
            startRuntimeIfNeeded()
        }
        refreshSystemGestureConflicts()
        return true
    }

    private func currentStoredConfiguration() -> StoredConfiguration {
        StoredConfiguration(
            configuredSlots: configuredGestureSlots(),
            gestureSensitivity: GestureSensitivitySetting.storedValue()
        )
    }

    private func handleGestureEvent(_ event: GestureEvent, source: GestureEventSource) {
        guard coordinator.hasOutputAccess else { return }

        if source == .touch, !shouldHandleTouchEvent(event) {
            return
        }

        let actionKind = actionKind(for: event.slot)
        if event.slot.isTapGesture {
            PadiumLogger.gesture.notice(
                "TAP-DIAG: dispatch slot=\(event.slot.rawValue, privacy: .public) source=\(String(describing: source), privacy: .public) action=\(actionKind.rawValue, privacy: .public)"
            )
        }

        let didEmit: Bool
        switch actionKind {
        case .shortcut:
            didEmit = shortcutEmitter.emitConfiguredShortcut(for: event.slot)
            if event.slot.isTapGesture {
                PadiumLogger.gesture.notice(
                    "TAP-DIAG: shortcut emit slot=\(event.slot.rawValue, privacy: .public) success=\(didEmit)"
                )
            }
        case .middleClick:
            didEmit = middleClickEmitter.emitMiddleClick()
            PadiumLogger.gesture.notice(
                "TAP-DIAG: middle click emit slot=\(event.slot.rawValue, privacy: .public) success=\(didEmit)"
            )
        }

        if didEmit, isGestureFeedbackEnabled {
            let message = GestureFeedbackMessage.format(slot: event.slot, action: actionKind)
            gestureFeedbackPresenter.showFeedback(message)
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

    private func touchRuntimeFailureMessage() -> String {
        if let startError = gestureEngine.lastStartError {
            PadiumLogger.gesture.error("Gesture engine failed to start: \(String(describing: startError), privacy: .public)")
        }
        return "Touch listener failed to start. Swipe and touch-tap gestures are unavailable."
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

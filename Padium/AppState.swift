import ApplicationServices
import Foundation
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
    private let preemptionController: PreemptionController
    private let gestureEngine: any GestureRuntimeControlling
    private let shortcutEmitter: any ShortcutEmitting
    private var runtimeTask: Task<Void, Never>?

    init(
        permissionChecker: PermissionChecking = SystemPermissionChecker(),
        preemptionController: PreemptionController? = nil,
        gestureEngine: (any GestureRuntimeControlling)? = nil,
        shortcutEmitter: (any ShortcutEmitting)? = nil
    ) {
        self.coordinator = PermissionCoordinator(checker: permissionChecker)

        let controller = preemptionController ?? PreemptionController()
        self.preemptionController = controller
        let policy = controller.currentPolicy()
        let supportedGestureSlots = Self.resolveSupportedGestureSlots(from: policy)
        self.systemGestureNotice = policy.ownerNotice
        self.conflictingSlots = controller.conflictingSlots()
        self.supportedGestureSlots = supportedGestureSlots
        self.gestureSensitivity = GestureSensitivitySetting.storedValue()

        if let gestureEngine {
            self.gestureEngine = gestureEngine
        } else {
            self.gestureEngine = GestureEngine(source: OMSGestureSource(), supportedSlots: Set(supportedGestureSlots))
        }

        self.shortcutEmitter = shortcutEmitter ?? ShortcutEmitter()
    }

    /// Check permissions and auto-start runtime if granted. Also refreshes system gesture conflicts.
    func refreshPermissions() {
        coordinator.checkPermissions()
        refreshSystemGestureConflicts()

        if coordinator.isFullyGranted {
            startRuntimeIfNeeded()
        } else {
            stopRuntime()
        }
    }

    func requestAccessibility() {
        coordinator.requestAccessibility()
    }

    func refreshSystemGestureConflicts() {
        let policy = preemptionController.currentPolicy()
        systemGestureNotice = policy.ownerNotice
        conflictingSlots = preemptionController.conflictingSlots()
    }

    func openTrackpadSettings() {
        preemptionController.openTrackpadSettings()
    }

    func systemGestureSettings() -> [SystemGestureSetting] {
        preemptionController.currentSystemGestureSettings()
    }

    func handleAppLaunch(onMissingPermissions: @escaping @MainActor () -> Void) {
        // If a previous session crashed without restoring system gestures, restore now.
        SystemGestureManager.shared.restoreIfNeeded()

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

        if isRunning {
            restartRuntime()
        }
    }

    private func startRuntimeIfNeeded() {
        guard runtimeTask == nil else { return }

        SystemGestureManager.shared.suppress()
        ScrollSuppressor.shared.start()

        guard gestureEngine.start() else {
            if let startError = gestureEngine.lastStartError {
                PadiumLogger.gesture.error("Gesture engine failed to start: \(String(describing: startError), privacy: .public)")
            }
            ScrollSuppressor.shared.stop()
            SystemGestureManager.shared.restore()
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
        SystemGestureManager.shared.restore()
    }

    private func restartRuntime() {
        stopRuntime()
        startRuntimeIfNeeded()
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

import AppKit
import Foundation
import os

/// Read-only surface over recent keyboard activity. Used by the gesture pipeline
/// as a palm-rejection signal: if the user is typing, any accidental trackpad
/// contact (e.g. a palm brushing a corner while the hands rest on the keyboard)
/// must not register as a touch tap.
protocol KeyboardActivitySensing: AnyObject, Sendable {
    /// Whether any key was pressed within the given interval from now.
    func wasKeyPressedRecently(within interval: TimeInterval) -> Bool
}

/// Lifecycle-facing surface injected into orchestration.
protocol KeyboardActivityMonitoring: KeyboardActivitySensing {
    func start()
    func stop()
}

/// Passive global-keydown observer used strictly as a palm-rejection signal:
/// never consumes events, never affects keyboard delivery. Works off the
/// Accessibility permission Padium already holds — no extra permission needed.
///
/// Thread-safety: the `NSEvent` monitor handlers run on the main thread, but
/// `wasKeyPressedRecently` is called from `GestureEngine.handleLift` on the
/// pipeline Task. The last-keypress timestamp is therefore guarded by an
/// `os_unfair_lock`.
final class KeyboardActivityMonitor: @unchecked Sendable, KeyboardActivityMonitoring {

    static let shared = KeyboardActivityMonitor()

    private var _lock = os_unfair_lock()
    private var _lastKeyDownReferenceTime: TimeInterval?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init() {}

    func start() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.recordKeyPress()
        }
        // Local monitor covers the (rare) case where a keyDown is delivered to
        // Padium's own window — e.g. the Settings recorder has focus. Still
        // passive: the event is returned unchanged.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.recordKeyPress()
            return event
        }

        PadiumLogger.gesture.info("Keyboard activity monitor started")
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }

        os_unfair_lock_lock(&_lock)
        _lastKeyDownReferenceTime = nil
        os_unfair_lock_unlock(&_lock)

        PadiumLogger.gesture.info("Keyboard activity monitor stopped")
    }

    func wasKeyPressedRecently(within interval: TimeInterval) -> Bool {
        os_unfair_lock_lock(&_lock)
        let lastReferenceTime = _lastKeyDownReferenceTime
        os_unfair_lock_unlock(&_lock)

        guard let lastReferenceTime else { return false }
        let elapsed = Date().timeIntervalSinceReferenceDate - lastReferenceTime
        return elapsed >= 0 && elapsed <= interval
    }

    private func recordKeyPress() {
        let now = Date().timeIntervalSinceReferenceDate
        os_unfair_lock_lock(&_lock)
        _lastKeyDownReferenceTime = now
        os_unfair_lock_unlock(&_lock)
    }
}

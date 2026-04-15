import CoreGraphics
import Foundation

/// Suppresses macOS scroll wheel events while 3+ finger multitouch is active.
///
/// Uses a CGEventTap at `.cghidEventTap` to intercept `scrollWheel` events.
/// When `isMultitouchActive` is true, scroll events (including subsequent momentum
/// events) are consumed (returning nil) so they don't reach the active window.
///
/// Thread-safety: `isMultitouchActive` is set from the OMS touch callback thread
/// and read from the CGEventTap callback thread. Uses `os_unfair_lock` for safety.
final class ScrollSuppressor: @unchecked Sendable {

    static let shared = ScrollSuppressor()

    // MARK: - Thread-safe multitouch flag

    private var _lock = os_unfair_lock()
    private var _multitouchActive = false
    private var _suppressMomentum = false

    /// Set to `true` when 3+ fingers are actively touching the trackpad.
    /// Set to `false` when fingers lift.
    var isMultitouchActive: Bool {
        get {
            os_unfair_lock_lock(&_lock)
            defer { os_unfair_lock_unlock(&_lock) }
            return _multitouchActive
        }
        set {
            os_unfair_lock_lock(&_lock)
            let wasActive = _multitouchActive
            _multitouchActive = newValue
            if newValue && !wasActive {
                // Entering multitouch — any ongoing or future scroll should be suppressed
                _suppressMomentum = true
            }
            if !newValue && wasActive {
                // Fingers lifted — keep suppressing momentum until momentum ends
                // _suppressMomentum stays true; cleared when momentum phase ends
            }
            os_unfair_lock_unlock(&_lock)
        }
    }

    // MARK: - Event tap

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?

    func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = 1 << CGEventType.scrollWheel.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: scrollTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            PadiumLogger.gesture.error("Failed to create scroll suppressor event tap")
            return
        }

        eventTap = tap

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            PadiumLogger.gesture.error("Failed to create run loop source for scroll suppressor")
            eventTap = nil
            return
        }

        runLoopSource = source

        // Run the tap on a dedicated thread so it doesn't block the main thread
        let thread = Thread { [weak self] in
            guard let self, let source = self.runLoopSource, let tap = self.eventTap else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "com.padium.scroll-suppressor"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread

        PadiumLogger.gesture.info("Scroll suppressor started")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if runLoopSource != nil {
            // Signal the run loop on the tap thread to stop
            if let thread = tapThread {
                CFRunLoopStop(CFRunLoopGetMain()) // fallback
                // The thread's run loop will exit when the source is removed
                _ = thread
            }
        }
        eventTap = nil
        runLoopSource = nil
        tapThread = nil

        os_unfair_lock_lock(&_lock)
        _multitouchActive = false
        _suppressMomentum = false
        os_unfair_lock_unlock(&_lock)

        PadiumLogger.gesture.info("Scroll suppressor stopped")
    }

    // MARK: - Internal suppression logic

    fileprivate func shouldSuppress(_ event: CGEvent) -> Bool {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        if _multitouchActive {
            return true
        }

        // After fingers lift, only suppress leftover momentum from the 3-finger swipe.
        // Any NEW scroll sequence (began/mayBegin) must pass through immediately.
        if _suppressMomentum {
            let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            // momentumPhase: 0 = none, 1 = began, 2 = changed, 3 = ended
            if momentumPhase != 0 {
                if momentumPhase == 3 {
                    _suppressMomentum = false
                }
                return true
            }

            let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            // scrollPhase: 1 = began, 2 = changed, 4 = ended, 8 = cancelled, 128 = mayBegin

            // New scroll sequence from the user (2-finger) — stop suppressing immediately.
            if scrollPhase == 1 || scrollPhase == 128 {
                _suppressMomentum = false
                return false
            }

            // End of the old scroll sequence or a discrete (legacy) event — clear and pass.
            if scrollPhase == 4 || scrollPhase == 8 || scrollPhase == 0 {
                _suppressMomentum = false
                return false
            }

            // scrollPhase == 2 (changed) from the old sequence — still suppress.
            return true
        }

        return false
    }
}

private func scrollTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let suppressor = Unmanaged<ScrollSuppressor>.fromOpaque(userInfo).takeUnretainedValue()

    // Re-enable tap if it was disabled by timeout
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = suppressor.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .scrollWheel else {
        return Unmanaged.passUnretained(event)
    }

    if suppressor.shouldSuppress(event) {
        return nil // consume the scroll event
    }

    return Unmanaged.passUnretained(event)
}

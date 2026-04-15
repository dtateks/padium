import CoreGraphics
import Foundation

/// Suppresses macOS scroll wheel events while 3+ finger multitouch is active.
///
/// Uses a CGEventTap at `.cghidEventTap` to intercept `scrollWheel`,
/// `leftMouseDown`, and `leftMouseUp` events. When `isMultitouchActive` is true,
/// scroll events (including subsequent momentum events) are consumed so they don't
/// reach the active window. Physical left clicks with 3+ fingers can also be
/// converted to middle-click events when the 3-finger tap slot is configured for it.
///
/// Thread-safety: `isMultitouchActive` is set from the OMS touch callback thread
/// and read from the CGEventTap callback thread. Uses `os_unfair_lock` for safety.
final class ScrollSuppressor: @unchecked Sendable {

    enum EventDisposition {
        case passThrough
        case suppress
        case replace(CGEvent)
    }

    static let shared = ScrollSuppressor()
    static let syntheticMiddleClickMarker: Int64 = 0x50414449554D

    private enum LeftMouseState {
        case idle
        case suppressingOriginalPair
        case convertingPair
    }

    private static let middleClickDedupWindow: TimeInterval = 0.5
    private static let middleMouseButtonNumber = Int64(CGMouseButton.center.rawValue)

    // MARK: - Thread-safe multitouch flag

    private var _lock = os_unfair_lock()
    private var _multitouchActive = false
    private var _currentFingerCount = 0
    private var _suppressMomentum = false
    private var _leftMouseState: LeftMouseState = .idle
    private var _lastTapMiddleClickAt: TimeInterval?
    private var _lastPhysicalMiddleClickAt: TimeInterval?

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

    /// Set to the current number of touches observed on the trackpad.
    var currentFingerCount: Int {
        get {
            os_unfair_lock_lock(&_lock)
            defer { os_unfair_lock_unlock(&_lock) }
            return _currentFingerCount
        }
        set {
            os_unfair_lock_lock(&_lock)
            _currentFingerCount = max(newValue, 0)
            os_unfair_lock_unlock(&_lock)
        }
    }

    // MARK: - Event tap

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?

    func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)

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
        _currentFingerCount = 0
        _suppressMomentum = false
        _leftMouseState = .idle
        _lastTapMiddleClickAt = nil
        _lastPhysicalMiddleClickAt = nil
        os_unfair_lock_unlock(&_lock)

        PadiumLogger.gesture.info("Scroll suppressor stopped")
    }

    @discardableResult
    func registerGestureMiddleClickIfNeeded(at timestamp: Date) -> Bool {
        let referenceTime = timestamp.timeIntervalSinceReferenceDate

        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        guard _leftMouseState == .idle else { return false }
        guard !isWithinDedupWindow(at: referenceTime, since: _lastPhysicalMiddleClickAt) else {
            return false
        }

        _lastTapMiddleClickAt = referenceTime
        return true
    }

    func eventDisposition(for type: CGEventType, event: CGEvent) -> EventDisposition {
        let isMiddleClickConfigured = GestureActionStore.actionKind(for: .threeFingerTap) == .middleClick
        return eventDisposition(for: type, event: event, isMiddleClickConfigured: isMiddleClickConfigured)
    }

    func eventDisposition(
        for type: CGEventType,
        event: CGEvent,
        isMiddleClickConfigured: Bool
    ) -> EventDisposition {
        switch type {
        case .scrollWheel:
            return shouldSuppress(event) ? .suppress : .passThrough
        case .leftMouseDown, .leftMouseUp:
            return leftMouseDisposition(
                for: type,
                event: event,
                isMiddleClickConfigured: isMiddleClickConfigured
            )
        default:
            return .passThrough
        }
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

    fileprivate func leftMouseDisposition(
        for type: CGEventType,
        event: CGEvent,
        isMiddleClickConfigured: Bool
    ) -> EventDisposition {
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMiddleClickMarker {
            return .passThrough
        }

        let referenceTime = Date().timeIntervalSinceReferenceDate

        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        if type == .leftMouseUp {
            switch _leftMouseState {
            case .convertingPair:
                guard let convertedEvent = Self.makeMiddleClickEvent(from: event, mouseType: .otherMouseUp) else {
                    _leftMouseState = .idle
                    PadiumLogger.gesture.error("Failed to convert physical click up to middle click")
                    return .passThrough
                }
                _leftMouseState = .idle
                _lastPhysicalMiddleClickAt = referenceTime
                PadiumLogger.gesture.debug("TAP-DIAG: converting physical click up to middle click")
                return .replace(convertedEvent)
            case .suppressingOriginalPair:
                _leftMouseState = .idle
                PadiumLogger.gesture.debug("TAP-DIAG: suppressing duplicate physical click up after tap middle click")
                return .suppress
            case .idle:
                break
            }
        }

        guard type == .leftMouseDown,
              isMiddleClickConfigured,
              _currentFingerCount >= 3 else {
            return .passThrough
        }

        if isWithinDedupWindow(at: referenceTime, since: _lastTapMiddleClickAt) {
            _leftMouseState = .suppressingOriginalPair
            PadiumLogger.gesture.debug("TAP-DIAG: suppressing duplicate physical click down after tap middle click")
            return .suppress
        }

        guard let convertedEvent = Self.makeMiddleClickEvent(from: event, mouseType: .otherMouseDown) else {
            PadiumLogger.gesture.error("Failed to convert physical click down to middle click")
            return .passThrough
        }

        _leftMouseState = .convertingPair
        _lastPhysicalMiddleClickAt = referenceTime
        PadiumLogger.gesture.debug("TAP-DIAG: converting physical click down to middle click fc=\(self._currentFingerCount)")
        return .replace(convertedEvent)
    }

    static func configureMiddleClickEvent(_ event: CGEvent, clickState: Int64) {
        event.setIntegerValueField(.mouseEventButtonNumber, value: middleMouseButtonNumber)
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMiddleClickMarker)
    }

    private func isWithinDedupWindow(at referenceTime: TimeInterval, since priorTime: TimeInterval?) -> Bool {
        guard let priorTime else { return false }
        return referenceTime - priorTime <= Self.middleClickDedupWindow
    }

    private static func makeMiddleClickEvent(from event: CGEvent, mouseType: CGEventType) -> CGEvent? {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let convertedEvent = CGEvent(
                mouseEventSource: source,
                mouseType: mouseType,
                mouseCursorPosition: event.location,
                mouseButton: .center
              )
        else {
            return nil
        }

        convertedEvent.flags = event.flags
        let clickState = max(event.getIntegerValueField(.mouseEventClickState), 1)
        configureMiddleClickEvent(convertedEvent, clickState: clickState)
        return convertedEvent
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

    switch suppressor.eventDisposition(for: type, event: event) {
    case .passThrough:
        return Unmanaged.passUnretained(event)
    case .suppress:
        return nil
    case .replace(let replacement):
        return Unmanaged.passRetained(replacement)
    }
}

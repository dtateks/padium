import AppKit
import CoreGraphics
import Foundation

protocol PhysicalClickScheduledWork: AnyObject {
    func cancel()
}

protocol PhysicalClickScheduling: AnyObject {
    @discardableResult
    func schedule(after delay: TimeInterval, action: @escaping @Sendable () -> Void) -> any PhysicalClickScheduledWork
}

final class DispatchPhysicalClickScheduler: PhysicalClickScheduling {
    @discardableResult
    func schedule(after delay: TimeInterval, action: @escaping @Sendable () -> Void) -> any PhysicalClickScheduledWork {
        DispatchPhysicalClickWork(delay: delay, action: action)
    }
}

final class DispatchPhysicalClickWork: PhysicalClickScheduledWork {
    private var workItem: DispatchWorkItem?

    init(delay: TimeInterval, action: @escaping @Sendable () -> Void) {
        let item = DispatchWorkItem(block: action)
        self.workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}

/// Orchestration-facing surface of the scroll suppressor: lifecycle, physical-click
/// routing, and the post-click touch-tap guard. Narrowed so AppState depends on
/// behaviour rather than a shared singleton.
protocol PhysicalClickCoordinating: AnyObject, Sendable {
    typealias ClickHandler = @Sendable (GestureEvent) -> Void
    func setPhysicalClickHandler(_ handler: ClickHandler?)
    func setAppInteractionActive(_ isActive: Bool)
    @discardableResult func start() -> Bool
    func stop()
    func shouldAllowTouchTap(fingerCount: Int, at timestamp: Date) -> Bool
}

/// Write-only surface of multitouch state used by the gesture pipeline to keep
/// scroll suppression and the trackpad-active flag in sync with the touch stream.
protocol MultitouchStateSink: AnyObject, Sendable {
    var currentFingerCount: Int { get set }
    var isMultitouchActive: Bool { get set }
}

/// Suppresses macOS scroll wheel events while 3+ finger multitouch is active.
///
/// Uses a CGEventTap at `.cghidEventTap` to intercept `scrollWheel`,
/// `leftMouseDown`, and `leftMouseUp` events. When `isMultitouchActive` is true,
/// scroll events (including subsequent momentum events) are consumed so they don't
/// reach the active window. Physical left clicks with 3/4 fingers are only
/// routed through AppState when stable multitouch is active, so raw landing/lift
/// frames do not swallow ordinary UI clicks.
///
/// Thread-safety: `isMultitouchActive` is set from the OMS touch callback thread
/// and read from the CGEventTap callback thread. Uses `os_unfair_lock` for safety.
final class ScrollSuppressor: @unchecked Sendable, PhysicalClickCoordinating, MultitouchStateSink {

    typealias PhysicalClickHandler = @Sendable (GestureEvent) -> Void

    private struct PendingPhysicalClick {
        let singleSlot: GestureSlot?
        let work: any PhysicalClickScheduledWork
    }

    enum EventDisposition {
        case passThrough
        case suppress
    }

    static let shared = ScrollSuppressor()
    static let syntheticMiddleClickMarker: Int64 = 0x50414449554D

    private enum LeftMouseState {
        case idle
        case suppressingHandledPair
    }

    // Raw values of CGEvent's kCGScrollWheelEventScrollPhase field. CoreGraphics
    // exposes these as opaque Int64 with no Swift enum; named cases make the
    // suppression logic self-documenting. `noPhase` instead of `none` because
    // the field gets matched as an Optional (from a failable rawValue init) and
    // `.none` would shadow `Optional.none` inside the switch.
    private enum ScrollPhase: Int64 {
        case noPhase = 0
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
        case mayBegin = 128
    }

    // Raw values of CGEvent's kCGScrollWheelEventMomentumPhase field.
    private enum MomentumPhase: Int64 {
        case noPhase = 0
        case began = 1
        case changed = 2
        case ended = 3
    }

    private static let physicalClickDedupWindow: TimeInterval = 0.5
    private static let physicalDoubleClickWindow: TimeInterval = NSEvent.doubleClickInterval
    private static let middleMouseButtonNumber = Int64(CGMouseButton.center.rawValue)

    // MARK: - Thread-safe multitouch flag

    private var _lock = os_unfair_lock()
    private var _multitouchActive = false
    private var _currentFingerCount = 0
    private var _suppressMomentum = false
    private var _leftMouseState: LeftMouseState = .idle
    private var _lastPhysicalClickAtByFingerCount: [Int: TimeInterval] = [:]
    private var _pendingPhysicalClicksByFingerCount: [Int: PendingPhysicalClick] = [:]
    private var _physicalClickHandler: PhysicalClickHandler?
    private var _appInteractionActive = false
    private var _tapRunLoop: CFRunLoop?

    private let clickScheduler: any PhysicalClickScheduling

    init(clickScheduler: (any PhysicalClickScheduling)? = nil) {
        self.clickScheduler = clickScheduler ?? DispatchPhysicalClickScheduler()
    }

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

    private func setTapRunLoop(_ runLoop: CFRunLoop?) {
        os_unfair_lock_lock(&_lock)
        _tapRunLoop = runLoop
        os_unfair_lock_unlock(&_lock)
    }

    private func tapRunLoop() -> CFRunLoop? {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _tapRunLoop
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

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
            return false
        }

        eventTap = tap

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            PadiumLogger.gesture.error("Failed to create run loop source for scroll suppressor")
            eventTap = nil
            return false
        }

        runLoopSource = source

        // Run the tap on a dedicated thread so it doesn't block the main thread.
        // The thread stores its CFRunLoop on self before entering CFRunLoopRun so
        // stop() can wake it deterministically and let it exit cleanly.
        let thread = Thread { [weak self] in
            guard let self, let source = self.runLoopSource, let tap = self.eventTap else { return }
            let runLoop = CFRunLoopGetCurrent()
            self.setTapRunLoop(runLoop)
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            self.setTapRunLoop(nil)
        }
        thread.name = "com.padium.scroll-suppressor"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread

        PadiumLogger.gesture.info("Scroll suppressor started")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop = tapRunLoop() {
            CFRunLoopStop(runLoop)
        }
        eventTap = nil
        runLoopSource = nil
        tapThread = nil

        os_unfair_lock_lock(&_lock)
        _multitouchActive = false
        _currentFingerCount = 0
        _suppressMomentum = false
        _leftMouseState = .idle
        _lastPhysicalClickAtByFingerCount = [:]
        for pendingClick in _pendingPhysicalClicksByFingerCount.values {
            pendingClick.work.cancel()
        }
        _pendingPhysicalClicksByFingerCount = [:]
        _physicalClickHandler = nil
        _appInteractionActive = false
        os_unfair_lock_unlock(&_lock)

        PadiumLogger.gesture.info("Scroll suppressor stopped")
    }

    func setPhysicalClickHandler(_ handler: PhysicalClickHandler?) {
        os_unfair_lock_lock(&_lock)
        _physicalClickHandler = handler
        os_unfair_lock_unlock(&_lock)
    }

    func setAppInteractionActive(_ isActive: Bool) {
        os_unfair_lock_lock(&_lock)
        _appInteractionActive = isActive
        if isActive {
            _leftMouseState = .idle
            _lastPhysicalClickAtByFingerCount = [:]
            for pendingClick in _pendingPhysicalClicksByFingerCount.values {
                pendingClick.work.cancel()
            }
            _pendingPhysicalClicksByFingerCount = [:]
        }
        os_unfair_lock_unlock(&_lock)
    }

    func shouldAllowTouchTap(fingerCount: Int, at timestamp: Date) -> Bool {
        guard fingerCount >= 3 else { return true }
        let referenceTime = timestamp.timeIntervalSinceReferenceDate

        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        guard !isWithinDedupWindow(
            at: referenceTime,
            since: _lastPhysicalClickAtByFingerCount[fingerCount]
        ) else {
            return false
        }
        return true
    }

    func eventDisposition(for type: CGEventType, event: CGEvent) -> EventDisposition {
        eventDisposition(
            for: type,
            event: event,
            configuredClickSlotsResolver: { fingerCount in
                self.configuredClickSlots(for: fingerCount)
            }
        )
    }

    func eventDisposition(
        for type: CGEventType,
        event: CGEvent,
        configuredClickSlotsResolver: (Int) -> (single: GestureSlot?, double: GestureSlot?)
    ) -> EventDisposition {
        switch type {
        case .scrollWheel:
            return shouldSuppress(event) ? .suppress : .passThrough
        case .leftMouseDown, .leftMouseUp:
            return leftMouseDisposition(
                for: type,
                event: event,
                configuredClickSlotsResolver: configuredClickSlotsResolver
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
            let momentumPhase = MomentumPhase(rawValue: event.getIntegerValueField(.scrollWheelEventMomentumPhase))
            if let momentumPhase, momentumPhase != .noPhase {
                if momentumPhase == .ended {
                    _suppressMomentum = false
                }
                return true
            }

            let scrollPhase = ScrollPhase(rawValue: event.getIntegerValueField(.scrollWheelEventScrollPhase))
            switch scrollPhase {
            case .began, .mayBegin:
                // New scroll sequence from the user (2-finger) — stop suppressing immediately.
                _suppressMomentum = false
                return false
            case .noPhase, .ended, .cancelled:
                // End of the old scroll sequence or a discrete (legacy) event — clear and pass.
                _suppressMomentum = false
                return false
            case .changed, nil:
                // Continuation of the old suppressed sequence, or an unknown raw value — keep suppressing.
                return true
            }
        }

        return false
    }

    fileprivate func leftMouseDisposition(
        for type: CGEventType,
        event: CGEvent,
        configuredClickSlotsResolver: (Int) -> (single: GestureSlot?, double: GestureSlot?)
    ) -> EventDisposition {
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMiddleClickMarker {
            return .passThrough
        }

        let referenceTime = Date().timeIntervalSinceReferenceDate
        let clickState = max(event.getIntegerValueField(.mouseEventClickState), 1)
        let eventTimestamp = Date(timeIntervalSinceReferenceDate: referenceTime)
        var eventToDispatch: GestureEvent?
        var clickHandler: PhysicalClickHandler?
        var disposition: EventDisposition = .passThrough

        os_unfair_lock_lock(&_lock)

        if type == .leftMouseUp {
            if _appInteractionActive {
                os_unfair_lock_unlock(&_lock)
                return .passThrough
            }
            if _leftMouseState == .suppressingHandledPair {
                _leftMouseState = .idle
                disposition = .suppress
            }
            os_unfair_lock_unlock(&_lock)
            return disposition
        }

        guard type == .leftMouseDown else {
            os_unfair_lock_unlock(&_lock)
            return .passThrough
        }

        if Self.isSystemMenuBarClick(at: event.location) {
            PadiumLogger.gesture.notice(
                "TAP-DIAG: click pass-through systemMenuBar fc=\(self._currentFingerCount) multitouch=\(self._multitouchActive) appInteraction=\(self._appInteractionActive)"
            )
            os_unfair_lock_unlock(&_lock)
            return .passThrough
        }

        if _appInteractionActive {
            PadiumLogger.gesture.notice(
                "TAP-DIAG: click pass-through appInteraction fc=\(self._currentFingerCount) multitouch=\(self._multitouchActive)"
            )
            os_unfair_lock_unlock(&_lock)
            return .passThrough
        }

        let fingerCount = _currentFingerCount
        guard _multitouchActive, (3...4).contains(fingerCount) else {
            if (3...4).contains(fingerCount) || _multitouchActive {
                PadiumLogger.gesture.notice(
                    "TAP-DIAG: click pass-through preconditions fc=\(fingerCount) multitouch=\(self._multitouchActive) appInteraction=\(self._appInteractionActive)"
                )
            }
            os_unfair_lock_unlock(&_lock)
            return .passThrough
        }

        let configuredSlots = configuredClickSlotsResolver(fingerCount)
        guard configuredSlots.single != nil || configuredSlots.double != nil else {
            PadiumLogger.gesture.notice(
                "TAP-DIAG: click pass-through noConfiguredSlots fc=\(fingerCount) multitouch=\(self._multitouchActive)"
            )
            os_unfair_lock_unlock(&_lock)
            return .passThrough
        }

        if (3...4).contains(fingerCount) {
            _lastPhysicalClickAtByFingerCount[fingerCount] = referenceTime
        }

        _leftMouseState = .suppressingHandledPair
        disposition = .suppress
        PadiumLogger.gesture.notice(
            "TAP-DIAG: click handled fc=\(fingerCount, privacy: .public) single=\(configuredSlots.single?.rawValue ?? "nil", privacy: .public) double=\(configuredSlots.double?.rawValue ?? "nil", privacy: .public) clickState=\(clickState)"
        )

        if let doubleSlot = configuredSlots.double,
           clickState >= 2 {
            if let pendingClick = _pendingPhysicalClicksByFingerCount.removeValue(forKey: fingerCount) {
                pendingClick.work.cancel()
            }
            eventToDispatch = GestureEvent(slot: doubleSlot, timestamp: eventTimestamp)
            clickHandler = _physicalClickHandler
        } else if configuredSlots.double != nil {
            if let pendingClick = _pendingPhysicalClicksByFingerCount.removeValue(forKey: fingerCount) {
                pendingClick.work.cancel()
            }
            let scheduledWork = clickScheduler.schedule(after: Self.physicalDoubleClickWindow) { [weak self] in
                self?.finalizePendingPhysicalClick(for: fingerCount, at: eventTimestamp)
            }
            _pendingPhysicalClicksByFingerCount[fingerCount] = PendingPhysicalClick(
                singleSlot: configuredSlots.single,
                work: scheduledWork
            )
        } else if let singleSlot = configuredSlots.single {
            eventToDispatch = GestureEvent(slot: singleSlot, timestamp: eventTimestamp)
            clickHandler = _physicalClickHandler
        }

        os_unfair_lock_unlock(&_lock)

        if let eventToDispatch, let clickHandler {
            clickHandler(eventToDispatch)
        }

        if let eventToDispatch {
            PadiumLogger.gesture.notice("TAP-DIAG: physical click dispatch fc=\(fingerCount) slot=\(eventToDispatch.slot.rawValue, privacy: .public)")
        }
        return disposition
    }

    private func finalizePendingPhysicalClick(for fingerCount: Int, at timestamp: Date) {
        var eventToDispatch: GestureEvent?
        var clickHandler: PhysicalClickHandler?

        os_unfair_lock_lock(&_lock)
        guard let pendingClick = _pendingPhysicalClicksByFingerCount.removeValue(forKey: fingerCount) else {
            os_unfair_lock_unlock(&_lock)
            return
        }
        pendingClick.work.cancel()

        if let singleSlot = pendingClick.singleSlot {
            eventToDispatch = GestureEvent(slot: singleSlot, timestamp: timestamp)
            clickHandler = _physicalClickHandler
        }
        os_unfair_lock_unlock(&_lock)

        if let eventToDispatch, let clickHandler {
            clickHandler(eventToDispatch)
        }
    }

    static func configureMiddleClickEvent(_ event: CGEvent, clickState: Int64) {
        event.setIntegerValueField(.mouseEventButtonNumber, value: middleMouseButtonNumber)
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMiddleClickMarker)
    }

    private func isWithinDedupWindow(at referenceTime: TimeInterval, since priorTime: TimeInterval?) -> Bool {
        guard let priorTime else { return false }
        return referenceTime - priorTime <= Self.physicalClickDedupWindow
    }

    private func configuredClickSlots(for fingerCount: Int) -> (single: GestureSlot?, double: GestureSlot?) {
        guard let clickSlots = Self.clickSlots(for: fingerCount) else {
            return (nil, nil)
        }

        let single = clickSlots.single.isConfigured ? clickSlots.single : nil
        let double = clickSlots.double.isConfigured ? clickSlots.double : nil
        return (single, double)
    }

    private static func clickSlots(for fingerCount: Int) -> (single: GestureSlot, double: GestureSlot)? {
        switch fingerCount {
        case 3:
            (.threeFingerClick, .threeFingerDoubleClick)
        case 4:
            (.fourFingerClick, .fourFingerDoubleClick)
        default:
            nil
        }
    }

    private static func isSystemMenuBarClick(at location: CGPoint) -> Bool {
        NSScreen.screens.contains { screen in
            screen.frame.contains(location) && location.y >= screen.visibleFrame.maxY
        }
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
    }
}

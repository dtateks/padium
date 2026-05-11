import AppKit
import CoreGraphics
import Foundation

/// Marks CGEvents that Padium itself posts (e.g. synthetic middle clicks)
/// so the scroll-suppressor's event tap recognizes them and passes them
/// through instead of trying to interpret them as user-driven clicks.
enum PadiumSyntheticEventMarker {
    static let value: Int64 = 0x50414449554D

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: value)
    }

    static func matches(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == value
    }
}

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

/// Write-only surface of multitouch state used by the gesture pipeline to keep
/// scroll suppression and the trackpad-active flag in sync with the touch stream.
/// `MultitouchState` is the production implementation; tests use lightweight
/// stubs.
protocol MultitouchStateSink: AnyObject, Sendable {
    var currentFingerCount: Int { get set }
    var isMultitouchActive: Bool { get set }
}

/// Orchestration-facing surface of the scroll suppressor: lifecycle, physical-click
/// routing, and the post-click touch-tap guard. Multitouch state lives in a
/// dedicated `MultitouchState` instance shared between the suppressor and the
/// gesture pipeline; this protocol no longer mixes the sink role in.
protocol PhysicalClickCoordinating: AnyObject, Sendable {
    typealias ClickHandler = @Sendable (GestureEvent) -> Void
    func setPhysicalClickHandler(_ handler: ClickHandler?)
    func setAppInteractionActive(_ isActive: Bool)
    @discardableResult func start() -> Bool
    func stop()
    func shouldAllowTouchTap(fingerCount: Int, at timestamp: Date) -> Bool
}

/// Owns the CGEventTap that suppresses macOS scroll wheel events during
/// multitouch and intercepts 3/4-finger physical left-clicks.
///
/// Uses a CGEventTap at `.cghidEventTap` to intercept `scrollWheel`,
/// `leftMouseDown`, and `leftMouseUp` events. Scroll-suppression decisions
/// (including post-multitouch momentum draining) are delegated to the shared
/// `MultitouchState`; the physical-click state machine lives here.
///
/// Thread-safety: click-pipeline state (`_leftMouseState`,
/// `_lastPhysicalClickAtByFingerCount`, etc.) is guarded by `_lock`. The
/// suppressor never holds `_lock` while calling back into `multitouchState`
/// in a way that could create a reverse-order dependency — lock order is
/// `_lock` → multitouchState's internal lock, never the reverse.
final class ScrollSuppressor: @unchecked Sendable, PhysicalClickCoordinating {

    typealias PhysicalClickHandler = @Sendable (GestureEvent) -> Void

    private struct PendingPhysicalClick {
        let singleSlot: GestureSlot?
        let work: any PhysicalClickScheduledWork
    }

    enum EventDisposition {
        case passThrough
        case suppress
    }

    private enum LeftMouseState {
        case idle
        case suppressingHandledPair
    }

    private static let physicalClickDedupWindow: TimeInterval = 0.5
    private static let physicalDoubleClickWindow: TimeInterval = NSEvent.doubleClickInterval

    // MARK: - Click-pipeline state (protected by _lock)

    private var _lock = os_unfair_lock()
    private var _leftMouseState: LeftMouseState = .idle
    private var _lastPhysicalClickAtByFingerCount: [Int: TimeInterval] = [:]
    private var _pendingPhysicalClicksByFingerCount: [Int: PendingPhysicalClick] = [:]
    private var _physicalClickHandler: PhysicalClickHandler?
    private var _appInteractionActive = false
    private var _tapRunLoop: CFRunLoop?

    private let multitouchState: MultitouchState
    private let clickScheduler: any PhysicalClickScheduling

    init(
        multitouchState: MultitouchState = MultitouchState(),
        clickScheduler: (any PhysicalClickScheduling)? = nil
    ) {
        self.multitouchState = multitouchState
        self.clickScheduler = clickScheduler ?? DispatchPhysicalClickScheduler()
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

        multitouchState.reset()

        os_unfair_lock_lock(&_lock)
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
            return multitouchState.shouldSuppressScroll(event: event) ? .suppress : .passThrough
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

    // MARK: - Internal click resolution

    fileprivate func leftMouseDisposition(
        for type: CGEventType,
        event: CGEvent,
        configuredClickSlotsResolver: (Int) -> (single: GestureSlot?, double: GestureSlot?)
    ) -> EventDisposition {
        if PadiumSyntheticEventMarker.matches(event) {
            return .passThrough
        }

        switch type {
        case .leftMouseUp:
            return handleLeftMouseUp()
        case .leftMouseDown:
            return handleLeftMouseDown(
                event: event,
                configuredClickSlotsResolver: configuredClickSlotsResolver
            )
        default:
            return .passThrough
        }
    }

    private func handleLeftMouseUp() -> EventDisposition {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        if _appInteractionActive {
            return .passThrough
        }
        if _leftMouseState == .suppressingHandledPair {
            _leftMouseState = .idle
            return .suppress
        }
        return .passThrough
    }

    private func handleLeftMouseDown(
        event: CGEvent,
        configuredClickSlotsResolver: (Int) -> (single: GestureSlot?, double: GestureSlot?)
    ) -> EventDisposition {
        // Snapshot multitouch state before grabbing the click lock so the
        // store's lock is held for a moment, never nested under `_lock`.
        let multitouch = multitouchState.snapshot()
        let referenceTime = Date().timeIntervalSinceReferenceDate
        let clickState = max(event.getIntegerValueField(.mouseEventClickState), 1)
        let eventTimestamp = Date(timeIntervalSinceReferenceDate: referenceTime)
        let eventLocation = event.location

        os_unfair_lock_lock(&_lock)

        if Self.isSystemMenuBarClick(at: eventLocation) {
            PadiumLogger.gesture.notice(
                "TAP-DIAG: click pass-through systemMenuBar fc=\(multitouch.currentFingerCount) multitouch=\(multitouch.isMultitouchActive) appInteraction=\(self._appInteractionActive)"
            )
            os_unfair_lock_unlock(&_lock)
            return .passThrough
        }

        if _appInteractionActive {
            PadiumLogger.gesture.notice(
                "TAP-DIAG: click pass-through appInteraction fc=\(multitouch.currentFingerCount) multitouch=\(multitouch.isMultitouchActive)"
            )
            os_unfair_lock_unlock(&_lock)
            return .passThrough
        }

        let fingerCount = multitouch.currentFingerCount
        guard multitouch.isMultitouchActive, (3...4).contains(fingerCount) else {
            if (3...4).contains(fingerCount) || multitouch.isMultitouchActive {
                PadiumLogger.gesture.notice(
                    "TAP-DIAG: click pass-through preconditions fc=\(fingerCount) multitouch=\(multitouch.isMultitouchActive) appInteraction=\(self._appInteractionActive)"
                )
            }
            os_unfair_lock_unlock(&_lock)
            return .passThrough
        }

        let configuredSlots = configuredClickSlotsResolver(fingerCount)
        guard configuredSlots.single != nil || configuredSlots.double != nil else {
            PadiumLogger.gesture.notice(
                "TAP-DIAG: click pass-through noConfiguredSlots fc=\(fingerCount) multitouch=\(multitouch.isMultitouchActive)"
            )
            os_unfair_lock_unlock(&_lock)
            return .passThrough
        }

        _lastPhysicalClickAtByFingerCount[fingerCount] = referenceTime
        _leftMouseState = .suppressingHandledPair
        PadiumLogger.gesture.notice(
            "TAP-DIAG: click handled fc=\(fingerCount, privacy: .public) single=\(configuredSlots.single?.rawValue ?? "nil", privacy: .public) double=\(configuredSlots.double?.rawValue ?? "nil", privacy: .public) clickState=\(clickState)"
        )

        let eventToDispatch = resolvePhysicalClickLocked(
            fingerCount: fingerCount,
            clickState: clickState,
            configuredSlots: configuredSlots,
            eventTimestamp: eventTimestamp
        )
        let clickHandler = eventToDispatch != nil ? _physicalClickHandler : nil

        os_unfair_lock_unlock(&_lock)

        if let eventToDispatch, let clickHandler {
            clickHandler(eventToDispatch)
            PadiumLogger.gesture.notice(
                "TAP-DIAG: physical click dispatch fc=\(fingerCount) slot=\(eventToDispatch.slot.rawValue, privacy: .public)"
            )
        }
        return .suppress
    }

    // Caller MUST hold `_lock`. Resolves the immediate click decision:
    // dispatches a double-click slot if the second click already arrived,
    // schedules a deferred single-click when a double-click slot is configured
    // but only the first click has arrived, or returns the immediate single-
    // click event when no double-click is configured.
    private func resolvePhysicalClickLocked(
        fingerCount: Int,
        clickState: Int64,
        configuredSlots: (single: GestureSlot?, double: GestureSlot?),
        eventTimestamp: Date
    ) -> GestureEvent? {
        if let doubleSlot = configuredSlots.double, clickState >= 2 {
            cancelPendingPhysicalClickLocked(for: fingerCount)
            return GestureEvent(slot: doubleSlot, timestamp: eventTimestamp)
        }

        if configuredSlots.double != nil {
            cancelPendingPhysicalClickLocked(for: fingerCount)
            let scheduledWork = clickScheduler.schedule(after: Self.physicalDoubleClickWindow) { [weak self] in
                self?.finalizePendingPhysicalClick(for: fingerCount, at: eventTimestamp)
            }
            _pendingPhysicalClicksByFingerCount[fingerCount] = PendingPhysicalClick(
                singleSlot: configuredSlots.single,
                work: scheduledWork
            )
            return nil
        }

        if let singleSlot = configuredSlots.single {
            return GestureEvent(slot: singleSlot, timestamp: eventTimestamp)
        }
        return nil
    }

    private func cancelPendingPhysicalClickLocked(for fingerCount: Int) {
        if let pendingClick = _pendingPhysicalClicksByFingerCount.removeValue(forKey: fingerCount) {
            pendingClick.work.cancel()
        }
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

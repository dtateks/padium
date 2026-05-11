import CoreGraphics
import Foundation
import os

/// Thread-safe holder of the multitouch state shared between the gesture
/// pipeline and the scroll suppressor's CGEventTap.
///
/// Writes arrive from the gesture pipeline on the main actor through the
/// `MultitouchStateSink` surface. Reads happen on the CGEventTap callback
/// thread via `snapshot()` and the scroll-suppression decision methods.
/// A sticky `suppressMomentum` flag set on every inactive→active transition
/// keeps consuming residual momentum scroll events until a new scroll-begin
/// or momentum-end arrives — the same lifecycle that used to live inline in
/// the scroll suppressor before extraction.
final class MultitouchState: MultitouchStateSink, @unchecked Sendable {

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

    private var lock = os_unfair_lock()
    private var _currentFingerCount = 0
    private var _isMultitouchActive = false
    private var _suppressMomentum = false

    var currentFingerCount: Int {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _currentFingerCount
        }
        set {
            os_unfair_lock_lock(&lock)
            _currentFingerCount = max(newValue, 0)
            os_unfair_lock_unlock(&lock)
        }
    }

    var isMultitouchActive: Bool {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _isMultitouchActive
        }
        set {
            os_unfair_lock_lock(&lock)
            let wasActive = _isMultitouchActive
            _isMultitouchActive = newValue
            if newValue && !wasActive {
                // Entering multitouch — any ongoing or future scroll should be suppressed.
                _suppressMomentum = true
            }
            // Lift transition keeps `_suppressMomentum` set; cleared by a new scroll-begin or momentum-end.
            os_unfair_lock_unlock(&lock)
        }
    }

    /// Atomic snapshot of the read-only multitouch fields. Cheap; safe to call
    /// from any thread, including under another lock.
    func snapshot() -> (currentFingerCount: Int, isMultitouchActive: Bool) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (_currentFingerCount, _isMultitouchActive)
    }

    /// Decide whether the given scroll wheel event should be suppressed.
    /// Pure delegate over `shouldSuppressScroll(scrollPhaseRaw:momentumPhaseRaw:)`
    /// that extracts the two phase fields the decision depends on.
    func shouldSuppressScroll(event: CGEvent) -> Bool {
        shouldSuppressScroll(
            scrollPhaseRaw: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhaseRaw: event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        )
    }

    /// Pure phase-driven scroll suppression decision. Splitting the CGEvent
    /// extraction from the decision lets tests drive the state machine without
    /// constructing synthetic events. While multitouch is active every scroll
    /// is suppressed. After lift the sticky `_suppressMomentum` bit consumes
    /// the residual momentum scroll until the system signals a new
    /// scroll-begin or the momentum phase ends.
    func shouldSuppressScroll(scrollPhaseRaw: Int64, momentumPhaseRaw: Int64) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if _isMultitouchActive {
            return true
        }

        if _suppressMomentum {
            let momentumPhase = MomentumPhase(rawValue: momentumPhaseRaw)
            if let momentumPhase, momentumPhase != .noPhase {
                if momentumPhase == .ended {
                    _suppressMomentum = false
                }
                return true
            }

            let scrollPhase = ScrollPhase(rawValue: scrollPhaseRaw)
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

    /// Reset all tracked state. Called when the suppressor stops so a later
    /// restart begins with a clean slate.
    func reset() {
        os_unfair_lock_lock(&lock)
        _currentFingerCount = 0
        _isMultitouchActive = false
        _suppressMomentum = false
        os_unfair_lock_unlock(&lock)
    }
}

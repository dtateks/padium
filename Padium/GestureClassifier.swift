import Foundation

// Classifies raw touch-frame sequences into GestureEvents.
//
// Thresholds derived from spikes-oms.md §5 (research candidates; confirmed on
// owner machine for swipe minimum distance via preemption spike):
//   - swipeMinDistance  ≥ 0.10 normalized (§5.3)
//   - noiseCapacitance  < 0.03 total       (§5.6)
//   - palmMajorAxis     > 30 sensor units  (§5.6)
//
// Supported gesture set: 8 swipe slots only (3- and 4-finger, 4 directions).
// Tap / double-tap support is excluded — spikes-preemption.md §4 confirms that
// GestureSlot is swipe-only and older tap planning docs are stale.
struct GestureClassifier: Sendable {

    // MARK: - Thresholds (named constants from spike evidence)

    // Minimum normalized distance across the trackpad to register as a swipe.
    private static let swipeMinDistance: Float = 0.10

    // Contacts with total capacitance below this value are noise.
    private static let noiseCapacitanceThreshold: Float = 0.03

    // Contacts with a major ellipse axis above this are likely a palm.
    private static let palmMajorAxisThreshold: Float = 30.0

    // MARK: - Classification

    func classify(frames: [[TouchPoint]]) -> GestureEvent? {
        guard frames.count >= 2 else { return nil }

        // Collect frames that contain at least one stable (non-noise) contact.
        let stableFrames = frames.filter { isStableFrame($0) }
        guard stableFrames.count >= 2 else { return nil }

        guard
            let firstStable = stableFrames.first,
            let lastStable  = stableFrames.last
        else { return nil }

        let fingerCount = stableFingerCount(in: stableFrames)
        guard fingerCount == 3 || fingerCount == 4 else { return nil }

        // Use centroid of first and last stable frames for direction.
        guard
            let startCentroid = centroid(of: firstStable),
            let endCentroid   = centroid(of: lastStable)
        else { return nil }

        let dx = endCentroid.x - startCentroid.x
        let dy = endCentroid.y - startCentroid.y
        let distance = (dx * dx + dy * dy).squareRoot()

        guard distance >= Self.swipeMinDistance else { return nil }

        guard let slot = swipeSlot(dx: dx, dy: dy, fingerCount: fingerCount) else { return nil }
        return GestureEvent(slot: slot, timestamp: Date())
    }

    // MARK: - Helpers

    // A frame is stable when it is non-empty and every contact passes noise
    // and palm guards, and at least one contact is in an active gesture state.
    private func isStableFrame(_ frame: [TouchPoint]) -> Bool {
        guard !frame.isEmpty else { return false }
        let validContacts = frame.filter { isValidContact($0) }
        guard !validContacts.isEmpty else { return false }
        return validContacts.contains { isActiveState($0.state) }
    }

    private func isValidContact(_ point: TouchPoint) -> Bool {
        point.total >= Self.noiseCapacitanceThreshold &&
        point.majorAxis <= Self.palmMajorAxisThreshold
    }

    // States used for position tracking. Hovering and notTouching are excluded.
    private func isActiveState(_ state: OMSTouchState) -> Bool {
        switch state {
        case .touching, .lingering, .breaking, .making, .starting:
            return true
        case .hovering, .notTouching, .leaving:
            return false
        }
    }

    // The stable finger count is the maximum number of valid active contacts
    // observed across all stable frames. Using the maximum avoids under-counting
    // during finger-stagger while still settling on the peak plateau.
    private func stableFingerCount(in frames: [[TouchPoint]]) -> Int {
        frames.map { frame in
            frame.filter { isValidContact($0) && isActiveState($0.state) }.count
        }.max() ?? 0
    }

    // Average position of valid active contacts in a frame.
    private func centroid(of frame: [TouchPoint]) -> (x: Float, y: Float)? {
        let active = frame.filter { isValidContact($0) && isActiveState($0.state) }
        guard !active.isEmpty else { return nil }
        let sumX = active.reduce(0) { $0 + $1.normalizedX }
        let sumY = active.reduce(0) { $0 + $1.normalizedY }
        let n = Float(active.count)
        return (x: sumX / n, y: sumY / n)
    }

    // Maps a displacement vector to a cardinal-direction swipe slot.
    // Uses ±45° sector boundaries (atan2-based quadrant classification).
    private func swipeSlot(dx: Float, dy: Float, fingerCount: Int) -> GestureSlot? {
        let angle = atan2(dy, dx)
        let pi = Float.pi
        // Sector boundaries at ±π/4 and ±3π/4
        let slot45 = pi / 4
        let slot135 = 3 * pi / 4

        let direction: SwipeDirection
        if angle >= -slot45 && angle < slot45 {
            direction = .right
        } else if angle >= slot45 && angle < slot135 {
            direction = .up
        } else if angle >= slot135 || angle < -slot135 {
            direction = .left
        } else {
            direction = .down
        }

        switch (fingerCount, direction) {
        case (3, .left):  return .threeFingerSwipeLeft
        case (3, .right): return .threeFingerSwipeRight
        case (3, .up):    return .threeFingerSwipeUp
        case (3, .down):  return .threeFingerSwipeDown
        case (4, .left):  return .fourFingerSwipeLeft
        case (4, .right): return .fourFingerSwipeRight
        case (4, .up):    return .fourFingerSwipeUp
        case (4, .down):  return .fourFingerSwipeDown
        default:          return nil
        }
    }

    private enum SwipeDirection { case left, right, up, down }
}

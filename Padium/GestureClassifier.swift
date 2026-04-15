import Foundation

enum GestureSensitivitySetting {
    static let minimumValue: Double = 0.0
    static let defaultValue: Double = 0.5
    static let maximumValue: Double = 1.0

    private static let userDefaultsKey = "gesture.sensitivity"
    private static let baseSensitivityBoost: Double = 0.25
    private static let minimumSwipeThreshold: Float = 0.06
    private static let maximumSwipeThreshold: Float = 0.14

    static func clamp(_ value: Double) -> Double {
        min(max(value, minimumValue), maximumValue)
    }

    static func storedValue(userDefaults: UserDefaults = .standard) -> Double {
        let value = userDefaults.object(forKey: userDefaultsKey) as? Double ?? defaultValue
        return clamp(value)
    }

    static func store(_ value: Double, userDefaults: UserDefaults = .standard) {
        userDefaults.set(clamp(value), forKey: userDefaultsKey)
    }

    static func swipeThreshold(for sensitivity: Double) -> Float {
        let progress = Float(effectiveSensitivity(for: sensitivity))
        let range = maximumSwipeThreshold - minimumSwipeThreshold
        return maximumSwipeThreshold - (range * progress)
    }

    static func effectiveSensitivity(for sensitivity: Double) -> Double {
        clamp(clamp(sensitivity) + baseSensitivityBoost)
    }

    static func currentSwipeThreshold(userDefaults: UserDefaults = .standard) -> Float {
        swipeThreshold(for: storedValue(userDefaults: userDefaults))
    }
}

enum GestureTapSettings {
    static let maximumTravel: Float = 0.05
    // 500ms supports both light taps (~100ms) and physical clicks (~300-500ms).
    static let maximumDuration: TimeInterval = 0.5
    static let doubleTapWindow: TimeInterval = 0.3
}

// Classifies raw touch-frame sequences into swipe events using stable touch IDs,
// dominant-axis commitment, and per-finger direction agreement.
//
// OMS normalizes touch coordinates per-axis independently to [0,1]. Because the
// trackpad is wider than it is tall (~1.5:1), a horizontal swipe produces a smaller
// normalized dx than a vertical swipe of the same physical distance. We compensate
// by scaling dx by the aspect ratio so that the threshold and dominance checks
// operate in physical-proportional space.
struct GestureClassifier: Sendable {

    private let swipeThresholdProvider: @Sendable () -> Float

    // Minimum normalized distance to register as a swipe.
    private var swipeThreshold: Float {
        swipeThresholdProvider()
    }

    // Trackpad aspect ratio (width / height). OMS normalizes each axis to [0,1]
    // independently, so horizontal displacement is underrepresented by this factor.
    // Typical MacBook trackpads are ~1.4–1.6:1; 1.5 is a safe middle ground.
    // This scales dx so thresholds are equalized across axes.
    static let trackpadAspectRatio: Float = 1.5

    // Dominant axis must clearly outweigh the cross axis before direction locks.
    private static let axisDominanceRatio: Float = 1.2

    // A finger may jitter slightly against the committed direction without invalidating the swipe.
    private static let perFingerDirectionTolerance: Float = 0.015

    // Contacts with total capacitance below this value are noise.
    private static let noiseCapacitanceThreshold: Float = 0.03

    // Contacts with a major ellipse axis above this are likely a palm.
    private static let palmMajorAxisThreshold: Float = 30.0

    init() {
        self.swipeThresholdProvider = { GestureSensitivitySetting.currentSwipeThreshold() }
    }

    init(swipeThreshold: Float) {
        self.swipeThresholdProvider = { swipeThreshold }
    }

    init(swipeThresholdProvider: @escaping @Sendable () -> Float) {
        self.swipeThresholdProvider = swipeThresholdProvider
    }

    /// Try to classify incrementally: given first stable frame and current frame,
    /// return a GestureEvent if displacement is sufficient. Returns nil if not yet a swipe.
    func classifyIncremental(
        firstFrame: [TouchPoint],
        currentFrame: [TouchPoint],
        peakFingerCount: Int
    ) -> GestureEvent? {
        guard
            let firstContacts = stableActiveContacts(in: firstFrame, expectedFingerCount: peakFingerCount),
            let currentContacts = stableActiveContacts(in: currentFrame, expectedFingerCount: peakFingerCount)
        else { return nil }

        return classifyIncremental(
            firstContacts: firstContacts,
            currentContacts: currentContacts,
            peakFingerCount: peakFingerCount
        )
    }

    func classifyIncremental(
        firstContacts: [Int: TouchPoint],
        currentContacts: [Int: TouchPoint],
        peakFingerCount: Int
    ) -> GestureEvent? {
        guard peakFingerCount == 3 || peakFingerCount == 4 else { return nil }
        guard firstContacts.count == peakFingerCount, currentContacts.count == peakFingerCount else { return nil }
        guard Set(firstContacts.keys) == Set(currentContacts.keys) else { return nil }

        let displacements = firstContacts.compactMap { identifier, startPoint in
            currentContacts[identifier].map { currentPoint in
                (
                    // Scale dx by aspect ratio to compensate for per-axis normalization.
                    // Without this, horizontal swipes need ~1.5x more physical movement.
                    dx: (currentPoint.normalizedX - startPoint.normalizedX) * Self.trackpadAspectRatio,
                    dy: currentPoint.normalizedY - startPoint.normalizedY
                )
            }
        }
        guard displacements.count == peakFingerCount else { return nil }

        let averageDx = displacements.reduce(0) { $0 + $1.dx } / Float(displacements.count)
        let averageDy = displacements.reduce(0) { $0 + $1.dy } / Float(displacements.count)
        guard let dominantAxis = dominantAxis(dx: averageDx, dy: averageDy) else { return nil }
        let dominantDelta = dominantAxis == .horizontal ? averageDx : averageDy
        guard abs(dominantDelta) >= swipeThreshold else { return nil }
        guard displacements.allSatisfy({ displacementSupportsCommittedDirection($0, axis: dominantAxis, dominantDelta: dominantDelta) }) else {
            return nil
        }

        guard let slot = swipeSlot(axis: dominantAxis, dominantDelta: dominantDelta, fingerCount: peakFingerCount) else {
            return nil
        }
        return GestureEvent(slot: slot, timestamp: Date())
    }

    // MARK: - Public helpers for engine

    func isStableFrame(_ frame: [TouchPoint]) -> Bool {
        stableActiveContacts(in: frame) != nil
    }

    func activeFingerCount(in frame: [TouchPoint]) -> Int {
        stableActiveContacts(in: frame)?.count ?? 0
    }

    func stableActiveContacts(
        in frame: [TouchPoint],
        expectedFingerCount: Int? = nil
    ) -> [Int: TouchPoint]? {
        guard !frame.isEmpty else { return nil }
        let activeContacts = frame.filter { isValidContact($0) && isActiveState($0.state) }
        guard !activeContacts.isEmpty else { return nil }
        if let expectedFingerCount, activeContacts.count != expectedFingerCount {
            return nil
        }

        var contactsByIdentifier: [Int: TouchPoint] = [:]
        contactsByIdentifier.reserveCapacity(activeContacts.count)
        for contact in activeContacts {
            guard contactsByIdentifier.updateValue(contact, forKey: contact.identifier) == nil else {
                return nil
            }
        }
        return contactsByIdentifier
    }

    static func travelDistance(from startPoint: TouchPoint, to currentPoint: TouchPoint) -> Float {
        let dx = (currentPoint.normalizedX - startPoint.normalizedX) * trackpadAspectRatio
        let dy = currentPoint.normalizedY - startPoint.normalizedY
        return sqrt((dx * dx) + (dy * dy))
    }

    // MARK: - Internal

    private func isValidContact(_ point: TouchPoint) -> Bool {
        point.total >= Self.noiseCapacitanceThreshold &&
        point.majorAxis <= Self.palmMajorAxisThreshold
    }

    private func isActiveState(_ state: OMSTouchState) -> Bool {
        switch state {
        case .starting, .making, .touching, .lingering, .breaking:
            return true
        case .hovering, .notTouching, .leaving:
            return false
        }
    }

    private func dominantAxis(dx: Float, dy: Float) -> SwipeAxis? {
        let absDx = abs(dx)
        let absDy = abs(dy)
        if absDx >= absDy * Self.axisDominanceRatio {
            return .horizontal
        }
        if absDy >= absDx * Self.axisDominanceRatio {
            return .vertical
        }
        return nil
    }

    private func displacementSupportsCommittedDirection(
        _ displacement: (dx: Float, dy: Float),
        axis: SwipeAxis,
        dominantDelta: Float
    ) -> Bool {
        let dominantComponent = axis == .horizontal ? displacement.dx : displacement.dy
        let sameDirection = dominantDelta >= 0
            ? dominantComponent >= -Self.perFingerDirectionTolerance
            : dominantComponent <= Self.perFingerDirectionTolerance
        let movedEnough = abs(dominantComponent) >= Self.perFingerDirectionTolerance

        return sameDirection && movedEnough
    }

    private func swipeSlot(axis: SwipeAxis, dominantDelta: Float, fingerCount: Int) -> GestureSlot? {
        let isPositiveDirection = dominantDelta >= 0

        switch (fingerCount, axis, isPositiveDirection) {
        case (3, .horizontal, false): return .threeFingerSwipeLeft
        case (3, .horizontal, true):  return .threeFingerSwipeRight
        case (3, .vertical, true):    return .threeFingerSwipeUp
        case (3, .vertical, false):   return .threeFingerSwipeDown
        case (4, .horizontal, false): return .fourFingerSwipeLeft
        case (4, .horizontal, true):  return .fourFingerSwipeRight
        case (4, .vertical, true):    return .fourFingerSwipeUp
        case (4, .vertical, false):   return .fourFingerSwipeDown
        default:                      return nil
        }
    }

    private enum SwipeAxis { case horizontal, vertical }
}

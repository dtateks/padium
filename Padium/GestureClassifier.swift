import Foundation

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

    // All contacts in a real swipe should contribute meaningful motion along the
    // committed axis. This rejects a stray palm/resting contact that only jitters
    // while the actual fingers move.
    private static let perFingerMotionConsensusRatio: Float = 0.35

    // Contacts with total capacitance below this value are noise.
    private static let noiseCapacitanceThreshold: Float = 0.03

    // Contacts with a major ellipse axis above this are likely a palm.
    private static let palmMajorAxisThreshold: Float = 30.0

    // Maximum aspect-corrected distance between any two contacts of the same
    // gesture, expressed in units of trackpad height (dx is already scaled by
    // `trackpadAspectRatio`). The rule: N fingers of a real gesture come from
    // ONE hand, so their mutual distances fit within hand reach; contacts that
    // come from two hands (e.g. palms resting on opposite corners while typing)
    // exceed any plausible single-hand spread. Thresholds match real anatomy
    // with modest headroom; they are the load-bearing palm/two-hand rejection
    // gate alongside the wall-clock tap gates.
    //
    // Tuned on the smallest common trackpad (MacBook Air 13", ~12cm × 7.5cm):
    //   - 2 fingers: real index+middle spread 2-3 cm → ≈ 0.25-0.45 aspect-
    //     corrected. 0.50 tightly admits adjacent-finger taps (including
    //     some thumb+index variants) while rejecting any pair ≥ ~3.3 cm
    //     apart — the canonical typing-palm false-positive geometry.
    //   - 3 fingers: real index+middle+ring spread 3-5 cm → ≈ 0.45-0.75.
    //     0.85 covers big hands while rejecting palm+2-finger artefacts.
    //   - 4 fingers: real index+middle+ring+pinky spread 5-7 cm → ≈ 0.75-1.05.
    //     1.20 covers big hands while rejecting any two-hand combination or
    //     wide palm-heel artefact that reaches beyond natural hand width.
    private static let handSpreadThresholds: [Int: Float] = [
        2: 0.50,
        3: 0.85,
        4: 1.20
    ]

    // Three-finger swipes should keep roughly the same hand shape over the commit
    // window. A stationary palm plus two moving fingers sharply changes pairwise
    // spacing even when the frame still fits inside the coarse one-hand spread gate.
    private static let swipeHandShapeChangeTolerance: [Int: Float] = [
        3: 0.25
    ]

    // A real 2-finger tap keeps the fingertip pair shape nearly fixed while the
    // hand lands and lifts. Incidental palm/corner contacts often deform or rotate
    // that pair even when each contact's absolute travel stays below tap threshold.
    private static let twoFingerTapPairVectorChangeTolerance: Float = 0.05

    // Swipes are only recognized for these finger counts; lower counts are
    // reserved for system gestures (2-finger scroll/back), higher counts
    // aren't exposed as slots today.
    private static let supportedSwipeFingerCounts: Set<Int> = [3, 4]

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
        guard Self.supportedSwipeFingerCounts.contains(peakFingerCount) else { return nil }
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
        guard dominantMotionIsConsistent(displacements, axis: dominantAxis) else { return nil }
        guard contactSetMaintainsSwipeShape(firstContacts: firstContacts, currentContacts: currentContacts) else { return nil }

        guard let slot = swipeSlot(axis: dominantAxis, dominantDelta: dominantDelta, fingerCount: peakFingerCount) else {
            return nil
        }
        return GestureEvent(slot: slot, timestamp: Date())
    }

    // MARK: - Public helpers for engine

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
        guard Self.contactsFitOneHand(contactsByIdentifier) else {
            return nil
        }
        return contactsByIdentifier
    }

    static func travelDistance(from startPoint: TouchPoint, to currentPoint: TouchPoint) -> Float {
        aspectCorrectedDistance(from: startPoint, to: currentPoint)
    }

    func tapCandidateMaintainsShape(
        firstContacts: [Int: TouchPoint],
        latestContacts: [Int: TouchPoint],
        fingerCount: Int
    ) -> Bool {
        guard fingerCount == 2 else { return true }
        guard firstContacts.count == 2, latestContacts.count == 2 else { return false }

        let identifiers = firstContacts.keys.sorted()
        guard identifiers == latestContacts.keys.sorted(), identifiers.count == 2,
              let startA = firstContacts[identifiers[0]],
              let startB = firstContacts[identifiers[1]],
              let latestA = latestContacts[identifiers[0]],
              let latestB = latestContacts[identifiers[1]]
        else {
            return false
        }

        let startVector = Self.aspectCorrectedPairVector(from: startA, to: startB)
        let latestVector = Self.aspectCorrectedPairVector(from: latestA, to: latestB)
        let pairVectorChange = Self.vectorMagnitude(
            dx: latestVector.dx - startVector.dx,
            dy: latestVector.dy - startVector.dy
        )

        return pairVectorChange <= Self.twoFingerTapPairVectorChangeTolerance
    }

    static func aspectCorrectedDistance(from startPoint: TouchPoint, to currentPoint: TouchPoint) -> Float {
        let dx = (currentPoint.normalizedX - startPoint.normalizedX) * trackpadAspectRatio
        let dy = currentPoint.normalizedY - startPoint.normalizedY
        return vectorMagnitude(dx: dx, dy: dy)
    }

    /// Rejects contact sets whose mutual spread exceeds one hand's reach —
    /// the load-bearing signal against two-handed palm artefacts (two palms on
    /// opposite corners of the trackpad while the user types). No threshold
    /// is configured for 1-finger (spread is undefined). Thresholds for 2/3/4
    /// fingers are tuned to real anatomical hand reach with modest headroom.
    static func contactsFitOneHand(_ contacts: [Int: TouchPoint]) -> Bool {
        guard let threshold = handSpreadThresholds[contacts.count] else { return true }
        let points = Array(contacts.values)
        for firstIndex in 0..<points.count {
            for secondIndex in (firstIndex + 1)..<points.count {
                let distance = aspectCorrectedDistance(
                    from: points[firstIndex],
                    to: points[secondIndex]
                )
                if distance > threshold { return false }
            }
        }
        return true
    }

    // MARK: - Internal

    private func isValidContact(_ point: TouchPoint) -> Bool {
        point.total >= Self.noiseCapacitanceThreshold &&
        point.majorAxis <= Self.palmMajorAxisThreshold
    }

    private func isActiveState(_ state: TouchState) -> Bool {
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

    private func dominantMotionIsConsistent(
        _ displacements: [(dx: Float, dy: Float)],
        axis: SwipeAxis
    ) -> Bool {
        let dominantComponents = displacements
            .map { abs(axis == .horizontal ? $0.dx : $0.dy) }
            .sorted()
        guard let medianTravel = Self.median(of: dominantComponents) else { return false }
        let minimumExpectedTravel = max(
            Self.perFingerDirectionTolerance,
            medianTravel * Self.perFingerMotionConsensusRatio
        )

        return dominantComponents.allSatisfy { $0 >= minimumExpectedTravel }
    }

    private func contactSetMaintainsSwipeShape(
        firstContacts: [Int: TouchPoint],
        currentContacts: [Int: TouchPoint]
    ) -> Bool {
        guard let tolerance = Self.swipeHandShapeChangeTolerance[firstContacts.count] else { return true }
        let identifiers = firstContacts.keys.sorted()

        for firstIndex in 0..<identifiers.count {
            for secondIndex in (firstIndex + 1)..<identifiers.count {
                guard
                    let startA = firstContacts[identifiers[firstIndex]],
                    let startB = firstContacts[identifiers[secondIndex]],
                    let currentA = currentContacts[identifiers[firstIndex]],
                    let currentB = currentContacts[identifiers[secondIndex]]
                else {
                    return false
                }

                let startDistance = Self.aspectCorrectedDistance(from: startA, to: startB)
                let currentDistance = Self.aspectCorrectedDistance(from: currentA, to: currentB)
                if abs(currentDistance - startDistance) > tolerance {
                    return false
                }
            }
        }

        return true
    }

    private static func median(of sortedValues: [Float]) -> Float? {
        guard !sortedValues.isEmpty else { return nil }
        let middleIndex = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            return (sortedValues[middleIndex - 1] + sortedValues[middleIndex]) / 2
        }
        return sortedValues[middleIndex]
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

    private static func aspectCorrectedPairVector(from firstPoint: TouchPoint, to secondPoint: TouchPoint) -> (dx: Float, dy: Float) {
        (
            dx: (secondPoint.normalizedX - firstPoint.normalizedX) * trackpadAspectRatio,
            dy: secondPoint.normalizedY - firstPoint.normalizedY
        )
    }

    private static func vectorMagnitude(dx: Float, dy: Float) -> Float {
        sqrt((dx * dx) + (dy * dy))
    }

    private enum SwipeAxis { case horizontal, vertical }
}

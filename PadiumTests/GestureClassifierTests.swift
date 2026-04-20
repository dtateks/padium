import Testing
@testable import Padium

struct GestureClassifierTests {

    private let testSwipeThreshold: Float = 0.10

    final class ThresholdBox: @unchecked Sendable {
        var value: Float

        init(_ value: Float) {
            self.value = value
        }
    }

    private func pt(
        id: Int = 1, x: Float = 0.5, y: Float = 0.5,
        state: TouchState = .touching, total: Float = 0.15, majorAxis: Float = 12.0
    ) -> TouchPoint {
        TouchPoint(identifier: id, normalizedX: x, normalizedY: y,
                   pressure: 0.3, state: state, total: total, majorAxis: majorAxis)
    }

    private func frame(_ count: Int, x: Float, y: Float, state: TouchState = .touching,
                       total: Float = 0.15, majorAxis: Float = 12.0) -> [TouchPoint] {
        (0..<count).map { i in pt(id: i+1, x: x, y: y, state: state, total: total, majorAxis: majorAxis) }
    }

    private func makeClassifier() -> GestureClassifier {
        GestureClassifier(swipeThreshold: testSwipeThreshold)
    }

    private func classify(fingers: Int, startX: Float, startY: Float, endX: Float, endY: Float) -> GestureEvent? {
        let c = makeClassifier()
        let first = frame(fingers, x: startX, y: startY)
        let last = frame(fingers, x: endX, y: endY)
        return c.classifyIncremental(firstFrame: first, currentFrame: last, peakFingerCount: fingers)
    }

    // MARK: - Rejection

    @Test func rejectsLowCapacitance() {
        let c = makeClassifier()
        let first = frame(3, x: 0.2, y: 0.5, total: 0.02)
        let last = frame(3, x: 0.8, y: 0.5, total: 0.02)
        #expect(c.classifyIncremental(firstFrame: first, currentFrame: last, peakFingerCount: 3) == nil)
    }

    @Test func rejectsPalm() {
        let c = makeClassifier()
        let first = frame(3, x: 0.2, y: 0.5, majorAxis: 35)
        let last = frame(3, x: 0.8, y: 0.5, majorAxis: 35)
        #expect(c.classifyIncremental(firstFrame: first, currentFrame: last, peakFingerCount: 3) == nil)
    }

    @Test func rejectsHovering() {
        let c = makeClassifier()
        let first = frame(3, x: 0.2, y: 0.5, state: .hovering)
        let last = frame(3, x: 0.8, y: 0.5, state: .hovering)
        #expect(c.classifyIncremental(firstFrame: first, currentFrame: last, peakFingerCount: 3) == nil)
    }

    @Test func rejectsTwoFinger() {
        #expect(classify(fingers: 2, startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5) == nil)
    }

    @Test func rejectsFiveFinger() {
        #expect(classify(fingers: 5, startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5) == nil)
    }

    @Test func rejectsBelowMinDistance() {
        #expect(classify(fingers: 3, startX: 0.5, startY: 0.5, endX: 0.53, endY: 0.5) == nil)
    }

    @Test func defaultSensitivityMapsToCurrentCalibratedThreshold() {
        let midpointThreshold = GestureSensitivitySetting.swipeThreshold(for: GestureSensitivitySetting.defaultValue)
        let calibratedDefaultThreshold: Float = 0.058

        #expect(abs(midpointThreshold - calibratedDefaultThreshold) < 0.0001)
    }

    @Test func midpointSensitivityAppliesBaseBoostBeforeThresholdMapping() {
        #expect(abs(GestureSensitivitySetting.effectiveSensitivity(for: 0.5) - 0.7) < 0.0001)
    }

    @Test func lowSensitivityClampsBeforeApplyingBaseBoost() {
        #expect(abs(GestureSensitivitySetting.effectiveSensitivity(for: -0.5) - 0.2) < 0.0001)
    }

    @Test func highSensitivitySaturatesAtCurrentMinimumThresholdAfterBoost() {
        #expect(abs(GestureSensitivitySetting.effectiveSensitivity(for: 0.9) - 1.0) < 0.0001)
        #expect(abs(GestureSensitivitySetting.swipeThreshold(for: 0.9) - 0.04) < 0.0001)
    }

    @Test func higherSensitivityLowersSwipeThreshold() {
        let lowSensitivity = GestureSensitivitySetting.swipeThreshold(for: 0.2)
        let highSensitivity = GestureSensitivitySetting.swipeThreshold(for: 0.8)
        #expect(highSensitivity < lowSensitivity)
    }

    @Test func defaultSensitivityMapsToCurrentTapTravelThreshold() {
        let midpointThreshold = GestureSensitivitySetting.tapTravelThreshold(for: GestureSensitivitySetting.defaultValue)
        let calibratedDefaultThreshold: Float = 0.061

        #expect(abs(midpointThreshold - calibratedDefaultThreshold) < 0.0001)
    }

    @Test func higherSensitivityRaisesTapTravelThreshold() {
        let lowSensitivity = GestureSensitivitySetting.tapTravelThreshold(for: 0.2)
        let highSensitivity = GestureSensitivitySetting.tapTravelThreshold(for: 0.8)
        #expect(highSensitivity > lowSensitivity)
    }

    @Test func liveSensitivityUpdatesApplyWithoutRecreatingClassifier() {
        let liveThreshold = ThresholdBox(0.12)
        let classifier = GestureClassifier(swipeThresholdProvider: { liveThreshold.value })
        let first = frame(3, x: 0.50, y: 0.50)
        let last = frame(3, x: 0.57, y: 0.50)

        #expect(classifier.classifyIncremental(firstFrame: first, currentFrame: last, peakFingerCount: 3) == nil)

        liveThreshold.value = 0.08

        #expect(classifier.classifyIncremental(firstFrame: first, currentFrame: last, peakFingerCount: 3)?.slot == .threeFingerSwipeRight)
    }

    @Test func rejectsMovementBelowEmpiricalSwipeThreshold() {
        // dx=0.05, after aspect ratio compensation: 0.05 * 1.5 = 0.075 < threshold 0.10
        #expect(classify(fingers: 3, startX: 0.5, startY: 0.5, endX: 0.55, endY: 0.5) == nil)
    }

    @Test func rejectsAmbiguousDiagonalMovement() {
        // After aspect ratio compensation, dx and dy should still be ambiguous.
        // raw dx=0.06 → scaled 0.09, dy=0.09 → dominance: 0.09 < 0.09*1.2=0.108 (no horizontal)
        //                                                   0.09 < 0.09*1.2=0.108 (no vertical)
        let c = makeClassifier()
        let first = [
            pt(id: 1, x: 0.20, y: 0.20),
            pt(id: 2, x: 0.40, y: 0.20),
            pt(id: 3, x: 0.60, y: 0.20)
        ]
        let last = [
            pt(id: 1, x: 0.26, y: 0.29),
            pt(id: 2, x: 0.46, y: 0.29),
            pt(id: 3, x: 0.66, y: 0.29)
        ]
        #expect(c.classifyIncremental(firstFrame: first, currentFrame: last, peakFingerCount: 3) == nil)
    }

    @Test func rejectsOpposingFingerDirections() {
        let c = makeClassifier()
        let first = [
            pt(id: 1, x: 0.20, y: 0.40),
            pt(id: 2, x: 0.40, y: 0.40),
            pt(id: 3, x: 0.60, y: 0.40)
        ]
        let last = [
            pt(id: 1, x: 0.33, y: 0.40),
            pt(id: 2, x: 0.53, y: 0.40),
            pt(id: 3, x: 0.56, y: 0.40)
        ]
        #expect(c.classifyIncremental(firstFrame: first, currentFrame: last, peakFingerCount: 3) == nil)
    }

    @Test func rejectsThreeFingerSwipeWhenOneContactIsNearlyStationary() {
        let c = makeClassifier()
        let first = [
            pt(id: 1, x: 0.20, y: 0.50),
            pt(id: 2, x: 0.40, y: 0.50),
            pt(id: 3, x: 0.52, y: 0.50)
        ]
        let last = [
            pt(id: 1, x: 0.50, y: 0.50),
            pt(id: 2, x: 0.70, y: 0.50),
            pt(id: 3, x: 0.54, y: 0.50)
        ]

        #expect(c.classifyIncremental(firstFrame: first, currentFrame: last, peakFingerCount: 3) == nil)
    }

    @Test func acceptsThreeFingerSwipeWhenOneFingerLagsButStillTracksTheGesture() {
        let c = makeClassifier()
        let first = [
            pt(id: 1, x: 0.20, y: 0.50),
            pt(id: 2, x: 0.40, y: 0.50),
            pt(id: 3, x: 0.60, y: 0.50)
        ]
        let last = [
            pt(id: 1, x: 0.40, y: 0.50),
            pt(id: 2, x: 0.55, y: 0.50),
            pt(id: 3, x: 0.71, y: 0.50)
        ]

        #expect(c.classifyIncremental(firstFrame: first, currentFrame: last, peakFingerCount: 3)?.slot == .threeFingerSwipeRight)
    }

    // MARK: - 3 finger directions

    @Test func threeFingerRight() {
        #expect(classify(fingers: 3, startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5)?.slot == .threeFingerSwipeRight)
    }

    @Test func threeFingerLeft() {
        #expect(classify(fingers: 3, startX: 0.9, startY: 0.5, endX: 0.1, endY: 0.5)?.slot == .threeFingerSwipeLeft)
    }

    @Test func threeFingerUp() {
        #expect(classify(fingers: 3, startX: 0.5, startY: 0.1, endX: 0.5, endY: 0.9)?.slot == .threeFingerSwipeUp)
    }

    @Test func threeFingerUpAcceptsLateralFingerDriftWhenVerticalMovementDominates() {
        let c = makeClassifier()
        let first = [
            pt(id: 1, x: 0.20, y: 0.20),
            pt(id: 2, x: 0.45, y: 0.20),
            pt(id: 3, x: 0.70, y: 0.20)
        ]
        let last = [
            pt(id: 1, x: 0.35, y: 0.35),
            pt(id: 2, x: 0.50, y: 0.36),
            pt(id: 3, x: 0.72, y: 0.36)
        ]

        #expect(c.classifyIncremental(firstFrame: first, currentFrame: last, peakFingerCount: 3)?.slot == .threeFingerSwipeUp)
    }

    @Test func threeFingerDown() {
        #expect(classify(fingers: 3, startX: 0.5, startY: 0.9, endX: 0.5, endY: 0.1)?.slot == .threeFingerSwipeDown)
    }

    // MARK: - 4 finger directions

    @Test func fourFingerRight() {
        #expect(classify(fingers: 4, startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5)?.slot == .fourFingerSwipeRight)
    }

    @Test func fourFingerLeft() {
        #expect(classify(fingers: 4, startX: 0.9, startY: 0.5, endX: 0.1, endY: 0.5)?.slot == .fourFingerSwipeLeft)
    }

    @Test func fourFingerUp() {
        #expect(classify(fingers: 4, startX: 0.5, startY: 0.1, endX: 0.5, endY: 0.9)?.slot == .fourFingerSwipeUp)
    }

    @Test func fourFingerDown() {
        #expect(classify(fingers: 4, startX: 0.5, startY: 0.9, endX: 0.5, endY: 0.1)?.slot == .fourFingerSwipeDown)
    }

    // MARK: - Mixed states

    @Test func acceptsLingering() {
        let c = makeClassifier()
        let first = frame(3, x: 0.1, y: 0.5, state: .touching)
        let last = frame(3, x: 0.9, y: 0.5, state: .lingering)
        #expect(c.classifyIncremental(firstFrame: first, currentFrame: last, peakFingerCount: 3)?.slot == .threeFingerSwipeRight)
    }

    // MARK: - Hand-spread rejection (palm-at-corners)

    @Test func rejectsTwoFingerContactsFurtherApartThanOneHand() {
        let c = makeClassifier()
        // Two contacts on opposite edges: aspect-corrected spread ≈ 1.35.
        let wide = [
            pt(id: 1, x: 0.05, y: 0.10),
            pt(id: 2, x: 0.95, y: 0.10)
        ]
        #expect(c.stableActiveContacts(in: wide) == nil)
    }

    @Test func acceptsTwoFingerContactsWithinHandSpread() {
        let c = makeClassifier()
        // Index + middle finger ~3cm apart on a typical trackpad: aspect-corrected 0.06.
        let close = [
            pt(id: 1, x: 0.48, y: 0.50),
            pt(id: 2, x: 0.52, y: 0.50)
        ]
        #expect(c.stableActiveContacts(in: close) != nil)
    }

    @Test func acceptsTwoFingerTapPairShapeWhenContactsMoveTogether() {
        let c = makeClassifier()
        let first = [
            pt(id: 1, x: 0.48, y: 0.50),
            pt(id: 2, x: 0.52, y: 0.50)
        ]
        let last = [
            pt(id: 1, x: 0.49, y: 0.50),
            pt(id: 2, x: 0.53, y: 0.50)
        ]

        #expect(c.tapCandidateMaintainsShape(firstContacts: [1: first[0], 2: first[1]], latestContacts: [1: last[0], 2: last[1]], fingerCount: 2))
    }

    @Test func acceptsTwoFingerTapPairShapeWithModerateFingerDrift() {
        let c = makeClassifier()
        let first = [
            pt(id: 1, x: 0.46, y: 0.50),
            pt(id: 2, x: 0.54, y: 0.50)
        ]
        let last = [
            pt(id: 1, x: 0.468, y: 0.488),
            pt(id: 2, x: 0.532, y: 0.522)
        ]

        #expect(c.tapCandidateMaintainsShape(firstContacts: [1: first[0], 2: first[1]], latestContacts: [1: last[0], 2: last[1]], fingerCount: 2))
    }

    @Test func rejectsTwoFingerTapPairShapeWhenGeometryDeforms() {
        let c = makeClassifier()
        let first = [
            pt(id: 1, x: 0.36, y: 0.83),
            pt(id: 2, x: 0.44, y: 0.83)
        ]
        let last = [
            pt(id: 1, x: 0.385, y: 0.80),
            pt(id: 2, x: 0.435, y: 0.86)
        ]

        #expect(!c.tapCandidateMaintainsShape(firstContacts: [1: first[0], 2: first[1]], latestContacts: [1: last[0], 2: last[1]], fingerCount: 2))
    }

    @Test func rejectsThreeFingerContactsFurtherApartThanOneHand() {
        let c = makeClassifier()
        // Three contacts spanning aspect-corrected ≈ 1.20 — exceeds 3-finger threshold 1.00.
        let wide = [
            pt(id: 1, x: 0.10, y: 0.20),
            pt(id: 2, x: 0.50, y: 0.20),
            pt(id: 3, x: 0.90, y: 0.20)
        ]
        #expect(c.stableActiveContacts(in: wide) == nil)
    }

    @Test func acceptsThreeFingerContactsInTypicalSpread() {
        let c = makeClassifier()
        // 3 fingers adjacent: aspect-corrected ≈ 0.45.
        let normal = [
            pt(id: 1, x: 0.40, y: 0.50),
            pt(id: 2, x: 0.50, y: 0.50),
            pt(id: 3, x: 0.60, y: 0.50)
        ]
        #expect(c.stableActiveContacts(in: normal) != nil)
    }

    @Test func fourFingerContactsFittingOneHandAreAccepted() {
        let c = makeClassifier()
        // Real one-hand 4-finger swipe span: index-to-pinky ~5-7 cm on a
        // 12 cm × 7.5 cm trackpad → ≈ 0.90 aspect-corrected, comfortably
        // below the 1.20 ceiling.
        let natural = [
            pt(id: 1, x: 0.30, y: 0.50),
            pt(id: 2, x: 0.45, y: 0.50),
            pt(id: 3, x: 0.60, y: 0.50),
            pt(id: 4, x: 0.75, y: 0.50)
        ]
        #expect(c.stableActiveContacts(in: natural) != nil)
    }

    @Test func fourFingerContactsExceedingOneHandReachAreRejected() {
        let c = makeClassifier()
        // Two-hand or palm-heel artefact spanning almost the full trackpad:
        // 0.05→0.95 = 0.90 × 1.5 = 1.35 aspect-corrected, above the 1.20
        // one-hand ceiling. Real anatomy cannot reach this span.
        let wide = [
            pt(id: 1, x: 0.05, y: 0.50),
            pt(id: 2, x: 0.35, y: 0.50),
            pt(id: 3, x: 0.65, y: 0.50),
            pt(id: 4, x: 0.95, y: 0.50)
        ]
        #expect(c.stableActiveContacts(in: wide) == nil)
    }
}

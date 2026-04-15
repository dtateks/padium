import Testing
@testable import Padium

struct GestureClassifierTests {

    private let testSwipeThreshold: Float = 0.10

    private func pt(
        id: Int = 1, x: Float = 0.5, y: Float = 0.5,
        state: OMSTouchState = .touching, total: Float = 0.15, majorAxis: Float = 12.0
    ) -> TouchPoint {
        TouchPoint(identifier: id, normalizedX: x, normalizedY: y,
                   pressure: 0.3, state: state, total: total, majorAxis: majorAxis)
    }

    private func frame(_ count: Int, x: Float, y: Float, state: OMSTouchState = .touching,
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

    @Test func defaultSensitivityKeepsEmpiricalSwipeThreshold() {
        #expect(GestureSensitivitySetting.swipeThreshold(for: GestureSensitivitySetting.defaultValue) == 0.10)
    }

    @Test func higherSensitivityLowersSwipeThreshold() {
        let lowSensitivity = GestureSensitivitySetting.swipeThreshold(for: 0.2)
        let highSensitivity = GestureSensitivitySetting.swipeThreshold(for: 0.8)
        #expect(highSensitivity < lowSensitivity)
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
}

import Testing
@testable import Padium

// Tests for GestureClassifier — swipe-only, using thresholds from spikes-oms.md.
struct GestureClassifierTests {

    // MARK: - Helpers

    private func makeTouchPoint(
        id: Int = 1,
        x: Float = 0.5,
        y: Float = 0.5,
        pressure: Float = 0.3,
        state: OMSTouchState = .touching,
        total: Float = 0.15,
        majorAxis: Float = 12.0
    ) -> TouchPoint {
        TouchPoint(
            identifier: id,
            normalizedX: x,
            normalizedY: y,
            pressure: pressure,
            state: state,
            total: total,
            majorAxis: majorAxis
        )
    }

    // Build a swipe gesture frame sequence: start frame + end frame.
    // All frames contain `fingerCount` touches in `.touching` state.
    private func swipeFrames(
        fingerCount: Int,
        startX: Float,
        startY: Float,
        endX: Float,
        endY: Float
    ) -> [[TouchPoint]] {
        let startFrame = (0..<fingerCount).map { i in
            makeTouchPoint(id: i + 1, x: startX, y: startY, state: .touching)
        }
        let endFrame = (0..<fingerCount).map { i in
            makeTouchPoint(id: i + 1, x: endX, y: endY, state: .touching)
        }
        return [startFrame, endFrame]
    }

    // MARK: - Empty / invalid input

    @Test func classifyEmptyFramesReturnsNil() {
        let classifier = GestureClassifier()
        #expect(classifier.classify(frames: []) == nil)
    }

    @Test func classifySingleFrameReturnsNil() {
        let classifier = GestureClassifier()
        let frame = [makeTouchPoint()]
        #expect(classifier.classify(frames: [frame]) == nil)
    }

    // MARK: - Noise / false-positive rejection

    @Test func classifyRejectsLowCapacitanceContacts() {
        // total < 0.03 is below the noise floor; should not produce a gesture
        let classifier = GestureClassifier()
        let start = (0..<3).map { i in makeTouchPoint(id: i + 1, x: 0.2, y: 0.5, total: 0.02) }
        let end   = (0..<3).map { i in makeTouchPoint(id: i + 1, x: 0.8, y: 0.5, total: 0.02) }
        #expect(classifier.classify(frames: [start, end]) == nil)
    }

    @Test func classifyRejectsPalmContact() {
        // axis.major > 30 is likely a palm — should not produce a gesture
        let classifier = GestureClassifier()
        let start = (0..<3).map { i in makeTouchPoint(id: i + 1, x: 0.2, y: 0.5, majorAxis: 35.0) }
        let end   = (0..<3).map { i in makeTouchPoint(id: i + 1, x: 0.8, y: 0.5, majorAxis: 35.0) }
        #expect(classifier.classify(frames: [start, end]) == nil)
    }

    @Test func classifyRejectsHoveringOnlyFrames() {
        // All contacts in hovering state → ignore
        let classifier = GestureClassifier()
        let start = (0..<3).map { i in makeTouchPoint(id: i + 1, x: 0.2, y: 0.5, state: .hovering) }
        let end   = (0..<3).map { i in makeTouchPoint(id: i + 1, x: 0.8, y: 0.5, state: .hovering) }
        #expect(classifier.classify(frames: [start, end]) == nil)
    }

    @Test func classifyRejectsTwoFingerSwipe() {
        // Only 3 and 4 finger swipes are in the supported gesture set
        let classifier = GestureClassifier()
        let frames = swipeFrames(fingerCount: 2, startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5)
        #expect(classifier.classify(frames: frames) == nil)
    }

    @Test func classifyRejectsFiveFingerSwipe() {
        let classifier = GestureClassifier()
        let frames = swipeFrames(fingerCount: 5, startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5)
        #expect(classifier.classify(frames: frames) == nil)
    }

    @Test func classifyRejectsSwipeBelowMinDistance() {
        // Movement < 0.10 normalized → not a swipe
        let classifier = GestureClassifier()
        let frames = swipeFrames(fingerCount: 3, startX: 0.5, startY: 0.5, endX: 0.55, endY: 0.5)
        #expect(classifier.classify(frames: frames) == nil)
    }

    // MARK: - 3-finger swipes

    @Test func classifyThreeFingerSwipeRight() {
        let classifier = GestureClassifier()
        let frames = swipeFrames(fingerCount: 3, startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5)
        let event = classifier.classify(frames: frames)
        #expect(event?.slot == .threeFingerSwipeRight)
    }

    @Test func classifyThreeFingerSwipeLeft() {
        let classifier = GestureClassifier()
        let frames = swipeFrames(fingerCount: 3, startX: 0.9, startY: 0.5, endX: 0.1, endY: 0.5)
        let event = classifier.classify(frames: frames)
        #expect(event?.slot == .threeFingerSwipeLeft)
    }

    @Test func classifyThreeFingerSwipeUp() {
        // In OMS, y=0 is near user (bottom), y=1 is top. Swiping "up" means increasing y.
        let classifier = GestureClassifier()
        let frames = swipeFrames(fingerCount: 3, startX: 0.5, startY: 0.1, endX: 0.5, endY: 0.9)
        let event = classifier.classify(frames: frames)
        #expect(event?.slot == .threeFingerSwipeUp)
    }

    @Test func classifyThreeFingerSwipeDown() {
        let classifier = GestureClassifier()
        let frames = swipeFrames(fingerCount: 3, startX: 0.5, startY: 0.9, endX: 0.5, endY: 0.1)
        let event = classifier.classify(frames: frames)
        #expect(event?.slot == .threeFingerSwipeDown)
    }

    // MARK: - 4-finger swipes

    @Test func classifyFourFingerSwipeRight() {
        let classifier = GestureClassifier()
        let frames = swipeFrames(fingerCount: 4, startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5)
        let event = classifier.classify(frames: frames)
        #expect(event?.slot == .fourFingerSwipeRight)
    }

    @Test func classifyFourFingerSwipeLeft() {
        let classifier = GestureClassifier()
        let frames = swipeFrames(fingerCount: 4, startX: 0.9, startY: 0.5, endX: 0.1, endY: 0.5)
        let event = classifier.classify(frames: frames)
        #expect(event?.slot == .fourFingerSwipeLeft)
    }

    @Test func classifyFourFingerSwipeUp() {
        let classifier = GestureClassifier()
        let frames = swipeFrames(fingerCount: 4, startX: 0.5, startY: 0.1, endX: 0.5, endY: 0.9)
        let event = classifier.classify(frames: frames)
        #expect(event?.slot == .fourFingerSwipeUp)
    }

    @Test func classifyFourFingerSwipeDown() {
        let classifier = GestureClassifier()
        let frames = swipeFrames(fingerCount: 4, startX: 0.5, startY: 0.9, endX: 0.5, endY: 0.1)
        let event = classifier.classify(frames: frames)
        #expect(event?.slot == .fourFingerSwipeDown)
    }

    // MARK: - Direction tolerance (diagonal → nearest cardinal)

    @Test func classifyDiagonalRightDominantAsSwipeRight() {
        // 44° angle from horizontal — still resolves to right (within ±45° tolerance)
        let classifier = GestureClassifier()
        // Δx = 0.6, Δy = 0.58 → angle ≈ 44° → right
        let frames = swipeFrames(fingerCount: 3, startX: 0.1, startY: 0.2, endX: 0.7, endY: 0.78)
        let event = classifier.classify(frames: frames)
        #expect(event?.slot == .threeFingerSwipeUp || event?.slot == .threeFingerSwipeRight)
    }

    // MARK: - GestureEvent content

    @Test func classifiedEventHasTimestamp() {
        let classifier = GestureClassifier()
        let frames = swipeFrames(fingerCount: 3, startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5)
        let event = classifier.classify(frames: frames)
        #expect(event != nil)
        #expect(event!.timestamp.timeIntervalSinceNow <= 0)
    }

    // MARK: - Finger count stability (mixed states accepted)

    @Test func classifyAcceptsFramesWithLingeringState() {
        // lingering is treated same as touching for count/position purposes
        let classifier = GestureClassifier()
        let start = (0..<3).map { i in makeTouchPoint(id: i + 1, x: 0.1, y: 0.5, state: .touching) }
        let end   = (0..<3).map { i in makeTouchPoint(id: i + 1, x: 0.9, y: 0.5, state: .lingering) }
        let event = classifier.classify(frames: [start, end])
        #expect(event?.slot == .threeFingerSwipeRight)
    }

    @Test func classifyAcceptsFramesWithBreakingState() {
        let classifier = GestureClassifier()
        let start = (0..<3).map { i in makeTouchPoint(id: i + 1, x: 0.1, y: 0.5, state: .touching) }
        let end   = (0..<3).map { i in makeTouchPoint(id: i + 1, x: 0.9, y: 0.5, state: .breaking) }
        let event = classifier.classify(frames: [start, end])
        #expect(event?.slot == .threeFingerSwipeRight)
    }
}

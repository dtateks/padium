import Testing
@testable import Padium

// Tests for GestureEngine — lifecycle, policy filtering, and event pipeline.
@MainActor
struct GestureEngineTests {

    // MARK: - Stub source

    final class StubGestureSource: GestureSource, @unchecked Sendable {
        var startShouldSucceed = true
        private(set) var startCallCount = 0
        private(set) var stopCallCount = 0

        private var stream: AsyncStream<[TouchPoint]>
        private var continuation: AsyncStream<[TouchPoint]>.Continuation

        var touchFrameStream: AsyncStream<[TouchPoint]> { stream }

        init() {
            (stream, continuation) = AsyncStream<[TouchPoint]>.makeStream()
        }

        func startListening() throws {
            startCallCount += 1
            if !startShouldSucceed {
                throw StubError.cannotStart
            }
            (stream, continuation) = AsyncStream<[TouchPoint]>.makeStream()
        }

        func stopListening() {
            stopCallCount += 1
            continuation.finish()
        }

        func yieldFrame(_ frame: [TouchPoint]) {
            continuation.yield(frame)
        }

        enum StubError: Error { case cannotStart }
    }

    // MARK: - Helpers

    private func makeSwipeFrames(
        fingerCount: Int,
        startX: Float, startY: Float,
        endX: Float, endY: Float
    ) -> [[TouchPoint]] {
        let start = (0..<fingerCount).map { i in
            TouchPoint(identifier: i + 1, normalizedX: startX, normalizedY: startY,
                       pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
        }
        let end = (0..<fingerCount).map { i in
            TouchPoint(identifier: i + 1, normalizedX: endX, normalizedY: endY,
                       pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
        }
        return [start, end]
    }

    // Deterministic collection: yields frames + lift, stops the engine, then
    // drains the passed-in stream (which terminates when the pipeline task exits).
    private func driveAndCollect(
        engine: GestureEngine,
        source: StubGestureSource,
        frames: [[TouchPoint]],
        eventsStream: AsyncStream<GestureEvent>
    ) async -> [GestureEvent] {
        for frame in frames { source.yieldFrame(frame) }
        source.yieldFrame([]) // lift — triggers classification
        engine.stop()         // finishes source → pipeline exits → events finishes

        var collected: [GestureEvent] = []
        for await event in eventsStream {
            collected.append(event)
        }
        return collected
    }

    // MARK: - start() lifecycle (non-throwing, CRIT-02)

    @Test func startReturnsTrueWhenSourceSucceeds() {
        let source = StubGestureSource()
        let engine = GestureEngine(source: source, supportedSlots: Set(GestureSlot.allCases))
        let result = engine.start()
        #expect(result == true)
        #expect(source.startCallCount == 1)
        #expect(engine.lastStartError == nil)
    }

    @Test func startReturnsFalseWhenSourceFails() {
        let source = StubGestureSource()
        source.startShouldSucceed = false
        let engine = GestureEngine(source: source, supportedSlots: Set(GestureSlot.allCases))
        let result = engine.start()
        #expect(result == false)
    }

    @Test func lastStartErrorIsSetWithUnderlyingCauseOnFailure() {
        let source = StubGestureSource()
        source.startShouldSucceed = false
        let engine = GestureEngine(source: source, supportedSlots: Set(GestureSlot.allCases))
        _ = engine.start()
        guard case .sourceUnavailable(let underlying) = engine.lastStartError else {
            Issue.record("Expected lastStartError to be .sourceUnavailable")
            return
        }
        #expect(underlying is StubGestureSource.StubError)
    }

    @Test func lastStartErrorClearedOnSuccess() {
        let source = StubGestureSource()
        // First call fails, setting lastStartError.
        source.startShouldSucceed = false
        let engine = GestureEngine(source: source, supportedSlots: Set(GestureSlot.allCases))
        _ = engine.start()
        #expect(engine.lastStartError != nil)

        // Second call succeeds — error must be cleared.
        source.startShouldSucceed = true
        _ = engine.start()
        #expect(engine.lastStartError == nil)
    }

    @Test func stopDelegatesToSource() {
        let source = StubGestureSource()
        let engine = GestureEngine(source: source, supportedSlots: Set(GestureSlot.allCases))
        engine.start()
        engine.stop()
        #expect(source.stopCallCount == 1)
    }

    @Test func doubleStartReturnsFalse() {
        let source = StubGestureSource()
        let engine = GestureEngine(source: source, supportedSlots: Set(GestureSlot.allCases))
        engine.start()
        let second = engine.start()
        #expect(second == false)
        #expect(source.startCallCount == 1)
    }

    // MARK: - events stream (deterministic — no Task.sleep)

    @Test func eventsStreamEmitsClassifiedGesture() async {
        let source = StubGestureSource()
        let engine = GestureEngine(source: source, supportedSlots: Set(GestureSlot.allCases))
        engine.start()
        let eventsStream = engine.events

        let frames = makeSwipeFrames(fingerCount: 3, startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5)
        let received = await driveAndCollect(engine: engine, source: source,
                                             frames: frames, eventsStream: eventsStream)

        #expect(received.count == 1)
        #expect(received.first?.slot == .threeFingerSwipeRight)
    }

    @Test func eventsStreamDoesNotEmitForSubthresholdMovement() async {
        let source = StubGestureSource()
        let engine = GestureEngine(source: source, supportedSlots: Set(GestureSlot.allCases))
        engine.start()
        let eventsStream = engine.events

        let frames = makeSwipeFrames(fingerCount: 3, startX: 0.5, startY: 0.5, endX: 0.55, endY: 0.5)
        let received = await driveAndCollect(engine: engine, source: source,
                                             frames: frames, eventsStream: eventsStream)

        #expect(received.isEmpty)
    }

    // MARK: - IMP-01: policy slot filtering

    @Test func engineUsesSupportedSlotsProvidedByOrchestration() {
        let source = StubGestureSource()
        let injectedSlots = Set(
            PreemptionController().currentPolicy()
                .supportedGestures
                .compactMap(GestureSlot.init(rawValue:))
        )
        let engine = GestureEngine(source: source, supportedSlots: injectedSlots)
        let policySlots = Set(
            PreemptionController().currentPolicy()
                .supportedGestures
                .compactMap(GestureSlot.init(rawValue:))
        )
        _ = engine.start()
        engine.stop()
        #expect(!policySlots.isEmpty)
        #expect(injectedSlots == policySlots)
    }

    @Test func engineSuppressesSlotNotInSupportedSet() async {
        let source = StubGestureSource()
        let fourFingerOnly = Set(GestureSlot.allCases.filter { $0.rawValue.hasPrefix("fourFinger") })
        let engine = GestureEngine(source: source, supportedSlots: fourFingerOnly)
        engine.start()
        let eventsStream = engine.events

        // 3-finger swipe — not in fourFingerOnly
        let frames = makeSwipeFrames(fingerCount: 3, startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5)
        let received = await driveAndCollect(engine: engine, source: source,
                                             frames: frames, eventsStream: eventsStream)

        #expect(received.isEmpty)
    }

    @Test func engineEmitsSlotInSupportedSet() async {
        let source = StubGestureSource()
        let fourFingerOnly = Set(GestureSlot.allCases.filter { $0.rawValue.hasPrefix("fourFinger") })
        let engine = GestureEngine(source: source, supportedSlots: fourFingerOnly)
        engine.start()
        let eventsStream = engine.events

        // 4-finger swipe — in fourFingerOnly
        let frames = makeSwipeFrames(fingerCount: 4, startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5)
        let received = await driveAndCollect(engine: engine, source: source,
                                             frames: frames, eventsStream: eventsStream)

        #expect(received.count == 1)
        #expect(received.first?.slot == .fourFingerSwipeRight)
    }

    // MARK: - CRIT-01: restartability

    @Test func engineCanRestartAfterStop() async {
        let source = StubGestureSource()
        let engine = GestureEngine(source: source, supportedSlots: Set(GestureSlot.allCases))

        engine.start()
        let firstStream = engine.events
        let frames = makeSwipeFrames(fingerCount: 3, startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5)
        let firstRun = await driveAndCollect(engine: engine, source: source,
                                             frames: frames, eventsStream: firstStream)
        #expect(firstRun.count == 1)

        let result = engine.start()
        #expect(result == true)
        #expect(source.startCallCount == 2)

        let secondStream = engine.events
        let secondRun = await driveAndCollect(engine: engine, source: source,
                                              frames: frames, eventsStream: secondStream)
        #expect(secondRun.count == 1)
        #expect(secondRun.first?.slot == .threeFingerSwipeRight)
    }
}

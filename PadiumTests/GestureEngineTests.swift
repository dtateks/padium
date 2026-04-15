import Testing
@testable import Padium

// Tests for GestureEngine — lifecycle, policy filtering, and event pipeline.
@MainActor
struct GestureEngineTests {
    private let testSwipeThreshold: Float = 0.10

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

    private func makeEngine(
        source: StubGestureSource,
        supportedSlots: Set<GestureSlot> = Set(GestureSlot.allCases)
    ) -> GestureEngine {
        GestureEngine(
            source: source,
            classifier: GestureClassifier(swipeThreshold: testSwipeThreshold),
            supportedSlots: supportedSlots
        )
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

    private func flushPipeline(turns: Int = 40) async {
        for _ in 0..<turns {
            await Task.yield()
        }
    }

    // MARK: - start() lifecycle (non-throwing, CRIT-02)

    @Test func startReturnsTrueWhenSourceSucceeds() {
        let source = StubGestureSource()
        let engine = makeEngine(source: source)
        let result = engine.start()
        #expect(result == true)
        #expect(source.startCallCount == 1)
        #expect(engine.lastStartError == nil)
    }

    @Test func startReturnsFalseWhenSourceFails() {
        let source = StubGestureSource()
        source.startShouldSucceed = false
        let engine = makeEngine(source: source)
        let result = engine.start()
        #expect(result == false)
    }

    @Test func lastStartErrorIsSetWithUnderlyingCauseOnFailure() {
        let source = StubGestureSource()
        source.startShouldSucceed = false
        let engine = makeEngine(source: source)
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
        let engine = makeEngine(source: source)
        _ = engine.start()
        #expect(engine.lastStartError != nil)

        // Second call succeeds — error must be cleared.
        source.startShouldSucceed = true
        _ = engine.start()
        #expect(engine.lastStartError == nil)
    }

    @Test func stopDelegatesToSource() {
        let source = StubGestureSource()
        let engine = makeEngine(source: source)
        engine.start()
        engine.stop()
        #expect(source.stopCallCount == 1)
    }

    @Test func doubleStartReturnsFalse() {
        let source = StubGestureSource()
        let engine = makeEngine(source: source)
        engine.start()
        let second = engine.start()
        #expect(second == false)
        #expect(source.startCallCount == 1)
    }

    // MARK: - events stream (deterministic — no Task.sleep)

    @Test func eventsStreamEmitsClassifiedGesture() async {
        let source = StubGestureSource()
        let engine = makeEngine(source: source)
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
        let engine = makeEngine(source: source)
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
        let engine = makeEngine(source: source, supportedSlots: injectedSlots)
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
        let engine = makeEngine(source: source, supportedSlots: fourFingerOnly)
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
        let engine = makeEngine(source: source, supportedSlots: fourFingerOnly)
        engine.start()
        let eventsStream = engine.events

        // 4-finger swipe — in fourFingerOnly
        let frames = makeSwipeFrames(fingerCount: 4, startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5)
        let received = await driveAndCollect(engine: engine, source: source,
                                             frames: frames, eventsStream: eventsStream)

        #expect(received.count == 1)
        #expect(received.first?.slot == .fourFingerSwipeRight)
    }

    @Test func idChurnBeforeCommitResetsGestureCandidate() async {
        let source = StubGestureSource()
        let engine = makeEngine(source: source)
        engine.start()
        let eventsStream = engine.events

        let first = [
            TouchPoint(identifier: 1, normalizedX: 0.10, normalizedY: 0.40, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
            TouchPoint(identifier: 2, normalizedX: 0.30, normalizedY: 0.40, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
            TouchPoint(identifier: 3, normalizedX: 0.50, normalizedY: 0.40, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
        ]
        let churned = [
            TouchPoint(identifier: 1, normalizedX: 0.24, normalizedY: 0.40, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
            TouchPoint(identifier: 2, normalizedX: 0.44, normalizedY: 0.40, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
            TouchPoint(identifier: 4, normalizedX: 0.64, normalizedY: 0.40, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
        ]
        let followUp = [
            TouchPoint(identifier: 1, normalizedX: 0.25, normalizedY: 0.40, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
            TouchPoint(identifier: 2, normalizedX: 0.45, normalizedY: 0.40, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
            TouchPoint(identifier: 4, normalizedX: 0.65, normalizedY: 0.40, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
        ]

        let received = await driveAndCollect(
            engine: engine,
            source: source,
            frames: [first, churned, followUp],
            eventsStream: eventsStream
        )

        #expect(received.isEmpty)
    }

    @Test func engineSuppressesDuplicateFramesUntilLift() async {
        let source = StubGestureSource()
        let engine = makeEngine(source: source)
        engine.start()
        let eventsStream = engine.events

        let collector = Task {
            var collected: [GestureEvent] = []
            for await event in eventsStream {
                collected.append(event)
            }
            return collected
        }

        let frames = makeSwipeFrames(fingerCount: 3, startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5)

        for frame in frames { source.yieldFrame(frame) }
        await flushPipeline()

        for frame in frames { source.yieldFrame(frame) }
        await flushPipeline()

        source.yieldFrame([])
        await flushPipeline()

        for frame in frames { source.yieldFrame(frame) }
        source.yieldFrame([])
        engine.stop()

        let received = await collector.value
        #expect(received.map(\.slot) == [.threeFingerSwipeRight, .threeFingerSwipeRight])
    }

    // MARK: - CRIT-01: restartability

    @Test func engineCanRestartAfterStop() async {
        let source = StubGestureSource()
        let engine = makeEngine(source: source)

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

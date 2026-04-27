import Testing
@testable import Padium
import Foundation
import os

// Tests for GestureEngine — lifecycle, policy filtering, and event pipeline.
@MainActor
@Suite(.serialized)
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

    final class StubMultitouchFrameMonitor: MultitouchFrameMonitoring, @unchecked Sendable {
        var startShouldSucceed = true
        private(set) var startCallCount = 0
        private(set) var stopCallCount = 0

        private var frameHandler: (@Sendable (MultitouchDeviceFrame) -> Void)?
        private var deviceResetHandler: (@Sendable () -> Void)?

        func startListening(
            onFrame: @escaping @Sendable (MultitouchDeviceFrame) -> Void,
            onDeviceReset: @escaping @Sendable () -> Void
        ) -> Bool {
            startCallCount += 1
            guard startShouldSucceed else {
                frameHandler = nil
                deviceResetHandler = nil
                return false
            }
            frameHandler = onFrame
            deviceResetHandler = onDeviceReset
            return true
        }

        func stopListening() {
            stopCallCount += 1
            frameHandler = nil
            deviceResetHandler = nil
        }

        func emit(deviceID: Int, points: [TouchPoint]) {
            frameHandler?(MultitouchDeviceFrame(deviceID: deviceID, points: points))
        }

        func emitDeviceReset() {
            deviceResetHandler?()
        }
    }

    @MainActor
    final class ManualGestureScheduler: GestureScheduling {
        final class ScheduledWork: GestureScheduledWork {
            private(set) var isCancelled = false

            func cancel() {
                isCancelled = true
            }
        }

        private struct ScheduledAction {
            let fireDate: Date
            let work: ScheduledWork
            let action: @MainActor () -> Void
        }

        private(set) var now: Date
        private var scheduledActions: [ScheduledAction] = []

        init(now: Date = Date(timeIntervalSinceReferenceDate: 0)) {
            self.now = now
        }

        @discardableResult
        func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> any GestureScheduledWork {
            let work = ScheduledWork()
            scheduledActions.append(
                ScheduledAction(
                    fireDate: now.addingTimeInterval(delay),
                    work: work,
                    action: action
                )
            )
            return work
        }

        func advance(by delay: TimeInterval) {
            now = now.addingTimeInterval(delay)
            runDueActions()
        }

        private func runDueActions() {
            while let index = nextDueActionIndex() {
                let scheduledAction = scheduledActions.remove(at: index)
                if !scheduledAction.work.isCancelled {
                    scheduledAction.action()
                }
                scheduledActions.removeAll { $0.work.isCancelled }
            }
        }

        private func nextDueActionIndex() -> Int? {
            scheduledActions.indices
                .filter { !scheduledActions[$0].work.isCancelled && scheduledActions[$0].fireDate <= now }
                .min { scheduledActions[$0].fireDate < scheduledActions[$1].fireDate }
        }
    }

    @MainActor
    final class EventCollector {
        private(set) var events: [GestureEvent] = []

        func collect(from stream: AsyncStream<GestureEvent>) -> Task<Void, Never> {
            Task { @MainActor [weak self] in
                guard let self else { return }
                for await event in stream {
                    self.events.append(event)
                }
            }
        }
    }

    // MARK: - Helpers

    private func makeSwipeFrames(
        fingerCount: Int,
        startX: Float, startY: Float,
        endX: Float, endY: Float
    ) -> [[TouchPoint]] {
        // Six frames so even the engine's extended stable-frame window
        // (used when the peak is below the highest configured finger count)
        // reaches the classification gate before the lift frame.
        let frameCount = 6
        let span = Float(frameCount - 1)
        return (0..<frameCount).map { i in
            let progress = Float(i) / span
            let x = startX + (endX - startX) * progress
            let y = startY + (endY - startY) * progress
            return (0..<fingerCount).map { id in
                TouchPoint(identifier: id + 1, normalizedX: x, normalizedY: y,
                           pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
            }
        }
    }

    private func makeTapFrames(
        fingerCount: Int,
        startX: Float = 0.50,
        startY: Float = 0.50,
        endX: Float = 0.51,
        endY: Float = 0.50
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
        supportedSlots: Set<GestureSlot> = Set(GestureSlot.allCases),
        scheduler: (any GestureScheduling)? = nil
    ) -> GestureEngine {
        GestureEngine(
            source: source,
            classifier: GestureClassifier(swipeThreshold: testSwipeThreshold),
            supportedSlots: supportedSlots,
            scheduler: scheduler
        )
    }

    // Deterministic collection: yields frames + lift, stops the engine, then
    // drains the passed-in stream (which terminates when the pipeline task exits).
    // When a `ManualGestureScheduler` is provided the wall clock is advanced by
    // `framePeriod` after each frame so the engine's time-based settle window
    // (`peakUpgradeSettleWindow`) can elapse deterministically without `Task.sleep`.
    private func driveAndCollect(
        engine: GestureEngine,
        source: StubGestureSource,
        scheduler: ManualGestureScheduler? = nil,
        framePeriod: TimeInterval = 0.020,
        frames: [[TouchPoint]],
        eventsStream: AsyncStream<GestureEvent>
    ) async -> [GestureEvent] {
        for frame in frames {
            source.yieldFrame(frame)
            await flushPipeline()
            scheduler?.advance(by: framePeriod)
        }
        source.yieldFrame([]) // lift — triggers classification
        await flushPipeline()
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

    private func restoreGestureSensitivity(from originalValue: Double?) {
        if let originalValue {
            GestureSensitivitySetting.store(originalValue)
        } else {
            GestureSensitivitySetting.clearStoredValue()
        }
        UserDefaults.standard.synchronize()
    }

    private func makeSourcePoint(identifier: Int, x: Float, y: Float) -> TouchPoint {
        TouchPoint(
            identifier: identifier,
            normalizedX: x,
            normalizedY: y,
            pressure: 0.3,
            state: .touching,
            total: 0.15,
            majorAxis: 12.0
        )
    }

    private func performTap(
        source: StubGestureSource,
        scheduler: ManualGestureScheduler,
        frames: [[TouchPoint]],
        // Default tap duration mirrors a realistic light tap (~80 ms),
        // above the engine's minimum-stable-duration floor. Tests that
        // need to exercise the too-short-tap rejection path should pass
        // a shorter `contactDuration` explicitly.
        contactDuration: TimeInterval = 0.08
    ) async {
        for frame in frames {
            source.yieldFrame(frame)
            await flushPipeline()
        }

        scheduler.advance(by: contactDuration)
        source.yieldFrame([])
        await flushPipeline()
    }

    // MARK: - Multitouch source device arbitration

    @Test func multitouchSourceAcceptsFramesFromExternalDevice() async {
        let monitor = StubMultitouchFrameMonitor()
        let source = MultitouchGestureSource(monitor: monitor)
        let expectedPoint = makeSourcePoint(identifier: 1, x: 0.25, y: 0.40)

        do {
            try source.startListening()
        } catch {
            Issue.record("Expected source to start: \(String(describing: error))")
            return
        }

        let collector = Task { () -> [[TouchPoint]] in
            var frames: [[TouchPoint]] = []
            for await frame in source.touchFrameStream {
                frames.append(frame)
            }
            return frames
        }

        monitor.emit(deviceID: 99, points: [expectedPoint])
        await flushPipeline()
        source.stopListening()

        let receivedFrames = await collector.value
        #expect(monitor.startCallCount == 1)
        #expect(monitor.stopCallCount == 1)
        #expect(receivedFrames.count == 1)
        #expect(receivedFrames.first?.first?.identifier == expectedPoint.identifier)
        #expect(receivedFrames.first?.first?.normalizedX == expectedPoint.normalizedX)
    }

    @Test func multitouchSourceIgnoresSecondDeviceWhileFirstIsActive() async {
        let monitor = StubMultitouchFrameMonitor()
        let source = MultitouchGestureSource(monitor: monitor)

        do {
            try source.startListening()
        } catch {
            Issue.record("Expected source to start: \(String(describing: error))")
            return
        }

        let collector = Task { () -> [[TouchPoint]] in
            var frames: [[TouchPoint]] = []
            for await frame in source.touchFrameStream {
                frames.append(frame)
            }
            return frames
        }

        monitor.emit(deviceID: 10, points: [makeSourcePoint(identifier: 1, x: 0.20, y: 0.50)])
        monitor.emit(deviceID: 20, points: [makeSourcePoint(identifier: 2, x: 0.70, y: 0.50)])
        await flushPipeline()
        source.stopListening()

        let receivedFrames = await collector.value
        #expect(receivedFrames.count == 1)
        #expect(receivedFrames.first?.first?.identifier == 1)
    }

    @Test func multitouchSourceAllowsDeviceSwitchAfterLift() async {
        let monitor = StubMultitouchFrameMonitor()
        let source = MultitouchGestureSource(monitor: monitor)

        do {
            try source.startListening()
        } catch {
            Issue.record("Expected source to start: \(String(describing: error))")
            return
        }

        let collector = Task { () -> [[TouchPoint]] in
            var frames: [[TouchPoint]] = []
            for await frame in source.touchFrameStream {
                frames.append(frame)
            }
            return frames
        }

        monitor.emit(deviceID: 10, points: [makeSourcePoint(identifier: 1, x: 0.20, y: 0.50)])
        monitor.emit(deviceID: 20, points: [makeSourcePoint(identifier: 2, x: 0.70, y: 0.50)]) // ignored
        monitor.emit(deviceID: 10, points: []) // lift for active device
        monitor.emit(deviceID: 20, points: [makeSourcePoint(identifier: 2, x: 0.72, y: 0.52)])
        await flushPipeline()
        source.stopListening()

        let receivedFrames = await collector.value
        #expect(receivedFrames.count == 3)
        #expect(receivedFrames.map(\.count) == [1, 0, 1])
        #expect(receivedFrames.first?.first?.identifier == 1)
        #expect(receivedFrames.last?.first?.identifier == 2)
    }

    @Test func multitouchSourceAllowsDeviceSwitchAfterDeviceReset() async {
        let monitor = StubMultitouchFrameMonitor()
        let source = MultitouchGestureSource(monitor: monitor)

        do {
            try source.startListening()
        } catch {
            Issue.record("Expected source to start: \(String(describing: error))")
            return
        }

        let collector = Task { () -> [[TouchPoint]] in
            var frames: [[TouchPoint]] = []
            for await frame in source.touchFrameStream {
                frames.append(frame)
            }
            return frames
        }

        monitor.emit(deviceID: 10, points: [makeSourcePoint(identifier: 1, x: 0.20, y: 0.50)])
        monitor.emit(deviceID: 20, points: [makeSourcePoint(identifier: 2, x: 0.70, y: 0.50)]) // ignored
        monitor.emitDeviceReset()
        monitor.emit(deviceID: 20, points: [makeSourcePoint(identifier: 2, x: 0.72, y: 0.52)])
        await flushPipeline()
        source.stopListening()

        let receivedFrames = await collector.value
        #expect(receivedFrames.count == 3)
        #expect(receivedFrames.map(\.count) == [1, 0, 1])
        #expect(receivedFrames.first?.first?.identifier == 1)
        #expect(receivedFrames.last?.first?.identifier == 2)
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
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(source: source, scheduler: scheduler)
        engine.start()
        let eventsStream = engine.events

        let frames = makeSwipeFrames(fingerCount: 3, startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5)
        let received = await driveAndCollect(engine: engine, source: source,
                                             scheduler: scheduler,
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

    // When no higher-finger gesture is configured, the 3-finger candidate
    // commits on the minimum stability window with no extended wait — there
    // is no upgrade path to protect against, so the latency budget stays small.
    @Test func threeFingerOnlyConfigCommitsWithoutSettleDelay() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let threeFingerSlots = Set(GestureSlot.allCases.filter { $0.fingerCount == 3 })
        let engine = makeEngine(source: source, supportedSlots: threeFingerSlots, scheduler: scheduler)
        engine.start()
        let eventsStream = engine.events

        func point(_ id: Int, x: Float) -> TouchPoint {
            TouchPoint(identifier: id, normalizedX: x, normalizedY: 0.5,
                       pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
        }
        // Two frames are enough for displacement; the wall clock is not
        // advanced. Without a higher finger count configured the engine has
        // no reason to wait for an upgrade, so the swipe must commit on
        // motion alone.
        let f1 = (1...3).map { point($0, x: 0.10) }
        let f2 = (1...3).map { point($0, x: 0.90) }

        let received = await driveAndCollect(
            engine: engine,
            source: source,
            frames: [f1, f2],
            eventsStream: eventsStream
        )

        #expect(received.map(\.slot) == [.threeFingerSwipeRight])
    }

    @Test func unsupportedFourFingerPreludeDoesNotDowngradeIntoThreeFingerSwipe() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [
                .twoFingerDoubleTap,
                .threeFingerSwipeRight, .threeFingerSwipeLeft,
                .threeFingerSwipeUp, .threeFingerSwipeDown,
                .threeFingerDoubleTap
            ],
            scheduler: scheduler
        )
        engine.start()
        let eventsStream = engine.events

        func point(_ id: Int, x: Float) -> TouchPoint {
            TouchPoint(identifier: id, normalizedX: x, normalizedY: 0.5,
                       pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
        }

        let fourStart = (1...4).map { point($0, x: 0.10) }
        let fourMid = (1...4).map { point($0, x: 0.40) }
        let threeLateA = (1...3).map { point($0, x: 0.60) }
        let threeLateB = (1...3).map { point($0, x: 0.90) }

        let received = await driveAndCollect(
            engine: engine,
            source: source,
            scheduler: scheduler,
            frames: [fourStart, fourMid, threeLateA, threeLateB],
            eventsStream: eventsStream
        )

        #expect(received.isEmpty)
    }

    // Regression: when 4-finger gestures are also configured, the 3-finger
    // candidate must hold past the upgrade settle window so the 4th finger
    // has time to land even on slower hand placements. Five 3-finger frames
    // with motion that would clear the swipe threshold must NOT pre-empt
    // a 4-finger swipe that follows. The wall clock is intentionally NOT
    // advanced for the 3-finger frames — proving the gate is closed by
    // duration, not by frame count.
    @Test func slowFourthFingerLandingAfterMultipleStableThreeFingerFramesDoesNotFireThreeFingerSwipe() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(source: source, scheduler: scheduler)
        engine.start()
        let eventsStream = engine.events

        func point(_ id: Int, x: Float) -> TouchPoint {
            TouchPoint(identifier: id, normalizedX: x, normalizedY: 0.5,
                       pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
        }

        let three1 = (1...3).map { point($0, x: 0.10) }
        let three2 = (1...3).map { point($0, x: 0.20) }
        let three3 = (1...3).map { point($0, x: 0.30) }
        let three4 = (1...3).map { point($0, x: 0.40) }
        let three5 = (1...3).map { point($0, x: 0.50) }
        // 4th finger lands; all four continue to a clear 4-finger swipe.
        let four1 = (1...4).map { point($0, x: 0.60) }
        let four2 = (1...4).map { point($0, x: 0.75) }
        let four3 = (1...4).map { point($0, x: 0.90) }

        let received = await driveAndCollect(
            engine: engine,
            source: source,
            scheduler: scheduler,
            framePeriod: 0,  // pin wall clock — only peak == max should commit
            frames: [three1, three2, three3, three4, three5, four1, four2, four3],
            eventsStream: eventsStream
        )

        #expect(received.map(\.slot) == [.fourFingerSwipeRight])
    }

    // Regression: a 4-finger swipe whose 4th finger lands a frame after the
    // first three must not be misclassified as a 3-finger swipe during the
    // brief landing window. The engine should re-anchor to the 4-finger
    // peak and fire only the 4-finger swipe. Wall clock pinned to prove
    // the time-based settle holds the 3-finger commit closed.
    @Test func gradualFourFingerLandingDoesNotMisfireAsThreeFingerSwipe() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(source: source, scheduler: scheduler)
        engine.start()
        let eventsStream = engine.events

        func point(_ id: Int, x: Float) -> TouchPoint {
            TouchPoint(identifier: id, normalizedX: x, normalizedY: 0.5,
                       pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
        }

        // Three fingers detected first, already swiping fast enough that the
        // pre-fix engine would commit a 3-finger swipe before the 4th lands.
        let threeStart = (1...3).map { point($0, x: 0.10) }
        let threeMid = (1...3).map { point($0, x: 0.40) }
        // 4th finger arrives, all four continue the swipe to completion.
        let fourA = (1...4).map { point($0, x: 0.50) }
        let fourB = (1...4).map { point($0, x: 0.70) }
        let fourC = (1...4).map { point($0, x: 0.90) }

        let received = await driveAndCollect(
            engine: engine,
            source: source,
            scheduler: scheduler,
            framePeriod: 0,
            frames: [threeStart, threeMid, fourA, fourB, fourC],
            eventsStream: eventsStream
        )

        #expect(received.map(\.slot) == [.fourFingerSwipeRight])
    }

    // Regression: a sub-threshold 4-finger gesture that lifts one finger at
    // a time must not register as a 2- or 3-finger tap. The candidate's
    // peak count locks to 4, so any tap recognition on lift maps to the
    // 4-finger slot — never a smaller-finger slot from the lift artifact.
    @Test func sequentialLiftDoesNotMisfireFourFingerGestureAsLowerFingerTap() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [
                .fourFingerSwipeRight, .fourFingerSwipeLeft,
                .twoFingerDoubleTap, .threeFingerDoubleTap, .fourFingerDoubleTap
            ],
            scheduler: scheduler
        )
        engine.start()

        let collector = EventCollector()
        let collectionTask = collector.collect(from: engine.events)

        func point(_ id: Int, x: Float) -> TouchPoint {
            TouchPoint(identifier: id, normalizedX: x, normalizedY: 0.5,
                       pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
        }

        // Two consecutive sub-threshold 4-finger gestures with sequential lifts.
        // Without the fix, the lift transitions reset the candidate down to 2
        // fingers and the second lift completes a spurious 2-finger double tap.
        for _ in 0..<2 {
            source.yieldFrame((1...4).map { point($0, x: 0.50) })
            await flushPipeline()
            source.yieldFrame((1...4).map { point($0, x: 0.51) })
            await flushPipeline()
            source.yieldFrame((1...4).map { point($0, x: 0.52) })
            await flushPipeline()
            source.yieldFrame((1...3).map { point($0, x: 0.52) })
            await flushPipeline()
            source.yieldFrame((1...2).map { point($0, x: 0.52) })
            await flushPipeline()
            scheduler.advance(by: 0.05)
            source.yieldFrame([])
            await flushPipeline()
            scheduler.advance(by: 0.10)
        }

        engine.stop()
        await collectionTask.value

        let receivedSlots = Set(collector.events.map(\.slot))
        #expect(!receivedSlots.contains(.twoFingerDoubleTap))
        #expect(!receivedSlots.contains(.threeFingerDoubleTap))
    }

    // Regression: a real 4-finger swipe followed by sequential lift must not
    // leak a smaller-finger pending tap. After the swipe fires, the candidate
    // is cleared and waitingForLift is true — subsequent partial-finger frames
    // during the lift must not register taps that could later combine into
    // an unintended double tap.
    @Test func fourFingerSwipeLiftDoesNotRegisterLowerFingerPendingTap() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [
                .fourFingerSwipeRight, .twoFingerDoubleTap,
                .threeFingerDoubleTap, .fourFingerDoubleTap
            ],
            scheduler: scheduler
        )
        engine.start()

        let collector = EventCollector()
        let collectionTask = collector.collect(from: engine.events)

        func point(_ id: Int, x: Float) -> TouchPoint {
            TouchPoint(identifier: id, normalizedX: x, normalizedY: 0.5,
                       pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
        }

        // 4-finger swipe right (3 frames to clear minimum stable count).
        source.yieldFrame((1...4).map { point($0, x: 0.10) })
        await flushPipeline()
        source.yieldFrame((1...4).map { point($0, x: 0.50) })
        await flushPipeline()
        source.yieldFrame((1...4).map { point($0, x: 0.90) })
        await flushPipeline()

        // Sequential lift through 3 → 2 → empty.
        source.yieldFrame((1...3).map { point($0, x: 0.90) })
        await flushPipeline()
        source.yieldFrame((1...2).map { point($0, x: 0.90) })
        await flushPipeline()
        scheduler.advance(by: 0.05)
        source.yieldFrame([])
        await flushPipeline()

        // Within the double-tap window, perform a real 2-finger double tap.
        // The pending-tap state must be clean of any 2-finger artifact, so
        // this should require two distinct 2-finger taps to fire — and it
        // should fire on its own merits without the swipe lift contaminating it.
        scheduler.advance(by: 0.10)
        source.yieldFrame([
            point(1, x: 0.40),
            point(2, x: 0.50)
        ])
        await flushPipeline()
        scheduler.advance(by: 0.05)
        source.yieldFrame([])
        await flushPipeline()
        // Only one 2-finger tap so far → no double tap should fire yet.
        #expect(!collector.events.map(\.slot).contains(.twoFingerDoubleTap))

        engine.stop()
        await collectionTask.value

        let slots = collector.events.map(\.slot)
        #expect(slots == [.fourFingerSwipeRight])
    }

    @Test func engineSuppressesDuplicateFramesUntilLift() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(source: source, scheduler: scheduler)
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
        let framePeriod: TimeInterval = 0.020

        for frame in frames {
            source.yieldFrame(frame)
            await flushPipeline()
            scheduler.advance(by: framePeriod)
        }

        for frame in frames {
            source.yieldFrame(frame)
            await flushPipeline()
            scheduler.advance(by: framePeriod)
        }

        source.yieldFrame([])
        await flushPipeline()

        for frame in frames {
            source.yieldFrame(frame)
            await flushPipeline()
            scheduler.advance(by: framePeriod)
        }
        source.yieldFrame([])
        await flushPipeline()
        engine.stop()

        let received = await collector.value
        #expect(received.map(\.slot) == [.threeFingerSwipeRight, .threeFingerSwipeRight])
    }

    @Test func oneFingerSecondTapInsideWindowEmitsDoubleTapWithoutSingleTap() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [.oneFingerDoubleTap],
            scheduler: scheduler
        )
        engine.start()

        let collector = EventCollector()
        let collectionTask = collector.collect(from: engine.events)

        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 1)
        )
        scheduler.advance(by: GestureTapSettings.doubleTapWindow + 0.01)
        await flushPipeline()
        #expect(collector.events.isEmpty)

        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 1)
        )
        scheduler.advance(by: 0.10)
        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 1)
        )

        #expect(collector.events.map(\.slot) == [.oneFingerDoubleTap])

        engine.stop()
        await collectionTask.value
    }

    @Test func twoFingerTapDoesNotEnableScrollSuppression() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [.twoFingerDoubleTap],
            scheduler: scheduler
        )
        engine.start()

        source.yieldFrame(makeTapFrames(fingerCount: 2)[0])
        await flushPipeline()

        #expect(ScrollSuppressor.shared.currentFingerCount == 2)
        #expect(ScrollSuppressor.shared.isMultitouchActive == false)

        engine.stop()
    }

    @Test func twoFingerSecondTapInsideWindowEmitsDoubleTapWithoutSingleTap() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [.twoFingerDoubleTap],
            scheduler: scheduler
        )
        engine.start()

        let collector = EventCollector()
        let collectionTask = collector.collect(from: engine.events)

        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 2)
        )
        scheduler.advance(by: GestureTapSettings.doubleTapWindow + 0.01)
        await flushPipeline()
        #expect(collector.events.isEmpty)

        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 2)
        )
        scheduler.advance(by: 0.10)
        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 2)
        )

        #expect(collector.events.map(\.slot) == [.twoFingerDoubleTap])

        engine.stop()
        await collectionTask.value
    }

    @Test func moderateTwoFingerPairDriftStillEmitsDoubleTap() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [.twoFingerDoubleTap],
            scheduler: scheduler
        )
        engine.start()

        let collector = EventCollector()
        let collectionTask = collector.collect(from: engine.events)

        let validDriftFrames = [
            [
                TouchPoint(identifier: 1, normalizedX: 0.46, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
                TouchPoint(identifier: 2, normalizedX: 0.54, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
            ],
            [
                TouchPoint(identifier: 1, normalizedX: 0.468, normalizedY: 0.488, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
                TouchPoint(identifier: 2, normalizedX: 0.532, normalizedY: 0.522, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
            ]
        ]

        await performTap(source: source, scheduler: scheduler, frames: validDriftFrames)
        scheduler.advance(by: 0.10)
        await performTap(source: source, scheduler: scheduler, frames: validDriftFrames)

        #expect(collector.events.map(\.slot) == [.twoFingerDoubleTap])

        engine.stop()
        await collectionTask.value
    }

    @Test func changingTwoFingerPairShapeDoesNotCountTowardDoubleTap() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [.twoFingerDoubleTap],
            scheduler: scheduler
        )
        engine.start()

        let collector = EventCollector()
        let collectionTask = collector.collect(from: engine.events)

        let palmLikeFrames = [
            [
                TouchPoint(identifier: 1, normalizedX: 0.36, normalizedY: 0.83, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
                TouchPoint(identifier: 2, normalizedX: 0.44, normalizedY: 0.83, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
            ],
            [
                TouchPoint(identifier: 1, normalizedX: 0.385, normalizedY: 0.80, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
                TouchPoint(identifier: 2, normalizedX: 0.435, normalizedY: 0.86, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
            ]
        ]

        await performTap(source: source, scheduler: scheduler, frames: palmLikeFrames)
        scheduler.advance(by: 0.10)
        await performTap(source: source, scheduler: scheduler, frames: palmLikeFrames)
        scheduler.advance(by: GestureTapSettings.doubleTapWindow + 0.01)
        await flushPipeline()

        #expect(collector.events.isEmpty)

        engine.stop()
        await collectionTask.value
    }

    @Test func partialTwoFingerFramesDoNotFallBackToOneFingerDoubleTap() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [.oneFingerDoubleTap, .twoFingerDoubleTap],
            scheduler: scheduler
        )
        engine.start()

        let collector = EventCollector()
        let collectionTask = collector.collect(from: engine.events)

        let partialTwoFingerFrame = [
            TouchPoint(identifier: 1, normalizedX: 0.50, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
            TouchPoint(identifier: 2, normalizedX: 0.54, normalizedY: 0.50, pressure: 0.3, state: .hovering, total: 0.15, majorAxis: 12.0)
        ]

        await performTap(
            source: source,
            scheduler: scheduler,
            frames: [partialTwoFingerFrame]
        )
        scheduler.advance(by: 0.10)
        await performTap(
            source: source,
            scheduler: scheduler,
            frames: [partialTwoFingerFrame]
        )
        scheduler.advance(by: GestureTapSettings.doubleTapWindow + 0.01)
        await flushPipeline()

        #expect(collector.events.isEmpty)

        engine.stop()
        await collectionTask.value
    }

    @Test func secondTapInsideWindowEmitsDoubleTapWithoutSingleTap() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [.threeFingerDoubleTap],
            scheduler: scheduler
        )
        engine.start()

        let collector = EventCollector()
        let collectionTask = collector.collect(from: engine.events)

        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 3)
        )
        #expect(collector.events.isEmpty)

        scheduler.advance(by: 0.10)
        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 3)
        )

        #expect(collector.events.map(\.slot) == [.threeFingerDoubleTap])

        scheduler.advance(by: GestureTapSettings.doubleTapWindow + 0.01)
        await flushPipeline()
        #expect(collector.events.map(\.slot) == [.threeFingerDoubleTap])

        engine.stop()
        await collectionTask.value
    }

    @Test func fourFingerSecondTapInsideWindowEmitsDoubleTapWithoutSingleTap() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [.fourFingerDoubleTap],
            scheduler: scheduler
        )
        engine.start()

        let collector = EventCollector()
        let collectionTask = collector.collect(from: engine.events)

        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 4)
        )
        scheduler.advance(by: 0.10)
        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 4)
        )

        #expect(collector.events.map(\.slot) == [.fourFingerDoubleTap])

        engine.stop()
        await collectionTask.value
    }

    @Test func doubleTapOnlyConfigurationDropsSingleTap() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [.threeFingerDoubleTap],
            scheduler: scheduler
        )
        engine.start()

        let collector = EventCollector()
        let collectionTask = collector.collect(from: engine.events)

        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 3)
        )

        scheduler.advance(by: GestureTapSettings.doubleTapWindow + 0.01)
        await flushPipeline()
        #expect(collector.events.isEmpty)

        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 3)
        )
        scheduler.advance(by: 0.10)
        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 3)
        )

        #expect(collector.events.map(\.slot) == [.threeFingerDoubleTap])

        engine.stop()
        await collectionTask.value
    }

    @Test func clickSlotsDoNotEmitFromTouchTapPipeline() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [.threeFingerClick, .threeFingerDoubleClick],
            scheduler: scheduler
        )
        engine.start()

        let collector = EventCollector()
        let collectionTask = collector.collect(from: engine.events)

        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 3)
        )
        scheduler.advance(by: GestureTapSettings.doubleTapWindow + 0.01)
        await flushPipeline()

        #expect(collector.events.isEmpty)

        engine.stop()
        await collectionTask.value
    }

    @Test func doubleTapDoesNotEmitWhenTravelExceedsThreshold() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [.threeFingerDoubleTap],
            scheduler: scheduler
        )
        engine.start()

        let collector = EventCollector()
        let collectionTask = collector.collect(from: engine.events)

        // Both taps have excessive travel — neither registers as a tap candidate.
        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 3, endX: 0.60, endY: 0.50)
        )
        scheduler.advance(by: 0.10)
        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 3, endX: 0.60, endY: 0.50)
        )

        #expect(collector.events.isEmpty)

        engine.stop()
        await collectionTask.value
    }

    @Test func higherSensitivityMakesTapTravelMoreForgiving() async {
        let originalSensitivity = UserDefaults.standard.object(forKey: "gesture.sensitivity") as? Double
        defer { restoreGestureSensitivity(from: originalSensitivity) }

        GestureSensitivitySetting.store(0.0)
        UserDefaults.standard.synchronize()

        do {
            let source = StubGestureSource()
            let scheduler = ManualGestureScheduler()
            let engine = makeEngine(
                source: source,
                supportedSlots: [.threeFingerDoubleTap],
                scheduler: scheduler
            )
            engine.start()

            let collector = EventCollector()
            let collectionTask = collector.collect(from: engine.events)

            // Two taps with moderate travel — at low sensitivity, travel is rejected.
            await performTap(
                source: source,
                scheduler: scheduler,
                frames: makeTapFrames(fingerCount: 3, endX: 0.543, endY: 0.50)
            )
            scheduler.advance(by: 0.10)
            await performTap(
                source: source,
                scheduler: scheduler,
                frames: makeTapFrames(fingerCount: 3, endX: 0.543, endY: 0.50)
            )

            #expect(collector.events.isEmpty)

            engine.stop()
            await collectionTask.value
        }

        GestureSensitivitySetting.store(1.0)
        UserDefaults.standard.synchronize()

        do {
            let source = StubGestureSource()
            let scheduler = ManualGestureScheduler()
            let engine = makeEngine(
                source: source,
                supportedSlots: [.threeFingerDoubleTap],
                scheduler: scheduler
            )
            engine.start()

            let collector = EventCollector()
            let collectionTask = collector.collect(from: engine.events)

            // At high sensitivity, moderate travel is accepted — double tap emits.
            await performTap(
                source: source,
                scheduler: scheduler,
                frames: makeTapFrames(fingerCount: 3, endX: 0.543, endY: 0.50)
            )
            scheduler.advance(by: 0.10)
            await performTap(
                source: source,
                scheduler: scheduler,
                frames: makeTapFrames(fingerCount: 3, endX: 0.543, endY: 0.50)
            )

            #expect(collector.events.map(\.slot) == [.threeFingerDoubleTap])

            engine.stop()
            await collectionTask.value
        }
    }

    @Test func stopCancelsPendingDoubleTapDetection() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [.threeFingerDoubleTap],
            scheduler: scheduler
        )
        engine.start()

        let collector = EventCollector()
        let collectionTask = collector.collect(from: engine.events)

        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 3)
        )
        #expect(collector.events.isEmpty)

        engine.stop()
        scheduler.advance(by: GestureTapSettings.doubleTapWindow + 0.01)
        await flushPipeline()
        #expect(collector.events.isEmpty)

        await collectionTask.value
    }

    // MARK: - CRIT-01: restartability

    // MARK: - Palm rejection

    @Test func nearStationaryThirdContactDoesNotTriggerThreeFingerSwipe() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(source: source, scheduler: scheduler)
        engine.start()
        let eventsStream = engine.events

        let frames = [
            [
                TouchPoint(identifier: 1, normalizedX: 0.20, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
                TouchPoint(identifier: 2, normalizedX: 0.40, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
                TouchPoint(identifier: 3, normalizedX: 0.52, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
            ],
            [
                TouchPoint(identifier: 1, normalizedX: 0.26, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
                TouchPoint(identifier: 2, normalizedX: 0.46, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
                TouchPoint(identifier: 3, normalizedX: 0.524, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
            ],
            [
                TouchPoint(identifier: 1, normalizedX: 0.32, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
                TouchPoint(identifier: 2, normalizedX: 0.52, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
                TouchPoint(identifier: 3, normalizedX: 0.528, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
            ],
            [
                TouchPoint(identifier: 1, normalizedX: 0.38, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
                TouchPoint(identifier: 2, normalizedX: 0.58, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
                TouchPoint(identifier: 3, normalizedX: 0.532, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
            ],
            [
                TouchPoint(identifier: 1, normalizedX: 0.44, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
                TouchPoint(identifier: 2, normalizedX: 0.64, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
                TouchPoint(identifier: 3, normalizedX: 0.536, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
            ],
            [
                TouchPoint(identifier: 1, normalizedX: 0.50, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
                TouchPoint(identifier: 2, normalizedX: 0.70, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
                TouchPoint(identifier: 3, normalizedX: 0.54, normalizedY: 0.50, pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
            ]
        ]

        let received = await driveAndCollect(
            engine: engine,
            source: source,
            scheduler: scheduler,
            frames: frames,
            eventsStream: eventsStream
        )

        #expect(received.isEmpty)
    }

    @Test func palmRestAtOppositeCornersDoesNotEmitTwoFingerDoubleTap() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [.twoFingerDoubleTap],
            scheduler: scheduler
        )
        engine.start()

        let collector = EventCollector()
        let collectionTask = collector.collect(from: engine.events)

        // Two palm-like contacts on opposite horizontal edges: aspect-corrected
        // spread ≈ 0.90 * 1.5 = 1.35, well above the 2-finger 0.70 threshold.
        func palmFrame() -> [TouchPoint] {
            [
                TouchPoint(identifier: 1, normalizedX: 0.05, normalizedY: 0.10,
                           pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0),
                TouchPoint(identifier: 2, normalizedX: 0.95, normalizedY: 0.10,
                           pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
            ]
        }

        await performTap(source: source, scheduler: scheduler, frames: [palmFrame()])
        scheduler.advance(by: 0.10)
        await performTap(source: source, scheduler: scheduler, frames: [palmFrame()])

        #expect(collector.events.isEmpty)

        engine.stop()
        await collectionTask.value
    }

    // Regression: a 4-finger swipe whose 4th finger arrives AFTER a 3-finger
    // candidate already formed (and is only configured for 2/3-finger slots)
    // must never downgrade into a 3-finger commit. The raw-peak taint drops
    // the in-flight candidate the moment a RAW frame of >max-configured
    // appears, and latches suppression until lift.
    @Test func fourthFingerAfterThreeFingerCandidateDoesNotCommitThreeFingerSwipe() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [
                .twoFingerDoubleTap,
                .threeFingerSwipeRight, .threeFingerSwipeLeft,
                .threeFingerSwipeUp, .threeFingerSwipeDown,
                .threeFingerDoubleTap
            ],
            scheduler: scheduler
        )
        engine.start()
        let eventsStream = engine.events

        func point(_ id: Int, x: Float) -> TouchPoint {
            TouchPoint(identifier: id, normalizedX: x, normalizedY: 0.5,
                       pressure: 0.3, state: .touching, total: 0.15, majorAxis: 12.0)
        }

        // 3 fingers visible briefly with sub-threshold motion (the realistic
        // landing-spread pattern), then the 4th finger arrives and the hand
        // completes a clear 4-finger swipe — which isn't configured, so
        // nothing must emit.
        let three1 = (1...3).map { point($0, x: 0.10) }
        let three2 = (1...3).map { point($0, x: 0.12) }
        let four1 = (1...4).map { point($0, x: 0.30) }
        let four2 = (1...4).map { point($0, x: 0.60) }
        let four3 = (1...4).map { point($0, x: 0.90) }

        let received = await driveAndCollect(
            engine: engine,
            source: source,
            scheduler: scheduler,
            frames: [three1, three2, four1, four2, four3],
            eventsStream: eventsStream
        )

        #expect(received.isEmpty)
    }

    // Regression: two contacts that land asynchronously (palm at one corner,
    // then second palm at another corner while typing) must not register a
    // tap even if the final stable frame looks geometrically plausible.
    // Real one-hand 2-finger taps land within ~50ms; asynchronous corner
    // palms routinely exceed 80ms apart.
    @Test func asynchronousTwoFingerLandingDoesNotEmitDoubleTap() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [.twoFingerDoubleTap],
            scheduler: scheduler
        )
        engine.start()

        let collector = EventCollector()
        let collectionTask = collector.collect(from: engine.events)

        func point(_ id: Int, x: Float, state: TouchState = .touching) -> TouchPoint {
            TouchPoint(identifier: id, normalizedX: x, normalizedY: 0.50,
                       pressure: 0.3, state: state, total: 0.15, majorAxis: 12.0)
        }

        // Tap 1: finger 1 lands first, then >80ms later finger 2 lands; both
        // end up in a stable frame that passes shape coherence, but the raw
        // first-seen spread exceeds the concurrency window.
        source.yieldFrame([point(1, x: 0.48)])
        await flushPipeline()
        scheduler.advance(by: 0.15)
        source.yieldFrame([point(1, x: 0.48), point(2, x: 0.52)])
        await flushPipeline()
        scheduler.advance(by: 0.02)
        source.yieldFrame([])
        await flushPipeline()

        // Tap 2: same asynchronous pattern.
        scheduler.advance(by: 0.10)
        source.yieldFrame([point(3, x: 0.48)])
        await flushPipeline()
        scheduler.advance(by: 0.15)
        source.yieldFrame([point(3, x: 0.48), point(4, x: 0.52)])
        await flushPipeline()
        scheduler.advance(by: 0.02)
        source.yieldFrame([])
        await flushPipeline()

        #expect(collector.events.isEmpty)

        engine.stop()
        await collectionTask.value
    }

    // Regression: palm grazes during typing are capacitive flickers that
    // appear and vanish within 10-30 ms (palm never actually rests). Two
    // such flickers inside the double-tap window must never emit
    // twoFingerDoubleTap. Gated by `minimumStableDuration` — the same
    // principle as libinput's `tap-minimum-time` — independent of any
    // keyboard-activity heuristic.
    @Test func briefPalmGrazeDoesNotEmitTwoFingerDoubleTap() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [.twoFingerDoubleTap],
            scheduler: scheduler
        )
        engine.start()

        let collector = EventCollector()
        let collectionTask = collector.collect(from: engine.events)

        // Two grazes 20 ms long each — below minimumStableDuration (50 ms).
        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 2),
            contactDuration: 0.02
        )
        scheduler.advance(by: 0.10)
        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 2),
            contactDuration: 0.02
        )

        #expect(collector.events.isEmpty)

        engine.stop()
        await collectionTask.value
    }

    // Regression proving sensitivity isn't regressed: two contacts that land
    // within the concurrency window (simultaneous one-hand tap) must still
    // produce a double tap.
    @Test func synchronousTwoFingerLandingStillEmitsDoubleTap() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(
            source: source,
            supportedSlots: [.twoFingerDoubleTap],
            scheduler: scheduler
        )
        engine.start()

        let collector = EventCollector()
        let collectionTask = collector.collect(from: engine.events)

        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 2)
        )
        scheduler.advance(by: 0.10)
        await performTap(
            source: source,
            scheduler: scheduler,
            frames: makeTapFrames(fingerCount: 2)
        )

        #expect(collector.events.map(\.slot) == [.twoFingerDoubleTap])

        engine.stop()
        await collectionTask.value
    }

    @Test func engineCanRestartAfterStop() async {
        let source = StubGestureSource()
        let scheduler = ManualGestureScheduler()
        let engine = makeEngine(source: source, scheduler: scheduler)

        engine.start()
        let firstStream = engine.events
        let frames = makeSwipeFrames(fingerCount: 3, startX: 0.1, startY: 0.5, endX: 0.9, endY: 0.5)
        let firstRun = await driveAndCollect(engine: engine, source: source,
                                             scheduler: scheduler,
                                             frames: frames, eventsStream: firstStream)
        #expect(firstRun.count == 1)

        let result = engine.start()
        #expect(result == true)
        #expect(source.startCallCount == 2)

        let secondStream = engine.events
        let secondRun = await driveAndCollect(engine: engine, source: source,
                                              scheduler: scheduler,
                                              frames: frames, eventsStream: secondStream)
        #expect(secondRun.count == 1)
        #expect(secondRun.first?.slot == .threeFingerSwipeRight)
    }
}

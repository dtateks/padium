import Testing
@testable import Padium
import Foundation

// Tests for MultitouchGestureSource — single-device frame arbitration,
// device-switch handling, and device-reset semantics.
@MainActor
struct MultitouchGestureSourceTests {

    // MARK: - Stub monitor

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

    // MARK: - Helpers

    private func flushPipeline(turns: Int = 40) async {
        for _ in 0..<turns {
            await Task.yield()
        }
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

    // MARK: - Tests

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

    @Test func multitouchSourceEmitsLiftForDeviceResetBeforeSameDeviceIDFrames() async {
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
        monitor.emitDeviceReset()
        monitor.emit(deviceID: 10, points: [makeSourcePoint(identifier: 2, x: 0.72, y: 0.52)])
        await flushPipeline()
        source.stopListening()

        let receivedFrames = await collector.value
        #expect(receivedFrames.count == 3)
        #expect(receivedFrames.map(\.count) == [1, 0, 1])
        #expect(receivedFrames.first?.first?.identifier == 1)
        #expect(receivedFrames.last?.first?.identifier == 2)
    }
}

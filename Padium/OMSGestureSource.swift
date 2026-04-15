import Foundation
import OpenMultitouchSupport

// Concrete GestureSource backed by OpenMultitouchSupport.
// Thread-safety: OMSManager is Sendable (OSAllocatedUnfairLock-guarded internally).
// stream and continuation are replaced on each startListening() call so the source
// is restartable. @unchecked Sendable is justified: all mutable state is accessed
// only from the Task spawned inside startListening(), which is cancelled before any
// mutation in stopListening().
final class OMSGestureSource: GestureSource, @unchecked Sendable {
    private var stream: AsyncStream<[TouchPoint]>
    private var continuation: AsyncStream<[TouchPoint]>.Continuation
    private var omsTask: Task<Void, Never>?

    var touchFrameStream: AsyncStream<[TouchPoint]> { stream }

    init() {
        (stream, continuation) = AsyncStream<[TouchPoint]>.makeStream()
    }

    func startListening() throws {
        let started = OMSManager.shared.startListening()
        guard started else {
            PadiumLogger.gesture.error("OMS listener failed to start")
            throw OMSGestureSourceError.listenerAlreadyActiveOrHardwareUnavailable
        }

        PadiumLogger.gesture.info("OMS listener started")
        (stream, continuation) = AsyncStream<[TouchPoint]>.makeStream()
        let activeContinuation = continuation
        omsTask = Task {
            var frameCount = 0
            for await omsTouches in OMSManager.shared.touchDataStream {
                frameCount += 1
                if frameCount <= 5 || frameCount % 100 == 0 {
                    PadiumLogger.gesture.debug("OMS frame \(frameCount, privacy: .public): \(omsTouches.count, privacy: .public) touches")
                }
                let points = omsTouches.map { t in
                    TouchPoint(
                        identifier: Int(t.id),
                        normalizedX: t.position.x,
                        normalizedY: t.position.y,
                        pressure: t.pressure,
                        state: OMSTouchState(t.state),
                        total: t.total,
                        majorAxis: t.axis.major
                    )
                }
                activeContinuation.yield(points)
            }
        }
    }

    func stopListening() {
        OMSManager.shared.stopListening()
        omsTask?.cancel()
        omsTask = nil
        continuation.finish()
        PadiumLogger.gesture.info("OMS listener stopped")
    }
}

enum OMSGestureSourceError: Error {
    case listenerAlreadyActiveOrHardwareUnavailable
}

private extension OMSTouchState {
    init(_ state: OMSState) {
        switch state {
        case .notTouching: self = .notTouching
        case .starting:    self = .starting
        case .hovering:    self = .hovering
        case .making:      self = .making
        case .touching:    self = .touching
        case .breaking:    self = .breaking
        case .lingering:   self = .lingering
        case .leaving:     self = .leaving
        }
    }
}

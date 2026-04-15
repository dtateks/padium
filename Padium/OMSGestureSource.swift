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
            throw OMSGestureSourceError.listenerAlreadyActiveOrHardwareUnavailable
        }
        // Replace stream+continuation so consumers on a restarted engine get a
        // fresh, non-finished stream. The previous continuation is already finished
        // by the preceding stopListening() call.
        (stream, continuation) = AsyncStream<[TouchPoint]>.makeStream()
        let activeContinuation = continuation
        omsTask = Task {
            for await omsTouches in OMSManager.shared.touchDataStream {
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

import Foundation

// Drives the gesture pipeline: reads from a GestureSource, classifies frame
// sequences, and emits GestureEvents on the `events` stream.
//
// Gesture boundary: a sequence starts on the first non-empty stable frame after
// a lift (empty frame) or engine start, and ends when an empty frame is received.
// The accumulated frames are then classified; results are emitted only when their
// slot is in the active supported set provided by orchestration.
//
// Lifecycle: `events` is replaced on each `start()` call. Callers must re-subscribe
// after a stop/start cycle. The previous stream is finished when the pipeline exits.
//
// Contract C-04-gesture-engine:
//   var events: AsyncStream<GestureEvent>
//   @discardableResult func start() -> Bool
//   func stop()
//   var lastStartError: GestureEngineError?   — explicit failure reason (CRIT-02)
@MainActor
final class GestureEngine {
    private let source: any GestureSource
    private let classifier: GestureClassifier
    private let supportedSlots: Set<GestureSlot>

    private(set) var events: AsyncStream<GestureEvent>
    private var continuation: AsyncStream<GestureEvent>.Continuation
    private var pipelineTask: Task<Void, Never>?
    private var isRunning = false

    // Set when start() fails; nil on success. Allows callers to inspect the
    // concrete failure reason without requiring a throwing call site.
    private(set) var lastStartError: GestureEngineError?

    init(
        source: any GestureSource,
        classifier: GestureClassifier = GestureClassifier(),
        supportedSlots: Set<GestureSlot>
    ) {
        self.source = source
        self.classifier = classifier
        self.supportedSlots = supportedSlots
        (events, continuation) = AsyncStream<GestureEvent>.makeStream()
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return false }
        do {
            try source.startListening()
        } catch {
            lastStartError = .sourceUnavailable(underlying: error)
            return false
        }
        lastStartError = nil
        // Fresh stream per start() so a restart produces a non-finished stream.
        // The previous stream is finished by the prior pipeline task's defer.
        (events, continuation) = AsyncStream<GestureEvent>.makeStream()
        isRunning = true
        let localSource = source
        let localClassifier = classifier
        let localSupportedSlots = supportedSlots
        let localContinuation = continuation
        pipelineTask = Task { [localSource, localClassifier, localSupportedSlots, localContinuation] in
            defer {
                // Finish the events stream whether the source ended normally or the
                // task was cancelled, so consumers' for-await loops always terminate.
                localContinuation.finish()
            }
            var accumulatedFrames: [[TouchPoint]] = []
            for await frame in localSource.touchFrameStream {
                if frame.isEmpty {
                    // Empty frame marks lift — classify then filter by policy.
                    if let event = localClassifier.classify(frames: accumulatedFrames),
                       localSupportedSlots.contains(event.slot) {
                        localContinuation.yield(event)
                    }
                    accumulatedFrames = []
                } else {
                    accumulatedFrames.append(frame)
                }
            }
        }
        return true
    }

    func stop() {
        source.stopListening()
        pipelineTask?.cancel()
        pipelineTask = nil
        isRunning = false
    }
}

enum GestureEngineError: Error {
    // The underlying GestureSource could not start (hardware unavailable,
    // listener already active, or permission denied).
    case sourceUnavailable(underlying: Error)
}

import Foundation

// Drives the gesture pipeline from raw touch frames to emitted gesture events.
// A gesture candidate is tracked only while finger count and touch identifiers stay
// stable; once a swipe commits, the engine ignores subsequent frames until lift.
@MainActor
final class GestureEngine {
    private struct GestureCandidate {
        let originContacts: [Int: TouchPoint]
        let fingerCount: Int

        var trackedIdentifiers: Set<Int> {
            Set(originContacts.keys)
        }
    }

    private let source: any GestureSource
    private let classifierFactory: @Sendable () -> GestureClassifier
    private let supportedSlots: Set<GestureSlot>

    private(set) var events: AsyncStream<GestureEvent>
    private var continuation: AsyncStream<GestureEvent>.Continuation
    private var pipelineTask: Task<Void, Never>?
    private var isRunning = false

    private(set) var lastStartError: GestureEngineError?

    init(source: any GestureSource, supportedSlots: Set<GestureSlot>) {
        self.source = source
        self.classifierFactory = { GestureClassifier() }
        self.supportedSlots = supportedSlots
        (events, continuation) = AsyncStream<GestureEvent>.makeStream()
    }

    init(source: any GestureSource, classifier: GestureClassifier, supportedSlots: Set<GestureSlot>) {
        self.source = source
        self.classifierFactory = { classifier }
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
        (events, continuation) = AsyncStream<GestureEvent>.makeStream()
        isRunning = true
        let localSource = source
        let localClassifier = classifierFactory()
        let localSupportedSlots = supportedSlots
        let localContinuation = continuation
        pipelineTask = Task { [localSource, localClassifier, localSupportedSlots, localContinuation] in
            defer {
                localContinuation.finish()
                ScrollSuppressor.shared.isMultitouchActive = false
            }

            var candidate: GestureCandidate?
            var waitingForLift = false

            for await frame in localSource.touchFrameStream {
                if frame.isEmpty {
                    candidate = nil
                    waitingForLift = false
                    ScrollSuppressor.shared.isMultitouchActive = false
                    continue
                }

                if waitingForLift {
                    // Keep suppression active while waiting for lift
                    continue
                }

                guard let contacts = localClassifier.stableActiveContacts(in: frame) else {
                    candidate = nil
                    ScrollSuppressor.shared.isMultitouchActive = false
                    continue
                }

                let fingerCount = contacts.count
                guard fingerCount == 3 || fingerCount == 4 else {
                    candidate = nil
                    ScrollSuppressor.shared.isMultitouchActive = false
                    continue
                }

                // 3+ fingers active — suppress scroll events
                ScrollSuppressor.shared.isMultitouchActive = true

                guard let activeCandidate = candidate else {
                    candidate = GestureCandidate(originContacts: contacts, fingerCount: fingerCount)
                    continue
                }

                guard activeCandidate.fingerCount == fingerCount,
                      activeCandidate.trackedIdentifiers == Set(contacts.keys) else {
                    candidate = GestureCandidate(originContacts: contacts, fingerCount: fingerCount)
                    continue
                }

                if let event = localClassifier.classifyIncremental(
                    firstContacts: activeCandidate.originContacts,
                    currentContacts: contacts,
                    peakFingerCount: fingerCount
                ), localSupportedSlots.contains(event.slot) {
                    localContinuation.yield(event)
                    waitingForLift = true
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
    case sourceUnavailable(underlying: Error)
}

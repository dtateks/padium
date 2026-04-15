import Foundation

@MainActor
protocol GestureScheduledWork: AnyObject {
    func cancel()
}

@MainActor
protocol GestureScheduling: AnyObject {
    var now: Date { get }

    @discardableResult
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> any GestureScheduledWork
}

@MainActor
final class TaskGestureScheduler: GestureScheduling {
    var now: Date { Date() }

    @discardableResult
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> any GestureScheduledWork {
        TaskScheduledWork(delay: delay, action: action)
    }
}

@MainActor
final class TaskScheduledWork: GestureScheduledWork {
    private var task: Task<Void, Never>?

    init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        let nanoseconds = UInt64(max(delay, 0) * 1_000_000_000)
        task = Task {
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                action()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

// Drives the gesture pipeline from raw touch frames to emitted gesture events.
// Tracks stable 3/4-finger contact sequences, emits swipes immediately, and
// arbitrates taps versus double taps when the fingers lift.
@MainActor
final class GestureEngine {
    private struct GestureCandidate {
        let originContacts: [Int: TouchPoint]
        let fingerCount: Int
        let startedAt: Date
        var maximumTravel: Float = 0

        var trackedIdentifiers: Set<Int> {
            Set(originContacts.keys)
        }

        mutating func recordTravel(using currentContacts: [Int: TouchPoint]) {
            for (identifier, startPoint) in originContacts {
                guard let currentPoint = currentContacts[identifier] else { continue }
                maximumTravel = max(
                    maximumTravel,
                    GestureClassifier.travelDistance(from: startPoint, to: currentPoint)
                )
            }
        }

        func duration(at timestamp: Date) -> TimeInterval {
            timestamp.timeIntervalSince(startedAt)
        }
    }

    private struct PendingTap {
        let recognizedAt: Date
        let scheduledWork: any GestureScheduledWork
    }

    private struct TapActivation {
        let singleTapSlot: GestureSlot?
        let doubleTapSlot: GestureSlot?

        var hasAnyTapSlot: Bool {
            singleTapSlot != nil || doubleTapSlot != nil
        }
    }

    private let source: any GestureSource
    private let classifierFactory: @Sendable () -> GestureClassifier
    private let scheduler: any GestureScheduling
    private let supportedSlots: Set<GestureSlot>

    private var activeSlots: Set<GestureSlot>
    private(set) var events: AsyncStream<GestureEvent>
    private var continuation: AsyncStream<GestureEvent>.Continuation
    private var pipelineTask: Task<Void, Never>?
    private var isRunning = false
    private var pendingTaps: [Int: PendingTap] = [:]

    private(set) var lastStartError: GestureEngineError?

    init(
        source: any GestureSource,
        supportedSlots: Set<GestureSlot>,
        scheduler: (any GestureScheduling)? = nil
    ) {
        self.source = source
        self.classifierFactory = { GestureClassifier() }
        self.scheduler = scheduler ?? TaskGestureScheduler()
        self.supportedSlots = supportedSlots
        self.activeSlots = supportedSlots
        (events, continuation) = AsyncStream<GestureEvent>.makeStream()
    }

    init(
        source: any GestureSource,
        classifier: GestureClassifier,
        supportedSlots: Set<GestureSlot>,
        scheduler: (any GestureScheduling)? = nil
    ) {
        self.source = source
        self.classifierFactory = { classifier }
        self.scheduler = scheduler ?? TaskGestureScheduler()
        self.supportedSlots = supportedSlots
        self.activeSlots = supportedSlots
        (events, continuation) = AsyncStream<GestureEvent>.makeStream()
    }

    func updateActiveSlots(_ activeSlots: Set<GestureSlot>) {
        self.activeSlots = supportedSlots.intersection(activeSlots)
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return false }
        cancelPendingTaps()

        do {
            try source.startListening()
        } catch {
            lastStartError = .sourceUnavailable(underlying: error)
            return false
        }

        lastStartError = nil
        (events, continuation) = AsyncStream<GestureEvent>.makeStream()
        isRunning = true

        let localClassifier = classifierFactory()
        let localContinuation = continuation
        pipelineTask = Task { [weak self, localContinuation] in
            guard let self else {
                localContinuation.finish()
                return
            }

            defer {
                localContinuation.finish()
                ScrollSuppressor.shared.isMultitouchActive = false
            }

            var candidate: GestureCandidate?
            var waitingForLift = false

            for await frame in self.source.touchFrameStream {
                if Task.isCancelled {
                    break
                }

                if frame.isEmpty {
                    if let candidate {
                        self.handleLift(of: candidate, using: localContinuation)
                    }
                    candidate = nil
                    waitingForLift = false
                    ScrollSuppressor.shared.isMultitouchActive = false
                    continue
                }

                if waitingForLift {
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

                guard self.hasActiveSlots(for: fingerCount) else {
                    candidate = nil
                    ScrollSuppressor.shared.isMultitouchActive = false
                    continue
                }

                ScrollSuppressor.shared.isMultitouchActive = true

                guard let activeCandidate = candidate else {
                    candidate = GestureCandidate(
                        originContacts: contacts,
                        fingerCount: fingerCount,
                        startedAt: self.scheduler.now
                    )
                    continue
                }

                guard activeCandidate.fingerCount == fingerCount,
                      activeCandidate.trackedIdentifiers == Set(contacts.keys) else {
                    candidate = GestureCandidate(
                        originContacts: contacts,
                        fingerCount: fingerCount,
                        startedAt: self.scheduler.now
                    )
                    continue
                }

                if let event = localClassifier.classifyIncremental(
                    firstContacts: activeCandidate.originContacts,
                    currentContacts: contacts,
                    peakFingerCount: fingerCount
                ), self.activeSlots.contains(event.slot) {
                    localContinuation.yield(event)
                    waitingForLift = true
                    candidate = nil
                    continue
                }

                var updatedCandidate = activeCandidate
                updatedCandidate.recordTravel(using: contacts)
                candidate = updatedCandidate
            }
        }
        return true
    }

    func stop() {
        cancelPendingTaps()
        source.stopListening()
        pipelineTask?.cancel()
        pipelineTask = nil
        isRunning = false
        ScrollSuppressor.shared.isMultitouchActive = false
    }

    private func hasActiveSlots(for fingerCount: Int) -> Bool {
        activeSlots.contains { $0.fingerCount == fingerCount }
    }

    private func tapActivation(for fingerCount: Int) -> TapActivation {
        let relevantSlots = activeSlots.filter { $0.fingerCount == fingerCount }
        return TapActivation(
            singleTapSlot: relevantSlots.first(where: { $0.kind == .tap }),
            doubleTapSlot: relevantSlots.first(where: { $0.kind == .doubleTap })
        )
    }

    private func handleLift(
        of candidate: GestureCandidate,
        using continuation: AsyncStream<GestureEvent>.Continuation
    ) {
        let recognitionTime = scheduler.now
        guard candidate.duration(at: recognitionTime) <= GestureTapSettings.maximumDuration else { return }
        guard candidate.maximumTravel <= GestureTapSettings.maximumTravel else { return }

        handleRecognizedTap(
            fingerCount: candidate.fingerCount,
            recognizedAt: recognitionTime,
            using: continuation
        )
    }

    private func handleRecognizedTap(
        fingerCount: Int,
        recognizedAt: Date,
        using continuation: AsyncStream<GestureEvent>.Continuation
    ) {
        let activation = tapActivation(for: fingerCount)
        guard activation.hasAnyTapSlot else { return }

        resolvePendingTapIfNeeded(for: fingerCount, recognizedAt: recognizedAt, using: continuation)

        if let pendingTap = pendingTaps[fingerCount],
           recognizedAt.timeIntervalSince(pendingTap.recognizedAt) <= GestureTapSettings.doubleTapWindow,
           let doubleTapSlot = activation.doubleTapSlot {
            pendingTap.scheduledWork.cancel()
            pendingTaps.removeValue(forKey: fingerCount)
            emit(doubleTapSlot, at: recognizedAt, using: continuation)
            return
        }

        if let pendingTap = pendingTaps[fingerCount] {
            pendingTap.scheduledWork.cancel()
            pendingTaps.removeValue(forKey: fingerCount)

            if let singleTapSlot = activation.singleTapSlot {
                emit(singleTapSlot, at: recognizedAt, using: continuation)
            }
        }

        guard activation.doubleTapSlot != nil else {
            if let singleTapSlot = activation.singleTapSlot {
                emit(singleTapSlot, at: recognizedAt, using: continuation)
            }
            return
        }

        let scheduledWork = scheduler.schedule(after: GestureTapSettings.doubleTapWindow) { [weak self, continuation] in
            self?.finalizePendingTap(for: fingerCount, using: continuation)
        }
        pendingTaps[fingerCount] = PendingTap(recognizedAt: recognizedAt, scheduledWork: scheduledWork)
    }

    private func resolvePendingTapIfNeeded(
        for fingerCount: Int,
        recognizedAt: Date,
        using continuation: AsyncStream<GestureEvent>.Continuation
    ) {
        guard let pendingTap = pendingTaps[fingerCount] else { return }
        guard recognizedAt.timeIntervalSince(pendingTap.recognizedAt) > GestureTapSettings.doubleTapWindow else {
            return
        }

        pendingTap.scheduledWork.cancel()
        pendingTaps.removeValue(forKey: fingerCount)

        let activation = tapActivation(for: fingerCount)
        if let singleTapSlot = activation.singleTapSlot {
            emit(singleTapSlot, at: recognizedAt, using: continuation)
        }
    }

    private func finalizePendingTap(
        for fingerCount: Int,
        using continuation: AsyncStream<GestureEvent>.Continuation
    ) {
        guard let pendingTap = pendingTaps.removeValue(forKey: fingerCount) else { return }
        pendingTap.scheduledWork.cancel()

        let activation = tapActivation(for: fingerCount)
        if let singleTapSlot = activation.singleTapSlot {
            emit(singleTapSlot, at: scheduler.now, using: continuation)
        }
    }

    private func cancelPendingTaps() {
        for pendingTap in pendingTaps.values {
            pendingTap.scheduledWork.cancel()
        }
        pendingTaps.removeAll()
    }

    private func emit(
        _ slot: GestureSlot,
        at timestamp: Date,
        using continuation: AsyncStream<GestureEvent>.Continuation
    ) {
        continuation.yield(GestureEvent(slot: slot, timestamp: timestamp))
    }
}

enum GestureEngineError: Error {
    case sourceUnavailable(underlying: Error)
}

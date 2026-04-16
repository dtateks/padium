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
// Tracks stable contact sequences for configured finger counts, emits 3/4-finger
// swipes immediately, and arbitrates taps versus double taps when the fingers lift.
@MainActor
final class GestureEngine {
    private struct GestureCandidate {
        let originContacts: [Int: TouchPoint]
        // The highest finger count observed for this candidate. Once a peak
        // is reached we never downgrade — intermediate lower-finger frames
        // during landing/lift transitions belong to the same gesture.
        let peakFingerCount: Int
        let startedAt: Date
        var maximumTravel: Float = 0
        // Consecutive frames seen at the peak count with matching identifiers.
        // Resets when the candidate is re-anchored (upgrade or ID churn).
        var stableFrameCount: Int = 1

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

        mutating func incrementStability() {
            stableFrameCount += 1
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
        let doubleTapSlot: GestureSlot?

        var hasAnyTapSlot: Bool {
            doubleTapSlot != nil
        }
    }

    // Frames required at the peak finger count before a swipe is committed.
    // Two frames is the minimum for displacement to exist (one origin + one
    // current); the third frame buys ~1 OMS frame of tolerance for trailing
    // landing fingers, preventing a 4-finger swipe from firing as a 3-finger
    // swipe in the brief window before the 4th finger lands.
    private static let minimumStableFramesForSwipe: Int = 3

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
                ScrollSuppressor.shared.currentFingerCount = 0
                ScrollSuppressor.shared.isMultitouchActive = false
            }

            var candidate: GestureCandidate?
            var waitingForLift = false

            for await frame in self.source.touchFrameStream {
                if Task.isCancelled {
                    break
                }

                ScrollSuppressor.shared.currentFingerCount = frame.count

                if frame.isEmpty {
                    if let candidate {
                        PadiumLogger.gesture.debug("TAP-DIAG: lift with candidate fc=\(candidate.peakFingerCount) travel=\(candidate.maximumTravel) dur=\(candidate.duration(at: self.scheduler.now))")
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

                // Log raw frame states for 3+ touch frames
                if frame.count >= 3 {
                    let states = frame.map { "\($0.identifier):\($0.state.rawValue)" }.joined(separator: " ")
                    PadiumLogger.gesture.debug("TAP-DIAG: frame touches=\(frame.count) states=[\(states, privacy: .public)]")
                }

                guard let contacts = localClassifier.stableActiveContacts(in: frame, expectedFingerCount: frame.count) else {
                    // Touches are present but not in a classifiable state (e.g., starting
                    // or leaving transitions). Keep the candidate alive so tap recognition
                    // can complete on the subsequent empty frame.
                    if frame.count >= 3 {
                        PadiumLogger.gesture.debug("TAP-DIAG: no active contacts, candidate=\(candidate != nil)")
                    }
                    continue
                }

                let fingerCount = contacts.count

                guard self.hasActiveSlots(for: fingerCount) else {
                    // No slots configured for the active count. Preserve any
                    // in-progress candidate so transient 5+ finger noise or a
                    // lift transition through an unsupported count does not
                    // tear it down. Travel is updated for fingers we can match.
                    if var preserved = candidate {
                        preserved.recordTravel(using: contacts)
                        candidate = preserved
                        ScrollSuppressor.shared.isMultitouchActive = preserved.peakFingerCount >= 3
                    } else {
                        ScrollSuppressor.shared.isMultitouchActive = false
                    }
                    PadiumLogger.gesture.debug("TAP-DIAG: no active slots for fc=\(fingerCount), candidate=\(candidate != nil)")
                    continue
                }

                // Reflect the gesture's intent (peak count) when reporting
                // multitouch activity so scroll suppression keeps holding
                // through brief lift transitions of 3/4-finger gestures.
                ScrollSuppressor.shared.isMultitouchActive = max(fingerCount, candidate?.peakFingerCount ?? 0) >= 3

                guard let activeCandidate = candidate else {
                    candidate = GestureCandidate(
                        originContacts: contacts,
                        peakFingerCount: fingerCount,
                        startedAt: self.scheduler.now
                    )
                    continue
                }

                if fingerCount > activeCandidate.peakFingerCount {
                    // UPGRADE: more fingers than ever seen. Re-anchor at the
                    // new peak so swipe displacement is measured from when
                    // the user's intended finger count was actually present.
                    candidate = GestureCandidate(
                        originContacts: contacts,
                        peakFingerCount: fingerCount,
                        startedAt: self.scheduler.now
                    )
                    continue
                }

                if fingerCount < activeCandidate.peakFingerCount {
                    // Lift in progress: do NOT downgrade. Treating an
                    // intermediate lower-finger frame as a separate gesture
                    // is what causes a 4-finger swipe to be misclassified
                    // as a 2/3-finger tap on lift.
                    var preserved = activeCandidate
                    preserved.recordTravel(using: contacts)
                    candidate = preserved
                    continue
                }

                // fingerCount == peakFingerCount.
                guard activeCandidate.trackedIdentifiers == Set(contacts.keys) else {
                    // ID churn at the peak — re-anchor with the new identifiers.
                    candidate = GestureCandidate(
                        originContacts: contacts,
                        peakFingerCount: fingerCount,
                        startedAt: self.scheduler.now
                    )
                    continue
                }

                var updatedCandidate = activeCandidate
                updatedCandidate.incrementStability()
                updatedCandidate.recordTravel(using: contacts)

                // Defer swipe classification until the candidate has stayed
                // at the peak for a minimum number of consecutive frames.
                // Without this gate, a fast 4-finger swipe can fire as a
                // 3-finger swipe in the brief window before the 4th finger
                // lands.
                if updatedCandidate.stableFrameCount >= Self.minimumStableFramesForSwipe,
                   let event = localClassifier.classifyIncremental(
                       firstContacts: updatedCandidate.originContacts,
                       currentContacts: contacts,
                       peakFingerCount: updatedCandidate.peakFingerCount
                   ),
                   self.activeSlots.contains(event.slot) {
                    localContinuation.yield(event)
                    waitingForLift = true
                    candidate = nil
                    continue
                }

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
        ScrollSuppressor.shared.currentFingerCount = 0
        ScrollSuppressor.shared.isMultitouchActive = false
    }

    private func hasActiveSlots(for fingerCount: Int) -> Bool {
        activeSlots.contains { $0.fingerCount == fingerCount }
    }

    private func tapActivation(for fingerCount: Int) -> TapActivation {
        let relevantSlots = activeSlots.filter { $0.fingerCount == fingerCount }
        return TapActivation(
            doubleTapSlot: relevantSlots.first(where: { $0.kind == .doubleTap })
        )
    }

    private func handleLift(
        of candidate: GestureCandidate,
        using continuation: AsyncStream<GestureEvent>.Continuation
    ) {
        let recognitionTime = scheduler.now
        let duration = candidate.duration(at: recognitionTime)
        let travel = candidate.maximumTravel
        let maximumTravel = GestureTapSettings.currentMaximumTravel()
        guard duration <= GestureTapSettings.maximumDuration else {
            PadiumLogger.gesture.debug("TAP-DIAG: REJECTED duration=\(duration) > max=\(GestureTapSettings.maximumDuration)")
            return
        }
        guard travel <= maximumTravel else {
            PadiumLogger.gesture.debug("TAP-DIAG: REJECTED travel=\(travel) > max=\(maximumTravel)")
            return
        }
        PadiumLogger.gesture.debug("TAP-DIAG: ACCEPTED tap fc=\(candidate.peakFingerCount) dur=\(duration) travel=\(travel)")

        handleRecognizedTap(
            fingerCount: candidate.peakFingerCount,
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
        }

        let scheduledWork = scheduler.schedule(after: GestureTapSettings.doubleTapWindow) { [weak self] in
            self?.cleanUpExpiredPendingTap(for: fingerCount)
        }
        pendingTaps[fingerCount] = PendingTap(recognizedAt: recognizedAt, scheduledWork: scheduledWork)
    }

    private func cleanUpExpiredPendingTap(for fingerCount: Int) {
        guard let pendingTap = pendingTaps.removeValue(forKey: fingerCount) else { return }
        pendingTap.scheduledWork.cancel()
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

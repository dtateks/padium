import Foundation

@MainActor
protocol GestureRuntimeControlling: AnyObject {
    var events: AsyncStream<GestureEvent> { get }
    var lastStartError: GestureEngineError? { get }
    @discardableResult func start() -> Bool
    func stop()
    func updateActiveSlots(_ activeSlots: Set<GestureSlot>)
}

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
        // The time the current peak was reached (or the candidate was created).
        // Re-anchored on every peak upgrade and on ID churn at the same peak.
        let startedAt: Date
        var latestStableContacts: [Int: TouchPoint]
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
        let doubleTapSlot: GestureSlot?

        var hasAnyTapSlot: Bool {
            doubleTapSlot != nil
        }
    }

    // Wall-clock window the candidate must hold at its peak before a swipe
    // commits when a higher finger count is still configured (i.e. an upgrade
    // is still possible). This is the libinput-style "wait for additional
    // fingers" gate: at 80 ms it sits between libinput's 40 ms quick-floor
    // and its 150 ms swipe default, sized for Padium's bounded peak (max 4
    // fingers) and the empirical ~20–60 ms multi-finger landing spread on
    // macOS trackpads. Time-based (not frame-based) so the behavior is
    // independent of OMS frame rate (90–120 Hz across hardware).
    private static let peakUpgradeSettleWindow: TimeInterval = 0.080

    // Maximum wall-clock spread between the first and last identifier of a
    // real N-finger tap. Two fingers from one hand land within ~30–50 ms on
    // macOS trackpads; palms at opposite trackpad corners while typing land
    // independently and typically exceed 80 ms apart. Gate is evaluated on
    // raw-frame identifier first-seen timestamps (not on classifier-filtered
    // contacts) so palm+finger artefacts that happen to settle into a valid
    // frame still fail the concurrency test. 80 ms is the same budget used
    // by `peakUpgradeSettleWindow` — consistent latency ceiling.
    private static let multiFingerConcurrencyWindow: TimeInterval = 0.080

    private let source: any GestureSource
    private let classifierFactory: @Sendable () -> GestureClassifier
    private let scheduler: any GestureScheduling
    private let supportedSlots: Set<GestureSlot>
    private let multitouchSink: any MultitouchStateSink

    private var activeSlots: Set<GestureSlot>
    private(set) var events: AsyncStream<GestureEvent>
    private var continuation: AsyncStream<GestureEvent>.Continuation
    private var pipelineTask: Task<Void, Never>?
    private var isRunning = false
    private var pendingTaps: [Int: PendingTap] = [:]

    private(set) var lastStartError: GestureEngineError?

    init(
        source: any GestureSource,
        classifier: GestureClassifier? = nil,
        supportedSlots: Set<GestureSlot>,
        scheduler: (any GestureScheduling)? = nil,
        multitouchSink: any MultitouchStateSink
    ) {
        self.source = source
        // When a fixed classifier is provided, reuse it across every `start()`.
        // Otherwise build a fresh one each start so it reads live shared
        // sensitivity from UserDefaults without an engine restart.
        if let classifier {
            self.classifierFactory = { classifier }
        } else {
            self.classifierFactory = { GestureClassifier() }
        }
        self.scheduler = scheduler ?? TaskGestureScheduler()
        self.supportedSlots = supportedSlots
        self.activeSlots = supportedSlots
        self.multitouchSink = multitouchSink
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

            let sink = self.multitouchSink
            defer {
                localContinuation.finish()
                sink.currentFingerCount = 0
                sink.isMultitouchActive = false
            }

            var state = SequenceState()

            for await frame in self.source.touchFrameStream {
                if Task.isCancelled { break }
                self.processFrame(
                    frame,
                    state: &state,
                    classifier: localClassifier,
                    sink: sink,
                    continuation: localContinuation
                )
            }
        }
        return true
    }

    // Per-sequence mutable state captured between frames. Local to a single
    // `start()` call so a restart begins with empty state — never hoisted to
    // an instance property, which would create cross-start aliasing.
    private struct SequenceState {
        var candidate: GestureCandidate?
        var waitingForLift = false
        var suppressNewCandidatesUntilLift = false
        // Raw-frame identifier first-seen timestamps for the whole sequence
        // (reset on lift). Drives the multi-finger concurrency gate that
        // rejects asynchronously-landed palm/corner contacts which pass
        // geometric filters by coincidence.
        var identifierFirstSeenAt: [Int: Date] = [:]
        // Highest RAW frame.count observed in the current sequence. Load-bearing
        // signal against "unsupported higher-count frame appears AFTER a
        // candidate already formed" — the classic 4-finger-lands-after-3 path.
        // Tainted even when raw fingers aren't yet classifiable (starting/
        // making states) so nothing about stable contacts can hide a real
        // 4-finger event.
        var rawMaximumFingerCount = 0
    }

    private func processFrame(
        _ frame: [TouchPoint],
        state: inout SequenceState,
        classifier: GestureClassifier,
        sink: any MultitouchStateSink,
        continuation: AsyncStream<GestureEvent>.Continuation
    ) {
        sink.currentFingerCount = frame.count

        if frame.isEmpty {
            handleLiftFrame(state: &state, classifier: classifier, sink: sink, continuation: continuation)
            return
        }

        recordFrameLanding(frame: frame, state: &state)

        if state.waitingForLift {
            if frame.count >= 2 {
                PadiumLogger.gesture.debug("TAP-DIAG: post-commit frame ignored fc=\(frame.count) raw=\(Self.describeFrame(frame), privacy: .public)")
            }
            return
        }

        let rawPeakSnapshot = state.rawMaximumFingerCount
        if frame.count >= 2 {
            // Per-touch geometry, state, total capacitance, and major-axis for
            // every 2+ touch frame so palm/corner false-positive investigation
            // has the raw signals available without attaching a debugger.
            PadiumLogger.gesture.debug("TAP-DIAG: frame fc=\(frame.count) rawPeak=\(rawPeakSnapshot) raw=\(Self.describeFrame(frame), privacy: .public)")
        }

        let maxConfiguredFingerCount = maximumConfiguredFingerCount(
            defaultingTo: max(frame.count, rawPeakSnapshot)
        )

        // LOAD-BEARING GATE: if the RAW frame count (or the sequence's raw
        // peak) ever exceeded the max configured finger count, this sequence
        // belongs to an unbound higher-finger macOS gesture. Drop any in-flight
        // candidate and suppress new candidates until the user lifts. Bursts
        // the classic "4-finger landed after 3-finger candidate already formed"
        // false-positive path regardless of whether the extra finger appears
        // in the very first frame, mid-sequence, or during the lift transition.
        if rawPeakSnapshot > maxConfiguredFingerCount {
            let hadCandidate = state.candidate != nil
            if hadCandidate || !state.suppressNewCandidatesUntilLift {
                PadiumLogger.gesture.debug("TAP-DIAG: rawPeak SUPPRESS rawPeak=\(rawPeakSnapshot) maxConfigured=\(maxConfiguredFingerCount) hadCandidate=\(hadCandidate)")
            }
            state.candidate = nil
            state.suppressNewCandidatesUntilLift = true
            sink.isMultitouchActive = frame.count >= 3
            return
        }

        guard let contacts = classifier.stableActiveContacts(in: frame, expectedFingerCount: frame.count) else {
            // Touches are present but not in a classifiable state (e.g., starting
            // or leaving transitions). Keep the candidate alive so tap recognition
            // can complete on the subsequent empty frame.
            if frame.count >= 2 {
                let reason = Self.describeStableContactsRejection(frame: frame)
                let hadCandidate = state.candidate != nil
                PadiumLogger.gesture.debug("TAP-DIAG: no stable contacts fc=\(frame.count) reason=\(reason, privacy: .public) candidate=\(hadCandidate)")
            }
            return
        }

        let fingerCount = contacts.count

        if state.suppressNewCandidatesUntilLift {
            sink.isMultitouchActive = fingerCount >= 3
            return
        }

        guard hasActiveSlots(for: fingerCount) else {
            // No slots configured for the active count. Preserve any in-progress
            // candidate so transient 5+ finger noise or a lift transition
            // through an unsupported count does not tear it down. Travel is
            // updated for fingers we can match.
            if var preserved = state.candidate {
                preserved.recordTravel(using: contacts)
                state.candidate = preserved
                sink.isMultitouchActive = preserved.peakFingerCount >= 3
            } else {
                sink.isMultitouchActive = false
            }
            let hadCandidate = state.candidate != nil
            PadiumLogger.gesture.debug("TAP-DIAG: no active slots for fc=\(fingerCount), candidate=\(hadCandidate)")
            return
        }

        // Reflect the gesture's intent (peak count) when reporting multitouch
        // activity so scroll suppression keeps holding through brief lift
        // transitions of 3/4-finger gestures.
        sink.isMultitouchActive = max(fingerCount, state.candidate?.peakFingerCount ?? 0) >= 3

        advanceCandidate(
            contacts: contacts,
            fingerCount: fingerCount,
            state: &state,
            classifier: classifier,
            continuation: continuation
        )
    }

    private func handleLiftFrame(
        state: inout SequenceState,
        classifier: GestureClassifier,
        sink: any MultitouchStateSink,
        continuation: AsyncStream<GestureEvent>.Continuation
    ) {
        if let candidate = state.candidate {
            let rawPeakAtLift = state.rawMaximumFingerCount
            PadiumLogger.gesture.debug("TAP-DIAG: lift with candidate fc=\(candidate.peakFingerCount) travel=\(candidate.maximumTravel) dur=\(candidate.duration(at: self.scheduler.now)) rawPeak=\(rawPeakAtLift)")
            handleLift(
                of: candidate,
                classifier: classifier,
                identifierFirstSeenAt: state.identifierFirstSeenAt,
                using: continuation
            )
        }
        state.candidate = nil
        state.waitingForLift = false
        state.suppressNewCandidatesUntilLift = false
        state.identifierFirstSeenAt.removeAll(keepingCapacity: true)
        state.rawMaximumFingerCount = 0
        sink.isMultitouchActive = false
    }

    private func recordFrameLanding(frame: [TouchPoint], state: inout SequenceState) {
        // Record first-seen timestamps for every raw identifier in this frame
        // BEFORE any filtering, so the concurrency gate sees the true landing
        // spread even when early frames are rejected by `stableActiveContacts`.
        let now = scheduler.now
        for point in frame where state.identifierFirstSeenAt[point.identifier] == nil {
            state.identifierFirstSeenAt[point.identifier] = now
        }
        // Track raw peak count independent of classifier filters.
        state.rawMaximumFingerCount = max(state.rawMaximumFingerCount, frame.count)
    }

    private func advanceCandidate(
        contacts: [Int: TouchPoint],
        fingerCount: Int,
        state: inout SequenceState,
        classifier: GestureClassifier,
        continuation: AsyncStream<GestureEvent>.Continuation
    ) {
        guard let activeCandidate = state.candidate else {
            PadiumLogger.gesture.debug("TAP-DIAG: candidate SEED fc=\(fingerCount)")
            state.candidate = makeCandidate(contacts: contacts, peakFingerCount: fingerCount)
            return
        }

        if fingerCount > activeCandidate.peakFingerCount {
            // UPGRADE: more fingers than ever seen. Re-anchor at the new peak
            // so swipe displacement is measured from when the user's intended
            // finger count was actually present.
            PadiumLogger.gesture.debug("TAP-DIAG: candidate UPGRADE peak=\(activeCandidate.peakFingerCount) -> \(fingerCount)")
            state.candidate = makeCandidate(contacts: contacts, peakFingerCount: fingerCount)
            return
        }

        if fingerCount < activeCandidate.peakFingerCount {
            // Lift in progress: do NOT downgrade. Treating an intermediate
            // lower-finger frame as a separate gesture is what causes a
            // 4-finger swipe to be misclassified as a 2/3-finger tap on lift.
            var preserved = activeCandidate
            preserved.recordTravel(using: contacts)
            state.candidate = preserved
            PadiumLogger.gesture.debug("TAP-DIAG: candidate HOLD peak=\(preserved.peakFingerCount) active=\(fingerCount) travel=\(preserved.maximumTravel)")
            return
        }

        // fingerCount == peakFingerCount.
        guard activeCandidate.trackedIdentifiers == Set(contacts.keys) else {
            // ID churn at the peak — re-anchor with the new identifiers.
            PadiumLogger.gesture.debug("TAP-DIAG: candidate RE-ANCHOR (id churn) peak=\(fingerCount) oldIDs=\(activeCandidate.trackedIdentifiers.sorted(), privacy: .public) newIDs=\(contacts.keys.sorted(), privacy: .public)")
            state.candidate = makeCandidate(contacts: contacts, peakFingerCount: fingerCount)
            return
        }

        var updatedCandidate = activeCandidate
        updatedCandidate.latestStableContacts = contacts
        updatedCandidate.recordTravel(using: contacts)

        // Defer swipe classification while a higher finger count is still
        // possible AND the peak hasn't held long enough for the trailing
        // landing finger to arrive. Once the gate is open (or no upgrade is
        // possible), commit on motion alone.
        let settleSatisfied = swipeSettleSatisfied(for: updatedCandidate, now: scheduler.now)
        if settleSatisfied,
           let event = classifier.classifyIncremental(
               firstContacts: updatedCandidate.originContacts,
               currentContacts: contacts,
               peakFingerCount: updatedCandidate.peakFingerCount
           ),
           activeSlots.contains(event.slot) {
            PadiumLogger.gesture.debug("TAP-DIAG: EMIT swipe slot=\(event.slot.rawValue, privacy: .public) fc=\(updatedCandidate.peakFingerCount) travel=\(updatedCandidate.maximumTravel) dur=\(updatedCandidate.duration(at: self.scheduler.now))")
            continuation.yield(event)
            state.waitingForLift = true
            state.candidate = nil
            return
        }

        state.candidate = updatedCandidate
    }

    func stop() {
        cancelPendingTaps()
        source.stopListening()
        pipelineTask?.cancel()
        pipelineTask = nil
        isRunning = false
        multitouchSink.currentFingerCount = 0
        multitouchSink.isMultitouchActive = false
    }

    private func makeCandidate(contacts: [Int: TouchPoint], peakFingerCount: Int) -> GestureCandidate {
        GestureCandidate(
            originContacts: contacts,
            peakFingerCount: peakFingerCount,
            startedAt: scheduler.now,
            latestStableContacts: contacts
        )
    }

    private func hasActiveSlots(for fingerCount: Int) -> Bool {
        activeSlots.contains { $0.fingerCount == fingerCount }
    }

    private func swipeSettleSatisfied(
        for candidate: GestureCandidate,
        now: Date
    ) -> Bool {
        let maxConfiguredFingerCount = maximumConfiguredFingerCount(defaultingTo: candidate.peakFingerCount)
        // Peak already at the max configured count → no upgrade possible,
        // commit as soon as classifyIncremental sees enough motion.
        guard candidate.peakFingerCount < maxConfiguredFingerCount else { return true }
        // Otherwise hold until the candidate has stayed at the peak for the
        // settle window, giving any trailing landing finger time to arrive.
        return candidate.duration(at: now) >= Self.peakUpgradeSettleWindow
    }

    private func tapActivation(for fingerCount: Int) -> TapActivation {
        let relevantSlots = activeSlots.filter { $0.fingerCount == fingerCount }
        return TapActivation(
            doubleTapSlot: relevantSlots.first(where: { $0.kind == .doubleTap })
        )
    }

    private func handleLift(
        of candidate: GestureCandidate,
        classifier: GestureClassifier,
        identifierFirstSeenAt: [Int: Date],
        using continuation: AsyncStream<GestureEvent>.Continuation
    ) {
        // Minimum peak-duration gate: deliberate taps hold their peak
        // finger count for ≥50 ms (libinput `tap-minimum-time` principle).
        // Palm grazes from typing are capacitive flickers lasting 10-30 ms;
        // asynchronous palm coincidences likewise hold their peak for one
        // frame (~10 ms). Measured at the latest peak anchor — re-anchored
        // on every peak upgrade and ID churn — so the floor counts time
        // spent at the peak finger count, not total sequence life.
        let liftDuration = candidate.duration(at: scheduler.now)
        if liftDuration < GestureTapSettings.minimumStableDuration {
            PadiumLogger.gesture.debug("TAP-DIAG: REJECTED tap minDuration fc=\(candidate.peakFingerCount) dur=\(liftDuration) min=\(GestureTapSettings.minimumStableDuration)")
            return
        }

        // Multi-finger concurrency gate: two contacts of a real one-hand tap
        // land within ~30-50ms. Palms at opposite trackpad corners while
        // typing land independently and typically exceed 80ms apart. Applied
        // before shape coherence so asynchronous arrivals that happen to end
        // up geometrically plausible still fail. Checked for 2+ finger taps
        // across all tap slots (2, 3, 4 finger) because the load-bearing
        // signal — one-hand synchronicity — holds for each.
        if candidate.peakFingerCount >= 2 {
            let identifiers = Array(candidate.originContacts.keys)
            let timestamps = identifiers.compactMap { identifierFirstSeenAt[$0] }
            if timestamps.count == candidate.peakFingerCount,
               let earliest = timestamps.min(),
               let latest = timestamps.max() {
                let spread = latest.timeIntervalSince(earliest)
                if spread > Self.multiFingerConcurrencyWindow {
                    PadiumLogger.gesture.debug("TAP-DIAG: REJECTED tap concurrency fc=\(candidate.peakFingerCount) spread=\(spread) window=\(Self.multiFingerConcurrencyWindow)")
                    return
                }
            }
        }

        guard classifier.tapCandidateMaintainsShape(
            firstContacts: candidate.originContacts,
            latestContacts: candidate.latestStableContacts,
            fingerCount: candidate.peakFingerCount
        ) else {
            let originDesc = Self.describeFrame(Array(candidate.originContacts.values))
            let latestDesc = Self.describeFrame(Array(candidate.latestStableContacts.values))
            PadiumLogger.gesture.debug("TAP-DIAG: REJECTED tap shape coherence fc=\(candidate.peakFingerCount) origin=[\(originDesc, privacy: .public)] latest=[\(latestDesc, privacy: .public)]")
            return
        }

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

    private func maximumConfiguredFingerCount(defaultingTo fallback: Int) -> Int {
        activeSlots.map(\.fingerCount).max() ?? fallback
    }

    // Dense per-touch description used in TAP-DIAG logs: id, state, normalized
    // position, total capacitance, and major-axis ellipse — the exact raw
    // signals that drive palm and noise rejection. Nothing here feeds logic,
    // only telemetry, so the format is optimised for grep-ability in os_log.
    private static func describeFrame(_ frame: [TouchPoint]) -> String {
        let sorted = frame.sorted { $0.identifier < $1.identifier }
        return sorted.map { point in
            let xs = String(format: "%.3f", point.normalizedX)
            let ys = String(format: "%.3f", point.normalizedY)
            let total = String(format: "%.3f", point.total)
            let major = String(format: "%.1f", point.majorAxis)
            return "\(point.identifier):\(point.state.rawValue)@(\(xs),\(ys))/t\(total)/m\(major)"
        }.joined(separator: " ")
    }

    // Classify why `stableActiveContacts` dropped a frame so logs make the
    // root cause obvious (noise capacitance, palm major-axis, inactive state,
    // duplicate identifier, or one-hand spread rejection).
    private static func describeStableContactsRejection(frame: [TouchPoint]) -> String {
        var reasons: [String] = []
        for point in frame.sorted(by: { $0.identifier < $1.identifier }) {
            if point.total < 0.03 {
                reasons.append("\(point.identifier):noise")
            }
            if point.majorAxis > 30 {
                reasons.append("\(point.identifier):palmMajor")
            }
            switch point.state {
            case .hovering, .notTouching, .leaving:
                reasons.append("\(point.identifier):inactive(\(point.state.rawValue))")
            default:
                break
            }
        }
        if reasons.isEmpty {
            reasons.append("spreadOrDuplicate")
        }
        return reasons.joined(separator: ",")
    }

    private func handleRecognizedTap(
        fingerCount: Int,
        recognizedAt: Date,
        using continuation: AsyncStream<GestureEvent>.Continuation
    ) {
        let activation = tapActivation(for: fingerCount)
        guard activation.hasAnyTapSlot else { return }

        let priorTap = pendingTaps.removeValue(forKey: fingerCount)
        priorTap?.scheduledWork.cancel()

        if let priorTap,
           recognizedAt.timeIntervalSince(priorTap.recognizedAt) <= GestureTapSettings.doubleTapWindow,
           let doubleTapSlot = activation.doubleTapSlot {
            PadiumLogger.gesture.debug("TAP-DIAG: EMIT doubleTap slot=\(doubleTapSlot.rawValue, privacy: .public) fc=\(fingerCount) gap=\(recognizedAt.timeIntervalSince(priorTap.recognizedAt))")
            emit(doubleTapSlot, at: recognizedAt, using: continuation)
            return
        }

        PadiumLogger.gesture.debug("TAP-DIAG: PENDING tap fc=\(fingerCount) waitingForSecondTap=true")
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

extension GestureEngine: GestureRuntimeControlling {}

enum GestureEngineError: Error {
    case sourceUnavailable(underlying: Error)
}

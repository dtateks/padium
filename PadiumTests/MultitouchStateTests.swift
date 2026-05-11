import Testing
@testable import Padium
import Foundation

// Unit tests for the multitouch state holder + scroll-suppression state machine.
// Uses the parametrized `shouldSuppressScroll(scrollPhaseRaw:momentumPhaseRaw:)`
// entry point so the state machine can be exercised deterministically without
// synthesising CGEvents — the CGEvent-taking overload is a pure delegate.
struct MultitouchStateTests {

    // Mirrors the private ScrollPhase / MomentumPhase raw values in
    // MultitouchState. Reproduced here so the tests stay readable; if the raw
    // values change in CoreGraphics, both copies must update together.
    private enum ScrollPhaseRaw {
        static let noPhase: Int64 = 0
        static let began: Int64 = 1
        static let changed: Int64 = 2
        static let ended: Int64 = 4
        static let mayBegin: Int64 = 128
    }

    private enum MomentumPhaseRaw {
        static let noPhase: Int64 = 0
        static let changed: Int64 = 2
        static let ended: Int64 = 3
    }

    @Test func suppressesAllScrollWhileMultitouchActive() {
        let state = MultitouchState()
        state.isMultitouchActive = true

        #expect(state.shouldSuppressScroll(
            scrollPhaseRaw: ScrollPhaseRaw.began,
            momentumPhaseRaw: MomentumPhaseRaw.noPhase
        ) == true)
        #expect(state.shouldSuppressScroll(
            scrollPhaseRaw: ScrollPhaseRaw.changed,
            momentumPhaseRaw: MomentumPhaseRaw.noPhase
        ) == true)
    }

    @Test func inactiveToActiveTransitionArmsMomentumSuppression() {
        let state = MultitouchState()
        // No multitouch yet → scrolls pass through.
        #expect(state.shouldSuppressScroll(
            scrollPhaseRaw: ScrollPhaseRaw.began,
            momentumPhaseRaw: MomentumPhaseRaw.noPhase
        ) == false)

        state.isMultitouchActive = true
        state.isMultitouchActive = false

        // Sticky momentum bit is set on the false→true transition and survives
        // the lift, so residual momentum continuations are still suppressed.
        #expect(state.shouldSuppressScroll(
            scrollPhaseRaw: ScrollPhaseRaw.noPhase,
            momentumPhaseRaw: MomentumPhaseRaw.changed
        ) == true)
    }

    @Test func newScrollBeganAfterLiftClearsMomentumSuppression() {
        let state = MultitouchState()
        state.isMultitouchActive = true
        state.isMultitouchActive = false

        // First scroll-began after lift signals user intent: pass it and clear sticky bit.
        #expect(state.shouldSuppressScroll(
            scrollPhaseRaw: ScrollPhaseRaw.began,
            momentumPhaseRaw: MomentumPhaseRaw.noPhase
        ) == false)
        // Subsequent .changed must also pass — sticky bit is gone.
        #expect(state.shouldSuppressScroll(
            scrollPhaseRaw: ScrollPhaseRaw.changed,
            momentumPhaseRaw: MomentumPhaseRaw.noPhase
        ) == false)
    }

    @Test func mayBeginAfterLiftClearsMomentumSuppression() {
        let state = MultitouchState()
        state.isMultitouchActive = true
        state.isMultitouchActive = false

        #expect(state.shouldSuppressScroll(
            scrollPhaseRaw: ScrollPhaseRaw.mayBegin,
            momentumPhaseRaw: MomentumPhaseRaw.noPhase
        ) == false)
    }

    @Test func momentumEndedClearsMomentumSuppression() {
        let state = MultitouchState()
        state.isMultitouchActive = true
        state.isMultitouchActive = false

        // momentum-ended is itself suppressed (it's the tail of the residual scroll)…
        #expect(state.shouldSuppressScroll(
            scrollPhaseRaw: ScrollPhaseRaw.noPhase,
            momentumPhaseRaw: MomentumPhaseRaw.ended
        ) == true)
        // …but afterwards a fresh scroll-began must pass through.
        #expect(state.shouldSuppressScroll(
            scrollPhaseRaw: ScrollPhaseRaw.began,
            momentumPhaseRaw: MomentumPhaseRaw.noPhase
        ) == false)
    }

    @Test func scrollChangedContinuationStaysSuppressedAfterLift() {
        let state = MultitouchState()
        state.isMultitouchActive = true
        state.isMultitouchActive = false

        // No prior .began on this side → continuation of the pre-lift scroll.
        #expect(state.shouldSuppressScroll(
            scrollPhaseRaw: ScrollPhaseRaw.changed,
            momentumPhaseRaw: MomentumPhaseRaw.noPhase
        ) == true)
    }

    @Test func noSuppressionWithoutPriorMultitouchActivation() {
        let state = MultitouchState()
        #expect(state.shouldSuppressScroll(
            scrollPhaseRaw: ScrollPhaseRaw.began,
            momentumPhaseRaw: MomentumPhaseRaw.noPhase
        ) == false)
        #expect(state.shouldSuppressScroll(
            scrollPhaseRaw: ScrollPhaseRaw.changed,
            momentumPhaseRaw: MomentumPhaseRaw.noPhase
        ) == false)
        #expect(state.shouldSuppressScroll(
            scrollPhaseRaw: ScrollPhaseRaw.noPhase,
            momentumPhaseRaw: MomentumPhaseRaw.changed
        ) == false)
    }

    @Test func resetClearsAllFlagsAndDisarmsSuppression() {
        let state = MultitouchState()
        state.currentFingerCount = 3
        state.isMultitouchActive = true
        state.reset()

        #expect(state.currentFingerCount == 0)
        #expect(state.isMultitouchActive == false)
        // Reset drops the sticky momentum bit too — no further suppression.
        #expect(state.shouldSuppressScroll(
            scrollPhaseRaw: ScrollPhaseRaw.changed,
            momentumPhaseRaw: MomentumPhaseRaw.noPhase
        ) == false)
    }

    @Test func currentFingerCountClampsToNonNegative() {
        let state = MultitouchState()
        state.currentFingerCount = -3
        #expect(state.currentFingerCount == 0)
        state.currentFingerCount = 4
        #expect(state.currentFingerCount == 4)
    }

    @Test func snapshotReflectsCurrentStateAtomically() {
        let state = MultitouchState()
        state.currentFingerCount = 4
        state.isMultitouchActive = true
        let snap = state.snapshot()
        #expect(snap.currentFingerCount == 4)
        #expect(snap.isMultitouchActive == true)
    }
}

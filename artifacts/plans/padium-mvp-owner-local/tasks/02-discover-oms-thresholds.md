# Task 02: Discover OMS raw-frame behavior and threshold candidates

- **Agent**: golem
- **Skills**: swift-concurrency-6-2
- **Wave**: 2
- **Complexity**: M

## Owns
- `Padium/PadiumApp.swift` (modify)
- `Padium/OMSGestureSource.swift` (modify)
- `plans/spikes-oms.md` (create)

## Prerequisites
- Task 01 completed and `C-01-project-skeleton` validated.
- Owner macOS 14+ machine with the built-in/default trackpad available for manual gesture probing.

## Entry References
- `docs/adr/0001-gesture-api-oms-over-nsevent.md:9-14` — OMS is the chosen gesture API and must sit behind `GestureSource`
- `.claude/PRPs/prds/padium-trackpad.prd.md:159-169` — the original discovery intent: inspect raw events before writing the classifier
- `artifacts/libs/openmultitouchsupport-padium-mvp_19.55_13-04-2026.md:66-95` — public OMS async stream API shape
- `artifacts/libs/openmultitouchsupport-padium-mvp_19.55_13-04-2026.md:96-152` — raw touch payload fields available for threshold decisions
- `artifacts/libs/openmultitouchsupport-padium-mvp_19.55_13-04-2026.md:154-167` — default-device limitation and sandbox constraint

## Exemplar
- Greenfield — follow the `OMSManager.shared.touchDataStream` pattern from `artifacts/libs/openmultitouchsupport-padium-mvp_19.55_13-04-2026.md:68-95`, but capture only diagnostic evidence rather than final gesture behavior.

## Research Notes
- **OMS lifecycle**: `startListening()` can fail if the listener already exists or the hardware is unavailable — surface that explicitly in the spike instead of retrying silently (source: `artifacts/libs/openmultitouchsupport-padium-mvp_19.55_13-04-2026.md:169-205`).

## Produces
- `C-02-oms-observations`:
  - Signature: `OMSObservation { supportedDevice: String, thresholdCandidates: {tapMaxDurationMs, doubleTapWindowMs, swipeMinDistance}, falsePositiveNotes: [String] }`
  - Behavior: Documents observed raw-frame behavior for 3-finger tap, 4-finger tap, swipe directions, hesitant taps, and resting-finger noise on the owner machine.
  - Validate: `plans/spikes-oms.md` exists and records repeated observations for each scenario with concrete threshold candidates.

## Consumes
- `C-01-project-skeleton` from Task 01:
  - Signature: `Padium.xcodeproj + Padium app target + PadiumTests target + macOS 14 + Swift 6 strict concurrency + dependencies wired`
  - Behavior: Provides a stable app shell and registered files for the diagnostic harness.

## Tests
- **Skip reason**: This is a hardware discovery spike. The evidence is the diagnostic note plus a building harness, not automated assertions.

## Steps
1. Add a temporary diagnostic path inside `Padium/OMSGestureSource.swift` and `Padium/PadiumApp.swift` that can start OMS capture without implementing the final classifier.
2. On the owner machine, collect repeated raw-frame observations for: 3-finger single tap, 4-finger single tap, double taps at different speeds, directional swipes, hesitant taps, and resting-finger noise.
3. Translate the observations into concrete threshold candidates for tap duration, double-tap window, and swipe distance.
4. Write the findings to `plans/spikes-oms.md` with enough detail that Task 04 can implement the classifier without rerunning discovery.
5. Leave the codebase in a buildable state after the spike.

## Failure Modes
- **If OMS does not start on the owner machine**: record the exact failure and stop with `Downstream action = escalate`; do not invent a fallback API.
- **If 3-finger and 4-finger observations are inconsistent across repeated trials**: capture the inconsistency and recommendation in the spike note; Task 04 must not guess.

## Guardrails
- Do not implement the final gesture classifier in this task.
- Do not broaden scope to external Magic Trackpad validation.
- Do not replace OMS with `NSEvent` or any alternate capture path.

## Acceptance
- `xcodebuild -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' build && test -f plans/spikes-oms.md`
  - Expected: build succeeds and `plans/spikes-oms.md` exists
- Manual: verify the spike note records concrete observations for both 3-finger and 4-finger input on the owner machine.

## Report (include in your final response to orchestrator)
- **Actual outputs**: files created/modified with paths
- **Test evidence**: exact command(s) executed + PASS/FAIL summary + scope (or skip reason)
- **Resolved review items**: `None` or `ID → changed files → verification command/result`
- **Contract amendments**: `None` or actual signature + reason + classification
- **New constraints or prerequisites**: newly discovered downstream-affecting constraints/prereqs, or `None`
- **Deviations**: other differences from planned behavior, or `None`
- **Discoveries**: patterns/gotchas affecting later tasks — include **Recommendation** + **Rationale**
- **Warnings**: anything downstream tasks should know
- **Downstream action**: `continue` | `amend` | `escalate` — with short reason
- **Prerequisites confirmed**: runtime prerequisites verified during execution

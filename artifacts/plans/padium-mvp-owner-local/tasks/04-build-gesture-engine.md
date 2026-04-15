# Task 04: Build gesture source, classifier, and engine

- **Agent**: golem
- **Skills**: swift-concurrency-6-2, swift-protocol-di-testing, tdd-workflow
- **Wave**: 4
- **Complexity**: L

## Owns
- `Padium/GestureEvent.swift` (modify)
- `Padium/GestureSource.swift` (modify)
- `Padium/OMSGestureSource.swift` (modify)
- `Padium/GestureClassifier.swift` (modify)
- `Padium/GestureEngine.swift` (modify)
- `Padium/PreemptionController.swift` (modify)
- `PadiumTests/GestureClassifierTests.swift` (modify)
- `PadiumTests/GestureEngineTests.swift` (modify)

## Prerequisites
- Tasks 02 and 03 completed and their contracts accepted.

## Entry References
- `docs/adr/0001-gesture-api-oms-over-nsevent.md:11-14` — OMS is mandatory and must stay behind `GestureSource`
- `.claude/PRPs/prds/padium-trackpad.prd.md:131-133` — classifier ambiguity is the hard logic risk
- `plans/padium-trackpad-mvp.md:171-175` — expected gesture-engine outcome from the earlier blueprint
- `artifacts/libs/openmultitouchsupport-padium-mvp_19.55_13-04-2026.md:68-95` — OMS async stream shape
- `artifacts/libs/openmultitouchsupport-padium-mvp_19.55_13-04-2026.md:169-205` — OMS lifecycle failure cases and availability behavior

## Exemplar
- Greenfield — follow the OMS async-stream adapter pattern from `artifacts/libs/openmultitouchsupport-padium-mvp_19.55_13-04-2026.md:68-95`, then layer Padium-specific classification logic on top.

## Research Notes
- **OMS is raw-frame only**: the library does not provide semantic taps/swipes; final gesture meaning must come from Padium's classifier logic (source: `artifacts/libs/openmultitouchsupport-padium-mvp_19.55_13-04-2026.md:220-223`).
- **Availability is explicit**: a failed `startListening()` is a capability signal, not a case for hidden retries (source: `artifacts/libs/openmultitouchsupport-padium-mvp_19.55_13-04-2026.md:169-205`).

## Produces
- `C-04-gesture-engine`:
  - Signature: `GestureEngine { var events: AsyncStream<GestureEvent>; @discardableResult func start() -> Bool; func stop() }`
  - Behavior: Emits only the supported gesture set from `C-03-preemption-policy`, classifies raw OMS frames using thresholds from `C-02-oms-observations`, and fails explicitly when capture cannot start.
  - Validate: targeted gesture tests pass and manual runtime smoke no longer depends on spike-only code paths.

## Consumes
- `C-02-oms-observations` from Task 02:
  - Signature: `OMSObservation { supportedDevice, thresholdCandidates, falsePositiveNotes }`
  - Behavior: Supplies the threshold inputs and noise notes for the real classifier.
- `C-03-preemption-policy` from Task 03:
  - Signature: `PreemptionPolicy { strategy, supportedGestures, ownerNotice? }`
  - Behavior: Defines which gesture slots are live and what preemption behavior the runtime must honor.

## Tests
- **Skip reason**: None

## Steps
1. Write failing tests first for the classifier cases that are not obvious from code review alone: tap vs swipe separation, double-tap timing, and false-positive rejection using the observed spike thresholds.
2. Implement `GestureEvent`, `GestureSource`, and the OMS-backed source so the runtime consumes raw frames without leaking OMS-specific details above the boundary.
3. Implement `GestureClassifier` from the observed thresholds and supported gesture set, not from the earlier blueprint's guessed values.
4. Implement `GestureEngine` start/stop lifecycle and fold the final preemption policy into the runtime path rather than leaving spike behavior scattered.
5. Run the targeted tests and keep the runtime buildable without spike-only shortcuts.

## Failure Modes
- **If the observed thresholds still produce false positives**: add or refine tests first, then tighten the classifier; do not “tune by feel” without updating the evidence.
- **If `C-03-preemption-policy` narrows the surviving gesture set**: reflect that exactly in emitted events; do not keep dead enum cases active just because the original product docs mentioned them.

## Guardrails
- Do not reintroduce `NSEvent` fallback or any parallel gesture API.
- Do not silently ignore OMS startup failures.
- Do not broaden support to 1/2-finger gestures or Magic Trackpad-specific behavior.

## Acceptance
- `xcodebuild test -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' -only-testing:PadiumTests/GestureClassifierTests -only-testing:PadiumTests/GestureEngineTests`
  - Expected: all selected tests pass

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

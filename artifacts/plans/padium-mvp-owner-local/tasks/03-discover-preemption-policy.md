# Task 03: Discover preemption policy and surviving gesture set

- **Agent**: hades
- **Skills**: swift-concurrency-6-2
- **Wave**: 3
- **Complexity**: L

## Owns
- `Padium/PadiumApp.swift` (modify)
- `Padium/PreemptionController.swift` (modify)
- `plans/spikes-preemption.md` (create)

## Prerequisites
- Task 01 completed and `C-01-project-skeleton` validated.
- Owner machine can open System Settings > Trackpad > More Gestures if a manual-disable fallback is needed.

## Entry References
- `CLAUDE.md:65-72` — hard gate for preemption plus MiddleDrag reference
- `.claude/PRPs/prds/padium-trackpad.prd.md:119-125` — event-preemption is a first-class technical decision
- `.claude/PRPs/prds/padium-trackpad.prd.md:129-139` — explicit preemption risk and manual-disable fallback direction
- `plans/padium-trackpad-mvp.md:173-200` — earlier gate framing for the preemption spike
- `PRODUCT-BRIEF.md:75-80` — system-gesture conflict is a top-level product risk

## Exemplar
- Greenfield — follow the referenced MiddleDrag-style investigation path from `CLAUDE.md:70-72`, but optimize for confirming Padium's allowed fallback policy rather than cloning implementation details.

## Produces
- `C-03-preemption-policy`:
  - Signature: `PreemptionPolicy { strategy: 'suppress' | 'manual-disable', supportedGestures: [String], ownerNotice: String? }`
  - Behavior: States whether macOS system gestures can be suppressed for the required slots and, if not, which owner-facing notice/manual-disable instruction later tasks must surface.
  - Validate: `plans/spikes-preemption.md` exists and includes the tested approach, observed behavior, surviving gesture set, and exact owner-facing fallback text if suppression is incomplete.

## Consumes
- `C-01-project-skeleton` from Task 01:
  - Signature: `Padium.xcodeproj + Padium app target + PadiumTests target + macOS 14 + Swift 6 strict concurrency + dependencies wired`
  - Behavior: Provides the app shell needed for a real preemption probe.

## Tests
- **Skip reason**: This is a hardware/system-behavior discovery spike. Acceptance is a buildable probe plus recorded findings.

## Steps
1. Use the scaffolded app entry point to add a temporary preemption probe path in `Padium/PreemptionController.swift` and expose it through `Padium/PadiumApp.swift`.
2. Test whether Padium can intercept the target gestures before Mission Control / Spaces behavior wins on the owner machine.
3. If full suppression is not reliable, convert that result into an explicit manual-disable policy that the owner can actually follow.
4. Record the tested strategy, observed behavior, surviving gesture set, and exact fallback notice text in `plans/spikes-preemption.md`.
5. Leave the workspace buildable after the spike; do not leave probe-only dead ends behind.

## Failure Modes
- **If suppression is inconsistent or flaky**: treat it as unsupported and document the manual-disable fallback rather than optimistically reporting success.
- **If the probe reveals a smaller supported gesture set than planned**: report the reduced set explicitly and set `Downstream action = amend` so later tasks do not blindly implement stale scope.

## Guardrails
- Do not silently assume suppression works because the app receives events.
- Do not expand scope to packaging, friend UX, or alternate release paths.
- Do not keep preemption behavior ambiguous; later tasks need an explicit policy.

## Acceptance
- `xcodebuild -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' build && test -f plans/spikes-preemption.md`
  - Expected: build succeeds and `plans/spikes-preemption.md` exists
- Manual: verify the spike note clearly states either a working suppression strategy or a manual-disable fallback with owner-facing instructions.

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

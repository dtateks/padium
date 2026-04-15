# Task 08: Wire runtime end-to-end and pass owner-local acceptance

- **Agent**: titan
- **Skills**: verification-loop, swiftui-patterns, swift-concurrency-6-2
- **Wave**: 6
- **Complexity**: L

## Owns
- `Padium/PadiumApp.swift` (modify)
- `Padium/AppState.swift` (modify)
- `Padium/GestureEngine.swift` (modify)
- `Padium/GestureClassifier.swift` (modify)
- `Padium/ShortcutEmitter.swift` (modify)
- `Padium/SettingsView.swift` (modify)
- `Padium/PermissionCoordinator.swift` (modify)
- `PadiumTests/GestureEngineTests.swift` (modify)
- `PadiumTests/PermissionCoordinatorTests.swift` (modify)
- `plans/owner-local-qa.md` (create)

## Prerequisites
- Tasks 04, 05, 06, and 07 completed and their contracts accepted.
- Owner machine can grant Accessibility and Input Monitoring for final local validation.

## Entry References
- `PRODUCT-BRIEF.md:63-69` — RAM/latency success targets still apply even for owner-local MVP
- `.claude/PRPs/prds/padium-trackpad.prd.md:36-43` — measurable success metrics
- `.claude/PRPs/prds/padium-trackpad.prd.md:101-109` — intended launch-to-configuration flow
- `plans/padium-trackpad-mvp.md:380-407` — earlier integration checklist, reused here but trimmed to owner-local scope
- `CLAUDE.md:8-9` — product target: menubar app, <20MB RAM, <50ms latency

## Exemplar
- Greenfield — integrate using the contracts from Tasks 04-07 as the source of truth. There is no in-repo integration exemplar; prefer the cleaner contract-respecting design over a smaller diff.

## Produces
- `C-08-owner-local-mvp`:
  - Signature: `Padium app integrates gesture engine + shortcut runtime + app shell + grouped settings surface and passes the owner-local checklist in plans/owner-local-qa.md`
  - Behavior: While enabled, supported gestures trigger the configured shortcuts on the owner machine; while disabled, they do not. Settings changes persist across relaunch, and missing permissions/manual-disable requirements are explicit.
  - Validate: full `xcodebuild test`, `xcodebuild build`, and a completed owner-local checklist.

## Consumes
- `C-04-gesture-engine` from Task 04:
  - Signature: `GestureEngine { events, start(), stop() }`
  - Behavior: Emits the supported gesture set with explicit lifecycle control.
- `C-05-shortcut-runtime` from Task 05:
  - Signature: `GestureSlot + ShortcutRegistry + ShortcutEmitter`
  - Behavior: Resolves configured shortcuts and emits them safely.
- `C-06-app-shell` from Task 06:
  - Signature: `@MainActor @Observable AppState { isEnabled, permissionState, systemGestureNotice, isSettingsPresented }`
  - Behavior: Holds enable/disable state, permission state, and settings presentation.
- `C-07-settings-surface` from Task 07:
  - Signature: `SettingsView(appState: AppState) -> some View`
  - Behavior: Renders the grouped-list Recorder surface for the supported slots.

## Tests
- **Skip reason**: None. Existing targeted tests remain mandatory; any non-obvious bug found during integration must get a failing regression test before the fix lands.

## Steps
1. Integrate the contracts from Tasks 04-07 without bypassing their boundaries: wire `GestureEngine` output into the configured shortcut runtime through `AppState.isEnabled` gating.
2. Finalize the launch flow so the app lands in the correct shell/onboarding/settings states for the owner machine.
3. Write `plans/owner-local-qa.md` as the executable manual checklist for: supported gestures, enable/disable toggle, relaunch persistence, missing-permission handling, and any required manual system-gesture-disable notice.
4. Run full automated tests and fix any non-obvious failures with regression tests first.
5. Run the owner-local manual checklist and tune only where the evidence says the integration contract is wrong.

## Failure Modes
- **If integration exposes contract mismatches**: record them explicitly and amend the plan if needed; do not patch around the mismatch inside `PadiumApp.swift`.
- **If the owner-local checklist reveals gesture instability**: add or refine regression coverage around the specific logic rather than weakening the checklist.
- **If permissions or manual-disable guidance are unclear**: fix the owner-facing state/copy before declaring the MVP done.

## Guardrails
- Do not add packaging, friend-installable workflows, export/import, or launch-at-login.
- Do not silently drop unsupported gestures or permission failures.
- Do not weaken existing tests to make integration green.

## Acceptance
- `xcodebuild test -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' && xcodebuild -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' build`
  - Expected: full tests pass and build succeeds
- Manual: complete `plans/owner-local-qa.md` on the owner machine and confirm the supported gesture set, enable/disable behavior, relaunch persistence, and owner-facing notices all pass.

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

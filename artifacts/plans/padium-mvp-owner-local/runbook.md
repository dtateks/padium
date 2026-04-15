# Padium MVP — Owner-Local Core Build Plan

## TL;DR
> Re-plan Padium MVP from scratch as a gate-first build: establish a strict-concurrency menubar workspace, prove OMS capture and macOS gesture-preemption behavior on the owner machine, then implement the core runtime, grouped-list settings UI, and owner-local acceptance flow. Estimated effort: 8 implementation tasks across 6 execution waves + 1 final AGENTS sync wave.

## Context
### Original Request
- Analyze all repo files, clear assumptions first, then create an MVP plan.
- After plan creation, ask again before destructive repo cleanup.

### Key Decisions (from interview)
- Re-plan from scratch; existing docs are evidence, not binding execution source.
- MVP target is **owner-local only**, not friend-installable.
- Scope is core **trackpad gesture → keyboard shortcut** only.
- Runtime config is **UserDefaults only**.
- **No** JSON export/import in this MVP.
- **No** launch-at-login in this MVP.
- Settings UI is a **grouped list**, not a 2×6 matrix.
- Keep **2 dependencies**: `OpenMultitouchSupport` and `KeyboardShortcuts`.
- Assume **Accessibility + Input Monitoring** from day 1.
- Built-in/default trackpad first is sufficient for MVP success.
- If system-gesture preemption is incomplete, **manual system-gesture disable is allowed**.
- Post-plan cleanup is separate from MVP implementation; if requested later, keep `.git` and keep plan artifacts.

### Assumptions (evidence-based defaults applied — user did not explicitly decide)
- Keep the existing platform floor: **macOS 14 Sonoma**, Swift 6 strict concurrency, SwiftUI `MenuBarExtra`, App Sandbox off.
- Use one Xcode app target (`Padium`) plus one test target (`PadiumTests`) instead of splitting into local packages.
- Apply TDD only to non-obvious logic: gesture classification, shortcut runtime, and permission-state transitions; skip leaf SwiftUI composition unless logic moves into a testable model.

## Objectives
### Must Have (exact deliverables)
- Xcode workspace for a menu bar app that builds locally with Swift 6 strict concurrency.
- Verified OMS capture path for 3/4-finger gestures on the owner machine.
- Verified preemption policy: real suppression if possible, otherwise explicit manual-disable fallback.
- Gesture runtime that emits the supported gesture set behind a `GestureSource` abstraction.
- Keyboard shortcut runtime using `KeyboardShortcuts` + `CGEvent` emission.
- Grouped-list settings UI for the supported gesture slots.
- Owner-local onboarding for required permissions.
- End-to-end owner-local acceptance checklist proving enabled/disabled behavior, persistence across relaunch, and shortcut firing on the owner machine.

### Must NOT Have (explicit exclusions)
- No export/import JSON.
- No launch-at-login.
- No friend-installable packaging, DMG creation, or release workflow.
- No Magic Trackpad day-1 guarantee.
- No per-app context, scripts, AppleScript, pinch/rotate, 1/2-finger gestures, triple tap/click, cloud sync, telemetry, or window-management features.
- No custom shortcut recorder or alternate runtime store that duplicates `KeyboardShortcuts`.

### Definition of Done
- `xcodebuild -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' build` succeeds.
- Targeted automated tests pass for gesture classification, shortcut runtime, and permission-state logic.
- Owner-local checklist passes for the supported gesture set on the built-in/default trackpad.
- Missing permissions and any required manual system-gesture-disable instructions are surfaced explicitly in the app.

## Execution Graph

### File Ownership Matrix
| File Path | Wave | Task | Action (create/modify/delete/rename/generate) | Merge Risk |
|---|---:|---:|---|---|
| `Padium.xcodeproj/project.pbxproj` | 1 | 01 | create | — |
| `Padium/Info.plist` | 1 | 01 | create | — |
| `Padium/PadiumApp.swift` | 1 | 01 | create | ⚠️ |
| `Padium/AppState.swift` | 1 | 01 | create | ⚠️ |
| `Padium/GestureSlot.swift` | 1 | 01 | create | ⚠️ |
| `Padium/GestureEvent.swift` | 1 | 01 | create | ⚠️ |
| `Padium/GestureSource.swift` | 1 | 01 | create | ⚠️ |
| `Padium/OMSGestureSource.swift` | 1 | 01 | create | ⚠️ |
| `Padium/GestureClassifier.swift` | 1 | 01 | create | ⚠️ |
| `Padium/GestureEngine.swift` | 1 | 01 | create | ⚠️ |
| `Padium/ShortcutRegistry.swift` | 1 | 01 | create | ⚠️ |
| `Padium/ShortcutEmitter.swift` | 1 | 01 | create | ⚠️ |
| `Padium/SettingsView.swift` | 1 | 01 | create | ⚠️ |
| `Padium/GestureRowView.swift` | 1 | 01 | create | ⚠️ |
| `Padium/PermissionCoordinator.swift` | 1 | 01 | create | ⚠️ |
| `Padium/PermissionsView.swift` | 1 | 01 | create | ⚠️ |
| `Padium/PreemptionController.swift` | 1 | 01 | create | ⚠️ |
| `Padium/Logger.swift` | 1 | 01 | create | ⚠️ |
| `PadiumTests/GestureClassifierTests.swift` | 1 | 01 | create | ⚠️ |
| `PadiumTests/GestureEngineTests.swift` | 1 | 01 | create | ⚠️ |
| `PadiumTests/ShortcutRegistryTests.swift` | 1 | 01 | create | ⚠️ |
| `PadiumTests/ShortcutEmitterTests.swift` | 1 | 01 | create | ⚠️ |
| `PadiumTests/PermissionCoordinatorTests.swift` | 1 | 01 | create | ⚠️ |
| `Padium/PadiumApp.swift` | 2 | 02 | modify | ⚠️ merge with 01/03/06/08 |
| `Padium/OMSGestureSource.swift` | 2 | 02 | modify | ⚠️ merge with 01/04 |
| `plans/spikes-oms.md` | 2 | 02 | create | — |
| `Padium/PadiumApp.swift` | 3 | 03 | modify | ⚠️ merge with 01/02/06/08 |
| `Padium/PreemptionController.swift` | 3 | 03 | modify | ⚠️ merge with 01/04 |
| `plans/spikes-preemption.md` | 3 | 03 | create | — |
| `Padium/GestureEvent.swift` | 4 | 04 | modify | ⚠️ merge with 01 |
| `Padium/GestureSource.swift` | 4 | 04 | modify | ⚠️ merge with 01 |
| `Padium/OMSGestureSource.swift` | 4 | 04 | modify | ⚠️ merge with 01/02 |
| `Padium/GestureClassifier.swift` | 4 | 04 | modify | ⚠️ merge with 01/08 |
| `Padium/GestureEngine.swift` | 4 | 04 | modify | ⚠️ merge with 01/08 |
| `Padium/PreemptionController.swift` | 4 | 04 | modify | ⚠️ merge with 01/03 |
| `PadiumTests/GestureClassifierTests.swift` | 4 | 04 | modify | ⚠️ merge with 01 |
| `PadiumTests/GestureEngineTests.swift` | 4 | 04 | modify | ⚠️ merge with 01/08 |
| `Padium/GestureSlot.swift` | 2 | 05 | modify | ⚠️ merge with 01 |
| `Padium/ShortcutRegistry.swift` | 2 | 05 | modify | ⚠️ merge with 01 |
| `Padium/ShortcutEmitter.swift` | 2 | 05 | modify | ⚠️ merge with 01/08 |
| `PadiumTests/ShortcutRegistryTests.swift` | 2 | 05 | modify | ⚠️ merge with 01 |
| `PadiumTests/ShortcutEmitterTests.swift` | 2 | 05 | modify | ⚠️ merge with 01 |
| `Padium/PadiumApp.swift` | 4 | 06 | modify | ⚠️ merge with 01/02/03/08 |
| `Padium/AppState.swift` | 4 | 06 | modify | ⚠️ merge with 01/08 |
| `Padium/PermissionCoordinator.swift` | 4 | 06 | modify | ⚠️ merge with 01/08 |
| `Padium/PermissionsView.swift` | 4 | 06 | modify | ⚠️ merge with 01 |
| `Padium/Logger.swift` | 4 | 06 | modify | ⚠️ merge with 01 |
| `PadiumTests/PermissionCoordinatorTests.swift` | 4 | 06 | modify | ⚠️ merge with 01/08 |
| `Padium/SettingsView.swift` | 5 | 07 | modify | ⚠️ merge with 01/08 |
| `Padium/GestureRowView.swift` | 5 | 07 | modify | ⚠️ merge with 01 |
| `Padium/PadiumApp.swift` | 6 | 08 | modify | ⚠️ merge with 01/02/03/06 |
| `Padium/AppState.swift` | 6 | 08 | modify | ⚠️ merge with 01/06 |
| `Padium/GestureEngine.swift` | 6 | 08 | modify | ⚠️ merge with 01/04 |
| `Padium/GestureClassifier.swift` | 6 | 08 | modify | ⚠️ merge with 01/04 |
| `Padium/ShortcutEmitter.swift` | 6 | 08 | modify | ⚠️ merge with 01/05 |
| `Padium/SettingsView.swift` | 6 | 08 | modify | ⚠️ merge with 01/07 |
| `Padium/PermissionCoordinator.swift` | 6 | 08 | modify | ⚠️ merge with 01/06 |
| `PadiumTests/GestureEngineTests.swift` | 6 | 08 | modify | ⚠️ merge with 01/04 |
| `PadiumTests/PermissionCoordinatorTests.swift` | 6 | 08 | modify | ⚠️ merge with 01/06 |
| `plans/owner-local-qa.md` | 6 | 08 | create | — |
| `AGENTS.md` | 7 | 09 | create | — |

### Wave Schedule
| Wave | Tasks (parallel) | Glue Task (sequential) | Depends On | Est. Complexity |
|---:|---|---|---|---|
| 1 | 01 | — | — | M |
| 2 | 02, 05 | — | 01 | M |
| 3 | 03 | — | 01 | L |
| 4 | 04, 06 | — | 02, 03 | L |
| 5 | 07 | — | 03, 05, 06 | M |
| 6 | 08 | — | 04, 05, 06, 07 | L |
| 7 | 09 | — | 08 | S |

### Contract Dependencies
| Contract ID | Producer (Task) | Consumer (Tasks) | Signature (abbreviated) |
|---|---:|---|---|
| `C-01-project-skeleton` | 01 | 02, 03, 04, 05, 06, 07, 08 | `Padium.xcodeproj + Padium + PadiumTests exist and build with Swift 6/macOS 14/deps wired` |
| `C-02-oms-observations` | 02 | 04 | `OMSObservation { supportedDevice, thresholdCandidates, falsePositiveNotes }` |
| `C-03-preemption-policy` | 03 | 04, 06, 07, 08 | `PreemptionPolicy { strategy, supportedGestures, ownerNotice? }` |
| `C-04-gesture-engine` | 04 | 08 | `GestureEngine.events -> AsyncStream<GestureEvent>; start/stop lifecycle` |
| `C-05-shortcut-runtime` | 05 | 07, 08 | `GestureSlot + ShortcutRegistry + ShortcutEmitter` |
| `C-06-app-shell` | 06 | 07, 08 | `@MainActor AppState + menu shell + permission state surface` |
| `C-07-settings-surface` | 07 | 08 | `SettingsView renders grouped Recorder rows for supported gestures` |

### Wave Prerequisites
| Wave | Task | Prerequisite | Verify Command |
|---:|---:|---|---|
| 2 | 02 | Run on the owner macOS 14+ machine with a built-in/default trackpad available for manual gesture probing | `sw_vers -productVersion` then manual: confirm the machine has the intended built-in/default trackpad available |
| 3 | 03 | Same owner machine can open System Settings for any required manual system-gesture-disable fallback | `manual: open System Settings > Trackpad > More Gestures on the test machine` |
| 6 | 08 | Local machine can grant Accessibility and Input Monitoring during end-to-end acceptance | `manual: open System Settings > Privacy & Security and confirm both panes are reachable` |

### Task Index
> Grouped by wave. Orchestrator dispatches, verifies, and cascade-blocks using ONLY this table + Contract Dependencies.
> Acceptance commands are non-destructive and idempotent; where manual verification is needed, the note is explicit.

#### Wave 1 (parallel)
| # | Task | File | Agent | Skills | Review | Acceptance | Status |
|---|---|---|---|---|---|---|---|
| 01 | Scaffold strict-concurrency menubar workspace | [tasks/01-scaffold-workspace.md](tasks/01-scaffold-workspace.md) | golem | swiftui-patterns, swift-concurrency-6-2 | per-task | `xcodebuild -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' build` → `BUILD SUCCESS` | done |

#### Wave 2 (depends on Wave 1)
| # | Task | File | Agent | Skills | Review | Acceptance | Status |
|---|---|---|---|---|---|---|---|
| 02 | Discover OMS raw-frame behavior and threshold candidates | [tasks/02-discover-oms-thresholds.md](tasks/02-discover-oms-thresholds.md) | golem | swift-concurrency-6-2 | skip | `xcodebuild -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' build && test -f plans/spikes-oms.md` → build passes and spike notes exist; manual review of findings required | done |
| 05 | Build shortcut runtime backed by KeyboardShortcuts | [tasks/05-build-shortcut-runtime.md](tasks/05-build-shortcut-runtime.md) | golem | swift-protocol-di-testing, tdd-workflow | per-task | `xcodebuild test -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' -only-testing:PadiumTests/ShortcutRegistryTests -only-testing:PadiumTests/ShortcutEmitterTests` → all selected tests pass | done |

#### Wave 3 (depends on Wave 1)
| # | Task | File | Agent | Skills | Review | Acceptance | Status |
|---|---|---|---|---|---|---|---|
| 03 | Discover preemption policy and surviving gesture set | [tasks/03-discover-preemption-policy.md](tasks/03-discover-preemption-policy.md) | hades | swift-concurrency-6-2 | skip | `xcodebuild -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' build && test -f plans/spikes-preemption.md` → build passes and spike notes exist; manual review of findings required | done |

#### Wave 4 (parallel)
| # | Task | File | Agent | Skills | Review | Acceptance | Status |
|---|---|---|---|---|---|---|---|
| 04 | Build gesture source, classifier, and engine | [tasks/04-build-gesture-engine.md](tasks/04-build-gesture-engine.md) | golem | swift-concurrency-6-2, swift-protocol-di-testing, tdd-workflow | per-task | `xcodebuild test -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' -only-testing:PadiumTests/GestureClassifierTests -only-testing:PadiumTests/GestureEngineTests` → all selected tests pass | done |
| 06 | Build app shell and permission onboarding | [tasks/06-build-app-shell-and-onboarding.md](tasks/06-build-app-shell-and-onboarding.md) | venus | swiftui-patterns, swift-concurrency-6-2, tdd-workflow | per-task | `xcodebuild test -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' -only-testing:PadiumTests/PermissionCoordinatorTests && xcodebuild -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' build` → tests pass and build succeeds | done |

#### Wave 5 (depends on Waves 3-4)
| # | Task | File | Agent | Skills | Review | Acceptance | Status |
|---|---|---|---|---|---|---|---|
| 07 | Build grouped-list settings UI | [tasks/07-build-grouped-settings-ui.md](tasks/07-build-grouped-settings-ui.md) | venus | swiftui-patterns | per-task | `xcodebuild -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' build` → build succeeds; manual UI scan for grouped list + Recorder placement | done |

#### Wave 6 (depends on Waves 4-5)
| # | Task | File | Agent | Skills | Review | Acceptance | Status |
|---|---|---|---|---|---|---|---|
| 08 | Wire runtime end-to-end and pass owner-local acceptance | [tasks/08-wire-runtime-and-validate.md](tasks/08-wire-runtime-and-validate.md) | titan | verification-loop, swiftui-patterns, swift-concurrency-6-2 | per-task | `xcodebuild test -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' && xcodebuild -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' build` → full tests/build pass; manual owner-local checklist in `plans/owner-local-qa.md` passes | done |

#### Wave 7 (depends on Wave 6)
| # | Task | File | Agent | Skills | Review | Acceptance | Status |
|---|---|---|---|---|---|---|---|
| 09 | Sync AGENTS.md memory after multi-file implementation | — (clio reads brief only) | clio | — | skip | `test -f AGENTS.md` → AGENTS memory exists or is updated | done |

## Dispatch Protocol

> **For the orchestrator**: READ runbook only. WRITE whiteboard between waves. NEVER read task cards, brief, or source code.

### Per-Wave Flow
```
FOR each wave in Wave Schedule:
  1. PREFLIGHT — verify Wave Prerequisites from runbook for this wave's tasks
  2. DISPATCH  — launch all tasks in this wave as parallel subagents
  3. VERIFY    — run each task's Acceptance command from Task Index
  4. REVIEW    — for tasks with Review = per-task, dispatch Heimdall
  5. TRIAGE    — if any task failed, classify and handle using Failure Handling
  6. UPDATE    — collect executor findings and append delta-only notes to whiteboard.md
  7. NEXT      — proceed only after all tasks in the wave are verified and review-clean
```

### Step 1: Dispatch
For each task in the current wave, launch a subagent using:
- **Agent type**: from Task Index → Agent column
- **Skills**: from Task Index → Skills column
- **Delegation prompt**: use the templates below with the actual task file

**Template — Wave 1:**

> {IF task has tests in Owns: "MUST: write tests FIRST — RED (verify fails for behavioral reason, not config/import) → GREEN → REFACTOR. NEVER weaken tests to pass — fix implementation instead."}
> Read these files, then execute the task:
> 1. `./artifacts/plans/padium-mvp-owner-local/brief.md`
> 2. `./artifacts/plans/padium-mvp-owner-local/tasks/XX-{slug}.md`

**Template — Wave 2+:**

> {IF task has tests in Owns: "MUST: write tests FIRST — RED (verify fails for behavioral reason, not config/import) → GREEN → REFACTOR. NEVER weaken tests to pass — fix implementation instead."}
> ⚠️ If whiteboard shows contract deviations or new downstream constraints, use ACTUAL over planned.
> ⚠️ If whiteboard says `amend` or `escalate` for your dependency chain, stop and follow runbook handling.
> Read these files, then execute the task:
> 1. `./artifacts/plans/padium-mvp-owner-local/brief.md`
> 2. `./artifacts/plans/padium-mvp-owner-local/whiteboard.md`
> 3. `./artifacts/plans/padium-mvp-owner-local/tasks/XX-{slug}.md`

**clio dispatch (AGENTS.md sync):**

> `./artifacts/plans/padium-mvp-owner-local/brief.md`

### Step 2: Verify
After each executor completes:
1. Run the **Acceptance** command from Task Index.
2. If PASS, validate executor **Report** includes:
   - Actual outputs
   - Test evidence
   - Resolved review items
   - Contract amendments
   - New constraints or prerequisites
   - Deviations
   - Discoveries
   - Warnings
   - Downstream action
   - Prerequisites confirmed
3. If Report has Contract amendments, update whiteboard before dispatching consumers.
4. If Report says `amend`, invoke Plan Amendment before affected downstream tasks.
5. If Report says `escalate`, STOP and report to the user.
6. If FAIL, use Failure Handling.
7. Mark Status `done` only after review passes for Review=`per-task`, or immediately after acceptance for Review=`skip`.

### Step 2.5: Review
For each task where Review = `per-task` and Acceptance = PASS:

**Dispatch Heimdall using this template:**

> Review this task for spec compliance and code quality.
> 1. Read brief: `./artifacts/plans/padium-mvp-owner-local/brief.md`
> 2. Read task spec: `./artifacts/plans/padium-mvp-owner-local/tasks/XX-{slug}.md`
> 3. Review changed files (from task's Owns): {file list from File Ownership Matrix}
> Spec Compliance first, Code Quality second.

After Heimdall returns:
1. If no unresolved Critical/Important findings → mark task `done`.
2. If Critical/Important findings exist:
   - Re-dispatch the same executor session with the full finding table.
   - Re-run Acceptance.
   - Re-review via the same Heimdall session.
   - Repeat until no unresolved Critical/Important findings remain (max 3 review cycles).
3. Require `Resolved review items` mapping for every fixed `CRIT-*` / `IMP-*` ID.

### Step 3: Failure Handling
| Failure Type | Signal | Action |
|---|---|---|
| Crash | Executor errors out, no usable output | Retry same session via `task_id` (max 2 retries). If still failing, escalate to hades with crash context. |
| Wrong output | Acceptance fails, code exists but is incorrect | Re-dispatch same session with the exact failing acceptance details (max 2 retries). |
| Plan defect | Missing path, impossible contract, contradictory requirements, or plan/docs mismatch | Do not retry executor. Invoke Plan Amendment using executor evidence. |
| Review fail | Heimdall reports unresolved Critical/Important issues | Re-dispatch executor with the full issue table, re-run Acceptance, then re-review. |
| Review evidence missing | Executor fixed issues but omitted traceability | Re-dispatch same session requesting `ID → files → verification`. |
| Blocked | Missing prerequisite or unavailable upstream contract | Mark blocked, resolve blocker first, then re-dispatch. |
| Partial | Some acceptance passes, some fails | Re-dispatch same session targeting only the failed criteria. |
| Owns violation | Executor modified files outside Owns | Revert unauthorized changes; re-dispatch with explicit Owns warning. |
| Environment failure | Missing permissions/service/hardware distinct from executor bug | Check Wave Prerequisites. If missing from runbook, treat as Plan defect. |

**Cascade rule**: if Task X fails after max retries, mark all consumers of Task X's contracts as `blocked` and report the blocked chain.

### Step 4: Update Whiteboard
After all tasks in a wave are verified:
1. Extract from executor reports only: Actual outputs, Contract amendments, New constraints or prerequisites, Blockers/failures affecting later work, Deviations, Discoveries, Warnings, Downstream action.
2. Synthesize blockers affecting downstream work.
3. Append to `whiteboard.md` under `## After Wave N`.
4. Resolve conflicting discoveries before writing.
5. Write updated `whiteboard.md` before dispatching the next wave.

### Plan Amendment (after partial execution)
1. Keep completed waves and whiteboard entries as-is.
2. Re-invoke planner with `whiteboard.md`, `brief.md`, and the change description.
3. Planner emits only the remaining waves.
4. Append new tasks to `tasks/` and update `runbook.md` for remaining waves.

## Verification Strategy
> **TDD applies to**: gesture classification, shortcut runtime, permission-state logic, and any bug fixes discovered during integration.
> **Skip tests**: scaffolding/build settings, hardware spike notes, and leaf SwiftUI rendering when behavior is fully exercised through tested models/contracts.
> **Manual**: required for owner-machine gesture probing, permission UX, grouped-list UI sanity check, and final owner-local acceptance.

## Risks
- **OMS device scope remains hardware-bound**: external Magic Trackpad support is intentionally not a day-1 success gate.
- **Preemption may still require manual macOS settings changes**: Task 03 must convert this into an explicit policy, not an implicit workaround.
- **No in-repo code exemplars exist**: executors must follow library docs and this plan's contracts, not invent parallel patterns.
- **`Padium/PadiumApp.swift` and `Padium/AppState.swift` are high-touch files across waves**: follow wave ordering strictly and respect merge-risk notes.
- **Permissions are assumed upfront**: if either Accessibility or Input Monitoring proves unnecessary, record the simplification in whiteboard and amend later tasks rather than quietly changing scope.

## Commit Strategy
- One implementation branch per task (`feat/step-*` or `spike/phase-*`) following existing repo conventions.
- For tested tasks: checkpoint RED, then GREEN/refactor as separate logical commits.
- Keep each task mergeable on its own; do not batch unrelated concerns into one commit.

## Success Criteria
- Workspace builds cleanly on the owner macOS 14+ machine.
- Supported gestures on the built-in/default trackpad trigger the configured shortcuts only while Padium is enabled.
- Settings changes persist via UserDefaults across relaunch.
- Missing permissions and manual system-gesture-disable requirements are clear and recoverable.
- No share/export/launch-at-login/friend-install concerns are introduced into this MVP.

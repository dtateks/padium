# Whiteboard — Padium MVP — Owner-Local Core Build Plan

> Updated by orchestrator between waves. Executors read, never write directly.
> Contains only downstream-impacting deltas from completed waves.

## Contract Deviations (cumulative — orchestrator maintains)
| Contract ID | Planned Signature | Actual Signature | Reason | Affected Consumers |
|---|---|---|---|---|
| C-01-project-skeleton | OMS dependency source uses `qnoid/OpenMultitouchSupport` text reference | OMS dependency source is `Kyome22/OpenMultitouchSupport` pinned at `3.0.3` | Planned owner/repo reference is invalid; corrected to real upstream while keeping version contract intact | 02, 04 |
| C-03-preemption-policy | Preemption strategy unresolved until spike; supported gesture set phrased broadly in planning text | Strategy is `manual-disable`; supported set is the 8 swipe `GestureSlot` entries (3/4 finger, 4 directions each) | Owner-machine spike confirms system gesture conflicts and no reliable per-app suppression path | 04, 06, 07, 08 |

## After Wave 1

### Actual outputs
- Created strict-concurrency menubar scaffold (`Padium` + `PadiumTests`) with all Wave 1 owned files registered in `project.pbxproj`.
- Build acceptance passed on owner machine via `xcodebuild -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' build` (`BUILD SUCCEEDED`).

### New constraints / prerequisites
- Run `xcodebuild -runFirstLaunch` once on this machine before orchestration builds (Xcode plugin init issue observed).
- OMS API calls in implementation must use `OMSManager.shared` (property), not method-style access.
- `OMSGestureSource` currently uses `@unchecked Sendable` placeholder; Task 02 must confirm thread-safety assumptions before removal.

### Discoveries
- Brief/library artifact references for OMS source path were stale; downstream OMS API verification must come from resolved package source.
- OMS raw touch payload appears richer than current `TouchPoint` placeholder; Task 02 should decide whether to expand model or pass through OMS structs.

### Downstream action
- Continue to Wave 2.

## After Wave 2

### Actual outputs
- Task 02 delivered OMS diagnostic capture scaffolding in `Padium/PadiumApp.swift` + `Padium/OMSGestureSource.swift` and created `plans/spikes-oms.md`.
- Task 05 delivered shortcut runtime (`ShortcutRegistry`, `ShortcutEmitter`) with targeted test suite passing.

### Contract deviations / amendments
- `OMSManager.shared` is confirmed as the upstream API shape (property).
- Task 05 added grouped-list metadata to `GestureSlot` (`displayName`, `sectionTitle`) to satisfy downstream settings ownership.

### New constraints / prerequisites
- **Before Wave 4 / Task 04**: Padium must be granted **Input Monitoring** in System Settings; without it OMS starts but emits zero frames.
- `TouchPoint` currently drops OMS fields required for robust classifier (`state`, `total`, `axis`, `angle`, `density`); Task 04 must expand/passthrough model.
- Temporary compile bridge remains in `GestureSlot` (`GestureKind` alias + `gestureKind`) due ownership constraints; Task 04/07 must remove by updating `GestureEvent` and `GestureRowView` to `GestureSlot`-native API.

### Review status
- Task 05 Heimdall findings: IMP-01 resolved, IMP-03 resolved, IMP-02 deferred with explicit downstream removal requirement due cross-task ownership.

### Downstream action
- Continue to Wave 3.
- Enforce Task 04/07 cleanup of temporary `GestureKind` bridge before final acceptance.

## After Wave 3

### Actual outputs
- Task 03 delivered preemption spike implementation in `Padium/PreemptionController.swift` + `Padium/PadiumApp.swift` and created `plans/spikes-preemption.md`.
- Acceptance build + spike-file check passed.

### New constraints / prerequisites
- Preemption policy for MVP is **manual-disable**.
- Before Task 04/08 runtime validation, owner must disable in System Settings → Trackpad → More Gestures:
  - Swipe between full-screen applications
  - Mission Control
  - App Exposé
- If macOS 3-finger swipe gestures are re-enabled later, disable them while Padium is enabled.

### Discoveries
- Four-finger gestures are currently conflicted by default system gestures on this machine.
- No stable public per-app suppression path was identified for these macOS gestures.

### Downstream action
- Continue to Wave 4.
- Task 04/06/07/08 must consume `manual-disable` strategy and surface exact owner notice from `plans/spikes-preemption.md`.

## After Wave 4

### Actual outputs
- Task 04 delivered gesture runtime core: expanded `TouchPoint`, swipe classifier, `GestureEngine` pipeline, restart-safe OMS source behavior, and deterministic engine/classifier tests.
- Task 06 delivered app shell + onboarding: permission-gated enable flow, deterministic settings window opening, independent Input Monitoring preflight check, and permission transition tests.

### Contract updates
- `C-04-gesture-engine` signature remains `start() -> Bool` (non-throwing) with explicit failure context exposed via `lastStartError`.
- Engine default supported slots now derive from `PreemptionController.currentPolicy()` at initialization; runtime emission is filtered against policy-supported slots.

### New constraints / prerequisites
- Task 07 and Task 08 must preserve the `isSettingsPresented` state flow (`set true` → `.onChange` opens settings window → `onDisappear` resets false).
- Task 08 wiring should read `GestureEngine.lastStartError` when start returns false and surface actionable owner-facing diagnostics.

### Review status
- Task 04 Heimdall: all CRIT/IMP resolved.
- Task 06 Heimdall: all CRIT/IMP resolved.

### Downstream action
- Continue to Wave 5.

## After Wave 5 (blocked)

### Actual outputs
- Task 07 implemented grouped-list settings UI in `SettingsView` + `GestureRowView` and passes build acceptance.

### Blocker / plan defect
- Heimdall requires `SettingsView(appState: AppState)` contract enforcement and supported-slot filtering from app state/runtime contract.
- Task 07 owns only `SettingsView.swift` and `GestureRowView.swift`, but required contract closure needs `PadiumApp.swift` call-site wiring (`SettingsView(appState: appState)`) and/or upstream state provider changes.
- Under current ownership constraints, resolving CRIT/IMP findings for Task 07 is impossible without cross-task ownership changes.

### Downstream impact (cascade)
- Wave 6 Task 08 depends on Task 07 and is now blocked pending plan amendment.
- Wave 7 Task 09 blocked behind Wave 6.

### Required amendment
- Amend plan ownership or contract for Task 07 to include required call-site/state wiring in `Padium/PadiumApp.swift` (and any necessary app-state provider wiring), then re-run Task 07 review.

## After Wave 5 (resolved)

### Actual outputs
- Task 07 contract closure is now satisfied at call site: `Padium/PadiumApp.swift` passes `SettingsView(appState: appState)`.
- `SettingsView` renders grouped sections from `appState.supportedGestureSlots` and surfaces `appState.systemGestureNotice`.
- Temporary scaffold bridge in `GestureSlot` (`GestureKind` alias / `gestureKind`) removed.

### Verification
- `xcodebuild -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' build` → `** BUILD SUCCEEDED **`.

### Downstream action
- Unblock Wave 6.

## After Wave 6

### Actual outputs
- End-to-end runtime wiring is active in `AppState`: enable gate starts engine, stream events emit configured shortcuts, disable gate stops runtime.
- Owner-local checklist exists in `plans/owner-local-qa.md` with automated evidence and explicit manual matrix.

### Verification
- `xcodebuild test -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' && xcodebuild -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' build` → `** TEST SUCCEEDED **` and `** BUILD SUCCEEDED **`.

### New constraints / prerequisites
- Manual owner-machine checklist remains required for final human validation (real gestures, permission UX, relaunch persistence).

### Downstream action
- Continue to Wave 7.

## After Wave 7

### Actual outputs
- Added root `AGENTS.md` with stable project memory for owner-local scope, runtime boundaries, permissions model, settings-window contract, and deterministic test rules.

### Verification
- `test -f AGENTS.md` passes.

### Downstream action
- Plan execution complete. Remaining work is manual owner-machine QA completion in `plans/owner-local-qa.md`.

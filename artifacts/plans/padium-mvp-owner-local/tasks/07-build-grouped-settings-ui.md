# Task 07: Build grouped-list settings UI

- **Agent**: venus
- **Skills**: swiftui-patterns
- **Wave**: 5
- **Complexity**: M

## Owns
- `Padium/SettingsView.swift` (modify)
- `Padium/GestureRowView.swift` (modify)

## Prerequisites
- Tasks 03, 05, and 06 completed and their contracts accepted.

## Entry References
- `PRODUCT-BRIEF.md:42-45` — settings UI is in scope, but the plan supersedes its exact layout choice
- `.claude/PRPs/prds/padium-trackpad.prd.md:103-108` — settings is opened after permissions and is the primary editing surface
- `artifacts/libs/keyboardshortcuts-padium-mvp_19.55_13-04-2026.md:65-95` — canonical SwiftUI Recorder pattern
- `artifacts/libs/keyboardshortcuts-padium-mvp_19.55_13-04-2026.md:180-195` — recorder/menu-bar compatibility note
- `plans/padium-trackpad-mvp.md:324-337` — earlier matrix plan, useful only as a reminder of the gesture-slot inventory that this plan intentionally re-renders as a grouped list

## Exemplar
- Greenfield — follow the `KeyboardShortcuts.Recorder(name:)` SwiftUI pattern from `artifacts/libs/keyboardshortcuts-padium-mvp_19.55_13-04-2026.md:65-95`, but render rows in grouped-list sections instead of a matrix.

## Produces
- `C-07-settings-surface`:
  - Signature: `SettingsView(appState: AppState) -> some View` with grouped sections backed by `C-05-shortcut-runtime`
  - Behavior: Renders a grouped list of the supported gesture rows, uses `KeyboardShortcuts.Recorder(name:)` per row, and surfaces any manual-disable notice from `AppState.systemGestureNotice`.
  - Validate: build succeeds and manual UI review confirms grouped sections, Recorder placement, and supported-gesture filtering.

## Consumes
- `C-03-preemption-policy` from Task 03:
  - Signature: `PreemptionPolicy { strategy, supportedGestures, ownerNotice? }`
  - Behavior: Defines which gesture rows appear and whether the UI needs a system-gesture warning.
- `C-05-shortcut-runtime` from Task 05:
  - Signature: `GestureSlot + ShortcutRegistry + ShortcutEmitter`
  - Behavior: Supplies the stable slot ordering and Recorder names.
- `C-06-app-shell` from Task 06:
  - Signature: `@MainActor @Observable AppState { isEnabled, permissionState, systemGestureNotice, isSettingsPresented }`
  - Behavior: Supplies presentation state and owner-facing notices.

## Tests
- **Skip reason**: This task is leaf SwiftUI composition. The non-obvious logic (slot ordering and runtime mapping) is already covered in Task 05; final behavior is verified manually and again in Task 08.

## Steps
1. Render the settings surface as a grouped list with clear 3-finger / 4-finger sections using the slot ordering from `C-05-shortcut-runtime`.
2. Put one `KeyboardShortcuts.Recorder(name:)` on each supported row; unsupported rows from `C-03-preemption-policy` must not appear as active controls.
3. Surface the owner-facing system-gesture notice from `AppState.systemGestureNotice` without burying it in secondary UI.
4. Keep the view layer thin: no ad hoc slot ordering logic in the body if the contract already provides it.

## Failure Modes
- **If `C-03-preemption-policy` reduces the supported gesture set**: remove or disable those rows intentionally; do not leave dead Recorder controls visible.
- **If the grouped list becomes visually dense or unclear**: improve spacing/labels within the grouped-list constraint; do not switch back to a matrix.

## Guardrails
- Do not reintroduce a matrix/grid layout.
- Do not add export/import buttons or launch-at-login controls.
- Do not duplicate slot-ordering rules that already live in the shortcut runtime.

## Acceptance
- `xcodebuild -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' build`
  - Expected: `BUILD SUCCESS`
- Manual: verify the settings surface renders as a grouped list, shows Recorder controls for the supported slots only, and displays any required system-gesture notice.

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

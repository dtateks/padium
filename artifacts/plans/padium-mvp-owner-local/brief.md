# Brief — Padium MVP — Owner-Local Core Build Plan

> This file is read by EVERY executor before their task card.
> Contains shared conventions, confirmed technical decisions, and research findings that affect multiple tasks.

## Evidence Summary
- **Naming**: Use self-documenting names; functions as verbs, booleans as questions, collections as plurals. Prefer explicit names over short/vague helpers because executors will not share planner context — source: global rules.
- **Structure**: Repo is currently docs-only (`CLAUDE.md:4`, root directory read), so the plan establishes one Xcode app target (`Padium`) plus one test target (`PadiumTests`) with feature files kept under `Padium/` instead of introducing extra local packages up front — source: direct reads + oracle recommendation.
- **Separation of concerns**: Keep leaf modules pure and boundary layers thin. `GestureClassifier`, `ShortcutEmitter`, and permission-state logic should stay free of view code; `PadiumApp`/`AppState` orchestrate, views render, coordinators validate/delegate — source: global rules + oracle recommendation.
- **UI shell**: Use SwiftUI `MenuBarExtra`, `LSUIElement=YES`, no dock icon, App Sandbox off — source: `CLAUDE.md:19-25`.
- **Testing**: Use Swift Testing inside `PadiumTests`; apply RED → GREEN → REFACTOR to non-obvious logic (gesture classification, shortcut runtime, permission-state logic); skip leaf SwiftUI composition unless logic moves into a separate model. Use `xcodebuild test` because this plan creates an Xcode app target, not a standalone Swift package — source: `CLAUDE.md:35-39`, project rules, interview.
- **Library APIs**:
  - `OpenMultitouchSupport` latest stable researched for this plan is `3.0.3`; consume via SwiftPM `from: 3.0.3`. Public Swift entry point is `OMSManager.shared.touchDataStream`, with explicit `startListening()` / `stopListening()`, and it yields raw `[OMSTouchData]` frames rather than semantic gestures — source: `artifacts/libs/openmultitouchsupport-padium-mvp_19.55_13-04-2026.md:11-19`, `:66-95`, `:154-167`.
  - `KeyboardShortcuts` latest stable researched for this plan is `2.4.0`; consume via SwiftPM `from: 2.4.0`. Use `KeyboardShortcuts.Name`, `KeyboardShortcuts.Recorder(name:)`, `getShortcut(for:)`, and `setShortcut(nil, for:)`. Name-based Recorder persists automatically in UserDefaults. Context7 confirmed the same `Name` + `Recorder` usage pattern before deeper research was escalated to librarian — source: context7 + `artifacts/libs/keyboardshortcuts-padium-mvp_19.55_13-04-2026.md:11-18`, `:38-95`, `:143-179`.
- **Error handling**: No silent failures. OMS start failure, missing permissions, and any required manual system-gesture-disable fallback must surface explicitly in app state/UI instead of silently degrading — source: `PRODUCT-BRIEF.md:73-80`, `.claude/PRPs/prds/padium-trackpad.prd.md:127-139`, global rules.
- **Comments and constants**: Comments are deny-by-default; only durable WHY belongs in comments. Observed timing/distance thresholds from discovery must become named constants, not scattered literals — source: global rules + Task 02/04 contract flow.
- **Other cross-cutting constraints**:
  - Built-in/default trackpad first is sufficient for MVP success; Magic Trackpad is not a day-1 pass criterion — source: interview + OMS research `artifacts/libs/openmultitouchsupport-padium-mvp_19.55_13-04-2026.md:154-167`.
  - Assume both Accessibility and Input Monitoring from day 1 — source: interview + `.claude/PRPs/prds/padium-trackpad.prd.md:103-109`, `:124`, `:137`.
  - Runtime config is UserDefaults only; do not introduce JSON/export/import in this MVP — source: interview + `artifacts/libs/keyboardshortcuts-padium-mvp_19.55_13-04-2026.md:143-179`.
  - Settings surface is a grouped list, not a grid/matrix — source: interview.

## Research Context

### Library Deep Dives (from librarian)
- **OpenMultitouchSupport lookup path**: Context7 had no library listing for OMS during evidence gathering, so the plan escalated to librarian-backed repo/docs research instead of assuming stale API details — source: evidence-gathering escalation.
- **OpenMultitouchSupport**: `startListening()` can fail if multitouch is unavailable or a listener already exists, and the library only exposes low-level touch frames for the default trackpad device. Implementation implication: keep availability/lifecycle explicit in the `GestureSource` boundary and build your own classifier instead of expecting gesture semantics from the library — source: librarian TYPE mixed artifact `artifacts/libs/openmultitouchsupport-padium-mvp_19.55_13-04-2026.md:169-205`.
- **KeyboardShortcuts**: `Recorder(name:)` is the correct path when Padium wants library-owned persistence; the binding-based initializer is for app-owned custom storage and would fight the chosen MVP scope. Clearing is done with `setShortcut(nil, for:)` — source: librarian TYPE mixed artifact `artifacts/libs/keyboardshortcuts-padium-mvp_19.55_13-04-2026.md:65-99`, `:143-179`, `:208-210`.

### Architecture Rationale (from oracle)
- **Gate-first execution**: Treat OMS observations and preemption behavior as explicit upstream contracts before building runtime modules. This avoids writing a gesture engine and UI against an assumed gesture set that later proves false on the owner machine — source: oracle recommendation.
- **Single app target, no extra local packages**: The repo is too early and too small to justify package ceremony. Use one app target + one test target, plus clear feature-file ownership and contract boundaries, to get safe parallelization without fake modularity — source: oracle recommendation + architecture skill guidance.

## Design Decisions
- Use this plan as the sole execution source; existing brief/PRD/blueprint files are evidence only.
- Keep the original platform/tooling stack: Swift 6, SwiftUI `MenuBarExtra`, macOS 14+, App Sandbox off.
- Keep exactly two external dependencies: `OpenMultitouchSupport` and `KeyboardShortcuts`.
- Defer friend-installable packaging and launch-at-login until after the owner-local core flow is proven.
- Use UserDefaults-only shortcut persistence; no JSON config, no export/import, no second source of truth.
- Build settings as a grouped list with sectioned gesture rows; do not reintroduce the earlier matrix UI.
- If system gesture preemption is incomplete, accept a manual system-settings-disable fallback — but make it explicit and owner-visible.

## Pattern Conflicts
- **Persistence conflict**: Earlier docs oscillate between JSON-primary config and UserDefaults+JSON split. Chosen pattern: **UserDefaults only** for this MVP because sharing/export is out of scope and `KeyboardShortcuts` already owns runtime storage.
- **Settings UI conflict**: Earlier docs mention both a simple list and a matrix. Chosen pattern: **grouped list** because the user explicitly selected it during interview.
- **Release target conflict**: Earlier docs targeted a friend-shareable build. Chosen pattern: **owner-local only** for this MVP; packaging/release work is excluded.
- **Fallback conflict**: Earlier docs mixed stop/re-scope/manual-disable outcomes for preemption failure. Chosen pattern: **manual disable is allowed**, but Task 03 must formalize the exact owner-facing policy.

# Padium — Agent Memory

**Updated:** 2026-05-12 00:08
**Commit:** working tree
**Branch:** main

## Project Overview
macOS menu bar utility (Swift 5.9+, SwiftUI, Xcode). Trackpad swipe/tap/click gestures → keyboard shortcuts.
Bundle ID: `com.padium`, version 0.1.0. LSUIElement=true (no Dock icon).

**Scope**: owner-local MVP only — do NOT add packaging, export, or distribution features. Launch-at-login is intentionally always-on for the installed app (auto-register the main app, no user-facing toggle, keep login launches backgrounded).

## Dependencies (SPM via Xcode)
- `KeyboardShortcuts` 2.4.0 — shortcut recording UI + UserDefaults persistence
- Local `MultitouchSupport` private-framework bridge (`Padium/MultitouchBridge.{h,m}`) — multi-device touch capture
- Shared gesture sensitivity applies to swipes only; tap and double-tap gestures use fixed thresholds.

## Build & Run
- Local dev workflow uses `scripts/run-dev.sh`:
  ```
  scripts/run-dev.sh
  ```
- After any code change, run `scripts/run-dev.sh` so the latest app build is installed/opened before reporting completion.
- `scripts/install-hooks.sh` enables the local pre-push release fast lane by setting `git config --local core.hooksPath .githooks`, so Git runs the version-controlled hook directly from `.githooks/pre-push`
- Builds unsigned, replaces `/Applications/Padium.app` by default (or `$PADIUM_INSTALL_DIR`) by moving the built app into place, signs once with a stable Apple Development/Mac Development identity, then opens the installed copy.
- Stable install path + stable signing identity avoids repeated Accessibility re-grants from changing signatures.
- Launch path: requires **output access** (Accessibility + Post Event) before enabling output. Missing output access prompts and sets a terminate callback; relaunch after grant.
- `PadiumApp` skips that launch prompt+quit path under XCTest so host-app tests can execute.
- Missing Input Monitoring degrades runtime but does not stop touch-only gesture runtime.
- `PadiumApp.applicationDidBecomeActive(_:)` refreshes permissions/runtime state on activation.
- After re-sign, `tccutil reset Accessibility com.padium` only if permissions are stale.
- Input Monitoring and Post Event are requested by capability when missing.
- App only disables macOS system trackpad gestures for Padium slots that currently have configured shortcuts; unbound slots leave the original macOS gestures enabled. `SystemGestureManager` persists a backup to UserDefaults so crash recovery can restore on next launch
- `SystemGestureManager` also auto-suppresses Smart Zoom via `TrackpadTwoFingerDoubleTapGesture` when the configured 2-finger double-tap slot is in use
- `SystemGestureManager` only disables Dock gesture keys when all enabled vertical system gestures are being suppressed; partial vertical suppression leaves the other finger-count variant enabled
- `ScrollSuppressor` uses a CGEventTap to consume scroll wheel events while 3+ fingers are active on the trackpad, preventing 2-finger scroll from firing during 3-finger gestures; it also routes configured physical 3/4-finger click and double-click gestures through `AppState` and suppresses same-sequence touch taps so physical clicks take precedence

## Runtime Readiness
- `AppState` runs `GestureEngine` and `ScrollSuppressor` as independent runtimes.
- Touch and physical-click runtimes can run independently; one can be degraded while the other remains active.
- Missing Output access disables the whole runtime; touch runtime can stay active while Input Monitoring is missing.

## Test
- `xcodebuild -project Padium.xcodeproj -scheme Padium test`
- Swift Testing framework (`import Testing`, NOT XCTest)
- Tests MUST be deterministic: use `Task.yield`/stream control, NEVER `Task.sleep`

## Architecture
```
PadiumApp (@main)
├─ Window(id: "settings") — TabView
│   ├─ PermissionsView (Tab 1) — Accessibility status + System Settings link
│   └─ SettingsView (Tab 2) — KeyboardShortcuts.Recorder per slot
└─ AppState (@Observable, orchestration boundary)
    ├─ PermissionCoordinator — capability polling: Accessibility, Input Monitoring, Post Event
    ├─ GestureEngine — AsyncStream pipeline: source → classifier → filtered events
    │   ├─ MultitouchGestureSource — local multi-device MultitouchSupport bridge
    │   └─ GestureClassifier — swipe classification + tap travel helper
    ├─ MultitouchState — thread-safe shared seam between the pipeline (writes via MultitouchStateSink) and the CGEventTap (reads via shouldSuppressScroll / snapshot)
    └─ ShortcutEmitter — ShortcutRegistry lookup → CGEvent key-down/key-up post
```

## Runtime Pipeline
Touch path: `MultitouchGestureSource` → touch frames → single active device until empty-frame release → `GestureEngine` tracks a candidate only while finger count + touch IDs stay stable → `GestureClassifier.classifyIncremental()` for swipes or touch-tap/double-tap arbitration on lift → emits once, then ignores further frames until lift → `AppState` for-await loop → `ShortcutEmitter` → `CGEvent` post.

Physical click path: `ScrollSuppressor` CGEventTap detects configured 3/4-finger left-click sequences, suppresses handled original left-click pairs, emits click/double-click `GestureEvent`s to `AppState`, and only blocks same-sequence touch-tap events after Padium actually claimed that physical click path.

## Key Contracts
- `AppState` is the ONLY orchestration boundary — views toggle state, never run side effects
- `GestureEngine.start()` is non-throwing; exposes failure via `lastStartError` — callers MUST inspect on `false` return
- `GestureEngine`/`MultitouchGestureSource` are restart-safe: AsyncStream replaced on each `start()` call
- Touch runtime and physical-click runtime start/stop independently; runtime failure in one path marks `RuntimeStatus.degraded` without hard-killing the other.
- Launch flow: `PermissionChecking`/`PermissionCoordinator` owns runtime capability checks; `permissionState`, `inputMonitoringState`, and `postEventState` are independent.
- Output access = Accessibility + Post Event; missing either makes runtime status `.permissionsRequired`.
- Input Monitoring gap makes runtime status `.degraded`.
- `AppState` runtime status enum: `.checking`, `.permissionsRequired`, `.degraded`, `.active`.
- XCTest launch path bypasses that prompt+quit behavior so host-app tests can execute.
- `GestureEngine` tracks a peak finger count per candidate and upgrades (re-anchors origin + startedAt) when a higher count appears; it never downgrades on lift transitions, so a 4-finger swipe whose lift drops through 3/2 fingers cannot misfire as a smaller-finger tap. Swipe classification is gated by a wall-clock settle window (~80 ms) ONLY when the peak is below the highest configured finger count — this is the libinput Pattern B "wait for additional fingers" semantics, sized for Padium's bounded peak. When peak equals max configured, commit happens on motion alone (no wait). Time-based via `scheduler.now`, so behavior is independent of frame timing. After emission it suppresses duplicates until a lift frame
- `GestureClassifier` requires stable touch identifiers, dominant-axis commitment, and per-finger direction agreement; vertical swipes tolerate lateral drift while the dominant axis stays vertical
- `GestureClassifier.stableActiveContacts` enforces a per-finger-count hand-spread gate (aspect-corrected pairwise distance): 2 fingers ≤ 0.70, 3 fingers ≤ 1.00, 4+ unchecked. Rejects two-handed palm artefacts (e.g. palms on opposite trackpad corners while typing) that slip past the majorAxis palm filter, without reducing sensitivity for single-hand gestures on any trackpad size
- `GestureEngine` must suppress lower-count candidate creation until lift after an unsupported higher-count prelude; this prevents a 4-finger macOS gesture from degrading into a Padium 3-finger candidate when 4-finger Padium slots are unbound
- `GestureEngine.handleLift` validates 2-finger taps against `GestureClassifier.tapCandidateMaintainsShape` before duration/travel arbitration; the goal is to reject palm/corner artefacts by contact-pair geometry, not by keyboard heuristics or extra dwell requirements
- `GestureClassifier.tapCandidateMaintainsShape` is 2-finger-only and compares the aspect-corrected pair vector between first and latest stable contacts; keep it permissive enough for moderate finger drift so sensitivity does not regress
- `GestureEngine` is touch-only: it emits swipes plus double-tap slots (1/2-finger double-tap and 3/4-finger double-tap) and never emits physical click/double-click slots; there are no single touch-tap slots — only double-tap
- Legacy 3/4 click slots keep their historical raw values (`threeFingerTap`, `threeFingerDoubleTap`, `fourFingerTap`, `fourFingerDoubleTap`) for persisted shortcut/action-kind compatibility; 3/4-finger touch double-tap slots use distinct raw values (`threeFingerTouchDoubleTap`, `fourFingerTouchDoubleTap`)
- Shared sensitivity changes apply immediately without restarting the runtime for swipes and touch taps; `GestureClassifier` reads the current swipe threshold live and tap travel tolerance uses the same boosted sensitivity curve. UI sensitivity applies a +20 point base boost before threshold mapping, so default 50% behaves like the previous 70% calibration
- `AppState` refreshes live runtime/config state from `UserDefaults` changes; shortcut-binding changes must refresh conflict state and gesture routing together
- `AppState` also observes `KeyboardShortcuts_shortcutByNameDidChange` to refresh runtime active slots/conflicts immediately after shortcut assign/clear (no relaunch)
- `ShortcutRegistry.name(for:)` is the SINGLE source of truth for slot→`KeyboardShortcuts.Name` mapping — no ad-hoc Name creation elsewhere
- Settings window: app launch starts permission polling immediately; app activation/reopen focuses the existing settings window; `onDisappear` resets `isSettingsPresented` to `false`
- Permissions revoked while running → `refreshPermissions()` stops the runtime
- `SystemGestureManager.shared` handles selective save/disable/restore of system gesture preferences; `AppState` computes configured-slot conflicts before suppressing, passes full system-gesture settings so Dock keys only disable when all enabled vertical gestures are suppressed, and restores originals on runtime stop / app termination
- Live config changes must only touch system-gesture suppression when the conflicting system-gesture key set actually changed; if suppression is already active, update the desired disabled/restored keys in one pass instead of restore→suppress bouncing the Dock twice
- `SystemGestureManager.restoreIfNeeded()` runs at app launch to recover from a crash that left gestures suppressed
- `PreemptionController` detects per-slot system gesture conflicts for currently configured Padium slots; UI warnings should ignore unbound slots and only reflect active conflicts

## Coding Conventions
- `@MainActor` on all UI-bound and state classes
- Views are thin: render state only, no side-effect orchestration
- Protocols for DI boundaries: `GestureSource`, `GestureRuntimeControlling`, `ShortcutEmitting`, `MiddleClickEmitting`, `PreemptionControlling`, `SystemGestureManaging`, `PhysicalClickCoordinating`, `MultitouchStateSink`, `PermissionChecking`
- `PhysicalClickCoordinating` inherits `MultitouchStateSink`, so a single coordinator instance both gates physical clicks and absorbs the touch pipeline's per-frame state writes. `AppState` takes `scrollSuppressor: (any PhysicalClickCoordinating)? = nil` (defaults to a fresh `ScrollSuppressor()` it owns) and forwards that same instance to `GestureEngine` as `multitouchSink`. `GestureEngine.multitouchSink` is required — there is no `ScrollSuppressor.shared` fallback. Tests inject a `RecordingPhysicalClickCoordinator` (or a standalone `RecordingMultitouchStateSink` when only the sink surface is needed)
- `@discardableResult` on `start()`/`emitConfiguredShortcut()` methods
- Logging via `PadiumLogger` (OSLog): categories `gesture`, `shortcut`, `permission`
- Classifier thresholds are empirically derived — do NOT change without new evidence; swipe sensitivity and tap/double-tap thresholds are intentionally separate
- Event synthesis posts explicit modifier transitions before/after the key and uses `.cghidEventTap` for shortcut injection

## Anti-Patterns
- NEVER create `KeyboardShortcuts.Name` outside `ShortcutRegistry`
- NEVER use `Task.sleep` in tests — causes flaky non-determinism
- NEVER rely on temporary print debugging in multitouch plumbing; use `PadiumLogger.gesture`
- NEVER reintroduce flagged main-key pairs on `.cgAnnotatedSessionEventTap` for shortcut emission

## Where To Look
| Task | Location |
|------|----------|
| App entry / scene setup | `Padium/PadiumApp.swift` |
| Activation permission refresh | `Padium/PadiumApp.swift` |
| Runtime orchestration | `Padium/AppState.swift` |
| Gesture detection pipeline | `Padium/GestureEngine.swift` → `GestureClassifier.swift` |
| Multitouch hardware bridge | `Padium/MultitouchGestureSource.swift` + `Padium/MultitouchBridge.m` |
| Shortcut emission | `Padium/ShortcutEmitter.swift` |
| Permission logic | `Padium/PermissionCoordinator.swift` |
| System gesture policy | `Padium/PreemptionController.swift` |
| Slot↔shortcut mapping | `Padium/ShortcutRegistry.swift` |

<!-- code-review-graph MCP tools -->
## MCP Tools: code-review-graph

**IMPORTANT: This project has a knowledge graph. ALWAYS use the
code-review-graph MCP tools BEFORE using Grep/Glob/Read to explore
the codebase.** The graph is faster, cheaper (fewer tokens), and gives
you structural context (callers, dependents, test coverage) that file
scanning cannot.

### When to use graph tools FIRST

- **Exploring code**: `semantic_search_nodes` or `query_graph` instead of Grep
- **Understanding impact**: `get_impact_radius` instead of manually tracing imports
- **Code review**: `detect_changes` + `get_review_context` instead of reading entire files
- **Finding relationships**: `query_graph` with callers_of/callees_of/imports_of/tests_for
- **Architecture questions**: `get_architecture_overview` + `list_communities`

Fall back to Grep/Glob/Read **only** when the graph doesn't cover what you need.

### Key Tools

| Tool | Use when |
|------|----------|
| `detect_changes` | Reviewing code changes — gives risk-scored analysis |
| `get_review_context` | Need source snippets for review — token-efficient |
| `get_impact_radius` | Understanding blast radius of a change |
| `get_affected_flows` | Finding which execution paths are impacted |
| `query_graph` | Tracing callers, callees, imports, tests, dependencies |
| `semantic_search_nodes` | Finding functions/classes by name or keyword |
| `get_architecture_overview` | Understanding high-level codebase structure |
| `refactor_tool` | Planning renames, finding dead code |

### Workflow

1. The graph auto-updates on file changes (via hooks).
2. Use `detect_changes` for code review.
3. Use `get_affected_flows` to understand impact.
4. Use `query_graph` pattern="tests_for" to check coverage.

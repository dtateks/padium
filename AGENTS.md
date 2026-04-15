# Padium — Agent Memory

**Updated:** 2026-04-15 00:00
**Commit:** 0e0c074
**Branch:** unknown

## Project Overview
macOS menu bar utility (Swift 5.9+, SwiftUI, Xcode). Trackpad swipe/tap gestures → keyboard shortcuts.
Bundle ID: `com.padium`, version 0.1.0. LSUIElement=true (no Dock icon).

**Scope**: owner-local MVP only — do NOT add packaging, export, distribution, or launch-at-login features.

## Dependencies (SPM via Xcode)
- `KeyboardShortcuts` 2.4.0 — shortcut recording UI + UserDefaults persistence
- `OpenMultitouchSupport` 3.0.3 — private multitouch API bridge (OMSManager)
- Shared gesture sensitivity applies to swipes only; tap and double-tap gestures use fixed thresholds.

## Build & Run
- Local dev workflow uses `scripts/run-dev.sh`:
  ```
  scripts/run-dev.sh
  ```
- Builds unsigned, copies to stable `~/Applications/Padium.app` (or `$PADIUM_INSTALL_DIR`), signs once with a stable Apple Development/Mac Development identity, then opens the installed copy.
- Stable install path + stable signing identity avoids repeated Accessibility re-grants from changing signatures.
- Launch without Accessibility permission immediately prompts, then terminates; relaunch after granting permission.
- `PadiumApp` skips that launch prompt+quit path under XCTest so host-app tests can run.
- After re-sign, `tccutil reset Accessibility com.padium` only if permissions are stale.
- Requires granting Accessibility permission in System Settings.
- App only disables macOS system trackpad gestures for Padium slots that currently have configured shortcuts; unbound slots leave the original macOS gestures enabled. `SystemGestureManager` persists a backup to UserDefaults so crash recovery can restore on next launch
- `ScrollSuppressor` uses a CGEventTap to consume scroll wheel events while 3+ fingers are active on the trackpad, preventing 2-finger scroll from firing during 3-finger gestures; also suppresses momentum scroll after finger lift

## Test
- `xcodebuild -project Padium.xcodeproj -scheme Padium test`
- Swift Testing framework (`import Testing`, NOT XCTest)
- Tests MUST be deterministic: use `Task.yield`/stream control, NEVER `Task.sleep`

## Architecture
```
PadiumApp (@main)
├─ MenuBarExtra — status + settings button
├─ Window(id: "settings") — TabView
│   ├─ PermissionsView (Tab 1) — Accessibility status + System Settings link
│   └─ SettingsView (Tab 2) — KeyboardShortcuts.Recorder per slot
└─ AppState (@Observable, orchestration boundary)
    ├─ PermissionCoordinator — AXIsProcessTrusted polling + prompt
    ├─ GestureEngine — AsyncStream pipeline: source → classifier → filtered events
    │   ├─ OMSGestureSource — OpenMultitouchSupport bridge
    │   └─ GestureClassifier — swipe classification + tap travel helper
    └─ ShortcutEmitter — ShortcutRegistry lookup → CGEvent key-down/key-up post
```

## Runtime Pipeline
`OMSGestureSource` → touch frames → `GestureEngine` tracks a candidate only while finger count + touch IDs stay stable → `GestureClassifier.classifyIncremental()` for swipes or tap/double-tap arbitration on lift → emits once, then ignores further frames until lift → `AppState` for-await loop → `ShortcutEmitter` → `CGEvent` post

## Key Contracts
- `AppState` is the ONLY orchestration boundary — views toggle state, never run side effects
- `GestureEngine.start()` is non-throwing; exposes failure via `lastStartError` — callers MUST inspect on `false` return
- `GestureEngine`/`OMSGestureSource` are restart-safe: AsyncStream replaced on each `start()` call
- Launch flow: `PermissionChecking`/`PermissionCoordinator` owns the permission prompt; missing Accessibility permission prompts immediately and the app exits until relaunched after approval.
- XCTest launch path bypasses that prompt+quit behavior so host-app tests can execute.
- `GestureEngine` commits only when finger count and touch identifiers remain stable; after emission it suppresses duplicates until a lift frame
- `GestureClassifier` requires stable touch identifiers, dominant-axis commitment, and per-finger direction agreement; vertical swipes tolerate lateral drift while the dominant axis stays vertical
- `GestureEngine` arbitrates tap vs double-tap recognition from raw touch frames; 3-finger and 4-finger clicks/double-clicks are experimental and emitted only when the finger-count-specific thresholds are met
- Shared sensitivity changes apply immediately without restarting the runtime for swipes only; `GestureClassifier` reads the current threshold live. UI sensitivity applies a +20 point base boost before threshold mapping, so default 50% behaves like the previous 70% calibration
- `AppState` updates active slots from recorder `onChange` callbacks before runtime decisions; shortcut-binding changes must refresh conflict state and gesture routing together
- `ShortcutRegistry.name(for:)` is the SINGLE source of truth for slot→`KeyboardShortcuts.Name` mapping — no ad-hoc Name creation elsewhere
- Settings window: app launch starts permission polling immediately; menu-bar selection explicitly calls `openWindow(id: "settings")` and focuses the existing window; `onDisappear` resets `isSettingsPresented` to `false`
- Permissions revoked while running → `refreshPermissions()` stops the runtime
- `SystemGestureManager.shared` handles selective save/disable/restore of system gesture preferences; `AppState` computes configured-slot conflicts before suppressing, and restores originals on runtime stop / app termination
- `SystemGestureManager.restoreIfNeeded()` runs at app launch to recover from a crash that left gestures suppressed
- `PreemptionController` detects per-slot system gesture conflicts for currently configured Padium slots; UI warnings should ignore unbound slots and only reflect active conflicts

## Coding Conventions
- `@MainActor` on all UI-bound and state classes
- Views are thin: render state only, no side-effect orchestration
- Protocols for DI boundaries: `GestureSource`, `GestureRuntimeControlling`, `ShortcutEmitting`, `PermissionChecking`
- `@discardableResult` on `start()`/`emitConfiguredShortcut()` methods
- Logging via `PadiumLogger` (OSLog): categories `gesture`, `shortcut`, `permission`
- Classifier thresholds are empirically derived — do NOT change without new evidence; swipe sensitivity and tap/double-tap thresholds are intentionally separate
- Event synthesis posts explicit modifier transitions before/after the key and uses `.cghidEventTap` for shortcut injection

## Anti-Patterns
- NEVER create `KeyboardShortcuts.Name` outside `ShortcutRegistry`
- NEVER use `Task.sleep` in tests — causes flaky non-determinism
- NEVER rely on temporary print debugging in OMS plumbing; use `PadiumLogger.gesture`
- NEVER reintroduce flagged main-key pairs on `.cgAnnotatedSessionEventTap` for shortcut emission

## Where To Look
| Task | Location |
|------|----------|
| App entry / scene setup | `Padium/PadiumApp.swift` |
| Runtime orchestration | `Padium/AppState.swift` |
| Gesture detection pipeline | `Padium/GestureEngine.swift` → `GestureClassifier.swift` |
| Multitouch hardware bridge | `Padium/OMSGestureSource.swift` |
| Shortcut emission | `Padium/ShortcutEmitter.swift` |
| Permission logic | `Padium/PermissionCoordinator.swift` |
| System gesture policy | `Padium/PreemptionController.swift` |
| Slot↔shortcut mapping | `Padium/ShortcutRegistry.swift` |

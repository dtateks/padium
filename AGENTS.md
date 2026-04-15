# Padium — Agent Memory

## Project Overview
macOS menu bar utility (Swift 5.9+, SwiftUI, Xcode). Trackpad swipe gestures → keyboard shortcuts.
Bundle ID: `com.padium`, version 0.1.0. LSUIElement=true (no Dock icon).

**Scope**: owner-local MVP only — do NOT add packaging, export, distribution, or launch-at-login features.

## Dependencies (SPM via Xcode)
- `KeyboardShortcuts` 2.4.0 — shortcut recording UI + UserDefaults persistence
- `OpenMultitouchSupport` 3.0.3 — private multitouch API bridge (OMSManager)

## Build & Run
- Open `Padium.xcodeproj` → ⌘R
- Requires granting Accessibility + Input Monitoring permissions in System Settings
- User must manually disable system trackpad gestures (Mission Control, App Exposé, swipe-between-fullscreen) — app uses `manual-disable` policy, cannot suppress programmatically

## Test
- ⌘U in Xcode — Swift Testing framework (`import Testing`, NOT XCTest)
- Tests MUST be deterministic: use `Task.yield`/stream control, NEVER `Task.sleep`

## Architecture
```
PadiumApp (@main)
├─ MenuBarExtra — toggle + settings button
├─ Window(id: "settings") — TabView
│   ├─ PermissionsView (Tab 1) — dual-gate status + System Settings links
│   └─ SettingsView (Tab 2) — KeyboardShortcuts.Recorder per slot
└─ AppState (@Observable, orchestration boundary)
    ├─ PermissionCoordinator — AXIsProcessTrusted + CGPreflightListenEventAccess
    ├─ GestureEngine — AsyncStream pipeline: source → classifier → filtered events
    │   ├─ OMSGestureSource — OpenMultitouchSupport bridge
    │   └─ GestureClassifier — frame sequences → GestureEvent (8 swipe slots)
    └─ ShortcutEmitter — ShortcutRegistry lookup → CGEvent key-down/key-up post
```

## Runtime Pipeline
`OMSGestureSource` → touch frames → `GestureEngine` accumulates until lift (empty frame) → `GestureClassifier.classify()` → filters by `supportedSlots` from `PreemptionPolicy` → `AppState` for-await loop → `ShortcutEmitter` → `CGEvent` post

## Key Contracts
- `AppState` is the ONLY orchestration boundary — views toggle state, never run side effects
- `GestureEngine.start()` is non-throwing; exposes failure via `lastStartError` — callers MUST inspect on `false` return
- `GestureEngine`/`OMSGestureSource` are restart-safe: AsyncStream replaced on each `start()` call
- `ShortcutRegistry.name(for:)` is the SINGLE source of truth for slot→`KeyboardShortcuts.Name` mapping — no ad-hoc Name creation elsewhere
- Settings window: `isSettingsPresented = true` triggers `openWindow(id: "settings")`; `onDisappear` resets to `false`
- Permissions revoked while enabled → `refreshPermissions()` auto-disables
- `PreemptionController` policy is `manual-disable` — owner notice MUST stay visible in permissions/settings

## Coding Conventions
- `@MainActor` on all UI-bound and state classes
- Views are thin: render state only, no side-effect orchestration
- Protocols for DI boundaries: `GestureSource`, `GestureRuntimeControlling`, `ShortcutEmitting`, `PermissionChecking`
- `@discardableResult` on `start()`/`emitConfiguredShortcut()` methods
- Logging via `PadiumLogger` (OSLog): categories `gesture`, `shortcut`, `permission`
- Classifier thresholds are empirically derived — do NOT change without new evidence

## Anti-Patterns
- NEVER create `KeyboardShortcuts.Name` outside `ShortcutRegistry`
- NEVER use `Task.sleep` in tests — causes flaky non-determinism
- NEVER add tap/double-tap gesture support — spikes-preemption.md §4 confirms swipe-only

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


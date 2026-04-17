<!-- Scoped to Padium/ source directory. Root AGENTS.md covers architecture, contracts, and conventions. -->

# Source Files

| File | Role | Key Detail |
|------|------|------------|
| PadiumApp.swift | @main entry | Window(id: "settings"), `SettingsContentView` owns TabView |
| AppState.swift | Orchestration | `@Observable`, owns runtime Task, injects shortcut/middle-click emitters, routes physical 3/4-finger click events from `ScrollSuppressor`, and suppresses same-sequence touch taps |
| GestureEngine.swift | Pipeline | Tracks stable candidates by finger count + touch IDs, arbitrates tap vs double-tap on lift, emits once, suppresses duplicates until lift |
| GestureClassifier.swift | Classification | Stable touch IDs, dominant-axis commitment, per-finger direction agreement, lateral-drift tolerance on vertical swipes |
| GestureSource.swift | Protocol + types | `GestureSource` protocol, `TouchPoint` struct, `OMSTouchState` enum — boundary above OMS |
| GestureEvent.swift | Data | `GestureEvent(slot:timestamp:)` — emitted by engine |
| GestureSlot.swift | Enum | Gesture slots include 1-finger and 2-finger double-tap, legacy 3/4 click+dbl-click slots (stable raw values for persisted config), and dedicated 3/4 touch tap+dbl-tap slots; `displayName`/`sectionTitle` for UI grouping |
| OMSGestureSource.swift | Hardware bridge | `OMSManager.shared` → `AsyncStream<[TouchPoint]>`, `@unchecked Sendable` |
| ShortcutEmitter.swift | Key posting | `CGEventShortcutSender` posts explicit modifier transitions + key events via `.cghidEventTap` |
| ShortcutRegistry.swift | Name mapping | `"gesture.\(slot.rawValue)"` pattern — single source of truth |
| PermissionCoordinator.swift | Permissions | `PermissionState` enum (.checking/.granted/.denied), `SystemPermissionChecker` |
| PreemptionController.swift | Conflict detection | Reads `com.apple.AppleMultitouchTrackpad` domain, filters conflicts down to currently configured GestureSlots, `openTrackpadSettings()` deep-links to System Settings |
| SystemGestureManager.swift | Gesture suppression | `suppress(conflictingSettings:allSettings:)` selectively disables matching macOS gesture prefs via `defaults write` + `killall Dock`; Dock keys disable only when all enabled vertical gestures are suppressed; `restore()` writes back originals; backup in UserDefaults for crash recovery |
| ScrollSuppressor.swift | Scroll + click suppression | CGEventTap on `.scrollWheel`, `.leftMouseDown`, and `.leftMouseUp`; consumes scroll events while 3+ fingers active, emits configured physical 3/4-finger click+dbl-click gesture events to `AppState`, suppresses handled left-click pairs, and blocks same-sequence touch taps. Exposes two narrow protocols — `PhysicalClickCoordinating` (start/stop/handler/touch-tap gate) for `AppState`, `MultitouchStateSink` (set-only finger count + active flag) for `GestureEngine` — so collaborators depend on behaviour instead of the shared singleton |
| SettingsView.swift | UI | Groups slots by `sectionTitle`, shows per-row conflict warnings + experimental tap caveat, sensitivity copy explains shared swipe/touch-tap sensitivity; copy mentions Smart Zoom among experimental tap conflicts |
| PermissionsView.swift | UI | Accessibility status + per-system-gesture conflict list + "Open Trackpad Settings" + "Refresh" |
| GestureRowView.swift | UI | `KeyboardShortcuts.Recorder(for:)` per slot, shows conflict warning via `isConflicting` flag |
| Logger.swift | Logging | `PadiumLogger` enum: `.gesture`, `.shortcut`, `.permission` categories |

# Module-Specific Gotchas
- `OMSGestureSource` is `@unchecked Sendable` — mutable state accessed only from its internal Task; do not add shared mutable state without synchronization
- `GestureClassifier` applies a +20 point base boost before threshold mapping; swipe thresholds range 0.04-0.10 (previous 0.06-0.14), touch-tap travel thresholds range 0.04-0.07, and both use the same live shared sensitivity curve without an AppState runtime restart
- Palm rejection is geometric only: `GestureClassifier.stableActiveContacts` rejects contacts whose aspect-corrected pairwise spread exceeds one-hand reach — 2-finger 0.70, 3-finger 1.00, 4+ unchecked — catching two-palm-at-corners artefacts without any keyboard-activity heuristic
- `GestureClassifier` tolerates lateral drift on vertical swipes while preserving dominant-axis commitment and per-finger agreement
- `GestureEngine` tracks a peak finger count per candidate: it upgrades and re-anchors `originContacts`/`startedAt` when a higher count appears and preserves the candidate (no downgrade) when fewer fingers are active during landing/lift transitions. Swipe classification is gated by a wall-clock settle window (`peakUpgradeSettleWindow`, 80 ms via `scheduler.now`) ONLY when a higher finger count is still configured (i.e. an upgrade is still possible). When the peak already equals the highest configured finger count there is no settle wait — commit happens on motion alone. This is the libinput Pattern B (`UNKNOWN [hold_timer] → committed`) sized for Padium's bounded peak (max 4 fingers) and the empirical 20–60 ms multi-finger landing spread on macOS trackpads. Time-based, not frame-based, so behavior is independent of OMS frame rate (90–120 Hz across hardware). `handleLift` always evaluates tap recognition against the peak — a 4-finger swipe whose lift drops through 3/2 fingers can never register a 2/3-finger tap. Frames after a committed gesture are still ignored until a lift frame clears the candidate.
- `PermissionCoordinator` polling is owned by `AppState` from app launch so permission revocation can stop the runtime even while settings is closed
- Launch without Accessibility permission immediately prompts, then terminates; `PadiumApp` bypasses that path under XCTest so host-app tests can run
- `AppState` refreshes active slots and live runtime/config state from `UserDefaults` changes; shortcut-binding changes must refresh conflict state and gesture routing together
- App activation/reopen explicitly focuses the existing settings window rather than spawning duplicates
- `AppState.setAppInteractionActive(_:)` marks Padium's own menu/settings surfaces as UI-interaction mode so `ScrollSuppressor` passes physical left-click events through while the user is interacting with Padium itself
- `PreemptionController.conflictingSlots(for:)` returns only the currently configured Padium slots that still conflict with enabled system gestures; `AppState` refreshes this after permission and shortcut-binding changes
- OMS reads raw touches in parallel with macOS — it cannot suppress system gesture recognizers; `SystemGestureManager` handles system gesture prefs (Mission Control, Spaces, App Exposé); Dock keys are only disabled when all enabled vertical gestures are suppressed, not when a single finger-count variant is suppressed. `ScrollSuppressor` handles scroll-during-multitouch via CGEventTap and still activates only for 3+ active fingers
- `ScrollSuppressor.isMultitouchActive` and `currentFingerCount` are set from `GestureEngine`'s pipeline task via the injected `MultitouchStateSink` (which runs on an arbitrary thread from OMS); both use the same `os_unfair_lock`-protected state read by the CGEventTap callback, but physical click routing must require `isMultitouchActive == true` in addition to a raw 3/4-finger count so landing/lift noise cannot swallow ordinary clicks
- `ScrollSuppressor.start()/stop()` run the CGEventTap on a dedicated thread; the thread saves its `CFRunLoop` (lock-protected) so `stop()` wakes and exits that run loop deterministically, then removes the source and joins — no main-run-loop workaround, no thread leak on restart
- `GestureRowView` uses `@AppStorage` bound to `GestureActionStore.userDefaultsKey(for:)`, so the picker reflects external UserDefaults changes without a stale snapshot from view init; writes still go through `GestureActionStore.setActionKind` so the "remove key when back to `.shortcut`" behaviour is preserved
- Legacy click slots (`threeFingerClick`, `threeFingerDoubleClick`, `fourFingerClick`, `fourFingerDoubleClick`) preserve old raw values so stored shortcut/action-kind state remains valid; dedicated touch tap slots use distinct new raw values and stay shortcut-only
- Physical 3/4-finger clicks are detected from left-mouse events and emitted as `GestureEvent`s to `AppState`; touch tap events are only deduped after Padium actually handled a configured physical click, so pass-through left clicks do not poison touch-tap recognition
- Momentum scroll events after finger lift are also suppressed until the momentum phase ends

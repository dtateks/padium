<!-- Scoped to Padium/ source directory. Root AGENTS.md covers architecture, contracts, and conventions. -->

# Source Files

| File | Role | Key Detail |
|------|------|------------|
| PadiumApp.swift | @main entry | MenuBarExtra + Window(id: "settings"), `SettingsContentView` owns TabView |
| AppState.swift | Orchestration | `@Observable`, owns runtime Task, protocols `GestureRuntimeControlling`/`ShortcutEmitting` defined here |
| GestureEngine.swift | Pipeline | Tracks stable candidates by finger count + touch IDs, arbitrates tap vs double-tap on lift, emits once, suppresses duplicates until lift |
| GestureClassifier.swift | Classification | Stable touch IDs, dominant-axis commitment, per-finger direction agreement, lateral-drift tolerance on vertical swipes |
| GestureSource.swift | Protocol + types | `GestureSource` protocol, `TouchPoint` struct, `OMSTouchState` enum — boundary above OMS |
| GestureEvent.swift | Data | `GestureEvent(slot:timestamp:)` — emitted by engine |
| GestureSlot.swift | Enum | 12 gesture slots (8 swipes + 4 experimental tap/double-tap), `displayName`/`sectionTitle` for UI grouping |
| OMSGestureSource.swift | Hardware bridge | `OMSManager.shared` → `AsyncStream<[TouchPoint]>`, `@unchecked Sendable` |
| ShortcutEmitter.swift | Key posting | `CGEventShortcutSender` posts explicit modifier transitions + key events via `.cghidEventTap` |
| ShortcutRegistry.swift | Name mapping | `"gesture.\(slot.rawValue)"` pattern — single source of truth |
| PermissionCoordinator.swift | Permissions | `PermissionState` enum (.checking/.granted/.denied), `SystemPermissionChecker` |
| PreemptionController.swift | Conflict detection | Reads `com.apple.AppleMultitouchTrackpad` domain, filters conflicts down to currently configured GestureSlots, `openTrackpadSettings()` deep-links to System Settings |
| SystemGestureManager.swift | Gesture suppression | `suppress(conflictingSettings:)` selectively disables only the matching macOS gesture prefs via `defaults write` + `killall Dock`; `restore()` writes back originals; backup in UserDefaults for crash recovery |
| ScrollSuppressor.swift | Scroll suppression | CGEventTap on `.scrollWheel` consumes scroll events while 3+ fingers active; `os_unfair_lock`-guarded `isMultitouchActive` flag set by GestureEngine; also suppresses momentum scroll after lift |
| SettingsView.swift | UI | Groups slots by `sectionTitle`, shows per-row conflict warnings + experimental tap caveat, sensitivity copy limited to swipes |
| PermissionsView.swift | UI | Accessibility status + per-system-gesture conflict list + "Open Trackpad Settings" + "Refresh" |
| GestureRowView.swift | UI | `KeyboardShortcuts.Recorder(for:)` per slot, shows conflict warning via `isConflicting` flag |
| Logger.swift | Logging | `PadiumLogger` enum: `.gesture`, `.shortcut`, `.permission` categories |

# Module-Specific Gotchas
- `OMSGestureSource` is `@unchecked Sendable` — mutable state accessed only from its internal Task; do not add shared mutable state without synchronization
- `GestureClassifier` applies a +20 point base boost before threshold mapping, so default 50% behaves like the previous 70% calibration; shared sensitivity remaps swipe thresholds only and is read live without an AppState runtime restart
- `GestureClassifier` tolerates lateral drift on vertical swipes while preserving dominant-axis commitment and per-finger agreement
- `GestureEngine` ignores frames after a committed gesture until a lift frame clears the candidate; tap/double-tap recognition is experimental and derived from raw touch frames
- `PermissionCoordinator` polling is owned by `AppState` from app launch so permission revocation can stop the runtime even while settings is closed
- Launch without Accessibility permission immediately prompts, then terminates; `PadiumApp` bypasses that path under XCTest so host-app tests can run
- `AppState` updates active slots from recorder `onChange` callbacks before routing decisions; shortcut-binding changes must refresh conflict state and gesture routing together
- Menu-bar selection explicitly focuses the existing settings window rather than spawning duplicates
- `PreemptionController.conflictingSlots(for:)` returns only the currently configured Padium slots that still conflict with enabled system gestures; `AppState` refreshes this after permission and shortcut-binding changes
- OMS reads raw touches in parallel with macOS — it cannot suppress system gesture recognizers; `SystemGestureManager` handles system gesture prefs (Mission Control, Spaces, App Exposé) and `ScrollSuppressor` handles scroll-during-multitouch via CGEventTap
- `ScrollSuppressor.isMultitouchActive` is set from `GestureEngine`'s pipeline task (which runs on an arbitrary thread from OMS); the flag uses `os_unfair_lock`; the CGEventTap callback reads the flag to decide whether to consume scroll events
- Momentum scroll events after finger lift are also suppressed until the momentum phase ends

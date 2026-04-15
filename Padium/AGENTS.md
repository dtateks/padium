<!-- Scoped to Padium/ source directory. Root AGENTS.md covers architecture, contracts, and conventions. -->

# Source Files

| File | Role | Key Detail |
|------|------|------------|
| PadiumApp.swift | @main entry | MenuBarExtra + Window(id: "settings"), `SettingsContentView` owns TabView |
| AppState.swift | Orchestration | `@Observable`, owns runtime Task, protocols `GestureRuntimeControlling`/`ShortcutEmitting` defined here |
| GestureEngine.swift | Pipeline | Tracks stable candidate by finger count + touch IDs, emits once, suppresses duplicates until lift |
| GestureClassifier.swift | Classification | Stable touch IDs, dominant-axis commitment, per-finger direction agreement, lateral-drift tolerance on vertical swipes |
| GestureSource.swift | Protocol + types | `GestureSource` protocol, `TouchPoint` struct, `OMSTouchState` enum — boundary above OMS |
| GestureEvent.swift | Data | `GestureEvent(slot:timestamp:)` — emitted by engine |
| GestureSlot.swift | Enum | 8 swipe slots, `displayName`/`sectionTitle` for UI grouping |
| OMSGestureSource.swift | Hardware bridge | `OMSManager.shared` → `AsyncStream<[TouchPoint]>`, `@unchecked Sendable` |
| ShortcutEmitter.swift | Key posting | `CGEventShortcutSender` posts explicit modifier transitions + key events via `.cghidEventTap` |
| ShortcutRegistry.swift | Name mapping | `"gesture.\(slot.rawValue)"` pattern — single source of truth |
| PermissionCoordinator.swift | Permissions | `PermissionState` enum (.checking/.granted/.denied), `SystemPermissionChecker` |
| PreemptionController.swift | Policy | Reads `com.apple.AppleMultitouchTrackpad` domain, throws if manual disable needed |
| SettingsView.swift | UI | Groups slots by `sectionTitle`, shows `systemGestureNotice` warning |
| PermissionsView.swift | UI | Per-permission status rows + System Settings deep links |
| GestureRowView.swift | UI | `KeyboardShortcuts.Recorder(for:)` per slot |
| Logger.swift | Logging | `PadiumLogger` enum: `.gesture`, `.shortcut`, `.permission` categories |

# Module-Specific Gotchas
- `OMSGestureSource` is `@unchecked Sendable` — mutable state accessed only from its internal Task; do not add shared mutable state without synchronization
- `GestureClassifier` default swipe threshold is `0.10`; shared sensitivity remaps that threshold for all gestures and AppState restarts the runtime on change
- `GestureClassifier` tolerates lateral drift on vertical swipes while preserving dominant-axis commitment and per-finger agreement
- `GestureEngine` ignores frames after a committed swipe until a lift frame clears the candidate
- `PermissionCoordinator` polling is owned by `AppState` from app launch so permission revocation can stop the runtime even while settings is closed
- Launch without Accessibility permission immediately prompts, then terminates; `PadiumApp` bypasses that path under XCTest so host-app tests can run
- Shared gesture sensitivity lives in AppState/config state and restarts the runtime when changed
- Menu-bar selection explicitly focuses the existing settings window rather than spawning duplicates

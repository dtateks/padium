<!-- Scoped to Padium/ source directory. Root AGENTS.md covers architecture, contracts, and conventions. -->

# Source Files

| File | Role | Key Detail |
|------|------|------------|
| PadiumApp.swift | @main entry | MenuBarExtra + Window(id: "settings"), `SettingsContentView` owns TabView |
| AppState.swift | Orchestration | `@Observable`, owns runtime Task, protocols `GestureRuntimeControlling`/`ShortcutEmitting` defined here |
| GestureEngine.swift | Pipeline | Accumulates frames until lift → classifies → yields filtered events |
| GestureClassifier.swift | Classification | Centroid-based swipe detection, atan2 quadrant mapping, noise/palm rejection |
| GestureSource.swift | Protocol + types | `GestureSource` protocol, `TouchPoint` struct, `OMSTouchState` enum — boundary above OMS |
| GestureEvent.swift | Data | `GestureEvent(slot:timestamp:)` — emitted by engine |
| GestureSlot.swift | Enum | 8 swipe slots, `displayName`/`sectionTitle` for UI grouping |
| OMSGestureSource.swift | Hardware bridge | `OMSManager.shared` → `AsyncStream<[TouchPoint]>`, `@unchecked Sendable` |
| ShortcutEmitter.swift | Key posting | `CGEventShortcutSender` posts key-down/key-up via `cgAnnotatedSessionEventTap` |
| ShortcutRegistry.swift | Name mapping | `"gesture.\(slot.rawValue)"` pattern — single source of truth |
| PermissionCoordinator.swift | Permissions | `PermissionState` enum (.checking/.granted/.denied), `SystemPermissionChecker` |
| PreemptionController.swift | Policy | Reads `com.apple.AppleMultitouchTrackpad` domain, throws if manual disable needed |
| SettingsView.swift | UI | Groups slots by `sectionTitle`, shows `systemGestureNotice` warning |
| PermissionsView.swift | UI | Per-permission status rows + System Settings deep links |
| GestureRowView.swift | UI | `KeyboardShortcuts.Recorder(for:)` per slot |
| Logger.swift | Logging | `PadiumLogger` enum: `.gesture`, `.shortcut`, `.permission` categories |

# Module-Specific Gotchas
- `OMSGestureSource` is `@unchecked Sendable` — mutable state accessed only from its internal Task; do not add shared mutable state without synchronization
- `GestureClassifier` thresholds: `swipeMinDistance=0.10`, `noiseCapacitance<0.03`, `palmMajorAxis>30` — empirically derived, not tunable constants
- `PermissionCoordinator` has TWO instances: one in `AppState` (runtime), one in `SettingsContentView` (for opening System Settings) — the runtime one gates enable/disable
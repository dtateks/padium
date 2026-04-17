<!-- Scoped to PadiumTests/ directory. Root AGENTS.md covers test framework choice and determinism rule. -->

**Updated:** 2026-04-18 18:18
**Commit:** 861c705
**Branch:** main

# Test Patterns

- `@MainActor struct XxxTests` — all test structs are MainActor-isolated
- Use `@Suite(.serialized)` when a test suite mutates shared user-default-backed configuration or singleton runtime state
- `GestureEngineTests` stays serialized because it touches `ScrollSuppressor.shared` and other shared gesture runtime state
- Stubs implement DI protocols: `StubGestureSource`, `StubPermissionChecker`, `StubShortcutSender`, `RecordingPhysicalClickCoordinator`
- Stubs expose call counts (`startCallCount`, `stopCallCount`) and controllable async streams
- Frame helpers like `makeSwipeFrames(fingerCount:startX:startY:endX:endY:)` and tap/double-tap builders build `[[TouchPoint]]` for classifier/engine tests
- Async pipeline tests: yield frames into stub source → `Task.yield()` to flush → assert on collected events
- NEVER `Task.sleep` — use `continuation.yield()` + `Task.yield()` for deterministic sequencing
- `AppState` shortcut binding propagation tests mutate KeyboardShortcuts bindings directly (`setShortcut` / `setShortcut(nil)`), pump event loop, then assert immediate runtime slot updates via active slot history
- Gesture regression coverage must include stable-ID commit, dominant-axis rejection, lateral-drift tolerance on vertical swipes, per-finger agreement, swipe threshold rejection, duplicate suppression until lift, deterministic 1-finger/2-finger double-tap plus dedicated 3-finger/4-finger touch tap + double-tap timing, hand-spread rejection of palm-at-corners artefacts, and touch-only engine emission; config-mutating tests preserve and restore user gesture config
- Permission capability coverage: separate Accessibility / Input Monitoring / Post Event states, startup prompts, and startup-degraded handling via `applicationDidBecomeActive` + `AppState`.

# Coverage Map

| Test File | Component | What's Verified |
|-----------|-----------|-----------------|
| GestureEngineTests.swift | GestureEngine | Start/stop lifecycle, stream restart, policy slot filtering, stable-ID commit, duplicate suppression until lift, tap/double-tap arbitration across configured finger counts, stable full-finger contact-set gating |
| GestureClassifierTests.swift | GestureClassifier | All 8 swipe directions, finger count gating, stable IDs, dominant-axis rejection, lateral-drift tolerance on vertical swipes, opposing-direction rejection, threshold rejection |
| PermissionCoordinatorTests.swift | PermissionCoordinator / AppState / ScrollSuppressor | Capability checks (`permissionState` / `inputMonitoringState` / `postEventState`), degraded startup modes, startup prompts, KeyboardShortcuts-driven config propagation, and runtime separation under partial failures |
| ShortcutEmitterTests.swift | ShortcutEmitter | Lookup + send delegation, explicit modifier/key sequencing, unbound slot returns false |
| ShortcutRegistryTests.swift | ShortcutRegistry / SystemGestureManager | Name format `"gesture.\(rawValue)"` consistency; vertical Dock-key suppression only when all enabled vertical gestures are suppressed |

<!-- Scoped to PadiumTests/ directory. Root AGENTS.md covers test framework choice and determinism rule. -->

# Test Patterns

- `@MainActor struct XxxTests` — all test structs are MainActor-isolated
- Use `@Suite(.serialized)` when a test suite mutates shared user-default-backed configuration or singleton runtime state
- `GestureEngineTests` stays serialized because it touches `ScrollSuppressor.shared` and other shared gesture runtime state
- Stubs implement DI protocols: `StubGestureSource`, `StubPermissionChecker`, `StubShortcutSender`
- Stubs expose call counts (`startCallCount`, `stopCallCount`) and controllable async streams
- Frame helpers like `makeSwipeFrames(fingerCount:startX:startY:endX:endY:)` and tap/double-tap builders build `[[TouchPoint]]` for classifier/engine tests
- Async pipeline tests: yield frames into stub source → `Task.yield()` to flush → assert on collected events
- NEVER `Task.sleep` — use `continuation.yield()` + `Task.yield()` for deterministic sequencing
- Gesture regression coverage must include stable-ID commit, dominant-axis rejection, lateral-drift tolerance on vertical swipes, per-finger agreement, swipe threshold rejection, duplicate suppression until lift, deterministic 1-finger/2-finger double-tap plus dedicated 3-finger/4-finger touch tap + double-tap timing, and touch-only engine emission; config-mutating tests preserve and restore user gesture config
- Permission launch coverage must include immediate prompt+quit on missing Accessibility permission and XCTest bypass of that path in `PadiumApp`

# Coverage Map

| Test File | Component | What's Verified |
|-----------|-----------|-----------------|
| GestureEngineTests.swift | GestureEngine | Start/stop lifecycle, stream restart, policy slot filtering, stable-ID commit, duplicate suppression until lift, tap/double-tap arbitration across configured finger counts, stable full-finger contact-set gating |
| GestureClassifierTests.swift | GestureClassifier | All 8 swipe directions, finger count gating, stable IDs, dominant-axis rejection, lateral-drift tolerance on vertical swipes, opposing-direction rejection, threshold rejection |
| PermissionCoordinatorTests.swift | PermissionCoordinator / AppState / ScrollSuppressor | Permission transitions, AppState runtime routing for shortcut vs middle click, middle-click activation without a shortcut, physical 3/4 click routing from mouse events, and physical-click precedence over touch taps |
| ShortcutEmitterTests.swift | ShortcutEmitter | Lookup + send delegation, explicit modifier/key sequencing, unbound slot returns false |
| ShortcutRegistryTests.swift | ShortcutRegistry / SystemGestureManager | Name format `"gesture.\(rawValue)"` consistency; vertical Dock-key suppression only when all enabled vertical gestures are suppressed |

<!-- Scoped to PadiumTests/ directory. Root AGENTS.md covers test framework choice and determinism rule. -->

# Test Patterns

- `@MainActor struct XxxTests` — all test structs are MainActor-isolated
- Stubs implement DI protocols: `StubGestureSource`, `StubPermissionChecker`, `StubShortcutSender`
- Stubs expose call counts (`startCallCount`, `stopCallCount`) and controllable async streams
- Frame helpers like `makeSwipeFrames(fingerCount:startX:startY:endX:endY:)` build `[[TouchPoint]]` for classifier/engine tests
- Async pipeline tests: yield frames into stub source → `Task.yield()` to flush → assert on collected events
- NEVER `Task.sleep` — use `continuation.yield()` + `Task.yield()` for deterministic sequencing

# Coverage Map

| Test File | Component | What's Verified |
|-----------|-----------|-----------------|
| GestureEngineTests.swift | GestureEngine | Start/stop lifecycle, stream restart, policy slot filtering, error propagation |
| GestureClassifierTests.swift | GestureClassifier | All 8 swipe directions, finger count gating, noise rejection, palm rejection, min-distance threshold |
| PermissionCoordinatorTests.swift | PermissionCoordinator | State transitions: checking→granted, checking→denied, partial grant, revocation while enabled |
| ShortcutEmitterTests.swift | ShortcutEmitter | Lookup + send delegation, unbound slot returns false |
| ShortcutRegistryTests.swift | ShortcutRegistry | Name format `"gesture.\(rawValue)"` consistency |
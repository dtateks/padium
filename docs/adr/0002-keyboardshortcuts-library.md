# ADR-0002: Adopt sindresorhus/KeyboardShortcuts for recorder + runtime store

**Date**: 2026-04-13
**Status**: accepted
**Deciders**: Owner + researcher agent via `/ecc:search-first`

## Context

Padium MVP needs a **shortcut recorder UI** (user clicks a field, captures next keystroke like System Settings or Raycast) and **runtime storage** of the 12 gesture→shortcut bindings. Writing a shortcut recorder from scratch in SwiftUI requires handling `NSEvent.keyDown` capture, modifier flag normalization, collision detection with system shortcuts, and visual state transitions — a weekend of work with edge cases.

## Decision

Adopt `sindresorhus/KeyboardShortcuts` (MIT, active through 2026-02) via SwiftPM. Use its `Recorder` SwiftUI view for each of the 12 gesture slots, and let the library own **runtime binding storage** (UserDefaults-backed, built in). Define 12 `KeyboardShortcuts.Name` static properties, one per gesture slot.

## Alternatives Considered

### Alternative 1: Build shortcut recorder from scratch
- **Pros**: No dependency; full control over UX and style
- **Cons**: ~200 LOC + edge cases (sticky modifiers, system collision warnings, focus management). Reinventing a battle-tested component used by Plash, Dato, and many other apps.
- **Why not**: Effort/benefit ratio terrible. Search-first explicitly found this as a drop-in solution.

### Alternative 2: Clipy / KeyHolder
- **Pros**: Another mature option
- **Cons**: Cocoa-only (not SwiftUI native), requires bridging
- **Why not**: `KeyboardShortcuts` ships a native SwiftUI `Recorder` view — strictly better fit for our stack.

### Alternative 3: Use KeyboardShortcuts only for the Recorder view, store bindings separately in our own JSON
- **Pros**: Single source of truth in our JSON file
- **Cons**: Requires syncing UserDefaults ↔ JSON two-way, fighting the library's design
- **Why not**: Creates bugs at the boundary. Cleaner: let library own the runtime state, use JSON only for export/import (see ADR-0003).

## Consequences

### Positive
- Reduces Step 9 (Matrix Config UI) effort by ~40%
- Collision detection and system-shortcut warnings come free
- Actively maintained by sindresorhus (high confidence)
- MIT license

### Negative
- Runtime shortcut state lives in UserDefaults, not in our JSON config — requires ADR-0003's export/import layer for sharing presets
- Adds one dependency (small, pure Swift, no transitive deps)
- Binding layer tied to library's `KeyboardShortcuts.Name` pattern

### Risks
- **Library becomes unmaintained**: Mitigation: vendor-fork if/when it goes quiet; the code is small enough to own. Low probability — sindresorhus maintains across 100+ repos.
- **UserDefaults conflict with future macOS sandbox changes**: Mitigation: we're already un-sandboxed per ADR-0001; standard NSUserDefaults works in un-sandboxed apps.

## References

- `.claude/PRPs/prds/padium-trackpad.prd.md` — Step 7, Step 9
- `plans/padium-trackpad-mvp.md` — updated post-search-first
- `/ecc:search-first` report (2026-04-13)
- KeyboardShortcuts: https://github.com/sindresorhus/KeyboardShortcuts

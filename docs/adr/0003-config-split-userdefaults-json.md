# ADR-0003: Split config: UserDefaults runtime + JSON export/import

**Date**: 2026-04-13
**Status**: accepted
**Deciders**: Owner + side-effect of ADR-0002

## Context

Original PRD specified `~/.padium/config.json` as the **primary** persistence mechanism — human-editable, git-shareable, atomic-write. After adopting `sindresorhus/KeyboardShortcuts` (ADR-0002), runtime gesture→shortcut bindings are stored in `UserDefaults` by the library. Forcing a two-way sync between UserDefaults and a JSON file would introduce race conditions and double-source-of-truth bugs.

## Decision

Split responsibility:
- **UserDefaults (via `KeyboardShortcuts`)** is the authoritative runtime store for the 12 gesture→shortcut bindings
- **`~/.padium/config.json`** becomes an **export/import path only** — a human-readable snapshot for sharing presets between friends, backing up, or git-versioning
- UI includes "Export to JSON" and "Import from JSON" buttons; no background sync

## Alternatives Considered

### Alternative 1: JSON as primary, UserDefaults ignored
- **Pros**: Single source of truth, human-editable, git-friendly
- **Cons**: Fights `KeyboardShortcuts` library's design; every binding change requires manual UserDefaults overwrite; library's collision warnings break
- **Why not**: Wrong abstraction boundary. The library's `Name → Shortcut` mapping IS the runtime state.

### Alternative 2: UserDefaults only, no JSON at all
- **Pros**: Simpler, no export code
- **Cons**: Cannot share presets between friends (the whole point of "share binary to 5 friends"). Cannot back up config. Opaque to user.
- **Why not**: Sharing is an explicit success metric. JSON export preserves the friendly portability of the original design.

### Alternative 3: Two-way FileWatcher sync
- **Pros**: Edit JSON → UserDefaults auto-updates
- **Cons**: Race conditions (user edits JSON while app is running), complexity of conflict resolution, debounce logic
- **Why not**: Complexity for a feature (hot-reload) that isn't in MVP scope. Explicit Export/Import UX is clearer.

## Consequences

### Positive
- No double-source-of-truth bugs
- Leverages `KeyboardShortcuts` library idiomatically
- Manual Export/Import gives user explicit control over when sharing happens
- Preserves "share JSON to friends" value proposition

### Negative
- No live reload — user must click "Import" to apply edits made in JSON
- Two mechanisms (UserDefaults binary plist + JSON file) instead of one
- Slightly more UI surface (2 buttons in config view)

### Risks
- **User confusion about which is authoritative**: Mitigation: UI copy "Export current setup" / "Import replaces current setup"; README explains model clearly
- **Version drift between UserDefaults schema and JSON schema**: Mitigation: shared `GestureSlot` enum is the single mapping key; version field in JSON for future migrations

## Supersedes

None. This refines the persistence approach originally specified in PRD, post-ADR-0002.

## References

- ADR-0002 (adopts KeyboardShortcuts library that owns UserDefaults binding state)
- `.claude/PRPs/prds/padium-trackpad.prd.md` — Step 7 rewritten to match
- `plans/padium-trackpad-mvp.md` — Step 7 updated

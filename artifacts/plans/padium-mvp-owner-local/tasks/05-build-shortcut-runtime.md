# Task 05: Build shortcut runtime backed by KeyboardShortcuts

- **Agent**: golem
- **Skills**: swift-protocol-di-testing, tdd-workflow
- **Wave**: 2
- **Complexity**: M

## Owns
- `Padium/GestureSlot.swift` (modify)
- `Padium/ShortcutRegistry.swift` (modify)
- `Padium/ShortcutEmitter.swift` (modify)
- `PadiumTests/ShortcutRegistryTests.swift` (modify)
- `PadiumTests/ShortcutEmitterTests.swift` (modify)

## Prerequisites
- Task 01 completed and `C-01-project-skeleton` validated.

## Entry References
- `docs/adr/0002-keyboardshortcuts-library.md:9-14` — KeyboardShortcuts owns recorder + runtime storage
- `PRODUCT-BRIEF.md:38-45` — MVP scope is gesture → keyboard shortcut only
- `artifacts/libs/keyboardshortcuts-padium-mvp_19.55_13-04-2026.md:38-95` — typed names and Recorder usage
- `artifacts/libs/keyboardshortcuts-padium-mvp_19.55_13-04-2026.md:96-179` — get/set/clear APIs and persistence behavior
- `artifacts/libs/keyboardshortcuts-padium-mvp_19.55_13-04-2026.md:180-195` — menu-bar app compatibility note

## Exemplar
- Greenfield — follow the `KeyboardShortcuts.Name` + `Recorder(name:)` + `setShortcut/getShortcut` pattern from `artifacts/libs/keyboardshortcuts-padium-mvp_19.55_13-04-2026.md:38-95` and `:96-179`.

## Research Notes
- **Persistence is automatic**: name-based Recorder and `Name.shortcut` use `UserDefaults` under the hood; do not add a second persistence layer for this MVP (source: `artifacts/libs/keyboardshortcuts-padium-mvp_19.55_13-04-2026.md:143-179`).

## Produces
- `C-05-shortcut-runtime`:
  - Signature: `GestureSlot: CaseIterable & Sendable`, `ShortcutRegistry.name(for: GestureSlot) -> KeyboardShortcuts.Name`, `ShortcutEmitter.emitConfiguredShortcut(for: GestureSlot) -> Bool`
  - Behavior: Every supported gesture slot maps to one stable `KeyboardShortcuts.Name`; `ShortcutEmitter` posts the configured shortcut if present and returns `false` for an unbound slot without crashing.
  - Validate: targeted registry/emitter tests pass and no JSON/config side path is introduced.

## Consumes
- `C-01-project-skeleton` from Task 01:
  - Signature: `Padium.xcodeproj + Padium app target + PadiumTests target + macOS 14 + Swift 6 strict concurrency + dependencies wired`
  - Behavior: Provides compiled placeholders and dependency wiring for the real shortcut runtime.

## Tests
- **Skip reason**: None

## Steps
1. Write failing tests first for stable gesture-slot ordering, stable `KeyboardShortcuts.Name` mapping, and `ShortcutEmitter` behavior for bound vs unbound slots.
2. Implement `GestureSlot` as the single source of truth for the supported gesture rows and their grouped-list presentation metadata.
3. Implement `ShortcutRegistry` so later tasks consume one stable mapping surface instead of touching `KeyboardShortcuts.Name` ad hoc.
4. Implement `ShortcutEmitter` with explicit success/failure behavior and no sticky-modifier side effects.
5. Run the targeted tests and keep runtime storage strictly inside `KeyboardShortcuts`/UserDefaults.

## Failure Modes
- **If a shortcut API detail differs from the docs**: adjust the adapter, not the MVP scope; record the actual behavior in the report.
- **If an unbound slot currently crashes or mutates app state**: fix the runtime contract so unbound means “no-op + explicit false,” not hidden failure.

## Guardrails
- Do not add JSON/export/import, file-backed config, or a second runtime store.
- Do not hardcode default shortcuts.
- Do not scatter raw `KeyboardShortcuts.Name` definitions outside the registry surface.

## Acceptance
- `xcodebuild test -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' -only-testing:PadiumTests/ShortcutRegistryTests -only-testing:PadiumTests/ShortcutEmitterTests`
  - Expected: all selected tests pass

## Report (include in your final response to orchestrator)
- **Actual outputs**: files created/modified with paths
- **Test evidence**: exact command(s) executed + PASS/FAIL summary + scope (or skip reason)
- **Resolved review items**: `None` or `ID → changed files → verification command/result`
- **Contract amendments**: `None` or actual signature + reason + classification
- **New constraints or prerequisites**: newly discovered downstream-affecting constraints/prereqs, or `None`
- **Deviations**: other differences from planned behavior, or `None`
- **Discoveries**: patterns/gotchas affecting later tasks — include **Recommendation** + **Rationale**
- **Warnings**: anything downstream tasks should know
- **Downstream action**: `continue` | `amend` | `escalate` — with short reason
- **Prerequisites confirmed**: runtime prerequisites verified during execution

# Task 01: Scaffold a strict-concurrency menubar workspace

- **Agent**: golem
- **Skills**: swiftui-patterns, swift-concurrency-6-2
- **Wave**: 1
- **Complexity**: M

## Owns
- `Padium.xcodeproj/project.pbxproj` (create)
- `Padium/Info.plist` (create)
- `Padium/PadiumApp.swift` (create)
- `Padium/AppState.swift` (create)
- `Padium/GestureSlot.swift` (create)
- `Padium/GestureEvent.swift` (create)
- `Padium/GestureSource.swift` (create)
- `Padium/OMSGestureSource.swift` (create)
- `Padium/GestureClassifier.swift` (create)
- `Padium/GestureEngine.swift` (create)
- `Padium/ShortcutRegistry.swift` (create)
- `Padium/ShortcutEmitter.swift` (create)
- `Padium/SettingsView.swift` (create)
- `Padium/GestureRowView.swift` (create)
- `Padium/PermissionCoordinator.swift` (create)
- `Padium/PermissionsView.swift` (create)
- `Padium/PreemptionController.swift` (create)
- `Padium/Logger.swift` (create)
- `PadiumTests/GestureClassifierTests.swift` (create)
- `PadiumTests/GestureEngineTests.swift` (create)
- `PadiumTests/ShortcutRegistryTests.swift` (create)
- `PadiumTests/ShortcutEmitterTests.swift` (create)
- `PadiumTests/PermissionCoordinatorTests.swift` (create)

## Entry References
- `CLAUDE.md:19-25` — platform, UI shell, dependency count, sandbox constraint
- `CLAUDE.md:45-50` — branch/build workflow and manual verification gate
- `.claude/PRPs/prds/padium-trackpad.prd.md:118-125` — original technical stack, gesture abstraction, and permission deeplink direction
- `artifacts/libs/openmultitouchsupport-padium-mvp_19.55_13-04-2026.md:17-24` — OMS install path and version floor
- `artifacts/libs/keyboardshortcuts-padium-mvp_19.55_13-04-2026.md:21-36` — KeyboardShortcuts install path and platform support

## Exemplar
- Greenfield — follow SwiftUI `MenuBarExtra` app scaffolding plus SPM dependency wiring described in `CLAUDE.md:19-25` and `artifacts/libs/keyboardshortcuts-padium-mvp_19.55_13-04-2026.md:21-36`.

## Produces
- `C-01-project-skeleton`:
  - Signature: `Padium.xcodeproj + Padium app target + PadiumTests target + macOS 14 + Swift 6 strict concurrency + dependencies {OpenMultitouchSupport from 3.0.3, KeyboardShortcuts from 2.4.0}`
  - Behavior: Builds to a placeholder menubar app with all later-owned source and test files registered as compiling stubs, so downstream tasks do not need more project-file edits.
  - Validate: `xcodebuild -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' build` succeeds and the owned file list exists on disk.

## Tests
- **Skip reason**: This task is workspace scaffolding and build configuration only; the build itself is the evidence.

## Steps
1. Create the `Padium` macOS SwiftUI app target and `PadiumTests` test target inside `Padium.xcodeproj`.
2. Set the workspace baseline: macOS 14 minimum, Swift 6, strict concurrency checking complete, `LSUIElement=YES`, and App Sandbox disabled.
3. Add SwiftPM dependencies using `from: 3.0.3` for `OpenMultitouchSupport` and `from: 2.4.0` for `KeyboardShortcuts`.
4. Register every file in Owns as a compiling placeholder with self-documenting type names only; downstream tasks should refine these files instead of editing the project file again.
5. Make `Padium/PadiumApp.swift` build to a minimal `MenuBarExtra` placeholder so later waves have a stable entry point.

## Failure Modes
- **If the Xcode project keeps reformatting or reordering file references**: stop after the project builds once; do not churn the `.pbxproj` for cosmetic reasons.
- **If either dependency cannot be added at the planned version**: report the exact resolver error and stop with `Downstream action = escalate` rather than silently choosing another version.

## Guardrails
- Do not implement runtime gesture logic, permission flows, or shortcut behavior beyond placeholders.
- Do not add extra local packages, extra targets, launch-at-login code, or JSON config support.
- Do not leave any placeholder file unregistered if that would force downstream tasks to reopen the project file.

## Acceptance
- `xcodebuild -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' build`
  - Expected: `BUILD SUCCESS`

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

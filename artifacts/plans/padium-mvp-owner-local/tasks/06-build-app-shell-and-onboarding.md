# Task 06: Build app shell and permission onboarding

- **Agent**: venus
- **Skills**: swiftui-patterns, swift-concurrency-6-2, tdd-workflow
- **Wave**: 4
- **Complexity**: M

## Owns
- `Padium/PadiumApp.swift` (modify)
- `Padium/AppState.swift` (modify)
- `Padium/PermissionCoordinator.swift` (modify)
- `Padium/PermissionsView.swift` (modify)
- `Padium/Logger.swift` (modify)
- `PadiumTests/PermissionCoordinatorTests.swift` (modify)

## Prerequisites
- Tasks 01 and 03 completed and their contracts accepted.

## Entry References
- `PRODUCT-BRIEF.md:40-45` — menu bar icon + permission onboarding are part of MVP scope
- `.claude/PRPs/prds/padium-trackpad.prd.md:101-109` — intended launch/onboarding flow
- `.claude/PRPs/prds/padium-trackpad.prd.md:124-137` — permission and UX-risk guidance
- `CLAUDE.md:20-25` — `MenuBarExtra`, no dock icon, sandbox off
- `plans/padium-trackpad-mvp.md:351-373` — earlier onboarding expectations, useful as shape reference only

## Exemplar
- Greenfield — follow the SwiftUI `MenuBarExtra` + `@Observable` app-shell pattern from the loaded SwiftUI skill, while keeping permission logic in a coordinator instead of inside view bodies.

## Produces
- `C-06-app-shell`:
  - Signature: `@MainActor @Observable AppState { isEnabled: Bool, permissionState: PermissionState, systemGestureNotice: String?, isSettingsPresented: Bool }`
  - Behavior: Presents a menubar-only app shell, blocks core usage behind the required permission states, and exposes any Task 03 manual-disable notice in app state.
  - Validate: permission coordinator tests pass, build succeeds, and the app can present a menubar shell without reintroducing a dock icon.

## Consumes
- `C-01-project-skeleton` from Task 01:
  - Signature: `Padium.xcodeproj + Padium app target + PadiumTests target + macOS 14 + Swift 6 strict concurrency + dependencies wired`
  - Behavior: Provides the app entry, placeholder state, and test target.
- `C-03-preemption-policy` from Task 03:
  - Signature: `PreemptionPolicy { strategy, supportedGestures, ownerNotice? }`
  - Behavior: Supplies any required owner-facing manual-disable notice that the shell/onboarding must surface.

## Tests
- **Skip reason**: None for permission-state logic; purely visual layout validation remains manual.

## Steps
1. Write failing tests first for permission-state transitions that are non-obvious: missing permissions, granted permissions, and later revocation.
2. Implement `PermissionCoordinator` and `AppState` so permission logic, enable/disable state, and settings presentation are explicit and testable.
3. Build the menubar shell with `MenuBarExtra`, no dock icon, an enable toggle, and an “Open Settings” action only.
4. Build the onboarding surface for Accessibility + Input Monitoring, including system-settings deeplinks and the owner-facing notice from `C-03-preemption-policy` when required.
5. Keep visual views thin: delegate state checks to the coordinator/app state, and use `Logger` instead of ad hoc prints.

## Failure Modes
- **If a permission API behaves differently on the owner machine**: capture the actual state transition and amend the coordinator/tests rather than hardcoding the expected docs behavior.
- **If the shell starts showing a dock icon**: fix the app-shell configuration before proceeding; do not leave launch behavior ambiguous for later tasks.

## Guardrails
- Do not add launch-at-login, release packaging, or friend-facing setup copy.
- Do not bury permission failures inside view code or empty catches.
- Do not let the shell invent gesture availability; it must consume the policy produced by Task 03.

## Acceptance
- `xcodebuild test -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' -only-testing:PadiumTests/PermissionCoordinatorTests && xcodebuild -project Padium.xcodeproj -scheme Padium -destination 'platform=macOS' build`
  - Expected: permission coordinator tests pass and build succeeds
- Manual: launch the app and confirm it remains a menu bar app with no dock icon.

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

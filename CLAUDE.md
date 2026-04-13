# Padium Trackpad — Project Guide for Claude Code

**Repo:** https://github.com/dtateks/padium (private)
**Status:** Pre-Step 1 (planning complete, Xcode scaffolding pending)

## What this is

macOS menubar app that maps trackpad gestures (3/4-finger × tap/swipe) → keyboard shortcuts. Native Swift 6 + SwiftUI, target <20MB RAM, <50ms latency, macOS 14+.

## Read first

1. `PRODUCT-BRIEF.md` — why this exists, target user, success metrics
2. `.claude/PRPs/prds/padium-trackpad.prd.md` — full PRD with council decisions
3. `plans/padium-trackpad-mvp.md` — 12-step construction blueprint
4. `docs/adr/` — architectural decision records (0001-0003)

## Stack

- **Language:** Swift 6.0, strict concurrency
- **UI:** SwiftUI `MenuBarExtra` (`LSUIElement=YES`, no dock icon)
- **Min macOS:** 14 Sonoma
- **Dependencies (2 only):**
  - `OpenMultitouchSupport` (Kyome22, MIT) — trackpad gesture capture (ADR-0001)
  - `sindresorhus/KeyboardShortcuts` (MIT) — shortcut recorder UI + runtime store (ADR-0002)
- **App Sandbox:** disabled (private API requires it, and we're not targeting MAS)

## Relevant skills (use proactively)

### Swift/macOS (project-installed)
- **`swiftui-patterns`** — `MenuBarExtra`, state mgmt, navigation, performance
- **`swift-concurrency-6-2`** — Swift 6 strict concurrency, `@concurrent`, isolated conformances
- **`swift-actor-persistence`** — fits Step 7 ConfigStore (actor + atomic file I/O)
- **`swift-protocol-di-testing`** — fits Step 5 `GestureSource` protocol abstraction + Step 5-6 unit tests

### Workflow (project-installed)
- **`tdd-workflow`** — write tests first for Step 5 (classifier state machine), Step 6 (shortcut emitter), Step 7 (config)
- **`verification-loop`** — run before each PR merge
- **`security-review`** — invoke before Step 12 package-and-share (permission flow, IPC surface)
- **`strategic-compact`** — suggest when context gets heavy across multi-session work

## Rules (project-installed)

See `.claude/rules/` — Swift rules override common on overlapping concerns (coding-style, security, testing). Swift-specific: `patterns.md`, `hooks.md`, `testing.md`, `coding-style.md`, `security.md`. Common-only: `agents.md`, `code-review.md`, `development-workflow.md`, `git-workflow.md`, `performance.md`.

## Branching + PR conventions

- One branch per blueprint step: `feat/step-N-<slug>` or `spike/phase-0<x>-<slug>`
- Squash-merge to `main` with step name in commit subject
- No CI yet (v1 manual verification); `xcodebuild -scheme Padium build` is the gate
- Use `/commit` skill for commit message formatting

## Anti-goals (do not drift)

From PRODUCT-BRIEF.md — these are load-bearing:

- ❌ Per-app context (BTT territory)
- ❌ Shell script / AppleScript actions
- ❌ Pinch & rotate gestures
- ❌ 1-finger & 2-finger gestures (conflict with system)
- ❌ Triple tap/click (unreliable)
- ❌ Window management (Rectangle exists)
- ❌ Cloud sync / accounts / telemetry
- ❌ Mac App Store distribution (Sandbox-off per ADR-0001)

## Critical gates

- **Phase 0a** (Step 2, 2h): OMS finger-count detection — fail → STOP, no fallback
- **Phase 0c** (Step 4, 8h): `CGEventTap` preemption of macOS system gestures — fail → re-scope MVP (drop 3-finger swipes)

## Reference implementation (study, don't fork)

[MiddleDrag](https://github.com/NullPointerDepressiveDisorder/MiddleDrag) — same OMS + CGEventTap preemption pattern, MIT, active 2026-03. Read before Step 4.

## Current task state

See `TaskList` — 12 steps pending, Step 1 (Scaffold Xcode project) unblocked.

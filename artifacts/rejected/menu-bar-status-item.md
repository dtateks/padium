# Rejected: Menu bar status item (NSStatusItem / MenuBarExtra)

**Date:** 2026-05-16
**Status:** Rejected — do not re-propose without explicit owner request

## What was proposed

A SwiftUI `MenuBarExtra` scene exposing a status indicator icon, an "Open
Settings…" action, a "Pause/Resume Padium" toggle, and "Quit Padium" in
the macOS menu bar. The rationale was that Padium runs with
`LSUIElement=true` (no Dock icon) and is launch-at-login backgrounded,
so dismissing the Settings window leaves no in-app way to bring it back
short of a Spotlight/Finder relaunch.

## Why rejected

The owner explicitly does not want a menu bar entry for Padium. It is
viewed as redundant surface area, not a missing path. Relaunching via
Spotlight/Finder to reopen Settings is acceptable for the owner's
workflow.

## What still applies

Other Settings-window improvements built in the same loop remain valid
and are still wanted:

- Pause/Resume button in the Settings footer
- Inline conflict explanation banner (replacing the opaque
  "Fix System Conflicts" button)
- Opt-in on-screen gesture feedback HUD with a footer toggle

The `RuntimeStatus.paused` case, the `runtime.isPaused` UserDefaults
key, the `hud.gestureFeedback.enabled` UserDefaults key, and the
`GestureFeedbackPresenting` injection seam are all retained — they
just no longer have a menu bar surface.

## Constraint added by this rejection

Do not add a menu bar entry to Padium. Do not introduce features that
*require* a menu bar entry to be discoverable (e.g. "stay running on
missing permissions" only works if the user has a way back to Settings —
without a menu bar the original terminate-and-relaunch path is the
intended behaviour).

---
name: Menu bar status item
description: Padium does not expose an NSStatusItem / MenuBarExtra entry; Settings is the only owner-facing surface.
type: rejected
status: accepted
scope: PadiumApp scene tree
origin: user direction during /goal autonomous improvement loop, 2026-05-16
---

## Context

A SwiftUI `MenuBarExtra` scene exposing a status indicator icon, `Open Settings…`, `Pause/Resume Padium`, and `Quit Padium` was proposed and built. The motivation was that Padium runs with `LSUIElement=true` (no Dock icon) and background-launches at login, so dismissing the Settings window leaves no in-app way to bring it back short of a Spotlight/Finder relaunch.

## Why rejected

The owner explicitly rejected the menu bar entry as redundant ("feature thừa thãi") for their workflow. Relaunching via Spotlight/Finder to reopen Settings is acceptable; an always-visible menu bar icon adds attention surface they do not want. The rejection is durable: it applies to NSStatusItem, MenuBarExtra, and any equivalent always-visible system-bar surface, not just to the specific implementation that was rolled back.

## What we do instead

The Settings window is the only owner-facing surface — pause/resume, runtime status, and configuration all live there. When the Settings window is dismissed the user relaunches Padium via Spotlight/Finder to reopen it; this is the accepted recovery path. The handleAppLaunch terminate-on-missing-permissions behaviour remains, because without a menu bar there is no benefit to keeping the app alive after the user has been prompted.

## How to apply

- Do NOT suggest or build an NSStatusItem / MenuBarExtra / equivalent always-visible status-bar entry for Padium; instead route Padium status, pause/resume, and re-entry through the Settings window.
- Do NOT propose features whose discoverability or recovery path depends on having a menu bar entry (e.g. "stay running on missing permissions so the menu bar can guide the user back"). If a feature requires a menu bar surface to make sense, refuse it or redesign it for the Settings-only world.
- When Padium needs to be reopened, assume the owner uses Spotlight/Finder. Do not design around in-app reopen.
- If the owner later asks for a menu bar entry, treat this as a `prune` action (revoke this rejection with explicit approval) — do not silently flip the meaning.

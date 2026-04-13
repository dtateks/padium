# ADR-0001: Use OpenMultitouchSupport over NSEvent; abstract behind protocol

**Date**: 2026-04-13
**Status**: accepted
**Deciders**: Owner + 4-voice council (Architect, Skeptic, Pragmatist, Critic) via `/ecc:council`

## Context

Padium Trackpad MVP requires detecting **finger count** on tap and swipe gestures (3-finger vs 4-finger). Public `NSEvent` API exposes `NSEventTypeSwipe` direction but **does not** carry finger count, and `touches(matching:in:)` is explicitly documented as unsafe on mouse events. Apple provides no public API for raw trackpad contact data globally on macOS 14/15/26-beta. The private `MultitouchSupport.framework` has been the only viable route for 19 years (since macOS 10.5) and powers BetterTouchTool, Multitouch.app, MiddleDrag, Jitouch.

## Decision

Commit to `OpenMultitouchSupport` (Kyome22, MIT, v3.0.3) via SwiftPM from day 1. No NSEvent fallback. **Abstract the gesture source behind a `protocol GestureSource`** so the wrapper is swappable if Apple breaks the private API in a future macOS release.

## Alternatives Considered

### Alternative 1: NSEvent public API only
- **Pros**: No private-API risk, App Store compatible, no Sandbox-off requirement
- **Cons**: Cannot distinguish 3-finger vs 4-finger tap. Covers only ~4 of 12 MVP gesture slots.
- **Why not**: Killer constraint. Shipping a gesture app without finger-count discrimination means shipping a product no one (including owner) wants. Council 4/4 consensus rejected.

### Alternative 2: Hybrid OMS + NSEvent fallback
- **Pros**: Graceful degradation if OMS breaks on future macOS
- **Cons**: "Fallback" path ships <50% of promised gestures → still a broken product. Complexity doubles for no real resilience.
- **Why not**: Skeptic pointed out this is accepting a product nobody wants in exchange for imaginary safety. Better to own the private-API risk explicitly and pin versions.

### Alternative 3: Raw MultitouchSupport wrapper (DIY)
- **Pros**: No external dependency; full control.
- **Cons**: Reverse-engineering `MTDeviceCreateList` + palm rejection + thread-safety = weeks of work OMS already solved.
- **Why not**: OMS is MIT, actively maintained (Jan 2026), Swift 6 ready. Free-riding on a maintained wrapper beats reinventing.

## Consequences

### Positive
- Unblocks full 12-slot MVP (finger-count detection available)
- Community precedent: BTT, MiddleDrag, Multitouch.app all still work on macOS 26 beta — base rate for "Apple breaks this" is very low
- Protocol abstraction means future API swap is contained (Step 5 module boundary)

### Negative
- App Sandbox must be **disabled** → cannot ship to Mac App Store (acceptable; this is a private repo, .dmg-distributed app)
- Requires user to grant Accessibility permission (standard for this category of app)
- Tied to a private framework Apple does not document

### Risks
- **macOS 27 ships and breaks MultitouchSupport symbol layout** (~8 weeks away at WWDC 2026). Mitigation: pin OMS version in `Package.swift`, keep `GestureSource` protocol boundary clean, be prepared to fork or patch OMS when break happens. Historical base rate: 0 breaks in 19 years.
- **OMS maintainer stops updating**. Mitigation: fork into repo (vendored), keep patch-ready.

## References

- `.claude/PRPs/prds/padium-trackpad.prd.md` — technical approach section
- `/ecc:council` verdict (2026-04-13)
- OpenMultitouchSupport: https://github.com/Kyome22/OpenMultitouchSupport
- Reference impl: https://github.com/NullPointerDepressiveDisorder/MiddleDrag

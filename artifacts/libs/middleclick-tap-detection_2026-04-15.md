## Findings: MiddleClick 3-finger tap detection

### Research Metadata
- Question: How MiddleClick macOS app implements 3-finger tap detection from raw MultitouchSupport frames; which touch states count as active; exact flow from touch-down to tap recognition; how it distinguishes tap from resting finger or swipe
- Type: IMPLEMENTATION
- Target: artginzburg/MiddleClick
- Version Scope: `HEAD` at `21234476a51d58b87c4b8d6fdd7b49ce49147c8d` (shallow clone of the repository)
- Generated: 23.11_15-04-2026
- Coverage: COMPLETE

### Direct Answer
- Fact: MiddleClick does **not** inspect per-touch MultitouchSupport states like `touching`, `making`, `breaking`, or `lingering` for tap detection; its tap path is driven by the frame-level finger count `nFingers` plus per-frame touch positions from the raw `MTTouch` array [1][2].
- Trace: A 3-finger tap is recognized when the app sees a nonzero-finger frame to start timing, then later a zero-finger frame to end timing, with the intervening 3-finger frames kept within the configured time/distance limits [1][2].
- Fact: The exact thresholds are `maxDistanceDelta = 0.05` and `maxTimeDelta = 300 ms`; the code also suppresses repeated synthetic middle-clicks for `30%` of `maxTimeDelta` after the last emulation [2].
- Fact: Fingers resting on the trackpad are tolerated only insofar as they keep `nFingers > 0`; they do **not** complete a tap until a zero-finger frame arrives, and a long-held contact is disqualified once elapsed time exceeds `maxTimeDelta` [1][2].

### Key Findings
#### 1) Tap detection is frame-count driven, not per-touch-state driven

**Claim**: The implementation treats a tap as a gesture over frame transitions (`nFingers` and positions), not as a classification of `MTTouch` lifecycle states such as `touching`/`making`/`breaking`/`lingering` [1].

**Evidence** ([TouchHandler.swift#L30-L73](https://github.com/artginzburg/MiddleClick/blob/21234476a51d58b87c4b8d6fdd7b49ce49147c8d/MiddleClick/TouchHandler.swift#L30-L73) [1]):
```swift
private let touchCallback: MTFrameCallbackFunction = {
  _, data, nFingers, _, _ in
  guard !AppUtils.isIgnoredAppBundle() else { return }

  let state = GlobalState.shared

  state.threeDown =
  allowMoreFingers ? nFingers >= fingersQua : nFingers == fingersQua

  let handler = TouchHandler.shared

  guard handler.tapToClick else { return }

  guard nFingers != 0 else {
    handler.handleTouchEnd()
    return
  }
```

**Explanation**: The callback only receives `nFingers` and the raw `MTTouch` buffer; tap logic starts when `nFingers > 0` and ends when `nFingers == 0`. There is no branching on individual touch-state enums in this file, so the algorithm is effectively state-agnostic at the per-touch lifecycle level.

- Trace: The raw `MTTouch` positions are only summed for the first `fingersQua` touches in `processTouches(data:nFingers:)`, not filtered by touch-state flags [1].

#### 2) Exact flow from touch-down to tap recognition

**Claim**: The gesture flow is: first nonzero-finger frame starts a candidate, subsequent qualifying frames accumulate positions, zero-finger frame closes the candidate, and the final displacement/time check decides whether to synthesize a middle click [1][2].

**Evidence** ([TouchHandler.swift#L48-L117](https://github.com/artginzburg/MiddleClick/blob/21234476a51d58b87c4b8d6fdd7b49ce49147c8d/MiddleClick/TouchHandler.swift#L48-L117) [1][2]):
```swift
let isTouchStart = nFingers > 0 && handler.touchStartTime == nil
if isTouchStart {
  handler.touchStartTime = Date()
  handler.maybeMiddleClick = true
  handler.middleClickPos1 = .zero
} else if handler.maybeMiddleClick, let touchStartTime = handler.touchStartTime {
  // Timeout check for middle click
  let elapsedTime = -touchStartTime.timeIntervalSinceNow
  if elapsedTime > maxTimeDelta {
    handler.maybeMiddleClick = false
  }
}

guard !(nFingers < fingersQua) else { return }

if !allowMoreFingers && nFingers > fingersQua {
  handler.resetMiddleClick()
}

let isCurrentFingersQuaAllowed = allowMoreFingers ? nFingers >= fingersQua : nFingers == fingersQua
guard isCurrentFingersQuaAllowed else { return }

handler.processTouches(data: data, nFingers: nFingers)
```

```swift
private func handleTouchEnd() {
  guard let startTime = touchStartTime else { return }

  let elapsedTime = -startTime.timeIntervalSinceNow
  touchStartTime = nil

  guard middleClickPos1.isNonZero && elapsedTime <= Self.maxTimeDelta else { return }

  let delta = middleClickPos1.delta(to: middleClickPos2)
  if delta < Self.maxDistanceDelta && !shouldPreventEmulation() {
    Self.emulateMiddleClick()
  }
}
```

**Explanation**: The candidate begins on the first nonzero-finger frame (`touchStartTime` and `maybeMiddleClick` are set). While the fingers remain down, each qualifying frame is accepted only if it matches the required finger count policy. The gesture ends on the first zero-finger frame, at which point the code compares total elapsed time and summed positional drift before generating a synthetic middle click.

#### 3) Exact thresholds and the swipe-vs-tap separation

**Claim**: The tap window allows at most `0.05` normalized-distance drift and `300 ms` total duration; anything longer is rejected as a tap candidate [2].

**Evidence** ([Config.swift#L8-L18](https://github.com/artginzburg/MiddleClick/blob/21234476a51d58b87c4b8d6fdd7b49ce49147c8d/MiddleClick/Config.swift#L8-L18) [2]):
```swift
@UserDefault("fingers")
var minimumFingers = 3

@UserDefault var allowMoreFingers = false

@UserDefault var maxDistanceDelta: Float = 0.05

/// In milliseconds
@UserDefault(transformGet: { $0 / 1000 })
var maxTimeDelta = 300.0
```

**Evidence** ([TouchHandler.swift#L108-L116](https://github.com/artginzburg/MiddleClick/blob/21234476a51d58b87c4b8d6fdd7b49ce49147c8d/MiddleClick/TouchHandler.swift#L108-L116) [1][2]):
```swift
guard middleClickPos1.isNonZero && elapsedTime <= Self.maxTimeDelta else { return }

let delta = middleClickPos1.delta(to: middleClickPos2)
if delta < Self.maxDistanceDelta && !shouldPreventEmulation() {
  Self.emulateMiddleClick()
}
```

**Explanation**: A swipe is effectively rejected because the summed point movement (`delta`) must stay below the configured maximum. A slow press is also rejected because the candidate must finish within `maxTimeDelta`. The code does not contain a separate swipe classifier in this tap path; it uses displacement and duration as the swipe/tap separator.

#### 4) Which touch lifecycle states count as “active”

**Claim**: For tap detection, “active” means only that the frame reports at least `minimumFingers` touches (or `>=` when `allowMoreFingers` is enabled); the implementation does not further narrow that set by touch lifecycle state [1][2].

**Evidence** ([TouchHandler.swift#L36-L70](https://github.com/artginzburg/MiddleClick/blob/21234476a51d58b87c4b8d6fdd7b49ce49147c8d/MiddleClick/TouchHandler.swift#L36-L70) [1]):
```swift
state.threeDown =
allowMoreFingers ? nFingers >= fingersQua : nFingers == fingersQua
...
guard !(nFingers < fingersQua) else { return }
...
let isCurrentFingersQuaAllowed = allowMoreFingers ? nFingers >= fingersQua : nFingers == fingersQua
guard isCurrentFingersQuaAllowed else { return }
```

**Explanation**: The code’s active/inactive decision is purely count-based. The raw touch array is only sampled after the frame passes the finger-count gate, and the count gate is the only lifecycle filter visible here.

#### 5) Resting fingers / lingering contacts

**Claim**: Resting fingers do not immediately count as a tap; they are only part of a tap candidate while `nFingers > 0`, and the candidate must eventually end on `nFingers == 0`. If the fingers linger too long, the candidate is invalidated by the time limit before the lift frame [1][2].

**Evidence** ([TouchHandler.swift#L48-L59](https://github.com/artginzburg/MiddleClick/blob/21234476a51d58b87c4b8d6fdd7b49ce49147c8d/MiddleClick/TouchHandler.swift#L48-L59) [1][2]):
```swift
let isTouchStart = nFingers > 0 && handler.touchStartTime == nil
if isTouchStart {
  handler.touchStartTime = Date()
  handler.maybeMiddleClick = true
  handler.middleClickPos1 = .zero
} else if handler.maybeMiddleClick, let touchStartTime = handler.touchStartTime {
  // Timeout check for middle click
  let elapsedTime = -touchStartTime.timeIntervalSinceNow
  if elapsedTime > maxTimeDelta {
    handler.maybeMiddleClick = false
  }
}
```

**Explanation**: Lingering contact keeps the candidate alive only until the timeout expires. Once timed out, the later lift frame will not synthesize a click because `maybeMiddleClick` has been cleared and the duration check fails.

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `touchCallback` | Receives each raw multitouch frame, gets `nFingers`, and gates tap handling on `tapToClick` and non-ignored apps. | [1] |
| 2 | `touchCallback` | On the first nonzero-finger frame, starts a candidate by recording `touchStartTime` and setting `maybeMiddleClick = true`. | [1] |
| 3 | `touchCallback` | While fingers remain down, enforces the finger-count policy (`== 3` by default) and accumulates touch positions only for qualifying frames. | [1][2] |
| 4 | `handleTouchEnd()` | On the first zero-finger frame, computes elapsed time and rejects the candidate if it exceeded `300 ms`. | [1][2] |
| 5 | `handleTouchEnd()` | Computes Manhattan-like drift (`abs(dx)+abs(dy)`) and rejects if drift is at least `0.05`; otherwise emits a synthetic middle click unless recently blocked by a natural click. | [1][2] |

### Change Context
- History: No issue/PR rationale was needed to answer the implementation question; the current repository head and config values fully determine the tap algorithm [1][2].

### Caveats and Gaps
- The repository’s tap path does not expose or use named MultitouchSupport touch-state enums in the inspected code, so this research cannot confirm how the underlying framework labels `touching`/`making`/`breaking`/`lingering` internally; it can only confirm that MiddleClick itself ignores those distinctions here [1].
- `allowMoreFingers` is configurable, but the default tap target is 3 fingers via `minimumFingers = 3` [2].

### Confidence
**Level:** HIGH
**Rationale:** The governing tap path and thresholds are directly visible in the inspected source at an immutable commit, and the answer is supported by the exact code that starts, filters, times out, and finalizes the gesture [1][2].

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | code | MiddleClick `TouchHandler.swift` | `21234476a51d58b87c4b8d6fdd7b49ce49147c8d` lines 30-147 | Governs candidate start/end, frame gating, displacement check, and emulation | [GitHub permalink](https://github.com/artginzburg/MiddleClick/blob/21234476a51d58b87c4b8d6fdd7b49ce49147c8d/MiddleClick/TouchHandler.swift#L30-L147) |
| [2] | code | MiddleClick `Config.swift` | `21234476a51d58b87c4b8d6fdd7b49ce49147c8d` lines 8-18 | Defines the exact finger count and timing/distance thresholds | [GitHub permalink](https://github.com/artginzburg/MiddleClick/blob/21234476a51d58b87c4b8d6fdd7b49ce49147c8d/MiddleClick/Config.swift#L8-L18) |

### Evidence Appendix
```swift
// Helper used by the tap path to measure drift between the two accumulated samples.
extension SIMD2 where Scalar: FloatingPoint {
  func delta(to other: SIMD2) -> Scalar {
    return abs(x - other.x) + abs(y - other.y)
  }
}
```

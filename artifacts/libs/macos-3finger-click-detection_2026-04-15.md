## Findings: macOS 3-finger click detection

### Research Metadata
- Question: How macOS trackpad 3-finger physical click appears in raw MultitouchSupport/OpenMultitouchSupport, how MiddleClick and MiddleDrag detect it, whether there is a separate click event, and why MiddleClick can use a 300ms window for both click and tap
- Type: MIXED
- Target: macOS MultitouchSupport/OpenMultitouchSupport behavior; artginzburg/MiddleClick; NullPointerDepressiveDisorder/MiddleDrag
- Version Scope: MiddleClick `HEAD` at `21234476a51d58b87c4b8d6fdd7b49ce49147c8d`; MiddleDrag `HEAD` at `5b6654a818ac2a629c1fb1b619acbbcab3b88df0`; README/release metadata fetched 2026-04-15
- Generated: 23.44_15-04-2026
- Coverage: PARTIAL

### Direct Answer
- Fact: In both projects, a 3-finger physical click is not handled as a separate MultitouchSupport “click event”; it is recognized from touch-frame data plus `CGEvent`/event-tap mouse events, and MiddleClick’s tap path itself only sees raw frame timing/counts, not a dedicated click signal [1][2][3][4].
- Fact: MiddleClick’s `300 ms` window is for the **tap** path; its README explicitly advertises “three finger Click or Tap,” but the inspected code shows no separate physical-click detector in the tap code, only frame timing, finger count, and movement checks [1][2].
- Trace: MiddleDrag does have a separate physical-click path: a CGEvent tap converts a left mouse down/up into a middle click when `currentFingerCount >= 3`, then deduplicates that against the gesture-recognizer tap path with a 500 ms window [3][4].
- Caveat: The exact raw MultitouchSupport frame sequence for a Force Touch press (state transitions, persistence, and before/after ordering) is not documented in these repositories’ source; the repositories confirm how they consume it, not the framework’s internal frame semantics [1][2][3][4].

### Key Findings
#### 1) MiddleClick’s “click or tap” is not two different raw-touch detectors in the inspected code

**Claim**: MiddleClick’s implementation supports “Click or Tap” in the product copy, but the inspected source only shows one raw-touch tap detector; it does not branch on a separate physical-click signal in the MultitouchSupport stream [1][2].

**Evidence** ([README.md](https://raw.githubusercontent.com/artginzburg/MiddleClick/main/README.md) [1]):
```markdown
Emulate a scroll wheel click with three finger Click or Tap on MacBook trackpad and Magic Mouse
```

**Evidence** ([TouchHandler.swift#L30-L117](https://github.com/artginzburg/MiddleClick/blob/21234476a51d58b87c4b8d6fdd7b49ce49147c8d/MiddleClick/TouchHandler.swift#L30-L117) [2]):
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

**Explanation**: The exposed code only has a frame callback keyed on `nFingers`, then a timeout/drift check. There is no separate physical-click callback or event-type branch in the tap path, so the “Click” wording is not backed by a distinct raw-touch detector in the inspected source.

#### 2) MiddleClick’s 300 ms window is a release-bound tap window, not a press-duration ceiling for a separate click signal

**Claim**: MiddleClick starts timing on the first nonzero-finger frame and only commits on the first zero-finger frame; the 300 ms window bounds total candidate duration, not some hidden “click” subevent [2].

**Evidence** ([TouchHandler.swift#L48-L117](https://github.com/artginzburg/MiddleClick/blob/21234476a51d58b87c4b8d6fdd7b49ce49147c8d/MiddleClick/TouchHandler.swift#L48-L117) [2]):
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
...
private func handleTouchEnd() {
  guard let startTime = touchStartTime else { return }

  let elapsedTime = -startTime.timeIntervalSinceNow
  touchStartTime = nil

  guard middleClickPos1.isNonZero && elapsedTime <= Self.maxTimeDelta else { return }
```

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

**Explanation**: The 300 ms is a full-gesture timeout from first contact frame to lift frame. A “physical click” can still fit in that window if the press/release is quick enough, but the code does not prove a separate click-channel exists.

#### 3) MiddleDrag explicitly separates physical-click conversion from tap recognition

**Claim**: MiddleDrag has two pathways: a force-click path that watches CG left-mouse events while `currentFingerCount >= 3`, and a gesture-recognizer tap path that handles the raw touch frames; both can call `performClick()`, so it deduplicates them [3][4].

**Evidence** ([MultitouchManager.swift#L772-L789](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Managers/MultitouchManager.swift#L772-L789) [3]):
```swift
let hasThreeOrMoreFingers = currentFingerCount >= 3
if hasThreeOrMoreFingers && isLeftButton && !isOurEvent && !isActivelyDragging && !shouldPassThroughCurrentGesture {
    // Check event type - we want to handle both down and up
    if type == .leftMouseDown || type == .leftMouseUp {
        // Perform middle click instead
        if type == .leftMouseDown {
            lastForceClickTime = CACurrentMediaTime()
            mouseGenerator.performClick()
        }
        // Suppress the original left click
        return nil
    }
}
```

**Evidence** ([MultitouchManager.swift#L917-L939](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Managers/MultitouchManager.swift#L917-L939) [3]):
```swift
let timeSinceForceClick = CACurrentMediaTime() - lastForceClickTime
if timeSinceForceClick < forceClickDeduplicationWindow {
    // Still reset gesture state
    DispatchQueue.main.async { [weak self] in
        self?.isInThreeFingerGesture = false
        self?.isActivelyDragging = false
        self?.gestureEndTime = CACurrentMediaTime()
        self?.lastGestureWasActive = true  // Force click was active
    }
    return
}
```

**Evidence** ([GestureRecognizer.swift#L70-L80](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Core/GestureRecognizer.swift#L70-L80) [4]):
```swift
// Collect only valid touching fingers (state 3 = touching down, state 4 = active)
// Skip state 5 (lifting), 6 (lingering), 7 (gone)
var validFingers: [MTPoint] = []

for i in 0..<count {
    let touch = unsafe touchArray[i]
    if touch.state == 3 || touch.state == 4 {
```

**Explanation**: This is the clearest evidence for how a project can “support clicks and taps” without assuming a separate raw-touch click event. MiddleDrag watches the mouse event stream for force-clicks and the touch stream for taps.

#### 4) MiddleDrag’s timing shows why a 300 ms window can still work for a physical click

**Claim**: MiddleDrag’s default tap threshold is 150 ms, but it also allows up to 500 ms hold time, meaning it is designed around touch duration rather than assuming the press must be ultra-short [4].

**Evidence** ([GestureModels.swift#L32-L35](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Models/GestureModels.swift#L32-L35) [4]):
```swift
// Timing thresholds
var tapThreshold: Double = 0.15  // 150ms for tap detection
var maxTapHoldDuration: Double = 0.5  // 500ms max hold for tap (safety check)
var moveThreshold: Float = 0.015  // Movement threshold for tap vs drag
```

**Explanation**: A physical click does not need to be faster than 300 ms to be recognized by code like this; the app can decide based on the release frame plus motion constraints. MiddleClick’s 300 ms window is consistent with this kind of release-based recognition.

#### 5) What the repositories do and do not prove about raw MultitouchSupport ordering

**Claim**: These sources prove how the apps consume the stream, but not whether the Force Touch “haptic click” happens before or after contacts appear in the raw MultitouchSupport stream [2][3][4].

**Evidence** ([MultitouchFramework.swift#L10-L24](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Core/MultitouchFramework.swift#L10-L24) [4]):
```swift
/// Callback function type for receiving touch frame data
/// - Parameters:
///   - device: The device that generated the touches
///   - touches: Pointer to array of touch data
///   - numTouches: Number of touches in the array
///   - timestamp: Timestamp of the touch frame
///   - frame: Frame number
/// - Returns: 0 to pass through to system, non-zero to consume
typealias MTContactCallbackFunction = @convention(c) (
    MTDeviceRef?,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Int32
```

**Explanation**: The framework binding only exposes touch-frame callbacks. No source here documents an extra “click event” arriving from MultitouchSupport ahead of or behind the frame stream. To answer ordering precisely, the needed source would be framework docs, reverse-engineered traces, or an instrumented dump of raw frames during a real Force Touch press.

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | MiddleClick `touchCallback` | Receives raw touch frames, gates on `nFingers`, and starts timing on the first nonzero-finger frame. | [2] |
| 2 | MiddleClick `handleTouchEnd()` | On the first zero-finger frame, checks elapsed time and motion against the tap thresholds before emitting synthetic middle click. | [2] |
| 3 | MiddleDrag `processEvent(_:type:)` | Watches CG mouse events; when a left click occurs with `currentFingerCount >= 3`, it converts that physical click to a middle click and suppresses the original left click. | [3] |
| 4 | MiddleDrag `gestureRecognizerDidTap` | Separately handles touch-based taps, deduplicating against recent force-click conversions. | [3] |
| 5 | MiddleDrag `GestureRecognizer` | Filters raw touches by `state == 3 || state == 4`, then classifies tap vs drag based on elapsed time and movement thresholds. | [4] |

### Change Context
- History: MiddleClick’s latest release notes explicitly say it supports “Click or Tap,” but the inspected implementation still shows a single frame-based tap path; MiddleDrag’s implementation shows the more explicit dual-path design with force-click conversion plus gesture tap recognition [1][2][3][4].

### Caveats and Gaps
- The exact raw MultitouchSupport/OpenMultitouchSupport frame sequence for a physical Force Touch click is not established here; neither repository logs the complete upstream frame semantics for press-before-release ordering [2][3][4].
- I did not find a source in these repos that proves a separate CGEvent/NSEvent specifically named as the physical trackpad click; MiddleDrag instead intercepts normal left mouse events and turns them into middle clicks [3].
- “Typical duration” for a physical 3-finger click is not directly measured in these sources; the only hard timing values here are app thresholds (`150 ms`, `300 ms`, `500 ms`) and dedup windows (`500 ms`) [2][4].

### Confidence
**Level:** MEDIUM
**Rationale:** The app-level detection mechanisms and thresholds are directly evidenced, but the framework-level ordering/duration questions are only partially supported by these sources and remain uncertain without a raw frame capture or Apple documentation.

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | docs | MiddleClick README | main branch fetched 2026-04-15 | Establishes the product claim “Click or Tap” and default tap settings | [README.md](https://raw.githubusercontent.com/artginzburg/MiddleClick/main/README.md) |
| [2] | code | MiddleClick `TouchHandler.swift` and `Config.swift` | `21234476a51d58b87c4b8d6fdd7b49ce49147c8d` | Governs the only inspected raw-touch tap path and its 300 ms window | [TouchHandler.swift](https://github.com/artginzburg/MiddleClick/blob/21234476a51d58b87c4b8d6fdd7b49ce49147c8d/MiddleClick/TouchHandler.swift#L30-L147), [Config.swift](https://github.com/artginzburg/MiddleClick/blob/21234476a51d58b87c4b8d6fdd7b49ce49147c8d/MiddleClick/Config.swift#L8-L18) |
| [3] | code | MiddleDrag `MultitouchManager.swift` | `5b6654a818ac2a629c1fb1b619acbbcab3b88df0` | Shows the separate physical-click conversion path and deduplication | [MultitouchManager.swift](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Managers/MultitouchManager.swift#L772-L789), [MultitouchManager.swift](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Managers/MultitouchManager.swift#L917-L939) |
| [4] | code | MiddleDrag `GestureRecognizer.swift`, `GestureModels.swift`, `MultitouchFramework.swift` | `5b6654a818ac2a629c1fb1b619acbbcab3b88df0` | Shows raw touch-state filtering and the tap/hold thresholds | [GestureRecognizer.swift](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Core/GestureRecognizer.swift#L70-L80), [GestureModels.swift](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Models/GestureModels.swift#L32-L35), [MultitouchFramework.swift](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Core/MultitouchFramework.swift#L10-L24) |

## Findings: macOS trackpad click-vs-tap event discrimination

### Research Metadata
- Question: Can macOS CGEvent/NSEvent or trackpad-related event data reliably distinguish a trackpad tap-to-click from a physical trackpad click/force click, especially for multi-finger gestures?
- Type: MIXED
- Target: macOS public gesture docs + open-source event-tap implementations
- Version Scope: Apple Support page published 2026-02-24; open-source implementations fetched 2026-04-16; no Apple public API contract found that exposes a dedicated low-level “trackpad tap” vs “physical click” event type
- Generated: 08.30_16-04-2026
- Coverage: PARTIAL

### Direct Answer
- Fact: Apple publicly documents the user-visible gestures, not a separate public event classification for “tap” versus “physical click”; the support page describes tap-to-click, secondary click, Smart Zoom, and Force click as gestures, but does not expose a distinct CGEvent/NSEvent field that says which one occurred [1].
- Fact: In open-source macOS tooling, multi-finger trackpad taps are commonly recognized from raw multitouch frames, while physical clicks are often inferred from the resulting mouse event stream or from separate hardware/state cues; this split is visible in two independent implementations [2][3].
- Fact: A trackpad tap-to-click can still result in ordinary `leftMouseDown`/`leftMouseUp` events, so event taps that only see mouse-button events cannot reliably assume those events are “physical clicks” rather than taps [2][3].
- Trace: The most reliable separation pattern shown in the sources is to use raw touch-frame data for tap gestures and a separate CGEvent mouse-button path for physical-click-style handling, then deduplicate when both paths can fire [2][3].

### Key Findings
#### Public contract: Apple documents gestures, not a low-level tap/click discriminator

**Claim**: Apple’s public Mac gesture documentation describes tap-to-click and Force click as distinct user gestures, but it does not document a public CGEvent/NSEvent field or event type that reliably labels one as a tap versus a physical click [1].

**Evidence** ([Apple Support: Use Multi-Touch gestures on Mac](https://support.apple.com/en-us/102482) [1]):
```text
**Tap to click**

Tap with one finger to click.

If your trackpad supports Force Touch, you can also Force click and get haptic feedback.
```

**Evidence** ([same page](https://support.apple.com/en-us/102482) [1]):
```text
**Secondary click (right-click)**

Click or tap with two fingers.
```

**Explanation**: Apple publicly confirms that both tap-style and click-style gestures exist on the trackpad, and that some gestures are configurable in Trackpad settings, but this page does not define a machine-readable event attribute that distinguishes them at the CGEvent/NSEvent layer.

#### Tap and click can both surface as ordinary mouse events

**Claim**: Open-source macOS event-tap code shows that trackpad tap gestures and physical-click handling can both enter the app as ordinary mouse-button events, which means mouse-event fields alone are not a reliable tap-vs-click discriminator [2][3].

**Evidence** ([ButtonInputReceiver.m#L60-L112](https://raw.githubusercontent.com/noah-nuebling/mac-mouse-fix/master/Helper/Core/Buttons/ButtonInputReceiver.m) [2]):
```objective-c
CGEventMask mask =
CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp);
//    | CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp)
//    | CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp);

...

NSUInteger buttonNumber = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber) + 1;
BOOL mouseDown = CGEventGetIntegerValueField(event, kCGMouseEventPressure) != 0;
```

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
```

**Explanation**: One implementation treats `kCGMouseEventPressure` as the down/up discriminator for button events, while another explicitly intercepts `leftMouseDown`/`leftMouseUp` when three fingers are present. Together, they show that trackpad-originated gestures are not guaranteed to arrive as a uniquely identifiable event subtype; downstream code often sees plain mouse-button events and must rely on context.

#### Multi-finger taps are especially ambiguous

**Claim**: For multi-finger gestures, the safer pattern is to inspect raw touch frames for the tap path and treat mouse-button events as a separate physical-click path, because the sources show both can be present in the same overall interaction model [2][3].

**Evidence** ([GestureRecognizer.swift#L70-L80](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Core/GestureRecognizer.swift#L70-L80) [3]):
```swift
// Collect only valid touching fingers (state 3 = touching down, state 4 = active)
// Skip state 5 (lifting), 6 (lingering), 7 (gone)
var validFingers: [MTPoint] = []

for i in 0..<count {
    let touch = unsafe touchArray[i]
    if touch.state == 3 || touch.state == 4 {
```

**Evidence** ([MultitouchManager.swift#L917-L939](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Managers/MultitouchManager.swift#L917-L939) [3]):
```swift
let timeSinceForceClick = CACurrentMediaTime() - lastForceClickTime
if timeSinceForceClick < forceClickDeduplicationWindow {
    // Still reset gesture state
    DispatchQueue.main.async { [weak self] in
        self?.isInThreeFingerGesture = false
        self?.isActivelyDragging = false
```

**Explanation**: The raw-touch path tracks finger states directly, while the mouse-event path needs a dedup window to avoid double-handling the same user action. That is strong evidence that a trackpad tap and a physical click can overlap in the event surface enough to require explicit arbitration.

#### Can pressure, subtype, click state, or source fields solve it?

**Claim**: The inspected sources do not establish any CGEvent/NSEvent field combination that reliably and universally distinguishes tap-to-click from physical click for trackpad gestures; the observed implementations use context and deduplication rather than a single definitive field [2][3].

**Evidence** ([ButtonInputReceiver.m#L95-L112](https://raw.githubusercontent.com/noah-nuebling/mac-mouse-fix/master/Helper/Core/Buttons/ButtonInputReceiver.m) [2]):
```objective-c
NSUInteger buttonNumber = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber) + 1;
BOOL mouseDown = CGEventGetIntegerValueField(event, kCGMouseEventPressure) != 0;

/// Filter buttons
if ([_buttonParseBlacklist containsObject:@(buttonNumber)]) return event;
```

**Explanation**: This code uses button number plus pressure to infer button state, but it does not establish pressure as a tap-vs-click classifier. The same snippet also logs `NSEvent eventWithCGEvent:event`, showing that the event bridge itself is still just a mouse event to the app. No source here proves that `subtype`, `eventNumber`, `sourceStateID`, or `pressure` alone can separate tap and physical click reliably.

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | Apple Support gesture docs | Describes tap-to-click and Force click as user gestures, but not as distinct public event payloads. | [1] |
| 2 | `ButtonInputReceiver.eventTapCallback` | Receives mouse-button events and reads `buttonNumber` plus `kCGMouseEventPressure` from `CGEvent`. | [2] |
| 3 | `MultitouchManager.processEvent` | Treats `leftMouseDown`/`leftMouseUp` as a physical-click path when three or more fingers are active. | [3] |
| 4 | `GestureRecognizer` | Separately classifies raw touch frames by touch state. | [3] |
| 5 | Dedup window in `MultitouchManager` | Prevents the mouse-event path and touch-gesture path from double-firing on the same user action. | [3] |

### Caveats and Gaps
- I did not find a public Apple API contract that explicitly says “this CGEvent/NSEvent field distinguishes tap-to-click from physical click.” The evidence supports the opposite: apps usually infer from context and raw touch frames [1][2][3].
- The sources do not prove the exact raw frame ordering for every Mac model or Force Touch implementation; they only show how real tools consume the stream [2][3].
- The `pressure` field appears in mouse-event handling, but none of the sources demonstrate that it is a stable, universal discriminator for tap versus physical click across multi-finger gestures [2][3].

### Confidence
**Level:** MEDIUM
**Rationale:** The public Apple gesture semantics are clear, and two independent implementations show the practical separation pattern. However, the sources do not include an Apple-authored low-level API contract that definitively rules in or out every candidate CGEvent/NSEvent field.

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | docs | Apple Support: Use Multi-Touch gestures on Mac | Published 2026-02-24 | Authoritative public gesture semantics for tap-to-click, secondary click, and Force click | [support.apple.com/en-us/102482](https://support.apple.com/en-us/102482) |
| [2] | code | Mac Mouse Fix `ButtonInputReceiver.m` | `main` fetched 2026-04-16 | Shows CGEvent mouse-button handling with `buttonNumber` and `kCGMouseEventPressure` | [raw.githubusercontent.com/noah-nuebling/mac-mouse-fix/master/Helper/Core/Buttons/ButtonInputReceiver.m](https://raw.githubusercontent.com/noah-nuebling/mac-mouse-fix/master/Helper/Core/Buttons/ButtonInputReceiver.m) |
| [3] | code | MiddleDrag `MultitouchManager.swift` / `GestureRecognizer.swift` | `5b6654a818ac2a629c1fb1b619acbbcab3b88df0` | Shows multi-finger physical-click interception plus separate raw-touch tap classification and deduplication | [MultitouchManager.swift](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Managers/MultitouchManager.swift#L772-L789), [MultitouchManager.swift](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Managers/MultitouchManager.swift#L917-L939), [GestureRecognizer.swift](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Core/GestureRecognizer.swift#L70-L80) |

## Findings: macOS trackpad pressure / mouse-event discriminator

### Research Metadata
- Question: Does `kCGMouseEventPressure` or any other mouse-event field reliably differ between trackpad tap-to-click and physical trackpad click on macOS, especially in event tap handlers?
- Type: MIXED
- Target: Apple public docs + open-source macOS event-tap implementations + existing local artifact reuse
- Version Scope: Apple Developer docs surfaced 2026-04-16; Apple Support gesture page published 2026-02-24; open-source examples fetched 2026-04-16; no Apple public contract found that guarantees a tap-vs-click discriminator at the CGEvent/NSEvent layer
- Generated: 08.33_16-04-2026
- Coverage: PARTIAL

### Direct Answer
- Fact: I found no Apple-documented CGEvent/NSEvent field that is publicly specified as a reliable tap-to-click vs physical-click discriminator on trackpads; Apple’s public material describes the gestures but not a dedicated low-level field for telling them apart [1][2].
- Fact: `CGEvent.getIntegerValueField(_:)` is the documented accessor for integer event fields, and Apple documents `CGEventField.mouseEventSubtype` as a mouse-event integer field; however, the docs excerpt available here does not state that either `mouseEventSubtype` or `kCGMouseEventPressure` distinguishes tap-to-click from physical click [1][2].
- Trace: Open-source handlers commonly treat touch-frame data as the tap signal and mouse-button events as a separate path, which is consistent with the absence of a single trustworthy mouse-event field for tap-vs-click separation [3][4].
- Synthesis: For event-tap handlers, the evidence supports using surrounding context or separate multitouch input if you need to discriminate tap gestures; it does not support relying on pressure alone as a universal classifier [3][4].

### Key Findings
#### Apple’s public contract: event fields are documented, but not as tap-vs-click labels

**Claim**: Apple documents the generic CGEvent field access API and the existence of mouse-event subtype fields, but the public docs found here do not say that any mouse-event field distinguishes trackpad tap-to-click from physical click [1][2].

**Evidence** ([CGEvent docs](https://developer.apple.com/documentation/coregraphics/cgevent) [1]):
```text
Low-level hardware events of this type are referred to as Quartz events.
...
`getIntegerValueField(_:)` Returns the integer value of a field in a Quartz event.
...
`setIntegerValueField(_:value:)`
Sets the integer value of a field in a Quartz event.
```

**Evidence** ([CGEventField.mouseEventSubtype](https://developer.apple.com/documentation/coregraphics/cgeventfield/mouseeventsubtype) [2]):
```text
Key to access an integer field that encodes the mouse event subtype as a `kCFNumberIntType`.
```

**Explanation**: These are real public fields/APIs, but the excerpts do not attach any semantic guarantee like “tap-to-click” or “physical click.” So they establish that event fields exist, not that one of them reliably separates the two trackpad interactions.

#### Open-source event-tap code treats pressure as a button-state cue, not a universal tap classifier

**Claim**: In one widely cited open-source handler, `kCGMouseEventPressure` is used to infer mouse-down state from mouse events, not to prove tap-to-click vs physical-click origin [3].

**Evidence** ([ButtonInputReceiver.m#L46-L55](https://raw.githubusercontent.com/noah-nuebling/mac-mouse-fix/master/Helper/Core/Buttons/ButtonInputReceiver.m) [3]):
```objective-c
CGEventMask mask =
CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp);
//    | CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp)
//    | CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp);

...

NSUInteger buttonNumber = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber) + 1;
BOOL mouseDown = CGEventGetIntegerValueField(event, kCGMouseEventPressure) != 0;
```

**Explanation**: This code reads pressure alongside button number to decide state inside a mouse-event handler. It shows pressure is usable as an event-state bit in that implementation, but it does not establish pressure as a reliable discriminator for “tap-to-click” versus “physical click.”

#### Separate touch-frame and mouse-event paths are used when the distinction matters

**Claim**: Another implementation processes raw multitouch frames for tap detection and separately handles mouse-button events when fingers are active, implying that the mouse-event stream alone is insufficient for clean tap-vs-click separation [4].

**Evidence** ([MultitouchManager.swift#L772-L789](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Managers/MultitouchManager.swift#L772-L789) [4]):
```swift
let hasThreeOrMoreFingers = currentFingerCount >= 3
if hasThreeOrMoreFingers && isLeftButton && !isOurEvent && !isActivelyDragging && !shouldPassThroughCurrentGesture {
    // Check event type - we want to handle both down and up
    if type == .leftMouseDown || type == .leftMouseUp {
        // Perform middle click instead
        if type == .leftMouseDown {
            lastForceClickTime = CACurrentMediaTime()
            mouseGenerator.performClick()
```

**Evidence** ([GestureRecognizer.swift#L70-L85](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Core/GestureRecognizer.swift#L70-L85) [4]):
```swift
// Collect only valid touching fingers (state 3 = touching down, state 4 = active)
// Skip state 5 (lifting), 6 (lingering), 7 (gone)
var validFingers: [MTPoint] = []

for i in 0..<count {
    let touch = unsafe touchArray[i]
    if touch.state == 3 || touch.state == 4 {
```

**Explanation**: The tap path is derived from raw finger-state data, while mouse-button events are handled as a separate stream. That is stronger evidence for “use multitouch data if you need certainty” than for “pressure tells you everything.”

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | Apple CGEvent docs | Expose generic integer-field access for Quartz events. | [1] |
| 2 | Apple `CGEventField.mouseEventSubtype` | Defines a mouse-event subtype field, but no tap/click contract in the excerpt. | [2] |
| 3 | Mac Mouse Fix `ButtonInputReceiver` | Reads `kCGMouseEventButtonNumber` and `kCGMouseEventPressure` in a mouse-event handler. | [3] |
| 4 | MiddleDrag `GestureRecognizer` | Uses raw touch states to identify valid fingers for tap-style recognition. | [4] |
| 5 | MiddleDrag `MultitouchManager` | Handles `leftMouseDown`/`leftMouseUp` separately when multitouch context exists. | [4] |

### Caveats and Gaps
- I did not find an Apple-authored statement that `kCGMouseEventPressure`, `mouseEventSubtype`, `clickState`, or any other mouse-event field is a reliable tap-to-click vs physical-click discriminator for trackpads [1][2].
- The open-source examples show practical handling patterns, not a formal guarantee across all Mac models or macOS versions [3][4].
- Existing evidence is strongest for event-tap handlers that also have access to multitouch frames; it is weaker for pure mouse-event-only handlers [3][4].

### Confidence
**Level:** MEDIUM
**Rationale:** The Apple docs confirm the available fields, and the open-source code shows how real software handles the ambiguity. What remains unproven is a universal Apple contract that one mouse-event field reliably distinguishes tap-to-click from physical click.

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | docs | Apple Developer Documentation: CGEvent | surfaced 2026-04-16 | Authoritative API contract for `getIntegerValueField` / `setIntegerValueField` on Quartz events | [developer.apple.com/documentation/coregraphics/cgevent](https://developer.apple.com/documentation/coregraphics/cgevent) |
| [2] | docs | Apple Developer Documentation: `CGEventField.mouseEventSubtype` | surfaced 2026-04-16 | Authoritative definition of a mouse-event subtype field | [developer.apple.com/documentation/coregraphics/cgeventfield/mouseeventsubtype](https://developer.apple.com/documentation/coregraphics/cgeventfield/mouseeventsubtype) |
| [3] | code | Mac Mouse Fix `ButtonInputReceiver.m` | `main` fetched 2026-04-16 | Shows pressure used as a button-state cue in a mouse-event tap path | [raw.githubusercontent.com/noah-nuebling/mac-mouse-fix/master/Helper/Core/Buttons/ButtonInputReceiver.m](https://raw.githubusercontent.com/noah-nuebling/mac-mouse-fix/master/Helper/Core/Buttons/ButtonInputReceiver.m) |
| [4] | code | MiddleDrag `MultitouchManager.swift` / `GestureRecognizer.swift` | `5b6654a818ac2a629c1fb1b619acbbcab3b88df0` | Shows multitouch-based tap recognition plus separate mouse-event handling | [MultitouchManager.swift](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Managers/MultitouchManager.swift#L772-L789), [GestureRecognizer.swift](https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/5b6654a818ac2a629c1fb1b619acbbcab3b88df0/MiddleDrag/Core/GestureRecognizer.swift#L70-L85) |

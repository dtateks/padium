## Findings: OpenMultitouchSupport raw touch gesture patterns

### Research Metadata
- Question: How OpenMultitouchSupport exposes touch frames, what semantics/limits its source implies, which upstream issues/examples/forks report reliability problems, and what external patterns are used for robust swipe detection from raw trackpad frames.
- Type: MIXED
- Target: Kyome22/OpenMultitouchSupport 3.0.3; mhuusko5/M5MultitouchSupport; ris58h/Touch-Tab; Touch-Tab issue history
- Version Scope: OpenMultitouchSupport tag 3.0.3 at commit d7ec2276bea98711530dc610eb05563e9e1ce342; Touch-Tab current master as fetched 2026-04-15; M5MultitouchSupport master as fetched 2026-04-15
- Generated: 18.06_15-04-2026
- Coverage: PARTIAL

### Direct Answer
- Fact: OpenMultitouchSupport exposes raw multitouch frames as `AsyncStream<[OMSTouchData]>` via `OMSManager.shared().touchDataStream`; each callback delivers the current frame’s touches as an array, and an empty frame is emitted as `[]` when `touches.isEmpty` [1][2].
- Fact: The source preserves stable touch IDs and raw per-touch state/measurement fields (`id`, `position`, `total`, `pressure`, `axis`, `angle`, `density`, `state`, `timestamp`), but the public README does not document any higher-level gesture semantics, smoothing, or debouncing; those are left to consumers [1][2].
- Fact: Upstream issue history shows reliability complaints around sleep/wake and device lifecycle: OpenMultitouchSupport issue #2 says the project shares M5MultitouchSupport’s crash-after-sleep behavior, and the maintainer could not reproduce it; M5MultitouchSupport issue #1 reports `MTDeviceRelease()`-related `EXC_BAD_INSTRUCTION` after sleep, with a later comment suggesting the device may already be released on sleep [3][4][5].
- Fact: External gesture apps based on these APIs tend to add a frame history, per-finger id map, axis filtering, and a separate gesture-end condition rather than firing directly on every raw frame; Touch-Tab’s `SwipeManager` is a concrete example, and its own README documents user-visible failure modes for 3-finger gestures and sleep recovery [6][7].
- Synthesis: For a robust swipe detector, the safest pattern from the external evidence is: accumulate movement across a gesture, track by stable `identity`, reject mixed directions and non-dominant axes, wait for lift/end before finalizing, and suppress duplicate firings with cooldown/UI-delay logic. OpenMultitouchSupport itself does not provide those higher-level guarantees [1][2][6][7].

### Key Findings
#### 1) OpenMultitouchSupport frame semantics and exposed data

**Claim**: `OMSManager` yields one array per raw multitouch frame, not a pre-classified gesture event, and an empty frame is surfaced as `[]` [1][2].

**Evidence** ([OMSManager.swift#L18-L28](https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/Sources/OpenMultitouchSupport/OMSManager.swift#L18-L28) [1]):
```swift
private let touchDataSubject = PassthroughSubject<[OMSTouchData], Never>()
public var touchDataStream: AsyncStream<[OMSTouchData]> {
    AsyncStream { continuation in
        let cancellable = touchDataSubject.sink { value in
            continuation.yield(value)
        }
```

**Evidence** ([OMSManager.swift#L64-L84](https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/Sources/OpenMultitouchSupport/OMSManager.swift#L64-L84) [1]):
```swift
@objc func listen(_ event: OpenMTEvent) {
    guard let touches = (event.touches as NSArray) as? [OpenMTTouch] else { return }
    if touches.isEmpty {
        touchDataSubject.send([])
    } else {
        let array = touches.compactMap { touch -> OMSTouchData? in
            guard let state = OMSState(touch.state) else { return nil }
```

**Explanation**: The public stream is just a wrapper over each contact frame from the private bridge. The empty-array emission is a real semantic boundary: consumers can use it as “lift/end of contact” if they want, but the library does not label it as such.

#### 2) What raw fields are preserved, and what is not interpreted

**Claim**: The bridge preserves per-touch identity, position, velocity, state, capacitance/pressure shape data, and a timestamp, but it does not classify gestures or stabilize finger sets [1][2].

**Evidence** ([OpenMTTouch.m#L13-L28](https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/Framework/OpenMultitouchSupportXCF/OpenMTTouch.m#L13-L28) [2]):
```objective-c
- (id)initWithMTTouch:(MTTouch *)touch {
    if (self = [super init]) {
        _identifier = touch->identifier;
        _state = touch->state;
        _posX = touch->normalizedPosition.position.x;
        _posY = touch->normalizedPosition.position.y;
        _velX = touch->normalizedPosition.velocity.x;
        _velY = touch->normalizedPosition.velocity.y;
        _total = touch->total;
        _pressure = touch->pressure;
```

**Evidence** ([README.md](https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/README.md) [1]):
```text
The data you can get are as follows

struct OMSTouchData: Sendable {
    var id: Int32
    var position: OMSPosition
    var total: Float // total value of capacitance
    var pressure: Float
    var axis: OMSAxis
    var angle: Float // finger angle
    var density: Float // area density of capacitance
    var state: OMSState
    var timestamp: String
}
```

**Explanation**: The source and README expose only raw measurements. There is no built-in swipe direction logic, finger-count stabilization, or gesture cooldown layer in OpenMultitouchSupport.

#### 3) Sleep/wake and device lifecycle are known weak points upstream

**Claim**: Both OpenMultitouchSupport and its ancestor M5MultitouchSupport have issue history around sleep/wake, and the reported failure mode is consistent with device release/start-stop lifecycle bugs [3][4][5].

**Evidence** ([OpenMultitouchSupport issue #2](https://github.com/Kyome22/OpenMultitouchSupport/issues/2) [3]):
```text
I experience the same issue as in M5MultitouchSupport https://github.com/mhuusko5/M5MultitouchSupport/issues/1 . Not releasing a device helps BTW is done in Touch-Tab.
```

**Evidence** ([M5MultitouchSupport issue #1](https://github.com/mhuusko5/M5MultitouchSupport/issues/1) [4]):
```text
I get EXC_BAD_INSTRUCTION when laptop wakes up after sleep.

It seems like it's an issue with MTDeviceRelease(mtDevice); line. When I comment out this line it works fine.
```

**Evidence** ([M5MultitouchSupport issue #1 comment](https://github.com/mhuusko5/M5MultitouchSupport/issues/1#issuecomment-1235389610) [5]):
```text
Looks like MTDeviceRelease() sort of happens automatically on system sleep, and an object can't be released twice.
```

**Explanation**: The upstream trail points to lifecycle fragility at sleep/wake, especially around device release. This is relevant for gesture apps because any detector built on these APIs needs restart-safe state and careful device teardown/reinit handling.

#### 4) Concrete external swipe-detector pattern: Touch-Tab

**Claim**: Touch-Tab uses a history-based swipe accumulator with per-touch identity tracking, same-direction filtering, horizontal-vs-vertical dominance checks, and a gesture-end event when fingers lift [6][7].

**Evidence** ([SwipeManager.swift#L10-L18](https://github.com/ris58h/Touch-Tab/blob/master/Touch-Tab/SwipeManager.swift#L10-L18) [6]):
```swift
private static var accVelX: Float = 0
private static var prevTouchPositions: [String: NSPoint] = [:]
// Gesture state. Gesture may consists of multiple events.
private static var startTime: Date? = nil
```

**Evidence** ([SwipeManager.swift#L84-L110](https://github.com/ris58h/Touch-Tab/blob/master/Touch-Tab/SwipeManager.swift#L84-L110) [6]):
```swift
private static func processThreeFingers(touches: Set<NSTouch>) {
    let velX = SwipeManager.horizontalSwipeVelocity(touches: touches)
    // We don't care about non-horizontal swipes.
    if velX == nil {
        return
    }

    accVelX += velX!
    // Not enough swiping.
    if abs(accVelX) < accVelXThreshold {
        return
    }
```

**Evidence** ([SwipeManager.swift#L134-L173](https://github.com/ris58h/Touch-Tab/blob/master/Touch-Tab/SwipeManager.swift#L134-L173) [6]):
```swift
private static func horizontalSwipeVelocity(touches: Set<NSTouch>) -> Float? {
    var allRight = true
    var allLeft = true
    var sumVelX = Float(0)
    var sumVelY = Float(0)
    for touch in touches {
        let (velX, velY) = touchVelocity(touch)
        allRight = allRight && velX >= 0
        allLeft = allLeft && velX <= 0
        sumVelX += velX
        sumVelY += velY
```

**Explanation**: This is a robust raw-frame pattern because it does not trust any single frame. It stabilizes by identity, averages velocity, requires all fingers to move in the same sign, and rejects gestures whose vertical motion dominates.

#### 5) Touch-Tab’s documented failure modes mirror the current Padium complaints

**Claim**: Touch-Tab’s own README and issues show the same classes of problems Padium is seeing: 3-finger gestures can scroll content instead of switching, sleep can break recognition, and some directions fail more than others [7][8].

**Evidence** ([Touch-Tab README.md](https://github.com/ris58h/Touch-Tab/blob/master/README.md) [7]):
```text
5. Disable 3-finger swipe between full-screen apps or make it 4-finger in `System Settings > Trackpad > More Gestures > Swipe between full-screen apps`.
```

**Evidence** ([Touch-Tab issue #1](https://github.com/ris58h/Touch-Tab/issues/1) [8]):
```text
While using three finger gesture the contents of the window under the cursor is being scrolled. Very annoying.
```

**Evidence** ([Touch-Tab issue #28](https://github.com/ris58h/Touch-Tab/issues/28) [8]):
```text
Touch-Tab tends to stop working after Macbook sleeps for a few hours.
```

**Evidence** ([Touch-Tab issue #26](https://github.com/ris58h/Touch-Tab/issues/26) [8]):
```text
The app switcher does not appear for me when I swipe 3 fingers to the right.
```

**Explanation**: These reports are not proof of Padium’s bug, but they do show that 3-finger recognition, direction asymmetry, and post-sleep recovery are common failure surfaces for this API family.

#### 6) External pattern: cooldown / duplicate suppression

**Claim**: Touch-Tab explicitly adds a UI delay gate to suppress repeated firings while the app switcher UI is still appearing [6].

**Evidence** ([SwipeManager.swift#L97-L109](https://github.com/ris58h/Touch-Tab/blob/master/Touch-Tab/SwipeManager.swift#L97-L109) [6]):
```swift
if startTime == nil {
    startTime = Date()
} else {
    let interval = startTime!.timeIntervalSinceNow
    if -interval < appSwitcherUIDelay {
        // We skip subsequent events until App Switcher UI is shown.
        clearEventState()
        return
    }
}

startOrContinueGesture()
clearEventState()
```

**Explanation**: This is a direct duplicate-suppression pattern. It prevents repeated gesture frames from generating redundant actions before downstream UI has finished reacting.

#### 7) External pattern: sleep/wake recovery through restart instead of relying on stale device state

**Claim**: M5MultitouchSupport restarts handling on wake, and its README describes a multi-device listener model with explicit start/stop lifecycle [9][10].

**Evidence** ([M5MultitouchManager.m#L150-L168](https://github.com/mhuusko5/M5MultitouchSupport/blob/master/M5MultitouchSupport/M5MultitouchManager.m#L150-L168) [9]):
```objective-c
- (void)checkMultitouchHardware {
    CGDirectDisplayID builtInDisplay = 0;
    CGDirectDisplayID activeDisplays[10];
    uint32_t numActiveDisplays;
    CGGetActiveDisplayList(10, activeDisplays, &numActiveDisplays);
    ...
    NSArray *mtDevices = (NSArray *)CFBridgingRelease(MTDeviceCreateList());
    if (self.multitouchDevices.count && self.multitouchDevices.count != (int)mtDevices.count) {
        [self restartHandlingMultitouchEvents:nil];
    }
}
```

**Evidence** ([M5MultitouchManager.m#L239-L243](https://github.com/mhuusko5/M5MultitouchSupport/blob/master/M5MultitouchSupport/M5MultitouchManager.m#L239-L243) [9]):
```objective-c
- (void)restartHandlingMultitouchEvents:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopHandlingMultitouchEvents];
        [self startHandlingMultitouchEvents];
    });
}
```

**Explanation**: The ancestor project treats wake/device changes as a reason to restart the listener graph, not as a reason to keep stale state forever. That pattern is relevant for any robust detector built on these APIs.

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `OpenMTManager.contactEventHandler` | Raw `MTTouch[]` frame converted to `OpenMTEvent` with one `OpenMTTouch` per finger | [2] |
| 2 | `OMSManager.listen(_:)` | Converts each `OpenMTTouch` to `OMSTouchData` and emits `[OMSTouchData]` or `[]` | [1][2] |
| 3 | `Touch-Tab.SwipeManager.touchEventHandler` | Receives `NSTouch` set, filters empty frames and finger counts | [6] |
| 4 | `Touch-Tab.horizontalSwipeVelocity` | Computes average velocity, identity-based deltas, and axis dominance | [6] |
| 5 | `Touch-Tab.processThreeFingers` | Accumulates velocity until threshold, then gates on UI delay and emits action | [6] |
| 6 | `M5MultitouchManager.restartHandlingMultitouchEvents` | Recreates listeners on wake to avoid stale hardware state | [9] |

### Change Context
- History: OpenMultitouchSupport 3.0.3 is essentially a thin wrapper over the private MultitouchSupport bridge; its release commit on 2025-01-13 mainly updated packaging, not gesture semantics [1][2].
- History: Issue history in both OpenMultitouchSupport and M5MultitouchSupport shows sleep/wake fragility, which appears to have motivated restart logic in ancestor code and workarounds in downstream apps [3][4][5][9].
- History: Touch-Tab’s README and issues document the same class of 3-finger gesture flakiness that Padium is currently experiencing, so it is a relevant external comparator rather than an outlier [7][8].

### Code Pattern Comparison
| Project | Frame source | Gesture state | Axis / direction filter | End-of-gesture handling | Duplicate suppression | Notable risk |
|---------|--------------|---------------|--------------------------|-------------------------|-----------------------|--------------|
| OpenMultitouchSupport | `touchDataStream` of `[OMSTouchData]` | None built in | None built in | Emits `[]` on empty frame | None built in | Leaves all robustness to consumers [1][2] |
| Touch-Tab | `NSEvent.allTouches()` via `CGEventTap` | `accVelX`, `prevTouchPositions`, `startTime` | Requires same X sign; rejects if `abs(velX) <= abs(velY)` | `touchesCount == 0` / non-3-finger path ends gesture | `appSwitcherUIDelay` gate | Can still misfire on empty frames / direction asymmetry [6][7][8] |
| M5MultitouchSupport | `MTDeviceCreateList` + frame callback | Listener graph, device list | None in core manager | Restart on wake | None in core manager | Sleep/wake and release lifecycle are fragile [4][5][9][10] |

### Likely Gaps in Padium
- Padium’s current incremental classification is riskier than the external comparator patterns because the external examples mostly delay final action until a stronger accumulated condition or lift/end boundary is visible [6][7].
- If Padium only uses distance thresholds (for example the lowered `swipeMinDistance = 0.06`) without a velocity sign check, axis dominance check, and identity-stable accumulation, it is exposed to exactly the “3-finger up/down feels unreliable” failure mode seen in Touch-Tab issues [6][7][8].
- If Padium finalizes before lift/end, it may repeatedly classify transient mixed frames during finger reconfiguration; the external examples either clear state on empty frames or wait for a non-touching transition [1][6].
- If Padium does not restart or fully reset on sleep/wake, the upstream issue trail suggests a real risk of stale-device behavior or post-sleep breakage [3][4][5][9].
- If Padium does not track stable `id`/`identity` through the entire gesture and associate each new frame with previous positions, it loses the main safety mechanism used by Touch-Tab and the raw touch wrappers [1][2][6].

### Best External Code Samples to Mimic
1. **Touch-Tab `SwipeManager.swift`** — best direct model for raw-frame swipe classification: per-finger identity map, average velocity, same-direction filtering, axis dominance check, accumulation threshold, and cooldown gate [6][7].
2. **OpenMultitouchSupport `OMSManager.swift`** — best model for exposing raw frames cleanly as `AsyncStream<[OMSTouchData]>` with `[]` as the empty-frame sentinel [1].
3. **OpenMultitouchSupport `OpenMTTouch.m`** — best model for what raw per-touch fields are available from the private bridge, including velocity and state [2].
4. **M5MultitouchSupport `M5MultitouchManager.m`** — best model for sleep/wake restart handling and explicit listener/device lifecycle management [9][10].
5. **Touch-Tab README + issues** — best evidence for the failure modes to design against: content scroll hijack, post-sleep failure, and direction asymmetry [7][8].

### Caveats and Gaps
- I did not find a second independent raw-swipe project using OpenMultitouchSupport itself; the strongest concrete swipe classifier found was Touch-Tab, which uses AppKit `NSTouch`/`CGEventTap` rather than OMS directly.
- I did not locate upstream docs that define exact semantics for every `OMSState` case beyond the enum names; those names are exposed, but behavior appears inferred from the bridge and consumer code.
- The external evidence shows common failure modes and mitigation patterns, but it does not prove which exact change will fix Padium; it only narrows the high-probability design gaps.

### Confidence
**Level:** HIGH
**Rationale:** The core OpenMultitouchSupport API shape is directly confirmed by source, and the swipe-pattern comparison is grounded in concrete code and issue history. Remaining uncertainty is mainly about Padium-specific causality, not the external patterns themselves.

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | code/docs | Kyome22/OpenMultitouchSupport `README.md` + `Sources/OpenMultitouchSupport/OMSManager.swift` | tag 3.0.3 / commit d7ec2276bea98711530dc610eb05563e9e1ce342 | Defines the public stream contract and empty-frame emission | https://github.com/Kyome22/OpenMultitouchSupport |
| [2] | code | Kyome22/OpenMultitouchSupport `Framework/OpenMultitouchSupportXCF/OpenMTTouch.m` + `Framework/OpenMultitouchSupportXCF/OpenMTManager.m` | commit d7ec2276bea98711530dc610eb05563e9e1ce342 | Shows raw frame conversion and preserved per-touch fields | https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/Framework/OpenMultitouchSupportXCF/OpenMTTouch.m |
| [3] | issue | Kyome22/OpenMultitouchSupport issue #2 | opened 2023-02-22 | Upstream sleep/crash report and maintainer inability to reproduce | https://github.com/Kyome22/OpenMultitouchSupport/issues/2 |
| [4] | issue | mhuusko5/M5MultitouchSupport issue #1 | opened 2022-07-29 | Ancestor sleep/wake crash report around `MTDeviceRelease()` | https://github.com/mhuusko5/M5MultitouchSupport/issues/1 |
| [5] | comment | mhuusko5/M5MultitouchSupport issue #1 comment | 2022-09-02 | Suggests device may already be released on sleep | https://github.com/mhuusko5/M5MultitouchSupport/issues/1#issuecomment-1235389610 |
| [6] | code/docs | ris58h/Touch-Tab `SwipeManager.swift` | master as fetched 2026-04-15 | Best concrete raw-frame swipe classifier pattern | https://raw.githubusercontent.com/ris58h/Touch-Tab/master/Touch-Tab/SwipeManager.swift |
| [7] | docs | ris58h/Touch-Tab `README.md` | master as fetched 2026-04-15 | Documents known user-facing 3-finger gesture constraints/workarounds | https://github.com/ris58h/Touch-Tab/blob/master/README.md |
| [8] | issue | ris58h/Touch-Tab issues #1, #26, #28 | 2022-10-02, 2024-11-17, 2025-06-15 | Concrete reports of scroll hijack, direction asymmetry, and post-sleep failure | https://github.com/ris58h/Touch-Tab/issues |
| [9] | code | mhuusko5/M5MultitouchSupport `M5MultitouchManager.m` | master as fetched 2026-04-15 | Restart-on-wake and lifecycle management pattern | https://github.com/mhuusko5/M5MultitouchSupport/blob/master/M5MultitouchSupport/M5MultitouchManager.m |
| [10] | docs | mhuusko5/M5MultitouchSupport `README.md` | master as fetched 2026-04-15 | Listener lifecycle and thread-model documentation | https://github.com/mhuusko5/M5MultitouchSupport/blob/master/README.md |

### Evidence Appendix
#### OpenMultitouchSupport public usage contract
```text
Task { [weak self, manager] in
    for await touchData in manager.touchDataStream {
        // use touchData
    }
}

manager.startListening()
manager.stopListening()
```
[README.md](https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/README.md) [1]

#### Touch-Tab same-direction / axis-dominance gate
```swift
if !allRight && !allLeft {
    return nil
}
...
if abs(velX) <= abs(velY) {
    return nil
}
```
[SwipeManager.swift](https://github.com/ris58h/Touch-Tab/blob/master/Touch-Tab/SwipeManager.swift) [6]

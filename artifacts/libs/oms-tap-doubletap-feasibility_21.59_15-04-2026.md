## Findings: OpenMultitouchSupport / MultitouchSupport tap-double-tap feasibility

### Research Metadata
- Question: What upstream code/docs/history say about whether Padium can add 3-finger and 4-finger tap/double-tap recognition from raw OMS frames, what touch lifecycle data is available, and what caveats constrain local classification.
- Type: MIXED
- Target: Kyome22/OpenMultitouchSupport 3.0.3; mhuusko5/M5MultitouchSupport; ris58h/Touch-Tab; macOS private MultitouchSupport bridge
- Version Scope: OpenMultitouchSupport 3.0.3 at commit d7ec2276bea98711530dc610eb05563e9e1ce342; Touch-Tab master fetched 2026-04-15; M5MultitouchSupport master fetched 2026-04-15; macOS private API behavior inferred from upstream bridge/source
- Generated: 21.59_15-04-2026
- Coverage: COMPLETE

### Direct Answer
- Fact: OpenMultitouchSupport exposes only raw per-frame touch data, not tap or double-tap gestures; Padium can derive a tap classifier locally only if it uses touch state transitions, stable touch IDs, timing gaps, and spatial/pressure thresholds from the frame stream [1][2].
- Fact: The upstream bridge preserves the inputs needed for local tap detection — identity, state, position, velocity, total capacitance, pressure, axis, angle, density, and timestamp — and it emits an empty array when the contact set disappears [1][2].
- Fact: The public API does not encode “tap”, “double tap”, or any gesture-end semantics beyond raw state values such as `starting`, `touching`, `breaking`, and `leaving`, so consumers must define the gesture boundary themselves [1].
- Fact: Upstream history shows sleep/wake and release lifecycle fragility in the private MultitouchSupport family; that makes restart-safe state handling important for any tap/double-tap detector built on OMS frames [3][4][5].
- Synthesis: Padium can plausibly recognize 3-finger and 4-finger tap/double-tap locally from OMS data, but it should treat the library as a frame source only and avoid assuming the private API will provide a clean tap event or stable post-sleep behavior [1][2][3][4][5].

### Key Findings
#### 1) What OMS actually exposes

**Claim**: OMS exposes raw frames and the full touch fields needed for a local classifier, but no built-in tap gesture abstraction [1][2].

**Evidence** ([OMSManager.swift#L18-L28](https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/Sources/OpenMultitouchSupport/OMSManager.swift#L18-L28) [1]):
```swift
private let touchDataSubject = PassthroughSubject<[OMSTouchData], Never>()
public var touchDataStream: AsyncStream<[OMSTouchData]> {
    AsyncStream { continuation in
        let cancellable = touchDataSubject.sink { value in
            continuation.yield(value)
        }
```

**Evidence** ([OMSTouchData.swift#L20-L55](https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/Sources/OpenMultitouchSupport/OMSTouchData.swift#L20-L55) [1]):
```swift
public enum OMSState: String, Sendable {
    case notTouching
    case starting
    case hovering
    case making
    case touching
    case breaking
    case lingering
    case leaving
}

public struct OMSTouchData: CustomStringConvertible, Sendable {
    public var id: Int32
    public var position: OMSPosition
    public var total: Float
    public var pressure: Float
    public var axis: OMSAxis
    public var angle: Float
    public var density: Float
    public var state: OMSState
    public var timestamp: String
```

**Explanation**: The public stream is frame-based, and the state enum is the only lifecycle hint. There is no upstream tap, double-tap, or debounce layer.

#### 2) The private bridge carries the raw measurements Padium needs

**Claim**: The underlying private bridge copies identity, normalized position/velocity, total, pressure, axes, angle, density, and timestamp from `MTTouch` into the public wrapper [2].

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
        _minorAxis = touch->minorAxis;
        _majorAxis = touch->majorAxis;
        _angle = touch->angle;
        _density = touch->density;
        _timestamp = touch->timestamp;
    }
```

**Explanation**: These fields are enough to implement local tap heuristics: per-finger identity, contact start/end, movement tolerance, contact area/pressure gating, and timing.

#### 3) The public library does not define tap semantics; consumers must infer them

**Claim**: OpenMultitouchSupport only maps `OpenMTState` into `OMSState`; it does not interpret those states into gestures or define tap/double-tap boundaries [1].

**Evidence** ([OMSTouchData.swift#L20-L42](https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/Sources/OpenMultitouchSupport/OMSTouchData.swift#L20-L42) [1]):
```swift
public enum OMSState: String, Sendable {
    case notTouching
    case starting
    case hovering
    case making
    case touching
    case breaking
    case lingering
    case leaving

    init?(_ state: OpenMTState) {
        switch state {
        case .notTouching: self = .notTouching
        case .starting:    self = .starting
        case .hovering:    self = .hovering
        case .making:      self = .making
        case .touching:    self = .touching
        case .breaking:    self = .breaking
        case .lingering:   self = .lingering
        case .leaving:     self = .leaving
        @unknown default:  return nil
        }
    }
}
```

**Explanation**: The enum exposes raw lifecycle labels, but no gesture semantics. For tap/double-tap, Padium must choose its own rules for what sequence of states counts as a tap.

#### 4) Frame emptiness and raw timestamps matter for gesture endings and double-tap gaps

**Claim**: OMS emits `[]` when no touches remain, and the bridge timestamp is sourced from the frame itself, so end-of-contact and inter-tap timing can be tracked locally [1][2].

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

**Evidence** ([OpenMTTouch.m#L21-L27](https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/Framework/OpenMultitouchSupportXCF/OpenMTTouch.m#L21-L27) [2]):
```objective-c
        _total = touch->total;
        _pressure = touch->pressure;
        _minorAxis = touch->minorAxis;
        _majorAxis = touch->majorAxis;
        _angle = touch->angle;
        _density = touch->density;
        _timestamp = touch->timestamp;
```

**Explanation**: A tap detector can use the empty frame as a hard gesture-lift boundary and timestamps as the basis for single-vs-double tap separation.

#### 5) Upstream history says lifecycle handling is fragile

**Claim**: Sleep/wake can break the underlying private multitouch device lifecycle, so Padium should expect resets/restarts and stale state after sleep [3][4][5].

**Evidence** ([OpenMultitouchSupport issue #2](https://github.com/Kyome22/OpenMultitouchSupport/issues/2) [3]):
```text
I experience the same issue as in M5MultitouchSupport https://github.com/mhuusko5/M5MultitouchSupport/issues/1 . Not releasing a device helps BTW as it's done in Touch-Tab.
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

**Explanation**: This is not tap-specific, but it directly affects any classifier that caches gesture state across suspend/resume.

#### 6) Related upstream practice for raw gesture detection

**Claim**: Touch-Tab shows the safest external pattern for higher-level gesture inference from raw trackpad frames: per-touch identity tracking, accumulation, axis/direction filtering, and explicit end/reset boundaries [6].

**Evidence** ([SwipeManager.swift#L10-L18](https://raw.githubusercontent.com/ris58h/Touch-Tab/master/Touch-Tab/SwipeManager.swift) [6]):
```swift
private static let accVelXThreshold: Float = 0.07
private static let appSwitcherUIDelay: Double = 0.2

private static var eventTap: CFMachPort? = nil
private static var accVelX: Float = 0
private static var prevTouchPositions: [String: NSPoint] = [:]
private static var startTime: Date? = nil
```

**Evidence** ([SwipeManager.swift#L84-L173](https://raw.githubusercontent.com/ris58h/Touch-Tab/master/Touch-Tab/SwipeManager.swift) [6]):
```swift
private static func processThreeFingers(touches: Set<NSTouch>) {
    let velX = SwipeManager.horizontalSwipeVelocity(touches: touches)
    if velX == nil { return }

    accVelX += velX!
    if abs(accVelX) < accVelXThreshold { return }
    ...
    startOrContinueGesture()
    clearEventState()
}

private static func horizontalSwipeVelocity(touches: Set<NSTouch>) -> Float? {
    var allRight = true
    var allLeft = true
    ...
    if !allRight && !allLeft { return nil }
    ...
    if abs(velX) <= abs(velY) { return nil }
    return velX
}
```

**Explanation**: Even though this comparator is AppKit-based, it shows the shape of a robust raw-frame classifier: don’t trust one frame, and don’t finalize until the gesture is stable enough.

#### 7) Tap/double-tap implications for Padium

**Claim**: Padium can derive tap/double-tap locally, but only with conservative state rules; the upstream sources do not prove that the private API itself delivers a distinct tap event [1][2][3][4][5].

**Evidence** ([OMSTouchData.swift#L20-L55](https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/Sources/OpenMultitouchSupport/OMSTouchData.swift#L20-L55) [1]):
```swift
public enum OMSState: String, Sendable {
    case notTouching
    case starting
    case hovering
    case making
    case touching
    case breaking
    case lingering
    case leaving
}
```

**Explanation**: A practical classifier should wait for a full contact cycle, require stable finger count/IDs for the whole tap, enforce a maximum dwell/movement envelope, and only then emit one tap or start a double-tap timer. Double-tap should be recognized from two completed tap cycles separated by a short gap and followed by no extra contacts.

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `OpenMTManager` → `OMSManager.listen(_:)` | Raw `MTTouch` frames become `[OMSTouchData]` with empty frames surfaced as `[]` | [1][2] |
| 2 | `OMSState` | Frame-level lifecycle labels are exposed, but not interpreted as tap/double-tap | [1] |
| 3 | `OMSTouchData` | Local classifier has identity, position, velocity, pressure, axes, density, and timestamp | [1][2] |
| 4 | Consumer classifier | Must decide tap boundary, dwell/motion limits, and double-tap gap from raw frames | [1][2] |
| 5 | Sleep/wake lifecycle | Listener/device state may need restart or reset after suspend/resume | [3][4][5] |

### Change Context
- History: Release 3.0.3 is a thin wrapper release and does not document any new higher-level gesture semantics; the release page only points to the 3.0.2...3.0.3 diff and commit d7ec227, not to tap support [7].
- History: The sleep/wake issue trail suggests the underlying private API can lose device validity across sleep, which matters for any tap/double-tap timer or state machine that spans long idle periods [3][4][5].

### Caveats and Gaps
- No upstream source found that claims OpenMultitouchSupport or MultitouchSupport provides first-class tap/double-tap events.
- The exact meaning of each `OMSState` value is not documented beyond the enum names, so tap boundary rules remain a consumer policy choice.
- I did not find an OMS-native example implementing tap/double-tap; the closest related example is swipe-only detection in Touch-Tab.

### Confidence
**Level:** HIGH
**Rationale:** The public OMS surface and private-field bridge are explicit in source, and the history/issues confirm lifecycle caveats. The remaining uncertainty is not about available data, but about consumer-defined tap policy.

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | code/docs | Kyome22/OpenMultitouchSupport `Sources/OpenMultitouchSupport/OMSManager.swift` and `Sources/OpenMultitouchSupport/OMSTouchData.swift` | tag 3.0.3 / commit d7ec2276bea98711530dc610eb05563e9e1ce342 | Defines public frame stream and exposed state/data model | https://github.com/Kyome22/OpenMultitouchSupport/tree/d7ec2276bea98711530dc610eb05563e9e1ce342 |
| [2] | code | Kyome22/OpenMultitouchSupport `Framework/OpenMultitouchSupportXCF/OpenMTTouch.m` | commit d7ec2276bea98711530dc610eb05563e9e1ce342 | Shows private bridge fields copied from `MTTouch` | https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/Framework/OpenMultitouchSupportXCF/OpenMTTouch.m |
| [3] | issue | Kyome22/OpenMultitouchSupport issue #2 | opened 2023-02-22 | Sleep/crash report and mention of not releasing device | https://github.com/Kyome22/OpenMultitouchSupport/issues/2 |
| [4] | issue | mhuusko5/M5MultitouchSupport issue #1 | opened 2022-07-29 | Device-release crash after sleep | https://github.com/mhuusko5/M5MultitouchSupport/issues/1 |
| [5] | comment | mhuusko5/M5MultitouchSupport issue #1 comment | 2022-09-02 | Suggests automatic release on sleep and double-release hazard | https://github.com/mhuusko5/M5MultitouchSupport/issues/1#issuecomment-1235389610 |
| [6] | code/docs | ris58h/Touch-Tab `SwipeManager.swift` and README/issue history | master as fetched 2026-04-15 | Concrete raw-frame gesture classifier pattern and real-world caveats | https://raw.githubusercontent.com/ris58h/Touch-Tab/master/Touch-Tab/SwipeManager.swift |
| [7] | release | Kyome22/OpenMultitouchSupport release 3.0.3 | 2025-01-13 | Confirms current version/ref scope and that release notes do not add gesture semantics | https://github.com/Kyome22/OpenMultitouchSupport/releases/tag/3.0.3 |

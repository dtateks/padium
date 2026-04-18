## Findings: OpenMultitouchSupport 3.0.3 / external Magic Trackpad support

### Direct Answer
- Fact: OpenMultitouchSupport 3.0.3 is **not** designed to listen to all multitouch devices; its own README says it observes the trackpad on the **"only default device"**, and its implementation creates exactly one device with `MTDeviceCreateDefault()` rather than enumerating device list entries [1][2].
- Trace: That means “built-in MacBook trackpad works, external Magic Trackpad does not” is consistent with upstream behavior if the system default multitouch device remains the internal trackpad or otherwise is not the external device Padium expects. OpenMultitouchSupport does not expose any API to choose a different device [1][2][3].
- Fact: The upstream project OpenMultitouchSupport references, M5MultitouchSupport, explicitly claims support for global multitouch events from **"trackpad, Magic Mouse"** and implements that by enumerating `MTDeviceCreateList()` and registering callbacks on **every** device, carrying each event’s `deviceID` through to consumers [4][5][6].
- Synthesis: So the most evidence-backed explanation is not that MultitouchSupport categorically cannot work with external devices, but that **OpenMultitouchSupport 3.0.3 narrows the private API to the default device only**. If the external Magic Trackpad is not that default device, Padium will miss it unless the wrapper is changed to enumerate/select devices [1][2][4][5][6].

### Key Findings
#### OpenMultitouchSupport 3.0.3 only binds the default multitouch device

**Claim**: The library contract itself limits observation to the default device, not an arbitrary or selectable trackpad [1].

**Evidence** ([README.md#L1-L4](https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/README.md#L1-L4) [1]):
```markdown
# OpenMultitouchSupport

This enables you easily to observe global multitouch events on the trackpad (only default device).  
I created this library to make MultitouchSupport.framework (Private Framework) easy to use.
```

**Explanation**: This is the upstream contract statement for 3.0.3. It does not promise support for all attached trackpads; it explicitly scopes the wrapper to the default device.

#### The implementation hard-codes `MTDeviceCreateDefault()`

**Claim**: OpenMultitouchSupport 3.0.3 constructs one device with `MTDeviceCreateDefault()` and starts callbacks only for that single device [2].

**Evidence** ([OpenMTManager.m#L49-L52](https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/Framework/OpenMultitouchSupportXCF/OpenMTManager.m#L49-L52) [2]):
```objective-c
- (void)makeDevice {
    if (MTDeviceIsAvailable()) {
        self.device = MTDeviceCreateDefault();
```

**Evidence** ([OpenMTManager.m#L108-L116](https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/Framework/OpenMultitouchSupportXCF/OpenMTManager.m#L108-L116) [2]):
```objective-c
- (void)startHandlingMultitouchEvents {
    [self makeDevice];
    @try {
        MTRegisterContactFrameCallback(self.device, contactEventHandler);
        MTDeviceStart(self.device, 0);
    } @catch (NSException *exception) {
```

**Explanation**: There is no device enumeration path and no selector API. The wrapper creates one `MTDeviceRef`, registers one callback, and starts one device.

- Trace: `OpenMTInternal.h` declares only `MTDeviceCreateDefault()` and `MTDeviceIsAvailable()` in this wrapper’s imported private API surface; there is no local declaration for `MTDeviceCreateList()` or similar multi-device API in OpenMultitouchSupport’s bridge [3].

#### OpenMultitouchSupport surfaces device metadata but does not let callers choose a device

**Claim**: The callback includes a `deviceID` on emitted events, but that is observational metadata after the device has already been chosen, not a selection mechanism [2].

**Evidence** ([OpenMTManager.m#L187-L201](https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/Framework/OpenMultitouchSupportXCF/OpenMTManager.m#L187-L201) [2]):
```objective-c
static void contactEventHandler(MTDeviceRef eventDevice, MTTouch eventTouches[], int numTouches, double timestamp, int frame) {
    NSMutableArray *touches = [NSMutableArray array];
    ...
    OpenMTEvent *event = OpenMTEvent.new;
    event.touches = touches;
    event.deviceID = *(int *)eventDevice;
    event.frameID = frame;
    event.timestamp = timestamp;

    [OpenMTManager.sharedManager handleMultitouchEvent:event];
}
```

**Explanation**: `deviceID` proves the underlying private framework distinguishes devices, but OpenMultitouchSupport never uses that distinction to open a specific external device. It only reports the ID of whichever device was already opened via `MTDeviceCreateDefault()`.

#### The ancestor library shows the private framework can handle more than the default device

**Claim**: M5MultitouchSupport, which OpenMultitouchSupport cites as a reference, documents broader device coverage and implements it by enumerating all multitouch devices with `MTDeviceCreateList()` [4][5].

**Evidence** ([README.md#L1-L4](https://github.com/mhuusko5/M5MultitouchSupport/blob/f64fcccba07c484f578b1d958c309564fa8c387a/README.md#L1-L4) [4]):
```markdown
# M5MultitouchSupport

Easily and (thread/memory) safely consume global OS X multitouch (trackpad, Magic Mouse) events.
```

**Evidence** ([M5MultitouchManager.m#L191-L209](https://github.com/mhuusko5/M5MultitouchSupport/blob/f64fcccba07c484f578b1d958c309564fa8c387a/M5MultitouchSupport/M5MultitouchManager.m#L191-L209) [5]):
```objective-c
- (void)startHandlingMultitouchEvents {
    if (self.multitouchDevices.count) {
        return;
    }
    
    NSArray *mtDevices = (NSArray *)CFBridgingRelease(MTDeviceCreateList());
    
    int mtDeviceCount = (int)mtDevices.count;
    while (--mtDeviceCount >= 0) {
        id device = mtDevices[mtDeviceCount];
        
        @try {
            MTDeviceRef mtDevice = (__bridge MTDeviceRef)device;
            MTRegisterContactFrameCallback(mtDevice, mtEventHandler);
            MTDeviceStart(mtDevice, 0);
```

**Explanation**: This is decisive contrast with OpenMultitouchSupport. The ancestor library uses the private API in a multi-device way; OpenMultitouchSupport does not.

#### M5MultitouchSupport also preserves per-device event identity

**Claim**: The ancestor API treats device identity as a first-class property of each event, which is what a consumer would need if multiple devices can produce frames [5][6].

**Evidence** ([M5MultitouchEvent.h#L14-L18](https://github.com/mhuusko5/M5MultitouchSupport/blob/f64fcccba07c484f578b1d958c309564fa8c387a/M5MultitouchSupport/M5MultitouchEvent.h#L14-L18) [6]):
```objective-c
/** Array of M5MultitouchTouches associated with event. */
@property (strong, readonly) NSArray *touches;

/** Identifier of multitouch device (trackpad, Magic Mouse, etc.). Unique only per process. */
@property (assign, readonly) int deviceID;
```

**Explanation**: The upstream private-framework wrapper family clearly expects multiple device types to exist. OpenMultitouchSupport’s omission is wrapper-level scope, not proof that external Magic Trackpads are unsupported by the underlying framework.

#### Known upstream limitation unrelated to built-in vs external: sleep/wake lifecycle fragility

**Claim**: There is an independent known limitation in this API family around sleep/wake device lifecycle, but that explains post-sleep breakage rather than “internal works, external never does” [7][8].

**Evidence** ([OpenMultitouchSupport issue #2](https://github.com/Kyome22/OpenMultitouchSupport/issues/2) [7]):
```text
I experience the same issue as in M5MultitouchSupport https://github.com/mhuusko5/M5MultitouchSupport/issues/1 . Not releasing a device helps BTW as it's done in Touch-Tab.
```

**Evidence** ([M5MultitouchSupport issue #1](https://github.com/mhuusko5/M5MultitouchSupport/issues/1) [8]):
```text
I get EXC_BAD_INSTRUCTION when laptop wakes up after sleep.

It seems like it's an issue with MTDeviceRelease(mtDevice); line. When I comment out this line it works fine.
```

**Explanation**: This is a real upstream caveat, but it is about suspend/resume lifecycle. It does not contradict the stronger evidence that OpenMultitouchSupport is default-device-only.

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `OpenMultitouchSupport` README | Declares scope as trackpad on the “only default device” | [1] |
| 2 | `OpenMTManager.makeDevice` | Creates one `MTDeviceRef` via `MTDeviceCreateDefault()` | [2] |
| 3 | `OpenMTManager.startHandlingMultitouchEvents` | Registers callback and starts only that one device | [2] |
| 4 | `contactEventHandler` | Emits frames tagged with that chosen device’s `deviceID` | [2] |
| 5 | `M5MultitouchManager.startHandlingMultitouchEvents` | Contrasting ancestor code enumerates `MTDeviceCreateList()` and starts every device | [5] |
| 6 | `M5MultitouchEvent.deviceID` | Confirms multi-device event model in ancestor wrapper | [6] |

### Change Context
- History: OpenMultitouchSupport 3.0.3 still carries the same default-device scope in its tag `d7ec2276bea98711530dc610eb05563e9e1ce342`; I found no 3.0.3 release note or code path adding external-device selection [1][2][3].
- History: OpenMultitouchSupport explicitly cites M5MultitouchSupport as a reference, but narrows its device model from “trackpad, Magic Mouse” / device-list enumeration to a single default device [1][4][5].

### Caveats and Gaps
- I found no OpenMultitouchSupport issue or doc specifically mentioning “Magic Trackpad”; the strongest evidence is the default-device contract and single-device implementation, plus the ancestor library’s broader multi-device design.
- The sources show that the underlying MultitouchSupport private API distinguishes devices and that another wrapper enumerates them, but they do not prove which physical device macOS will designate as `MTDeviceCreateDefault()` when both internal and external trackpads are present.
- So the evidence-backed conclusion is: external Magic Trackpad support is plausible in the underlying private framework, but **not guaranteed through OpenMultitouchSupport 3.0.3’s API shape**.

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | docs | OpenMultitouchSupport README | tag 3.0.3 / `d7ec2276bea98711530dc610eb05563e9e1ce342` | States official scope as “only default device” | https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/README.md |
| [2] | code | `Framework/OpenMultitouchSupportXCF/OpenMTManager.m` | tag 3.0.3 / `d7ec2276bea98711530dc610eb05563e9e1ce342` | Decisive implementation of single-device selection and callback registration | https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/Framework/OpenMultitouchSupportXCF/OpenMTManager.m |
| [3] | code | `Framework/OpenMultitouchSupportXCF/OpenMTInternal.h` | tag 3.0.3 / `d7ec2276bea98711530dc610eb05563e9e1ce342` | Shows imported private API surface in this wrapper includes default-device APIs but not list enumeration | https://github.com/Kyome22/OpenMultitouchSupport/blob/d7ec2276bea98711530dc610eb05563e9e1ce342/Framework/OpenMultitouchSupportXCF/OpenMTInternal.h |
| [4] | docs | M5MultitouchSupport README | `f64fcccba07c484f578b1d958c309564fa8c387a` | Documents broader device support and serves as referenced ancestor contract | https://github.com/mhuusko5/M5MultitouchSupport/blob/f64fcccba07c484f578b1d958c309564fa8c387a/README.md |
| [5] | code | `M5MultitouchSupport/M5MultitouchManager.m` | `f64fcccba07c484f578b1d958c309564fa8c387a` | Shows multi-device enumeration via `MTDeviceCreateList()` and per-device start | https://github.com/mhuusko5/M5MultitouchSupport/blob/f64fcccba07c484f578b1d958c309564fa8c387a/M5MultitouchSupport/M5MultitouchManager.m |
| [6] | code | `M5MultitouchSupport/M5MultitouchEvent.h` | `f64fcccba07c484f578b1d958c309564fa8c387a` | Confirms ancestor event model includes per-device identity | https://github.com/mhuusko5/M5MultitouchSupport/blob/f64fcccba07c484f578b1d958c309564fa8c387a/M5MultitouchSupport/M5MultitouchEvent.h |
| [7] | issue | OpenMultitouchSupport issue #2 | opened 2023-02-22 | Documents known sleep/wake limitation in this wrapper family | https://github.com/Kyome22/OpenMultitouchSupport/issues/2 |
| [8] | issue | M5MultitouchSupport issue #1 | opened 2022-07-29 | Documents sleep/wake device-release failure in ancestor wrapper | https://github.com/mhuusko5/M5MultitouchSupport/issues/1 |

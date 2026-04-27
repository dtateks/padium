## Findings: MultitouchSupport / runtime device attach-detach and re-enumeration

### Direct Answer
- Fact: I found **no public reverse-engineered header or open-source consumer exposing MultitouchSupport symbols named `MTRegisterDeviceConnectedNotification`, `MTRegisterDeviceRemovedNotification`, `MTRegisterDeviceDisconnectedNotification`, or similar device-hotplug callbacks**. Across the inspected public headers and consumers, the MultitouchSupport SPI surface centers on device enumeration/creation (`MTDeviceCreateList`, `MTDeviceCreateDefault`, `MTDeviceCreateFromService`) and frame callbacks, not framework-level attach/detach notifications [1][2][3][4][5][6].
- Trace: The strongest evidence-backed runtime pattern for hotplug is **not** a MultitouchSupport notification API; it is either (a) periodically re-enumerating with `MTDeviceCreateList()` and restarting registrations when the device count changes, or (b) using **IOKit matching/termination notifications** for `AppleMultitouchDevice`, then creating/stopping `MTDeviceRef` objects via `MTDeviceCreateFromService` or re-registering the full device list [2][5][6].
- Synthesis: For Padium’s “external trackpad connected/reconnected while app is running stays dead until relaunch” bug, the public evidence supports treating hotplug as an **IOKit/device-list lifecycle problem above MultitouchSupport’s frame callback layer**, not as a missing call to a documented `MTRegisterDeviceConnectedNotification`-style SPI [1][2][5][6].

### Key Findings
#### No public evidence of MultitouchSupport-native hotplug notification symbols

**Claim**: The inspected reverse-engineered MultitouchSupport headers expose device constructors, lifecycle calls, metadata getters, and touch/path callbacks, but not device-attach/device-detach notification registration functions [1][2][3].

**Evidence** ([multitouch.h#L73-L105](https://github.com/fajran/tongseng/blob/master/multitouch.h#L73-L105) [1]):
```c
double MTAbsoluteTimeGetCurrent(void);
bool MTDeviceIsAvailable(void);

CFArrayRef MTDeviceCreateList(void);
MTDeviceRef MTDeviceCreateDefault(void);
MTDeviceRef MTDeviceCreateFromDeviceID(int64_t);
MTDeviceRef MTDeviceCreateFromService(io_service_t);
MTDeviceRef MTDeviceCreateFromGUID(uuid_t);
void MTDeviceRelease(MTDeviceRef);

OSStatus MTDeviceStart(MTDeviceRef, int);
OSStatus MTDeviceStop(MTDeviceRef);
bool MTDeviceIsRunning(MTDeviceRef);

void MTRegisterContactFrameCallback(MTDeviceRef, MTFrameCallbackFunction);
void MTUnregisterContactFrameCallback(MTDeviceRef, MTFrameCallbackFunction);
void MTRegisterPathCallback(MTDeviceRef, MTPathCallbackFunction);
void MTUnregisterPathCallback(MTDeviceRef, MTPathCallbackFunction);
```

**Evidence** ([MTSupportSPI.h#L89-L99](https://github.com/alphaArgon/ScrollToZoom/blob/main/ScrollToZoom/MTSupportSPI.h#L89-L99) [2]):
```objective-c
typedef int (*MTContactCallback)(MTDeviceRef, MTTouch const *touches, CFIndex touchCount, CFTimeInterval, MTFrameID, void *refcon);
void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallback);
void MTRegisterContactFrameCallbackWithRefcon(MTDeviceRef, MTContactCallback, void *refcon);

MTDeviceRef __nullable MTDeviceCreateFromService(io_service_t);
io_service_t MTDeviceGetService(MTDeviceRef);

static inline kern_return_t MTDeviceGetRegistryID(MTDeviceRef device, uint64_t *registryID) {
    io_registry_entry_t entry = MTDeviceGetService(device);
    return IORegistryEntryGetRegistryEntryID(entry, registryID);
}
```

**Evidence** ([MultitouchPrivate.h#L29-L35](https://github.com/pqrs-org/Karabiner-Elements/blob/main/src/apps/MultitouchExtension/src/MultitouchPrivate.h#L29-L35) [3]):
```c
typedef struct CF_BRIDGED_TYPE(id) MTDevice *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef, Finger *, int, double, int);

CFMutableArrayRef MTDeviceCreateList(void);
io_service_t MTDeviceGetService(MTDeviceRef);
void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTUnregisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
```

**Explanation**: These are the broadest public SPI declarations I found in reverse-engineered/open-source headers. None declare a MultitouchSupport-native “device connected/disconnected” registration function. That absence does not mathematically prove such a symbol never existed in some OS build, but it does mean the public reverse-engineering evidence here does **not** support relying on one.

#### Public consumers handle runtime hardware change by re-enumeration, not framework hotplug callbacks

**Claim**: M5MultitouchSupport handles runtime hardware changes by polling `MTDeviceCreateList()` and restarting all device registrations when the count changes [4].

**Evidence** ([M5MultitouchManager.m#L150-L168](https://github.com/mhuusko5/M5MultitouchSupport/blob/master/M5MultitouchSupport/M5MultitouchManager.m#L150-L168) [4]):
```objective-c
- (void)checkMultitouchHardware {
    ...
    NSArray *mtDevices = (NSArray *)CFBridgingRelease(MTDeviceCreateList());
    if (self.multitouchDevices.count && self.multitouchDevices.count != (int)mtDevices.count) {
        [self restartHandlingMultitouchEvents:nil];
    }
}
```

**Evidence** ([M5MultitouchManager.m#L191-L211](https://github.com/mhuusko5/M5MultitouchSupport/blob/master/M5MultitouchSupport/M5MultitouchManager.m#L191-L211) [4]):
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
        } @catch (NSException *exception) {}
```

**Explanation**: This is an accepted upstream pattern in a long-lived MultitouchSupport wrapper: watch the list shape, then tear down and rebuild registrations. It is explicit evidence that runtime device churn was solved in user space above the frame API rather than by a built-in MultitouchSupport device-notification callback.

- Trace: The same file’s teardown path unregisters callbacks, stops devices, and releases them before restart, so the re-enumeration pattern is a full lifecycle reset rather than an incremental add-only path [4].

#### Another public consumer delegates hotplug detection to IOKit and bridges back into MultitouchSupport

**Claim**: ScrollToZoom uses `IOServiceAddMatchingNotification` / `kIOTerminatedNotification` on `AppleMultitouchDevice`, then creates `MTDeviceRef` objects with `MTDeviceCreateFromService` and registers MultitouchSupport callbacks for newly matched devices [2][5].

**Evidence** ([STZDotDashDrag.c#L79-L122](https://github.com/alphaArgon/ScrollToZoom/blob/main/ScrollToZoom/STZDotDashDrag.c#L79-L122) [5]):
```c
CFMutableDictionaryRef properties = IOServiceMatching("AppleMultitouchDevice");
...
if (IOServiceAddMatchingNotification(mouseNotificationPort, kIOFirstMatchNotification,
                                     CFDictionaryCreateCopy(kCFAllocatorDefault, properties),
                                     anyMouseAdded, NULL, &addedIterator) != KERN_SUCCESS) {
    ...
}

if (IOServiceAddMatchingNotification(mouseNotificationPort, kIOTerminatedNotification,
                                     CFDictionaryCreateCopy(kCFAllocatorDefault, properties),
                                     anyMouseRemoved, NULL, &removedIterator) != KERN_SUCCESS) {
    ...
}

anyMouseAdded(NULL, addedIterator);
anyMouseRemoved(NULL, removedIterator);
```

**Evidence** ([STZDotDashDrag.c#L138-L163](https://github.com/alphaArgon/ScrollToZoom/blob/main/ScrollToZoom/STZDotDashDrag.c#L138-L163) [5]):
```c
while ((item = IOIteratorNext(iterator))) {
    MTDeviceRef device = MTDeviceCreateFromService(item);
    if (device) {
        uint32_t family = 0;
        MTDeviceGetFamilyID(device, &family);
        if (family == kMTDeviceFmailyMagicMouse) {
            uint64_t registryID = 0;
            IORegistryEntryGetRegistryEntryID(item, &registryID);
            CFDictionarySetValue(addedMice, uint64Key(registryID), device);

            MTDeviceStart(device, 0);
            MTRegisterContactFrameCallback(device, magicMouseTouched);
        }
```

**Evidence** ([STZDotDashDrag.c#L173-L184](https://github.com/alphaArgon/ScrollToZoom/blob/main/ScrollToZoom/STZDotDashDrag.c#L173-L184) [5]):
```c
while ((item = IOIteratorNext(iterator))) {
    if (addedMice) {
        uint64_t registryID = 0;
        IORegistryEntryGetRegistryEntryID(item, &registryID);

        MTDeviceRef device = (void *)CFDictionaryGetValue(addedMice, uint64Key(registryID));
        if (device) {
            MTDeviceStop(device);
            CFDictionaryRemoveValue(addedMice, uint64Key(registryID));
        }
    }
```

**Explanation**: This is the clearest public “runtime attach/detach” pattern I found. Hotplug detection comes from IOKit notifications; MultitouchSupport is used afterward to bind a device handle from the `io_service_t` and start/stop contact callbacks.

#### Karabiner’s MultitouchExtension also uses IOKit notifications, not MultitouchSupport device notifications

**Claim**: Karabiner-Elements observes `AppleMultitouchDevice` matching/termination notifications and responds by terminating/relaunching its extension, while its steady-state registration path always re-enumerates with `MTDeviceCreateList()` [3][6].

**Evidence** ([MultitouchDeviceManager.swift#L90-L115](https://github.com/pqrs-org/Karabiner-Elements/blob/main/src/apps/MultitouchExtension/src/MultitouchDeviceManager.swift#L90-L115) [6]):
```swift
for device in devices {
  MTDeviceStop(device, 0)
  MTUnregisterContactFrameCallback(device, callback)
}

devices.removeAll()

if register {
  devices = (MTDeviceCreateList().takeUnretainedValue() as? [MTDevice]) ?? []

  for device in devices {
    MTRegisterContactFrameCallback(device, callback)
    MTDeviceStart(device, 0)
  }
}
```

**Evidence** ([MultitouchDeviceManager.swift#L133-L158](https://github.com/pqrs-org/Karabiner-Elements/blob/main/src/apps/MultitouchExtension/src/MultitouchDeviceManager.swift#L133-L158) [6]):
```swift
func observeIONotification() {
  ...
  let match = IOServiceMatching("AppleMultitouchDevice") as NSMutableDictionary

  for notification in [
    kIOMatchedNotification,
    kIOTerminatedNotification,
  ] {
    ...
    let kr = IOServiceAddMatchingNotification(
      notificationPort,
      notification,
      match,
      { _, _ in
        NSApplication.shared.terminate(nil)
      },
```

**Explanation**: Karabiner is independent corroboration of the same architectural conclusion: the public workaround for Multitouch device churn is to watch IOKit and rebuild process/device state, not to subscribe to a MultitouchSupport-native attach/detach API.

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `MTDeviceCreateList` / `MTDeviceCreateFromService` | Public reverse-engineered SPI exposes enumeration and device construction from IOKit services | [1][2] |
| 2 | `IOServiceAddMatchingNotification(..., kIOFirstMatchNotification, ...)` | IOKit reports newly attached `AppleMultitouchDevice` services | [5][6] |
| 3 | `anyMouseAdded` / equivalent handler | Consumer converts `io_service_t` to `MTDeviceRef` with `MTDeviceCreateFromService` or re-enumerates the full list | [5][6] |
| 4 | `MTRegisterContactFrameCallback` + `MTDeviceStart` | Consumer begins receiving touch frames for the new device | [2][4][5][6] |
| 5 | `kIOTerminatedNotification` handler or count-change poll | Consumer detects device removal/disconnect | [4][5][6] |
| 6 | `MTUnregisterContactFrameCallback` / `MTDeviceStop` / restart | Consumer tears down stale registrations and rebuilds active device set | [4][5][6] |

### Caveats and Gaps
- I did **not** find a primary source proving that `MTRegisterDeviceConnectedNotification`-style symbols do not exist in every macOS build; the stronger and supportable statement is narrower: I found no public reverse-engineered header, open-source binding, or code-search hit exposing or using them [1][2][3][4][5][6].
- The most complete public attach/detach example I found is for Magic Mouse rather than external Magic Trackpad, but it still uses the same `AppleMultitouchDevice` + `MTDeviceCreateFromService` bridge that matters for MultitouchSupport device hotplug handling [2][5].
- Some consumers choose full-process restart on hotplug (Karabiner) while others re-enumerate in-process (M5MultitouchSupport, ScrollToZoom). The sources prove both are used patterns; they do not prove one is universally safer for every MultitouchSupport client [4][5][6].

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | code | `fajran/tongseng` `multitouch.h` | master as fetched 2026-04-27 | Broad public reverse-engineered MultitouchSupport header; decisive for available SPI names | https://github.com/fajran/tongseng/blob/master/multitouch.h |
| [2] | code | `alphaArgon/ScrollToZoom` `MTSupportSPI.h` | main as fetched 2026-04-27 | Newer public SPI header showing callback signature with refcon and `MTDeviceCreateFromService` | https://github.com/alphaArgon/ScrollToZoom/blob/main/ScrollToZoom/MTSupportSPI.h |
| [3] | code | `pqrs-org/Karabiner-Elements` `MultitouchPrivate.h` | main as fetched 2026-04-27 | Independent SPI declaration set used in production multitouch extension | https://github.com/pqrs-org/Karabiner-Elements/blob/main/src/apps/MultitouchExtension/src/MultitouchPrivate.h |
| [4] | code | `mhuusko5/M5MultitouchSupport` `M5MultitouchManager.m` | master as fetched 2026-04-27 | Open-source wrapper showing runtime re-enumeration pattern on device-count change | https://github.com/mhuusko5/M5MultitouchSupport/blob/master/M5MultitouchSupport/M5MultitouchManager.m |
| [5] | code | `alphaArgon/ScrollToZoom` `STZDotDashDrag.c` | main as fetched 2026-04-27 | Clearest public attach/detach implementation using IOKit notifications plus `MTDeviceCreateFromService` | https://github.com/alphaArgon/ScrollToZoom/blob/main/ScrollToZoom/STZDotDashDrag.c |
| [6] | code | `pqrs-org/Karabiner-Elements` `MultitouchDeviceManager.swift` | main as fetched 2026-04-27 | Independent production example using IOKit notifications and full re-enumeration/restart strategy | https://github.com/pqrs-org/Karabiner-Elements/blob/main/src/apps/MultitouchExtension/src/MultitouchDeviceManager.swift |

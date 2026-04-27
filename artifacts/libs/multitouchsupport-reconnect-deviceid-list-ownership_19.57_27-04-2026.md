## Findings: MultitouchSupport / hotplug-reconnect robustness, device identity, and ownership

### Direct Answer
- Fact: Public reverse-engineered headers expose both `MTDeviceGetDeviceID` and `MTDeviceGetService`, but the robust open-source clients I found do **not** trust `MTDeviceGetDeviceID` alone for runtime attach/detach tracking; the stronger pattern is to derive the underlying IOKit `AppleMultitouchDevice` registry entry ID from `MTDeviceGetService` and key reconnect logic off IOKit match/terminate notifications or a full re-enumeration/reset path [1][2][3].
- Trace: The best-supported explanation for “same external Magic Trackpad reconnect stays dead until app relaunch” is that a reconnect can recreate the underlying `AppleMultitouchDevice` service while leaving a prior `MTDeviceRef` or MultitouchSupport enumeration state stale; robust clients therefore either rebuild bindings from fresh `io_service_t` objects via `MTDeviceCreateFromService`, or terminate/re-enumerate all devices on IOKit hotplug events rather than relying on a stable MultitouchSupport device-ID signature [2][3][4].
- Fact: I found **no** public primary source proving that `MTDeviceGetDeviceID` changes or stays stable across disconnect/reconnect for Magic Trackpad. The evidence is narrower: public clients that need robust runtime reconnect behavior prefer IOKit service identity and full lifecycle reset, which implies that `MTDeviceGetDeviceID` equality is not sufficient evidence that the existing `MTDeviceRef` is still valid after hotplug [1][2][3][5].
- Fact: `MTDeviceCreateList()` is commonly treated as a Core Foundation “Create” result that callers own and must release exactly once; public clients either transfer ownership into ARC with `CFBridgingRelease` or call `CFRelease` on the returned array, while individual `MTDeviceRef`s are released only when the client separately owns them (for example via `MTDeviceCreateDefault`, `MTDeviceCreateFromService`, or an explicit `CFRetain`) [4][5][6][7].
- Synthesis: For a macOS app that must survive external Magic Trackpad disconnect/reconnect without restart, the most evidence-backed strategy is: **observe `AppleMultitouchDevice` via IOKit matched/terminated notifications, rebuild `MTDeviceRef`s from fresh services with `MTDeviceCreateFromService` or fully re-enumerate on every hotplug event, key device identity by IOKit registry entry ID instead of `MTDeviceGetDeviceID` alone, and optionally add a callback-silence watchdog as a fallback trigger for full rebind** [1][2][3][4].

### Key Findings
#### `MTDeviceGetDeviceID` is exposed, but robust reconnect code prefers IOKit identity

**Claim**: Public SPI exposes `MTDeviceGetDeviceID`, `MTDeviceGetService`, and a straightforward path from `MTDeviceRef` to the underlying IOKit registry entry ID, which is what robust clients actually use for runtime identity [1].

**Evidence** ([MTSupportSPI.h#L94-L100](https://github.com/alphaArgon/ScrollToZoom/blob/e8de6e83406b61f36f346a4fee489862869cd414/ScrollToZoom/MTSupportSPI.h#L94-L100) [1]):
```objective-c
MTDeviceRef __nullable MTDeviceCreateFromService(io_service_t);
io_service_t MTDeviceGetService(MTDeviceRef);

static inline kern_return_t MTDeviceGetRegistryID(MTDeviceRef device, uint64_t *registryID) {
    io_registry_entry_t entry = MTDeviceGetService(device);
    return IORegistryEntryGetRegistryEntryID(entry, registryID);
}
```

**Explanation**: The SPI itself gives clients a bridge from MultitouchSupport objects back to IOKit service identity. That matters because hotplug is an IOKit lifecycle event first. If a disconnect/reconnect recreates the underlying service, a stale `MTDeviceRef` can continue to exist as an object pointer while no longer representing the live hardware path.

- Fact: Another production client does exactly this conversion and passes the IOKit registry entry ID downstream with every frame instead of trusting the MultitouchSupport object identity alone [2].

**Evidence** ([MultitouchDeviceManager.swift#L3-L12](https://github.com/pqrs-org/Karabiner-Elements/blob/cb7db506fd59701657dc80582da4ec59b4bb7a41/src/apps/MultitouchExtension/src/MultitouchDeviceManager.swift#L3-L12) [2]):
```swift
func mtDeviceRegistryEntryID(of device: MTDevice?) -> UInt64? {
  let service = MTDeviceGetService(device)
  var entryID: UInt64 = 0
  let kr = IORegistryEntryGetRegistryEntryID(service, &entryID)

  guard kr == KERN_SUCCESS else {
    return nil
  }

  return entryID
}
```

**Explanation**: Karabiner treats the service registry entry ID as the stable key it can actually observe and compare. That is stronger evidence for reconnect handling than `MTDeviceGetDeviceID` because it is tied to the service instance that IOKit creates and destroys on hotplug.

- Caveat: I did not find a source that logs `MTDeviceGetDeviceID` before and after a Magic Trackpad reconnect and proves whether the numeric value stays the same. The supportable conclusion is behavioral: public robust clients avoid using it as the sole reconnect discriminator [1][2][3].

#### Public reconnect implementations do full lifecycle reset, not same-ID polling only

**Claim**: ScrollToZoom handles hotplug by subscribing to `AppleMultitouchDevice` match/terminate notifications, constructing a fresh `MTDeviceRef` from the newly matched `io_service_t`, and stopping the device when the service terminates [1][3].

**Evidence** ([STZDotDashDrag.c#L100-L122](https://github.com/alphaArgon/ScrollToZoom/blob/e8de6e83406b61f36f346a4fee489862869cd414/ScrollToZoom/STZDotDashDrag.c#L100-L122) [3]):
```c
if (IOServiceAddMatchingNotification(mouseNotificationPort, kIOFirstMatchNotification,
                                     CFDictionaryCreateCopy(kCFAllocatorDefault, properties) /* consumed */,
                                     anyMouseAdded, NULL, &addedIterator) != KERN_SUCCESS) {
    ...
}

if (IOServiceAddMatchingNotification(mouseNotificationPort, kIOTerminatedNotification,
                                     CFDictionaryCreateCopy(kCFAllocatorDefault, properties) /* consumed */,
                                     anyMouseRemoved, NULL, &removedIterator) != KERN_SUCCESS) {
    ...
}

anyMouseAdded(NULL, addedIterator);
anyMouseRemoved(NULL, removedIterator);
```

**Evidence** ([STZDotDashDrag.c#L150-L166](https://github.com/alphaArgon/ScrollToZoom/blob/e8de6e83406b61f36f346a4fee489862869cd414/ScrollToZoom/STZDotDashDrag.c#L150-L166) [3]):
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

        CFRelease(device);
    }
}
```

**Evidence** ([STZDotDashDrag.c#L173-L184](https://github.com/alphaArgon/ScrollToZoom/blob/e8de6e83406b61f36f346a4fee489862869cd414/ScrollToZoom/STZDotDashDrag.c#L173-L184) [3]):
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
}
```

**Explanation**: This code does not attempt “same `MTDeviceGetDeviceID` means the old handle is still good.” It reacts to service attach/detach, creates a fresh `MTDeviceRef` from the new service, and keys the active map by IOKit registry ID.

- Trace: The registry-ID map allows precise removal of the exact service instance that terminated, even if another device of the same family is still present [1][3].
- Version scope: ScrollToZoom main at `e8de6e83406b61f36f346a4fee489862869cd414` uses this pattern for Magic Mouse; the same `AppleMultitouchDevice` / `MTDeviceCreateFromService` mechanism is directly relevant to external Magic Trackpad hotplug because it is the same service class and bridge layer [1][3].

#### Polling `MTDeviceCreateList()` by count or ID is weaker than rebuilding on IOKit churn

**Claim**: M5MultitouchSupport’s runtime recovery strategy is only to compare `MTDeviceCreateList()` count and restart when the count changes, which corroborates that clients often need a full stop/start cycle—but it also shows why same-count reconnects can be missed [4].

**Evidence** ([M5MultitouchManager.m#L150-L168](https://github.com/mhuusko5/M5MultitouchSupport/blob/f64fcccba07c484f578b1d958c309564fa8c387a/M5MultitouchSupport/M5MultitouchManager.m#L150-L168) [4]):
```objective-c
- (void)checkMultitouchHardware {
    ...
    NSArray *mtDevices = (NSArray *)CFBridgingRelease(MTDeviceCreateList());
    if (self.multitouchDevices.count && self.multitouchDevices.count != (int)mtDevices.count) {
        [self restartHandlingMultitouchEvents:nil];
    }
}
```

**Evidence** ([M5MultitouchManager.m#L231-L243](https://github.com/mhuusko5/M5MultitouchSupport/blob/f64fcccba07c484f578b1d958c309564fa8c387a/M5MultitouchSupport/M5MultitouchManager.m#L231-L243) [4]):
```objective-c
MTDeviceRef mtDevice = (__bridge MTDeviceRef)device;
MTUnregisterContactFrameCallback(mtDevice, mtEventHandler);
MTDeviceStop(mtDevice);
MTDeviceRelease(mtDevice);
...
[self stopHandlingMultitouchEvents];
[self startHandlingMultitouchEvents];
```

**Explanation**: The recovery mechanism is a complete teardown/restart. But its trigger is only list-count change. If an external Magic Trackpad disappears and reappears as a replacement service while the overall list count remains unchanged, this strategy can miss the event entirely. That is directly consistent with your observed failure mode.

#### Another client explicitly resolves selected devices by `MTDeviceGetDeviceID`, but still recreates fresh refs from `MTDeviceCreateList()` each time

**Claim**: A newer OpenMultitouchSupport fork uses `MTDeviceGetDeviceID` as a user-facing selection key, but it does **not** keep old `MTDeviceRef`s alive across refresh; it re-enumerates the device list, retains a fresh match, and releases default-device fallbacks when the ID does not match [5].

**Evidence** ([OpenMTManager.m](https://raw.githubusercontent.com/RoversX/LaunchNext/main/LaunchNext/ThirdParty/OpenMultitouchSupport/Framework/OpenMultitouchSupportXCF/OpenMTManager.m) [5]):
```objective-c
CFArrayRef deviceList = MTDeviceCreateList();
if (deviceList) {
    CFIndex count = CFArrayGetCount(deviceList);
    for (CFIndex i = 0; i < count; i++) {
        MTDeviceRef deviceRef = (MTDeviceRef)CFArrayGetValueAtIndex(deviceList, i);
        uint64_t rawDeviceID = 0;
        OSStatus err = MTDeviceGetDeviceID(deviceRef, &rawDeviceID);
        if (!err) {
            NSString *resolvedID = [NSString stringWithFormat:@"%llu", rawDeviceID];
            if ([resolvedID isEqualToString:deviceID]) {
                foundDevice = deviceRef;
                CFRetain(foundDevice);
                break;
            }
        }
    }
    CFRelease(deviceList);
}
```

**Explanation**: This is the strongest public evidence in favor of using `MTDeviceGetDeviceID` as a selection key. But even here, the code still reacquires a fresh device ref from a fresh list every time rather than assuming the previous `MTDeviceRef` remains usable after device churn. That weakens the case for same-ID polling as a reconnect strategy.

- Fact: The same file stops running devices, releases owned refs, and repopulates `activeDevicesByID` on refresh/restart rather than trying to revive a stale pointer [5].

#### Production reconnect strategy can be “terminate and relaunch” when in-process rebinding is not trusted

**Claim**: Karabiner-Elements treats `AppleMultitouchDevice` matched/terminated notifications as a reason to terminate its helper process so launchd can relaunch it into a clean state, while its steady-state registration path always starts from a fresh `MTDeviceCreateList()` [2].

**Evidence** ([MultitouchDeviceManager.swift#L90-L115](https://github.com/pqrs-org/Karabiner-Elements/blob/cb7db506fd59701657dc80582da4ec59b4bb7a41/src/apps/MultitouchExtension/src/MultitouchDeviceManager.swift#L90-L115) [2]):
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

**Evidence** ([MultitouchDeviceManager.swift#L133-L169](https://github.com/pqrs-org/Karabiner-Elements/blob/cb7db506fd59701657dc80582da4ec59b4bb7a41/src/apps/MultitouchExtension/src/MultitouchDeviceManager.swift#L133-L169) [2]):
```swift
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

**Explanation**: This is evidence that even a mature production client does not assume in-process rebind is always reliable enough. A full helper-process restart is used as the safe response to device attach/detach or wake-related churn.

#### Ownership semantics: own the list result; release device refs only when you own them

**Claim**: Public clients consistently treat `MTDeviceCreateList()` as returning an owned Core Foundation object, and they distinguish that from device refs obtained out of the array, which are not individually released unless separately retained/created [4][5][6][7].

**Evidence** ([M5MultitouchManager.m#L165-L166](https://github.com/mhuusko5/M5MultitouchSupport/blob/f64fcccba07c484f578b1d958c309564fa8c387a/M5MultitouchSupport/M5MultitouchManager.m#L165-L166) [4]):
```objective-c
NSArray *mtDevices = (NSArray *)CFBridgingRelease(MTDeviceCreateList());
if (self.multitouchDevices.count && self.multitouchDevices.count != (int)mtDevices.count) {
```

**Evidence** ([OpenMTManager.m](https://raw.githubusercontent.com/RoversX/LaunchNext/main/LaunchNext/ThirdParty/OpenMultitouchSupport/Framework/OpenMultitouchSupportXCF/OpenMTManager.m) [5]):
```objective-c
CFArrayRef deviceList = MTDeviceCreateList();
if (deviceList) {
    ...
    CFRelease(deviceList);
}
```

**Evidence** ([tongseng.cpp#L253-L270](https://github.com/fajran/tongseng/blob/47df4a4cc6820e3dc36db364dc000b1d826d124f/tongseng.cpp#L253-L270) [6]):
```c
CFArrayRef devList = MTDeviceCreateList();
...
dev = (MTDeviceRef)CFArrayGetValueAtIndex(devList, dev_id);
MTRegisterContactFrameCallback(dev, callback);
MTDeviceStart(dev, 0);
...
MTUnregisterContactFrameCallback(dev, callback);
MTDeviceStop(dev);
MTDeviceRelease(dev);
```

**Evidence** ([multitouch.h#L76-L81](https://github.com/fajran/tongseng/blob/47df4a4cc6820e3dc36db364dc000b1d826d124f/multitouch.h#L76-L81) [7]):
```c
CFArrayRef MTDeviceCreateList(void);
MTDeviceRef MTDeviceCreateDefault(void);
MTDeviceRef MTDeviceCreateFromDeviceID(int64_t);
MTDeviceRef MTDeviceCreateFromService(io_service_t);
MTDeviceRef MTDeviceCreateFromGUID(uuid_t);
void MTDeviceRelease(MTDeviceRef);
```

**Explanation**: The array follows Core Foundation create-rule ownership. `CFBridgingRelease` is appropriate exactly once when you want ARC ownership of the array object. `CFRelease(deviceList)` is the manual equivalent. `MTDeviceRef`s obtained directly from the list are borrowed from the array unless you create/retain them separately; release them only if your code called `MTDeviceCreateDefault`, `MTDeviceCreateFromService`, `MTDeviceCreateFromDeviceID`, `CFRetain`, or if the framework’s documented/observed contract for the particular path says you now own the ref.

- Caveat: Public code is not perfectly consistent here. Some projects call `MTDeviceRelease` on refs pulled from the array after persisting them beyond the array lifetime, implying the array-provided refs remain valid but require explicit release once adopted [4][6]. The safest evidence-backed rule is: if you bridge-release or CF-release the list immediately, explicitly retain or recreate any `MTDeviceRef` you intend to keep past that list’s lifetime [5][7].

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `IOServiceMatching("AppleMultitouchDevice")` | IOKit defines the hardware attach/detach lifecycle boundary | [2][3] |
| 2 | `kIOMatchedNotification` / `kIOTerminatedNotification` | Client is told a multitouch service appeared or disappeared | [2][3] |
| 3 | `MTDeviceCreateFromService` or fresh `MTDeviceCreateList()` | Client creates fresh MultitouchSupport refs for currently live services | [1][2][3][5] |
| 4 | `MTDeviceGetService` → `IORegistryEntryGetRegistryEntryID` | Client derives live service identity suitable for attach/detach bookkeeping | [1][2] |
| 5 | `MTRegisterContactFrameCallback` + `MTDeviceStart` | New ref begins delivering touch frames | [2][3][4] |
| 6 | remove/timeout/reconnect | Client stops stale refs, releases owned handles, and rebuilds from live services | [2][3][4][5] |

### Change Context
- History: The public ecosystem shows three reconnect tiers rather than one canonical solution: count-change polling with full restart (M5MultitouchSupport) [4], IOKit hotplug plus in-process rebind from service (ScrollToZoom) [1][3], and IOKit hotplug plus full helper-process restart (Karabiner-Elements) [2].
- Synthesis: That spread is itself evidence that MultitouchSupport reconnect behavior is brittle enough that serious clients add a stronger lifecycle layer above it instead of trusting a single enumeration snapshot [2][3][4].

### Caveats and Gaps
- I found no primary source that directly measures whether `MTDeviceGetDeviceID` remains stable across a Magic Trackpad disconnect/reconnect. The current answer is therefore “not proven either way from public sources; insufficient as sole reconnect key because robust clients still rebuild off IOKit lifecycle.”
- I found no public source explicitly stating that `MTDeviceCreateList()` returns cached/stale refs. The supportable statement is behavioral: public robust clients assume enumeration alone may not be enough after hotplug and therefore rebind from IOKit notifications or restart the whole process.
- ScrollToZoom’s concrete hotplug example targets Magic Mouse family `112`, not Magic Trackpad family `128/129/130`; the attach/detach plumbing still applies because it is driven by the same `AppleMultitouchDevice` service class [3][5].
- Public ownership examples are somewhat inconsistent around releasing refs obtained from `MTDeviceCreateList()`. The conservative practical rule is to keep array ownership and device-ref ownership separate, and explicitly retain/recreate a device ref before storing it past the array lifetime [4][5][6][7].

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | code | `alphaArgon/ScrollToZoom` `MTSupportSPI.h` | `e8de6e83406b61f36f346a4fee489862869cd414` | Reverse-engineered SPI showing `MTDeviceCreateFromService`, `MTDeviceGetService`, and registry-ID bridge | https://github.com/alphaArgon/ScrollToZoom/blob/e8de6e83406b61f36f346a4fee489862869cd414/ScrollToZoom/MTSupportSPI.h |
| [2] | code | `pqrs-org/Karabiner-Elements` `MultitouchDeviceManager.swift` | `cb7db506fd59701657dc80582da4ec59b4bb7a41` | Production client using IOKit notifications, registry-entry IDs, and full restart/re-enumeration | https://github.com/pqrs-org/Karabiner-Elements/blob/cb7db506fd59701657dc80582da4ec59b4bb7a41/src/apps/MultitouchExtension/src/MultitouchDeviceManager.swift |
| [3] | code | `alphaArgon/ScrollToZoom` `STZDotDashDrag.c` | `e8de6e83406b61f36f346a4fee489862869cd414` | Clearest public in-process hotplug implementation using `AppleMultitouchDevice` notifications and `MTDeviceCreateFromService` | https://github.com/alphaArgon/ScrollToZoom/blob/e8de6e83406b61f36f346a4fee489862869cd414/ScrollToZoom/STZDotDashDrag.c |
| [4] | code | `mhuusko5/M5MultitouchSupport` `M5MultitouchManager.m` | `f64fcccba07c484f578b1d958c309564fa8c387a` | Public wrapper showing count-based polling and full stop/start reset | https://github.com/mhuusko5/M5MultitouchSupport/blob/f64fcccba07c484f578b1d958c309564fa8c387a/M5MultitouchSupport/M5MultitouchManager.m |
| [5] | code | `RoversX/LaunchNext` vendored `OpenMultitouchSupport` `OpenMTManager.m` | `main` as fetched 2026-04-27 | Public code that uses `MTDeviceGetDeviceID` for selection while reacquiring fresh refs and releasing owned devices correctly | https://raw.githubusercontent.com/RoversX/LaunchNext/main/LaunchNext/ThirdParty/OpenMultitouchSupport/Framework/OpenMultitouchSupportXCF/OpenMTManager.m |
| [6] | code | `fajran/tongseng` `tongseng.cpp` | `47df4a4cc6820e3dc36db364dc000b1d826d124f` | Older client showing direct `MTDeviceCreateList` use and explicit `MTDeviceRelease` lifecycle | https://github.com/fajran/tongseng/blob/47df4a4cc6820e3dc36db364dc000b1d826d124f/tongseng.cpp |
| [7] | code | `fajran/tongseng` `multitouch.h` | `47df4a4cc6820e3dc36db364dc000b1d826d124f` | Reverse-engineered header confirming Create-rule function surface and `MTDeviceRelease` availability | https://github.com/fajran/tongseng/blob/47df4a4cc6820e3dc36db364dc000b1d826d124f/multitouch.h |

### Evidence Appendix
**Recommended runtime policy distilled from the public implementations** [1][2][3][4]:

1. Treat `AppleMultitouchDevice` IOKit notifications as the primary hotplug signal.
2. On any match/terminate event, stop all active MT devices, discard stored refs, and rebuild from fresh services or a fresh `MTDeviceCreateList()`.
3. Use `MTDeviceGetService` + registry entry ID for runtime identity bookkeeping.
4. Keep `MTDeviceGetDeviceID` only as a user-facing selection key or secondary metadata field.
5. If hotplug notifications are unavailable or missed, add a callback-silence watchdog that triggers the same full rebind path rather than trying to “poke” old refs back to life.

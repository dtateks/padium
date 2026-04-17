## Findings: macOS gesture listener/runtime permissions

### Research Metadata
- Question: Research external macOS behavior relevant to a field failure where a SwiftUI menu bar app that observes trackpad gestures via OpenMultitouchSupport/MultitouchSupport, creates a CGEventTap for scroll/click suppression, and posts synthetic keyboard shortcuts via CGEvent works on one Mac but is dead on another after the user granted permissions.
- Type: MIXED
- Target: macOS TCC / CoreGraphics event taps / code signing / MultitouchSupport / OpenMultitouchSupport
- Version Scope: macOS Catalina → Tahoe-era evidence, with Apple docs/support/forum/repo reports current through 2026-04-18
- Generated: 00.59_18-04-2026
- Coverage: PARTIAL

### Direct Answer
- Fact: For modern macOS, a passive `CGEventTap` listener belongs to **Input Monitoring**, while a tap that modifies the event stream or synthetic keyboard injection belongs to the **Accessibility / post-event** path. Apple’s Catalina security talk draws the split explicitly: listen-only taps require Input Monitoring, modifying taps require Accessibility, and synthetic input uses `kIOHIDRequestTypePostEvent` [1][2][3][5].
- Fact: Yes, `AXIsProcessTrusted()` can be a false positive for your app’s real runtime needs. Apple’s docs only say it returns whether the process is a trusted accessibility client; Apple DTS and field reports show cases where that returns `true` but the actual `CGEventTap` or accessibility behavior still fails after updates/signature changes, so you need a live probe, not the boolean alone [4][5][6].
- Fact: TCC persistence is sensitive to **code identity** and, for non-bundled executables/launch jobs, can be **path-sensitive**. Apple’s code-signing technote says privacy-protected resources are tracked by designated requirement/code identity and that mutually compatible DRs share access; Apple forum guidance adds that command-line tools may be identified in TCC by full path and that stable signing identity is the fix [7][8].
- Fact: Best practice is to surface each dependency separately: check/report Accessibility and Input Monitoring independently, re-check after returning from System Settings or wake, and fail with a precise remediation when a functional probe fails. Don’t collapse it into one generic “permission granted” state [3][4][5][6][7][8].
- Fact: OpenMultitouchSupport / MultitouchSupport are fragile around sleep-wake and teardown. The strongest reports describe MT device release/stop races after sleep, and production apps work around this by restarting on wake or avoiding immediate stop/release; the library itself only documents the built-in/default device path and sandbox-off requirement [9][10][11][12].

### Key Findings
#### 1) CGEventTap listening vs synthetic keyboard posting

**Claim**: On Catalina-and-later macOS, a passive `CGEventTap` listener needs Input Monitoring, while a tap that can alter the stream and synthetic keyboard injection use the Accessibility/post-event path [1][2][3][5].

**Evidence** ([WWDC19 Advances in macOS Security](https://developer.apple.com/videos/play/wwdc2019/701/?time=1460) [1]):
```text
... a listenOnly event requires authorization for input monitoring, a modifying event app requires authorization for accessibility features.
... apps may check the authorization status without triggering the approval prompt, using the IOHIDCheckAccess function with the kIOHIDRequestTypeListenEvent parameter.
... apps can request an approval dialog to be displayed without creating an event tab or trying to post an event by using the IOHIDRequestAccess function ...
... using the kIOHIDRequestTypePostEvent instead.
```

**Evidence** ([Apple Support: Control access to input monitoring on Mac](https://support.apple.com/guide/mac-help/control-access-to-input-monitoring-on-mac-mchl4cedafb6/mac) [3]):
```text
Some apps can monitor your keyboard, mouse, or trackpad even when you’re using other apps.
... click Input Monitoring. For each app in the list, turn the ability to monitor your input devices on or off.
```

**Evidence** ([Apple Support: Allow accessibility apps to access your Mac](https://support.apple.com/guide/mac-help/control-access-to-your-mac-mh43185/mac) [4]):
```text
When a third-party app tries to access and control your Mac through accessibility features, you receive an alert, and you must specifically grant the app access ...
```

**Explanation**: The modern split is not “one permission for all keyboard work.” If you only observe, you need Input Monitoring. If you modify or synthesize input, you’re in the Accessibility/post-event path.

#### 2) Why `AXIsProcessTrusted()` can lie for your runtime

**Claim**: `AXIsProcessTrusted()` is necessary but not sufficient; a `true` result does not guarantee the tap or synthetic path still works after app updates, re-signs, or helper relaunches [4][5][6].

**Evidence** ([Apple Developer Documentation: AXIsProcessTrusted()](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted) [4]):
```text
Returns whether the current process is a trusted accessibility client.
```

**Evidence** ([Apple Developer Forum: Determining if Accessibility (for CGEventTap) access was revoked?](https://developer.apple.com/forums/thread/744440) [5]):
```text
If you’re using just CGEventTap, there’s CGPreflightListenEventAccess, CGRequestListenEventAccess, CGPreflightPostEventAccess, and CGRequestPostEventAccess.
You only need the Accessibility privilege if you’re doing other stuff with Accessibility ...
```

**Evidence** ([MiddleClick issue #162](https://github.com/artginzburg/MiddleClick/issues/162) [6]):
```text
After updating MiddleClick, macOS may silently invalidate the Accessibility permission. `AXIsProcessTrusted()` can still return `true` (false positive), but actual event taps fail.
```

**Explanation**: `AXIsProcessTrusted()` only answers “is this process trusted as an accessibility client?” It does not prove that the exact event-tap or posting path you rely on is still valid. Use the Boolean as a gate, then do a real capability probe.

#### 3) TCC identity, designated requirements, and path sensitivity

**Claim**: Apple documents TCC-relevant identity as code-signature/DR based, and Apple support/forum guidance shows that non-bundled executables can be tracked by path rather than bundle ID [7][8].

**Evidence** ([TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) [7]):
```text
When working with privacy-protected resources on macOS, like the microphone, you might find that the system fails to remember your choices during development.
The DR is part of the code signature.
... if the user grants the Mac App Store app access ... the Developer ID app gains access as well.
```

**Evidence** ([Apple Developer Forum: How to remove executable applications ...](https://developer.apple.com/forums/thread/697278) [8]):
```text
The trick here is to give your command-line tool a bundle ID.
... my executable seems to have no bundle ID ... and I don't know how to remove it.
... it’s identified by path within TCC.db rather than its bundle id.
```

**Explanation**: For bundled apps, stable signing identity / compatible DR matters most. For command-line tools and some launchd jobs, the path can be the identity anchor, which explains why moving, re-wrapping, or re-signing can make permissions look “lost” across machines.

#### 4) Best-practice UX/diagnostics for multi-permission runtime apps

**Claim**: The best upstream-backed pattern is separate capability checks, separate user-facing states, and a real runtime probe before you claim success [3][4][5][6][7][8].

**Evidence** ([Apple Support: Control access to input monitoring on Mac](https://support.apple.com/guide/mac-help/control-access-to-input-monitoring-on-mac-mchl4cedafb6/mac) [3]):
```text
For each app in the list, turn the ability to monitor your input devices on or off.
```

**Evidence** ([Apple Support: Allow accessibility apps to access your Mac](https://support.apple.com/guide/mac-help/control-access-to-your-mac-mh43185/mac) [4]):
```text
To review app permissions ... click Accessibility.
```

**Evidence** ([Apple DTS forum guidance](https://developer.apple.com/forums/thread/744440) [5]):
```text
If you’re using just CGEventTap, there’s CGPreflightListenEventAccess ... and CGPreflightPostEventAccess ...
```

**Explanation**: Model the app as a set of independent capabilities, not a single “permissions granted” flag. Show which subsystem failed (listen tap, post event, accessibility, multitouch device init), then link the user to the exact pane or relaunch step. Re-check on activation/wake because TCC and private frameworks can go stale.

#### 5) OpenMultitouchSupport / MultitouchSupport startup fragility

**Claim**: The concrete fragility is sleep/wake and teardown racing; the sources do not prove a universal first-run hardware-init bug, but they do show the framework path is private, default-device-only, and prone to wake-time breakage [9][10][11][12].

**Evidence** ([Kyome22/OpenMultitouchSupport README](https://github.com/Kyome22/OpenMultitouchSupport) [9]):
```text
This enables you easily to observe global multitouch events on the trackpad (only default device).
App SandBox must be disabled to use OpenMultitouchSupport.
```

**Evidence** ([mhuusko5/M5MultitouchSupport issue #1](https://github.com/mhuusko5/M5MultitouchSupport/issues/1) [10]):
```text
I get EXC_BAD_INSTRUCTION when laptop wakes up after sleep.
... Looks like MTDeviceRelease() sort of happens automatically on system sleep, and an object can't be released twice.
... Only not releasing a device works for me ...
```

**Evidence** ([Multitouch Community FAQ](https://github.com/rxhanson/Multitouch-Community) [11]):
```text
The app stops recognizing gestures when my mac wakes from sleep and I have to restart the app.
... Try enabling "Avoid private framework" ...
```

**Evidence** ([Stack Overflow: MTDeviceStop immediately after unregister can crash](https://stackoverflow.com/questions/79879212/why-does-macos-multitouchsupport-framework-crash-if-mtdevicestop-is-called-immed) [12]):
```text
If I call MTDeviceStop() immediately after MTUnregisterContactFrameCallback(), the app intermittently crashes ...
Adding a ~50ms delay between unregister and stop eliminates the crashes.
The issue is worse during system wake from sleep.
```

**Explanation**: If your OMS listener starts once on one machine but dies on another, the first suspects are wake-time teardown/init races, invalid device state after sleep, or a code-sign/TCC change that makes the private framework path unusable.

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `CGEventTapCreate` / `CGEvent.post(tap:)` | Listener/injector reaches the Quartz path; permission scope depends on whether you are only observing or also modifying/injecting | [1][2][5] |
| 2 | `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` | Modern request/check path for Input Monitoring | [1][5] |
| 3 | `IOHIDRequestAccess(kIOHIDRequestTypePostEvent)` / accessibility trust | Synthetic keyboard posting / controlling other apps belongs to the Accessibility-post-event side | [1][4][5] |
| 4 | `AXIsProcessTrusted()` | Boolean trust check only; can be stale or too coarse | [4][6] |
| 5 | TCC / DR / bundle ID / path | Stable identity determines whether the system considers a later build “the same app” | [7][8] |
| 6 | `OMSManager.startListening()` / MTDevice lifecycle | Private multitouch device starts are sensitive to sleep/wake and stop/release ordering | [9][10][11][12] |

### Caveats and Gaps
- I did not find an Apple doc that explicitly states “`CGEvent.post(tap:)` itself requires Accessibility” as a standalone sentence; the stronger evidence is the WWDC19 split between listen-only/Input Monitoring and modifying/post-event/Accessibility [1][5].
- The sources support sleep/wake fragility strongly, but they do not prove a single universal first-launch hardware-init bug for OpenMultitouchSupport [9][10][11][12].
- Install-path sensitivity is most directly documented for non-bundled executables and launch jobs; bundled-app TCC identity is more cleanly explained by DR/signature stability [7][8].

### Confidence
**Level:** MEDIUM
**Rationale:** The permission split and stale-trust behavior are strongly supported by Apple/field sources. The exact TCC identity model across all app forms is partly inferred from Apple forum guidance plus technote material, and the OpenMultitouchSupport startup-failure evidence is strongest for sleep/wake rather than fresh-machine init.

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | docs | WWDC19 “Advances in macOS Security” transcript | 2019-06-04 | Canonical Apple explanation of listen-only vs modifying event taps and listen/request post-event access | https://developer.apple.com/videos/play/wwdc2019/701/?time=1460 |
| [2] | docs | Apple Developer Docs: Quartz Event Services / `CGEventTapCreate` / `CGEvent.post(tap:)` / `CGEventTapLocation` | current | Confirms event taps and event posting are first-class Quartz mechanisms | https://developer.apple.com/documentation/coregraphics/quartz_event_services |
| [3] | docs | Apple Support: Control access to input monitoring on Mac | current | Official user-facing Input Monitoring pane behavior | https://support.apple.com/guide/mac-help/control-access-to-input-monitoring-on-mac-mchl4cedafb6/mac |
| [4] | docs | Apple Support: Allow accessibility apps to access your Mac | current | Official user-facing Accessibility permission pane behavior | https://support.apple.com/guide/mac-help/control-access-to-your-mac-mh43185/mac |
| [5] | forum | Apple Developer Forum: Determining if Accessibility (for CGEventTap) access was revoked? | Jan 2024 | DTS answer distinguishing CGEventTap-only permissions from Accessibility and naming CGPreflight/Request APIs | https://developer.apple.com/forums/thread/744440 |
| [6] | issue | artginzburg/MiddleClick #162 | 2026-03-23 | Field report of `AXIsProcessTrusted()==true` while event taps fail | https://github.com/artginzburg/MiddleClick/issues/162 |
| [7] | docs | TN3127: Inside Code Signing: Requirements | current | Apple’s code-identity / DR explanation for privacy-protected resources | https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements |
| [8] | forum | Apple Developer Forum: How to remove executable applications / TCC path identity discussion | 2022-2025 | Shows bundle-ID vs path behavior and stable-signing advice for TCC-like permissions | https://developer.apple.com/forums/thread/697278 |
| [9] | docs | Kyome22/OpenMultitouchSupport README | 3.0.3 / main | Official usage and scope of the raw multitouch wrapper | https://github.com/Kyome22/OpenMultitouchSupport |
| [10] | issue | mhuusko5/M5MultitouchSupport #1 | 2022-07 | Sleep/wake crash and MTDeviceRelease race report | https://github.com/mhuusko5/M5MultitouchSupport/issues/1 |
| [11] | repo/docs | Multitouch Community FAQ | 2025-11 | Production-app troubleshooting for wake-related gesture loss and private-framework fallback | https://github.com/rxhanson/Multitouch-Community |
| [12] | secondary | Stack Overflow: MTDeviceStop after unregister crash | 2026-01 | Strongly suggests stop/unregister race; worse during wake | https://stackoverflow.com/questions/79879212/why-does-macos-multitouchsupport-framework-crash-if-mtdevicestop-is-called-immed |

### Evidence Appendix
#### Apple’s permission split in one place
```text
listenOnly event requires authorization for input monitoring
modifying event app requires authorization for accessibility features
... request access ... kIOHIDRequestTypeListenEvent
... using the kIOHIDRequestTypePostEvent instead
```
[WWDC19 transcript](https://developer.apple.com/videos/play/wwdc2019/701/?time=1460) [1]

#### Apple’s DTS guidance for CGEventTap-only apps
```text
If you’re using just CGEventTap, there’s CGPreflightListenEventAccess, CGRequestListenEventAccess, CGPreflightPostEventAccess, and CGRequestPostEventAccess.
You only need the Accessibility privilege if you’re doing other stuff with Accessibility ...
```
[Apple DTS forum](https://developer.apple.com/forums/thread/744440) [5]

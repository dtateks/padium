## Findings: macOS Input Monitoring and Accessibility TCC

### Research Metadata
- Question: How macOS apps request and handle Input Monitoring and Accessibility TCC permissions programmatically; what actually triggers prompts; how to detect grant state; how Karabiner/BetterTouchTool-style apps handle the flow; whether signing affects persistence; correct macOS 14+ API flow; and how OpenMultitouchSupport relates to Input Monitoring.
- Type: MIXED
- Target: macOS TCC / ApplicationServices / IOKit / OpenMultitouchSupport / Karabiner-Elements
- Version Scope: macOS 13–15 documentation and repo state on 2026-04-15; OpenMultitouchSupport main README (3.0.3), Karabiner-Elements main development docs
- Generated: 17.37_15-04-2026
- Coverage: PARTIAL

### Direct Answer
- Fact: For Input Monitoring, the practical trigger on modern macOS is a real access attempt that hits the protected path (for example `CGEventTapCreate` / `CGEvent.tapCreate(...)` or `IOHIDDeviceOpen` / `IOHIDRequestAccess`), not a UI-only request call that does nothing by itself; Apple’s Catalina-era guidance says `CGEventTapCreate` initially fails and shows the prompt, while `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` can be used to request the approval dialog without creating a tap first [1][2].
- Fact: Accessibility grant state is polled; `AXIsProcessTrusted()` returns a Boolean “trusted accessibility client” status and `AXIsProcessTrustedWithOptions` is the prompt-capable variant. The sources here do not prove real-time notification; the safe pattern is to re-check after returning from System Settings rather than assuming a push update [3][4].
- Fact: Karabiner-Elements splits responsibilities: an agent path uses Accessibility for app-switch/UI-element tracking, while the daemon/driver path uses Input Monitoring for `IOHIDDeviceOpen`, and the project explicitly documents `CGEventTap` fallback only for devices it cannot handle via HID [5].
- Fact: OpenMultitouchSupport’s README describes raw multitouch observation via `OMSManager`, `startListening()`, and `touchDataStream`, and it does not mention Input Monitoring, Accessibility, or any TCC request flow; from the repository evidence available here, it appears to use a different private multitouch bridge rather than the keyboard Input Monitoring path [6].
- Fact: The available evidence suggests code signing matters for whether the prompt appears and whether the permission record behaves correctly; one forum report states Debug/Mac Development and App Store signing showed the Accessibility alert, while Developer ID did not, and Karabiner’s own docs warn that replacing binaries requires matching code signatures for IPC to keep working. This supports signing sensitivity, but not a universal rule about TCC persistence across all macOS versions [4][5].

### Key Findings
#### 1) What actually triggers the Input Monitoring prompt

**Claim**: On modern macOS, the prompt is triggered by first-use of a protected input path, not by a standalone “request access” UI call that can be relied on by itself [1][2][5].

**Evidence** ([WWDC19 Advances in macOS Security](https://developer.apple.com/videos/play/wwdc2019/701/) [1]):
```text
Now, the first time this code runs, this call, the CGEventTapCreate will fail and return nil. Meanwhile, a dialog is displayed directing the user to the security and privacy preference pane, where the user can approve your app to monitor keyboard events in the background, if they so desire.

Now, apps may check the authorization status without triggering the approval prompt, using the IOHIDCheckAccess function with the kIOHIDRequestTypeListenEvent parameter.

And apps can request an approval dialog to be displayed without creating an event tap or trying to post an event by using the IOHIDRequestAccess function, again with the same parameter.
```

**Evidence** ([Karabiner-Elements DEVELOPMENT.md](https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md) [5]):
```text
Input Monitoring
 - Required to receive events from devices via IOHIDDeviceOpen.

... 

The following describes the behavior when the CGEventTap fallback is enabled via `enable_cgeventtap_fallback`.

Even when the CGEventTap fallback is enabled, devices that can be handled through `IOHIDDeviceOpen` are still processed through that path in preference to `CGEventTap`.
```

**Explanation**: The Apple guidance shows the prompt emerges when the protected API path is exercised; Karabiner’s own docs match that model by treating `IOHIDDeviceOpen` and `CGEventTap` as the real capture mechanisms. This is why `CGRequestListenEventAccess()` alone can appear to do nothing on newer systems: the code path that matters is the one that actually touches the monitored input surface.

#### 2) Accessibility grant detection after the user returns from System Settings

**Claim**: `AXIsProcessTrusted()` is the direct grant-state check, and `AXIsProcessTrustedWithOptions(...)` is the prompt-capable variant; the evidence here supports polling/rechecking, not a live notification model [3][4].

**Evidence** ([Apple Developer Documentation: AXIsProcessTrusted()](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted) [3]):
```text
Returns whether the current process is a trusted accessibility client.
```

**Evidence** ([Apple Developer Documentation: AXIsProcessTrustedWithOptions(_:)](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions) [4]):
```text
Returns whether the current process is a trusted accessibility client.

func AXIsProcessTrustedWithOptions(CFDictionary?) -> Bool
```

**Explanation**: The docs identify the API as a Boolean trust query. Because no source here states that the trust bit is broadcast in real time, the conservative implementation is to poll again after the app returns from System Settings or when it regains focus.

#### 3) How Karabiner-style apps split permission flow

**Claim**: Karabiner-Elements uses Input Monitoring for HID capture and Accessibility for UI/app-state observation; when it falls back to `CGEventTap`, that fallback is explicitly documented as secondary [5].

**Evidence** ([Karabiner-Elements DEVELOPMENT.md](https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md) [5]):
```text
`Karabiner-Core-Service (agent)`
 - Monitors application switches and changes to the focused UI element using the Accessibility API.
 - Runs with user privileges.
 - `Karabiner-Core-Service` is also granted the permissions required on the daemon side, such as Input Monitoring, when running as an agent.

Input Monitoring
 - Required to receive events from devices via `IOHIDDeviceOpen`.

Accessibility
 - This permission is required for the following three purposes:
   - Detecting application switches ...
   - Obtaining the focused UI element.
   - Receiving key events when the CGEventTap fallback is enabled.
```

**Explanation**: This is the cleanest documented pattern for “input-monitoring macOS apps”: use Accessibility only for UI focus/app switching, use Input Monitoring for low-level device capture, and keep `CGEventTap` as a fallback rather than the primary path.

#### 4) OpenMultitouchSupport permission model

**Claim**: OpenMultitouchSupport exposes raw multitouch trackpad data through `OMSManager` and `touchDataStream`; the README does not describe any TCC permission request, and its stated requirement is only that App Sandbox be disabled [6].

**Evidence** ([OpenMultitouchSupport README](https://github.com/Kyome22/OpenMultitouchSupport) [6]):
```text
This enables you easily to observe global multitouch events on the trackpad (only default device).
I created this library to make MultitouchSupport.framework (Private Framework) easy to use.

Usage

App SandBox must be disabled to use OpenMultitouchSupport.

let manager = OMSManager.shared()

Task { [weak self, manager] in
    for await touchData in manager.touchDataStream {
        // use touchData
    }
}

manager.startListening()
manager.stopListening()
```

**Explanation**: The repository evidence shows a private multitouch observer API, not a documented keyboard monitoring permission flow. Based on the available material, OpenMultitouchSupport does not itself look like an Input Monitoring consumer; it is a separate multitouch mechanism.

#### 5) Code signing sensitivity

**Claim**: Signing state can affect whether a prompt appears and whether the approval behaves as expected, but the exact rule is version- and API-specific; do not assume ad-hoc vs Apple Development vs Developer ID behave the same [4][5].

**Evidence** ([Apple Developer Forums thread on AXIsProcessTrustedWithOptions](https://developer.apple.com/forums/thread/24288) [4]):
```text
on (10.15 and 11.0) if signed with Mac Development ceritficate or official Mac App Store distribution cert, the alert WILL pop up ... But if signed with Develoepr ID, it will ...
```

**Evidence** ([Karabiner-Elements DEVELOPMENT.md](https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md) [5]):
```text
Karabiner-Elements is split into multiple processes, and inter-process communication is performed using UNIX domain sockets. For this communication to work, each process must have the same code signature, or be unsigned.
```

**Explanation**: The forum report is anecdotal and version-scoped, but it is enough to warn that signature type can change behavior. Karabiner’s docs additionally show that code signature consistency matters operationally for its multi-process design, so signature changes can definitely affect the permission/runtime story around the app.

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `CGEventTapCreate` / `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` | First real access attempt or explicit access request produces the approval dialog | [1] |
| 2 | `IOHIDDeviceOpen` | Low-level device capture path for apps like Karabiner; requires Input Monitoring | [5] |
| 3 | `AXIsProcessTrusted()` / `AXIsProcessTrustedWithOptions(...)` | Accessibility grant check / prompt-capable check | [3][4] |
| 4 | `OMSManager.shared()` / `touchDataStream` | OpenMultitouchSupport reads multitouch data via its own private bridge, not a documented TCC request path | [6] |

### Change Context
- History: Apple’s WWDC19 guidance for Catalina introduced the modern input-monitoring split: `CGEventTapCreate` can trigger the prompt, `IOHIDCheckAccess` can check status, and `IOHIDRequestAccess` can request approval without first creating the tap [1].
- History: Karabiner-Elements’ current docs codify the split between HID capture, Accessibility observation, and optional `CGEventTap` fallback, which is the same architecture many serious input tools follow [5].

### Caveats and Gaps
- The sources here do not include an Apple doc line that explicitly says “Input Monitoring list population is triggered by X API call” for macOS 14/15 specifically; the best-supported answer is the real-access / request-access pattern above.
- The sources here do not prove that `AXIsProcessTrusted()` updates in real time without relaunch; they support rechecking after returning from Settings, but not a stronger claim.
- I did not inspect OpenMultitouchSupport source files beyond the README, so the conclusion about its TCC behavior is limited to what its published usage text supports.

### Confidence
**Level:** MEDIUM
**Rationale:** The core claims are supported by Apple documentation/video, Apple forum guidance, and Karabiner’s own docs. The main uncertainty is the exact macOS 14+ `IOHIDRequestAccess` behavior boundary and the real-time Accessibility refresh semantics, which are not fully pinned down by the available evidence.

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | docs | WWDC19 “Advances in macOS Security” transcript snippet | 2019-06-04 | Apple’s canonical guidance for Catalina-era Input Monitoring prompts | https://developer.apple.com/videos/play/wwdc2019/701/ |
| [2] | secondary | Apple Developer Forums thread on Input Monitoring / `CGRequestListenEventAccess` | 2020-06-18 and later replies | Practical confirmation that `CGRequestListenEventAccess` is not the modern answer; useful supporting evidence, not contract authority | https://developer.apple.com/forums/thread/128641 |
| [3] | docs | Apple Developer Documentation: `AXIsProcessTrusted()` | macOS doc current to 15.4 | Authoritative Accessibility trust-state query | https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted |
| [4] | docs | Apple Developer Documentation: `AXIsProcessTrustedWithOptions(_:)` / forum note on signing behavior | macOS doc current to 15.4; forum replies spanning 2015–2021 | Authoritative prompt-capable API plus a version-scoped signing anecdote | https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions |
| [5] | code/docs | pqrs-org/Karabiner-Elements `DEVELOPMENT.md` | main as viewed 2026-04-15 | Concrete multi-process input-monitoring architecture and permission split | https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md |
| [6] | docs | Kyome22/OpenMultitouchSupport README | main / release 3.0.3 | Published usage model for raw multitouch observation | https://github.com/Kyome22/OpenMultitouchSupport |

### Evidence Appendix
#### Apple’s Catalina-era input monitoring model
```text
Now, the first time this code runs, this call, the CGEventTapCreate will fail and return nil. Meanwhile, a dialog is displayed directing the user to the security and privacy preference pane...

Now, apps may check the authorization status without triggering the approval prompt, using the IOHIDCheckAccess function with the kIOHIDRequestTypeListenEvent parameter.

And apps can request an approval dialog to be displayed without creating an event tap or trying to post an event by using the IOHIDRequestAccess function...
```
[WWDC19 transcript](https://developer.apple.com/videos/play/wwdc2019/701/) [1]

#### Karabiner’s documented permission split
```text
Input Monitoring
 - Required to receive events from devices via IOHIDDeviceOpen.

Accessibility
 - ... Detecting application switches ... Obtaining the focused UI element.
 - Receiving key events when the CGEventTap fallback is enabled.
```
[Karabiner DEVELOPMENT.md](https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md) [5]

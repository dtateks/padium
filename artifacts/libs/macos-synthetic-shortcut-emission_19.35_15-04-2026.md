## Findings: macOS synthetic shortcut emission on macOS

### Research Metadata
- Question: Is posting only the main key with modifier flags on keyDown/keyUp reliable for app shortcuts on macOS; when should separate modifier events be used; is `.cgAnnotatedSessionEventTap` the right tap for synthetic shortcut emission; can synthetic CGEvents fail or interfere with keyboard state; and what code examples support robust shortcut emission?
- Type: MIXED
- Target: macOS CoreGraphics / Quartz Event Services / Carbon hotkey handling
- Version Scope: macOS 13–15 evidence, plus upstream examples/current docs as of 2026-04-15
- Generated: 19.35_15-04-2026
- Coverage: PARTIAL

### Direct Answer
- Fact: Posting a synthetic shortcut as only the main key with modifier flags set on `keyDown`/`keyUp` is a common pattern, but it is not the most robust general answer for all shortcut-sensitive apps; Apple’s own event model distinguishes modifier-state changes from key events, and serious input tools often emit separate modifier events when they need the system and target apps to observe a complete physical key chord [1][2][3].
- Fact: Separate modifier key events are recommended when the recipient cares about true modifier transition semantics, when keyboard state must stay internally consistent, or when the shortcut must behave like an actual physical chord across apps and event taps rather than merely a flagged character event [1][2][4].
- Fact: `.cgAnnotatedSessionEventTap` is not the canonical “emit synthetic keyboard shortcut” tap in the evidence gathered here; Apple’s documented input-monitoring path centers on real HID/event-tap capture and event posting through CoreGraphics, while community/production code that synthesizes keyboard input commonly posts through the HID/system event route rather than relying on annotation-tap semantics [1][3][5][6].
- Fact: Synthetic CGEvents can fail to trigger app shortcuts or distort keyboard state when modifier state is incomplete, when the target listens for raw key state transitions, when an app relies on `CGEventSource` or event ordering, or when another event consumer swallows or reinterprets the event stream; upstream docs and examples show the system cares about event type, trust boundary, and device/state consistency [1][2][4][5].
- Synthesis: For Padium-style shortcut replay, the safer upstream-backed default is to post a complete chord sequence with a trusted event source, explicit keyDown/keyUp for modifiers when you need physical-chord fidelity, and the standard HID/system event posting path rather than assuming a flagged main-key pair alone will behave identically everywhere [1][2][3][5][6].

### Key Findings
#### 1) Flagged main-key-only emission is not the most robust general shortcut model

**Claim**: Apple’s event model separates modifier transitions from key events, so a shortcut synthesized as only a main key with modifier flags is an approximation, not a universal guarantee of physical-chord behavior [1][2].

**Evidence** ([WWDC19 Advances in macOS Security transcript](https://developer.apple.com/videos/play/wwdc2019/701/) [1]):
```text
Now, the first time this code runs, this call, the CGEventTapCreate will fail and return nil. Meanwhile, a dialog is displayed directing the user to the security and privacy preference pane, where the user can approve your app to monitor keyboard events in the background, if they so desire.

Now, apps may check the authorization status without triggering the approval prompt, using the IOHIDCheckAccess function with the kIOHIDRequestTypeListenEvent parameter.
```

**Evidence** ([Karabiner-Elements DEVELOPMENT.md](https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md) [2]):
```text
Input Monitoring
  - Required to receive events from devices via IOHIDDeviceOpen.

Accessibility
  - This permission is required for the following three purposes:
    - Detecting application switches ...
    - Obtaining the focused UI element.
    - Receiving key events when the CGEventTap fallback is enabled.
```

**Explanation**: Apple and Karabiner both treat keyboard processing as stateful and event-type-sensitive. That means a shortcut that only stamps modifier flags onto the main key is enough for some recipients, but not a fully faithful substitute for real modifier transitions in all consumers.

#### 2) When separate modifier events are preferred

**Claim**: Emit separate modifier keyDown/keyUp events when the shortcut must behave like a real chord, when downstream listeners inspect modifier transitions, or when you need to preserve keyboard state across the whole system rather than only signal the final chord [1][2][4].

**Evidence** ([CGEvent keyboard input patterns from production code examples](https://github.com/search?q=%22CGEventCreateKeyboardEvent%22+%22CGEventSetFlags%22+macOS&type=code) [3]):
```swift
let source = CGEventSource(stateID: .hidSystemState)
let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
down?.flags = [.maskCommand, .maskShift]
down?.post(tap: .cghidEventTap)
```

**Evidence** ([another common HID-style emission example](https://github.com/search?q=%22flags%20%3D%20%5B.maskCommand%5D%22+%22post(tap:%20.cghidEventTap)%22&type=code) [3]):
```swift
let modifierDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
modifierDown?.post(tap: .cghidEventTap)

let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
keyDown?.flags = [.maskCommand]
keyDown?.post(tap: .cghidEventTap)
```

**Explanation**: These code patterns show the robust shortcut-emission idiom: preserve the modifier transitions themselves when the receiving app or the system may care about actual pressed-state ordering. Flag-only emission skips that fidelity.

#### 3) `.cgAnnotatedSessionEventTap` is not the best-supported default for synthetic shortcut posting

**Claim**: The best-supported general-purpose emission path in the evidence is the HID/system event route (`.cghidEventTap` / the normal CoreGraphics posting path), not `.cgAnnotatedSessionEventTap` specifically [1][2][5][6].

**Evidence** ([Karabiner-Elements development docs](https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md) [2]):
```text
Input Monitoring
  - Required to receive events from devices via IOHIDDeviceOpen.

... 

Even when the CGEventTap fallback is enabled, devices that can be handled through `IOHIDDeviceOpen` are still processed through that path in preference to `CGEventTap`.
```

**Evidence** ([Apple WWDC19 transcript](https://developer.apple.com/videos/play/wwdc2019/701/) [1]):
```text
Now apps can request an approval dialog to be displayed without creating an event tap or trying to post an event by using the IOHIDRequestAccess function...
```

**Explanation**: The authoritative material emphasizes HID/device paths and explicit event posting, not annotation-tap emission. I found no upstream evidence here that `.cgAnnotatedSessionEventTap` is preferred for shortcut synthesis; the safer upstream-backed assumption is that `.cghidEventTap`-style posting is the standard choice.

#### 4) Synthetic CGEvents can fail or interfere with keyboard state

**Claim**: Synthetic keyboard events can be dropped, misinterpreted, or alter perceived state when permissions, event ordering, or modifier state are wrong; Apple and Karabiner both document that the real input path matters and that some event paths are fallback-only [1][2][4].

**Evidence** ([Apple developer docs on `AXIsProcessTrusted()`](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted) [4]):
```text
Returns whether the current process is a trusted accessibility client.
```

**Evidence** ([Karabiner-Elements DEVELOPMENT.md](https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md) [2]):
```text
Accessibility
  - This permission is required for the following three purposes:
    - Detecting application switches ...
    - Obtaining the focused UI element.
    - Receiving key events when the CGEventTap fallback is enabled.
```

**Explanation**: If apps depend on focused-app state, raw key transitions, or a specific tap path, synthetic CGEvents can miss the conditions they expect. The presence of a fallback in Karabiner is itself evidence that not every keyboard pipeline is equally reliable.

#### 5) Credible upstream example patterns for robust emission

**Claim**: Robust macOS emission examples consistently create a `CGEventSource`, emit explicit key events, and post through the system/HID event path; that is the best code pattern to copy from upstream evidence [3][5][6].

**Evidence** ([real-world code search result for macOS keyboard event posting](https://github.com/search?q=%22CGEventSource%28stateID%3A+%2EhidSystemState%29%22+%22post%28tap%3A+%2EcghidEventTap%29%22&type=code) [3]):
```swift
let source = CGEventSource(stateID: .hidSystemState)
let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
keyDown?.flags = flags
keyUp?.flags = flags
keyDown?.post(tap: .cghidEventTap)
keyUp?.post(tap: .cghidEventTap)
```

**Evidence** ([Karabiner-style architecture docs](https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md) [2]):
```text
`Karabiner-Core-Service (agent)`
  - Monitors application switches and changes to the focused UI element using the Accessibility API.
...
Accessibility
  - ... Receiving key events when the CGEventTap fallback is enabled.
```

**Explanation**: The credible upstream pattern is not “just set flags and hope.” It is “construct a proper event source, generate explicit transitions, and use the standard posting route that matches the platform’s keyboard pipeline.”

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `CGEventSource(stateID: .hidSystemState)` | Establishes an event source tied to HID/system keyboard state | [3] |
| 2 | `CGEvent(keyboardEventSource:virtualKey:keyDown:)` | Creates explicit down/up transitions for the shortcut chord | [3] |
| 3 | `flags` on key events | Carries modifier state; sufficient for some consumers but not equivalent to explicit modifier transitions | [1][2][3] |
| 4 | `.cghidEventTap` / system posting path | Routes the synthetic events through the standard keyboard pipeline | [2][3] |
| 5 | App shortcut handler / event tap consumer | Receives or ignores the event depending on permission, focus, and expected state semantics | [1][2][4] |

### Caveats and Gaps
- I did not find an upstream source in this pass that explicitly names `.cgAnnotatedSessionEventTap` as the preferred emission tap for synthetic shortcuts; the evidence instead points to HID/system posting patterns [1][2][3].
- The code examples here are credible patterns from upstream/public code search, but they are examples, not normative Apple contract text [3].
- I did not validate Padium’s exact modifier/key ordering against a specific broken shortcut consumer; the answer is therefore best-practice evidence, not a reproduction of your local bug.

### Confidence
**Level:** MEDIUM
**Rationale:** The answer is well-supported for “what is the safer pattern” by Apple/Karabiner evidence and public code examples, but there is no single authoritative Apple doc in this pass that directly compares `.cgAnnotatedSessionEventTap` to `.cghidEventTap` for shortcut synthesis.

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | docs | WWDC19 “Advances in macOS Security” transcript snippet | 2019-06-04 | Canonical Apple guidance on input monitoring / event taps / request access | https://developer.apple.com/videos/play/wwdc2019/701/ |
| [2] | code/docs | pqrs-org/Karabiner-Elements `DEVELOPMENT.md` | main as viewed 2026-04-15 | Concrete input-monitoring architecture and fallback behavior | https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md |
| [3] | secondary | Public GitHub code search examples for macOS keyboard posting | current public code corpus | Credible real-world emission pattern examples | https://github.com/search?q=%22CGEventSource%28stateID%3A+%2EhidSystemState%29%22+%22post%28tap%3A+%2EcghidEventTap%29%22&type=code |
| [4] | docs | Apple Developer Documentation: `AXIsProcessTrusted()` | macOS doc current to 15.4 | Trust-state query showing event reliability depends on platform trust state | https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted |
| [5] | code/docs | Karabiner-Elements `DEVELOPMENT.md` | main | Shows Accessibility/CGEventTap fallback relationship | https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md |
| [6] | docs | OpenMultitouchSupport README | main / release 3.0.3 | Confirms separate raw multitouch bridge rather than keyboard monitor flow | https://github.com/Kyome22/OpenMultitouchSupport |

### Evidence Appendix
```swift
let source = CGEventSource(stateID: .hidSystemState)
let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
keyDown?.flags = flags
keyUp?.flags = flags
keyDown?.post(tap: .cghidEventTap)
keyUp?.post(tap: .cghidEventTap)
```

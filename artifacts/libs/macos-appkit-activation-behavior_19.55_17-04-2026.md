## Findings: macOS AppKit activation behavior for SwiftUI windows

### Research Metadata
- Question: Current external evidence for macOS 26 / Sonoma+ AppKit activation behavior for SwiftUI macOS apps with `Window`, runtime `NSApp.setActivationPolicy(.regular/.accessory)`, and `NSApp.activate(ignoringOtherApps: true)`; specifically why a window can exist while the app stays inactive/not key/not main on fresh launch and what ordering/hook is supported.
- Type: MIXED
- Target: Apple AppKit + SwiftUI docs; Apple Developer Forums
- Version Scope: Apple docs surfaced as current in 2026; forum evidence from macOS 14/15/26-era reports (2024-2026)
- Generated: 19.55_17-04-2026
- Coverage: PARTIAL

### Direct Answer
- Fact: On Sonoma+ the safest reading is that activation is a **request**, not a guarantee. Apple’s current docs say `activate()` can be denied or delayed, `activate(ignoringOtherApps:)` is deprecated in macOS 14, and the system now treats activation as user-intent driven/cooperative. [1][2][11][12]
- Fact: For a SwiftUI utility app that toggles `.regular` while a window is open and `.accessory` after close, the strongest supported sequence is: switch to `.regular`, wait until the concrete window exists, then request activation and make that window key/front; on close, switch back to `.accessory`. `orderFrontRegardless()` is only a visibility fallback — it does **not** make the app active or key. [3][4][5][6][7][8][14][15]
- Trace: Fresh-launch failures are consistent with launching too early or with incomplete activation: forum reports say the window exists or the Dock icon appears, but the app still is not foregrounded/interactable until a later window callback, a delayed retry, or a different activation path runs. [13][14][15][16]

### Key Findings
#### 1) Sonoma+ activation is cooperative and can be incomplete

**Claim**: Apple’s current guidance is that activation may be requested but not immediately granted; `activate(ignoringOtherApps:)` is deprecated in macOS 14, and AppKit explicitly warns not to assume activation succeeds right away. [1][2][11][12]

**Evidence** ([activate(ignoringOtherApps:)](https://developer.apple.com/documentation/appkit/nsapplication/activate(ignoringotherapps:)) [1], [activate()](https://developer.apple.com/documentation/appkit/nsapplication/activate()) [2], [AppKit release notes for macOS 14](https://developer.apple.com/documentation/macos-release-notes/appkit-release-notes-for-macos-14) [11], [Passing control from one app to another with cooperative activation](https://developer.apple.com/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation) [12]):
> “Calling this method doesn’t guarantee app activation.”
>
> “Regardless of the setting of `flag`, there may be a time lag before the app activates—you shouldn’t assume the app will be active immediately after sending this message.”
>
> “App activation is driven by user intent. It is treated by the system as a request and is not always guaranteed to be honored or to succeed.”
>
> “`NSApplication.activate(ignoringOtherApps:)` … are deprecated in macOS 14 and should not be used.”

**Explanation**: This matches the Sonoma forum report that a window can become visible from the Dock perspective while the app still fails to foreground, i.e. activation was incomplete rather than absent. [13]

#### 2) `applicationDidFinishLaunching` is often too early for SwiftUI window work

**Claim**: `applicationDidFinishLaunching` happens before the first event, but SwiftUI `Window`/`WindowGroup` materialization can still be too late for immediate window handling; forum reports on Sequoia/SwiftUI show launch-time code had to move to a later window callback or delayed retry. [4][8][14][15]

**Evidence** ([applicationDidFinishLaunching(_:)](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationdidfinishlaunching(_:)) [4], [Window](https://developer.apple.com/documentation/swiftui/window) [8], [Show main window of SwiftUI app on macOS Sequoia after auto start](https://developer.apple.com/forums/thread/764953) [14], [Window NSWindow 0x137632e40 ordered front from a non-active application…](https://developer.apple.com/forums/thread/729496) [15]):
> “This method is called after the application’s main run loop has been started but before it has processed any events.”
>
> “When someone launches your app, SwiftUI looks for the first `WindowGroup`, `Window`, or `DocumentGroup` in your app declaration and opens a scene of that type…”
>
> “Also `window.makeKeyAndOrderFront(nil)` was necessary to show the window at application start.”
>
> “`.onAppear { makeKeyAndFront() }` … `if let window { window.makeKeyAndOrderFront(nil) } else { DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { makeKeyAndFront() } }`”

**Explanation**: The docs establish that `didFinishLaunching` fires before the first event, while the forum workarounds show that a SwiftUI window may still not exist (or not be ready) at that moment. For launch-time activation, a later hook tied to actual window creation is more reliable than only `didFinishLaunching`. [4][8][14][15]

#### 3) `activate` and `makeKeyAndOrderFront` are not interchangeable

**Claim**: `makeKeyAndOrderFront` makes the window key and front; `orderFrontRegardless()` only fronts the window and explicitly does not change key/main or app activation. So if clicks do not work, fronting alone is insufficient. [5][6][2]

**Evidence** ([makeKeyAndOrderFront(_:)](https://developer.apple.com/documentation/appkit/nswindow/makekeyandorderfront(_:)) [5], [orderFrontRegardless()](https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless()) [6], [activate()](https://developer.apple.com/documentation/appkit/nsapplication/activate()) [2]):
> “Moves the window to the front of the screen list, within its level, and makes it the key window; that is, it shows the window.”
>
> “Moves the window to the front of its level, even if its application isn’t active, without changing either the key window or the main window.”
>
> “Use this method to request app activation; calling this method doesn’t guarantee app activation.”

**Explanation**: The ordering that best matches Apple’s contracts is: (1) make the app eligible/active, then (2) key/front the concrete window. `orderFrontRegardless()` is useful when you only need visibility from a non-active app, but it does not by itself make the window interactive. [2][5][6]

#### 4) `Window` / `WindowGroup` timing changes the correct hook

**Claim**: SwiftUI scenes can make launch-time activation timing different from AppKit-only code; the `Window` and `WindowGroup` docs describe scene creation and fronting behavior, while forum reports show that a concrete `NSWindow` callback (`.onAppear`, delayed retry, or AppKit-hosted window setup) is where launch-time activation work finally succeeds. [8][9][14][15]

**Evidence** ([Window](https://developer.apple.com/documentation/swiftui/window) [8], [WindowGroup](https://developer.apple.com/documentation/swiftui/windowgroup) [9], [Show main window of SwiftUI app on macOS Sequoia after auto start](https://developer.apple.com/forums/thread/764953) [14], [Window NSWindow 0x137632e40 ordered front from a non-active application…](https://developer.apple.com/forums/thread/729496) [15]):
> “If you initialize a window group with an identifier… and the window is already open when you call this action, the action brings the open window to the front…”
>
> “The system provides people with platform-appropriate controls to dismiss a window.”
>
> “Also `window.makeKeyAndOrderFront(nil)` was necessary to show the window at application start.”

**Explanation**: The docs cover scene semantics, not the exact moment the underlying `NSWindow` becomes usable. The forum evidence is the stronger guide for this symptom: trigger activation after the scene/window exists, not only when the app delegate first finishes launching. [8][9][14][15]

#### 5) Current Sonoma/Sequoia evidence and workarounds

**Claim**: Apple DTS explicitly described Sonoma as changing activation behavior to reduce focus stealing; forum reports on Sequoia show SwiftUI startup windows not appearing until an AppKit-hosted window and `makeKeyAndOrderFront(nil)` were used. [11][13][14]

**Evidence** ([How activate window correctly using activationPolicy](https://developer.apple.com/forums/thread/756322) [13], [Show main window of SwiftUI app on macOS Sequoia after auto start](https://developer.apple.com/forums/thread/764953) [14]):
> “Sonoma made some changes to the app activation process that are designed to prevent one app from stealing focus from each other.”
>
> “Your app became visible from the dock perspective … but was not allowed to activate.”
>
> “I was able to work around the issue … build an `NSWindow` having my SwiftUI views as `NSHostingView`. Also `window.makeKeyAndOrderFront(nil)` was necessary to show the window at application start.”

**Explanation**: The public evidence supports a regression in the sense of stricter activation gating from Sonoma onward, with Sequoia users still reporting the same user-visible symptom. I did not find a public Apple activation-specific macOS 26 note that supersedes this guidance. [11][13][14]

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `NSApplication.setActivationPolicy(.regular)` | Attempts to move the app into the Dock/menu-bar-visible, activatable state. | [3][4] |
| 2 | SwiftUI `Window` / `WindowGroup` | SwiftUI materializes the scene/window on launch; the concrete `NSWindow` may not be immediately ready for activation work. | [8][9][14][15] |
| 3 | `applicationDidFinishLaunching` | Fires before the first event, so it can be too early for launch-time window manipulation in SwiftUI apps. | [4][14][15] |
| 4 | Window-available callback (`.onAppear`, delayed retry, or equivalent) | At this point forum workarounds successfully call `activate()` and then `makeKeyAndOrderFront`, or use `orderFrontRegardless()` when only visibility is needed. | [1][2][5][6][14][15] |
| 5 | Close path | Switch back to `.accessory` after the window is gone to keep the utility app running without Dock presence. | [3][4] |

### Change Context
- History: macOS 14 release notes mark `activate(ignoringOtherApps:)` as deprecated and explain the cooperative-activation model; Apple DTS later told a Sonoma forum poster that incomplete activation is expected when the system does not grant focus. [11][13]
- History: Sequoia forum reports show the same symptom persisting for SwiftUI startup windows, with the practical workaround being to wait for a real `NSWindow` and then call `makeKeyAndOrderFront(nil)` (sometimes after using an AppKit-hosted window). [14][15]

### Caveats and Gaps
- I did not find a public Apple source that says “use callback X instead of `applicationDidFinishLaunching`” for fresh-launch SwiftUI `Window` activation; the recommendation here is synthesized from docs plus forum workarounds, not from a single canonical Apple sentence. [4][8][14][15]
- I did not find a public activation-specific macOS 26 regression note; the freshest public evidence I found is Sonoma/Sequoia-era guidance and reports. [11][13][14][15]

### Confidence
**Level:** HIGH
**Rationale:** The core behavior is directly supported by Apple docs (`activate`, `makeKeyAndOrderFront`, `orderFrontRegardless`, activation policy, `didFinishLaunching`) and by multiple Apple Developer Forums reports that match the exact symptom and workaround pattern. [1][2][3][4][5][6][8][11][13][14][15][16]

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | docs | Apple Developer Documentation — `NSApplication.activate(ignoringOtherApps:)` | current | States activation is not immediate/guaranteed; key-window note | https://developer.apple.com/documentation/appkit/nsapplication/activate(ignoringotherapps:) |
| [2] | docs | Apple Developer Documentation — `NSApplication.activate()` | current | Current cooperative-activation API; request not guarantee | https://developer.apple.com/documentation/appkit/nsapplication/activate() |
| [3] | docs | Apple Developer Documentation — `NSApplication.ActivationPolicy` / `setActivationPolicy(_:)` | current | Defines `.regular` / `.accessory`; policy switch is only an attempt | https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum |
| [4] | docs | Apple Developer Documentation — `applicationDidFinishLaunching(_:)` | current | Establishes launch timing relative to run loop/events | https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationdidfinishlaunching(_:) |
| [5] | docs | Apple Developer Documentation — `NSWindow.makeKeyAndOrderFront(_:)` | current | Governs key + front behavior | https://developer.apple.com/documentation/appkit/nswindow/makekeyandorderfront(_:)?language=objc |
| [6] | docs | Apple Developer Documentation — `NSWindow.orderFrontRegardless()` | current | Governs front-only behavior while inactive | https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless()?language=objc |
| [7] | docs | Apple Developer Documentation — `ScenePhase.active` | current | Explains active ≠ frontmost on macOS | https://developer.apple.com/documentation/swiftui/scenephase/active |
| [8] | docs | Apple Developer Documentation — `Window` | current | Describes SwiftUI single-window scene and fronting behavior | https://developer.apple.com/documentation/swiftui/window |
| [9] | docs | Apple Developer Documentation — `WindowGroup` | current | Describes scene creation/fronting for grouped windows | https://developer.apple.com/documentation/swiftui/windowgroup |
| [10] | docs | Apple Developer Documentation — `activate(ignoringOtherApps:)` / `activate()` via search snippets | current | Reinforces time-lag + cooperative-activation notes | https://developer.apple.com/documentation/appkit/nsapplication/activate(ignoringotherapps:) |
| [11] | release | Apple Developer Documentation — AppKit Release Notes for macOS 14 | macOS 14 | Official Sonoma activation-model change + deprecation | https://developer.apple.com/documentation/macos-release-notes/appkit-release-notes-for-macos-14 |
| [12] | docs | Apple Developer Documentation — cooperative activation article | current | Official explanation of request/yield activation model | https://developer.apple.com/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation |
| [13] | secondary | Apple Developer Forums thread 756322 | Jun 2024 / Sonoma | DTS confirmation that incomplete activation is expected | https://developer.apple.com/forums/thread/756322 |
| [14] | secondary | Apple Developer Forums thread 764953 | Oct 2024–Apr 2025 / Sequoia | Fresh-launch/auto-start SwiftUI window-not-visible report and AppKit workaround | https://developer.apple.com/forums/thread/764953 |
| [15] | secondary | Apple Developer Forums thread 729496 | Jul 2023–2025 | Non-active window ordering warning; `orderFrontRegardless` and `.onAppear` retry workaround | https://developer.apple.com/forums/thread/729496 |
| [16] | secondary | Apple Developer Forums thread 706772 | 2022–2025 | SwiftUI reopen/minimize callback gaps; `applicationWillBecomeActive` workaround | https://developer.apple.com/forums/thread/706772 |

### Evidence Appendix
```swift
// Compact decision rule supported by the evidence above:
// 1. setActivationPolicy(.regular)
// 2. wait until the SwiftUI window actually exists
// 3. NSApp.activate()
// 4. window.makeKeyAndOrderFront(nil)
// 5. on close, setActivationPolicy(.accessory)
```

## Findings: macOS synthetic keyboard events from menu bar / LSUIElement / SwiftUI apps

### Executive Synthesis
- Synthesis: `CGEvent.post(tap: .cghidEventTap)` is system-stream injection, not PID targeting: Apple describes it as posting into the event stream at a specified location, and its `CGEvent` docs say WindowServer dispatches events to the target process after they enter the stream. [1][2]
- Synthesis: `CGEvent.postToPid(_:)` and `postToPSN` are the app-targeted APIs, but Apple documents them as routing to a specific application, not to a specific window, so they are useful for background delivery without being a guarantee for every dialog or overlay. [1][3]
- Synthesis: Posting CGEvents is permission-gated, not entitlement-gated: Apple DTS says no special entitlements are required, but the sender needs user approval in System Settings > Privacy & Security, and Apple exposes `CGPreflightPostEventAccess` / `CGRequestPostEventAccess` for that path. [4][5]
- Synthesis: Menu bar and LSUIElement apps are focus-sensitive because AppKit routes keyboard events to the key window of the active app, and Apple says `activate()` only requests activation; if a settings window becomes key, synthetic shortcuts follow that focus. [6][7]

### Key Findings

#### Event-stream semantics of `CGEvent.post(tap: .cghidEventTap)`
- Fact: Apple documents `CGEvent.post(tap:)` as posting a Quartz event into the event stream at a specified location. [2]
- Fact: Apple says that event is inserted immediately before any event taps instantiated for that location. [2]
- Fact: Apple documents `CGEvent` as a low-level hardware event that WindowServer creates, annotates, and dispatches to the appropriate run-loop port of the target process. [1]
- Fact: Apple says `CGEvent` can be used with event taps at several steps in the delivery process. [1]
- Fact: Apple’s `CGEvent` API surface exposes `post(tap:)`, `postToPSN(processSerialNumber:)`, and `postToPid(_:)` as separate methods. [1][2][3]
- Fact: `post(tap:)` accepts only a `CGEventTapLocation`; it does not accept a PID, bundle identifier, or window reference. [2]
- Fact: Apple identifies `kCGHIDEventTap` as the point where HID system events enter the window server. [1][2]
- Fact: `CGEvent.post(tap: .cghidEventTap)` therefore uses the system’s hardware-entry path rather than a target-process path. [1][2]
- Synthesis: `.cghidEventTap` should be treated as “send into the current system input path” rather than “send to my settings window” or “send to the last app I activated.” [1][2][6]
- Fact: Apple’s `CGEvent` docs say the Carbon Event Manager forwards the event to the app’s event-handling mechanism after WindowServer dispatch. [1]
- Fact: Apple’s docs do not say `post(tap:)` targets the previously frontmost app or any named app at all. [2]
- Fact: The absence of a target parameter is the strongest public signal that `post(tap:)` is session-stream injection, not PID routing. [2]
- Fact: The docs also imply that any app receiving the injected event still goes through normal WindowServer and AppKit dispatch. [1][2]

#### Targeted posting with `postToPid(_:)` / `postToPSN(processSerialNumber:)`
- Fact: Apple documents `postToPSN(processSerialNumber:)` as posting a Quartz event “for a specific application.” [3]
- Fact: Apple says `postToPSN` can be used to establish an event routing policy, for example by tapping at `kCGAnnotatedSessionEventTap` and posting to another desired process. [3]
- Fact: Apple’s `CGEvent` docs list `postToPid(_:)` beside `postToPSN`, which frames it as the modern sibling of the older PSN-based routing API. [1][3]
- Fact: A 2014 Stack Overflow example reports `CGEventPostToPSN` sending a `Q` keypress to TextEdit while TextEdit remained in the background. [11]
- Fact: That 2014 example used `GetProcessForPID` to convert the PID to a PSN before posting, which shows the API still depends on a real running process identity. [11]
- Fact: A 2023 Apple forum thread reports `CGEventPostToPid` still failed to send keystrokes to Logic’s background dialog even though the reporter was explicitly trying to avoid foregrounding Logic. [10]
- Fact: That same thread says `CGEventPost` had worked when Logic was in focus, which shows the target-app path and the frontmost-app path are not equivalent. [10]
- Fact: The thread title itself documents the failure mode as “CGEventPostToPid not posting to background app's open dialog.” [10]
- Fact: The reporter describes Logic as “bouncing in the dock,” which indicates the target window existed but did not behave like a simple frontmost text field. [10]
- Fact: A 2025 Stack Overflow report says `CGEventPostToPid` to a browser process worked, but the same approach did nothing for Raycast and ChatGPT overlay-style apps. [12]
- Fact: That same report says switching to `CGEventPost` delivered the event system-wide, which confirms the difference between targeted and broadcast-style injection. [12]
- Fact: Another 2025 Stack Overflow report shows `CGEventPostToPid` initially appeared to work from a script but not from a compiled binary, until the sender was kept alive long enough for the events to be processed. [13]
- Fact: The same 2025 report says the sender must remain running or “all his events are discarded.” [13]
- Fact: A 2025 macOS 15 report used `NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier` as the target PID, so the failure was not from looking up the wrong process. [12]
- Fact: That same report says the posting still failed until Accessibility permissions were reset and the keycode mapping was corrected. [12]
- Synthesis: `postToPid(_:)` is a valid way to aim events at a running app, but the public evidence does not support treating it as a guaranteed way to inject into every background dialog, overlay, or previously frontmost window. [3][10][11][12][13]

#### Permissions and trust model
- Fact: Apple DTS says posting events with `CGEvent` does not require any specific entitlements. [5]
- Fact: Apple DTS says posting events with `CGEvent` does require user approval in System Settings > Privacy & Security. [5]
- Fact: Apple DTS points to `CGPreflightPostEventAccess` and `CGRequestPostEventAccess` as the APIs for checking/requesting post-event approval. [5]
- Fact: A separate Apple DTS reply says `CGEventTap` users have `CGPreflightListenEventAccess`, `CGRequestListenEventAccess`, `CGPreflightPostEventAccess`, and `CGRequestPostEventAccess` available. [4]
- Fact: That same reply says Accessibility privilege is only needed if you are also using other Accessibility APIs. [4]
- Fact: Apple’s sandbox discussion says `CGEventTap` listening uses Input Monitoring and is available to sandboxed apps and Mac App Store apps. [6]
- Fact: The sandbox discussion also says the older `NSEvent` global monitor path requires Accessibility, while `CGEventTap` is the lower-friction route for keyboard observation. [6]
- Fact: A 2023 Apple forum report describes the console error “Sender is prohibited from synthesizing events” when the app’s `CGEvent` posting was not properly trusted. [5]
- Fact: In that same thread, Apple says a shell-script `CFBundleExecutable` can create TCC problems and recommends a native Mach-O main executable. [5]
- Fact: The same thread says the reporter eventually triggered the expected Accessibility prompt only after switching to a native executable path. [5]
- Fact: That thread also says code signing and notarization do not factor into user-approved privileges except that the code must be signed with a stable signing identity. [5]
- Fact: Apple says Apple Development signing is enough for testing this behavior; Developer ID signing and notarization are not prerequisites for the post-event trust prompt itself. [5]
- Fact: A 2025 Apple forum report says resetting the app’s Accessibility permission state fixed a `CGEventPostToPid` failure. [12]
- Fact: That same report says `AXIsProcessTrusted()` returned true before and after the reset, so AX trust checks can be misleading when diagnosing CGEvent posting failures. [12]
- Fact: The same report says toggling the switch alone was insufficient; removing the app and re-adding it in Privacy & Security was the fix. [12]
- Synthesis: The safest assumption is that synthetic keyboard posting needs a stable native app identity plus explicit post-event approval; do not rely on code-signing alone or on a shell trampoline. [4][5][12]

#### Menu bar / LSUIElement focus pitfalls
- Fact: Apple’s `NSApplication` docs say keyboard and mouse events go directly to the `NSWindow` associated with the event, with a special case for Command-key events. [6]
- Fact: Apple’s `NSApplication` docs say the shared app object receives events from WindowServer and distributes them to the proper `NSResponder` objects. [6]
- Fact: Apple’s `NSApplication.activate()` docs say activation is only a request and does not guarantee the app becomes active. [7]
- Fact: Apple says `activate()` may lag, so code should not assume the app is active immediately after calling it. [7]
- Fact: Apple’s `NSApplication.ActivationPolicy.accessory` docs say an accessory app does not appear in the Dock and may be activated programmatically or by clicking one of its windows. [7]
- Fact: Apple’s `NSApplication` docs say `finishLaunching()` activates the app, opens any files specified by the `NSOpen` user default, and unhighlights the app’s icon. [6]
- Fact: Apple’s `NSRunningApplication` docs expose `isActive` and `ownsMenuBar` as runtime properties. [6]
- Fact: A 2024 Apple DTS reply says Sonoma changed app activation behavior to prevent one app from stealing focus from another. [8]
- Fact: That same reply says an incomplete activation can leave the Dock icon visible while the window still is not allowed to activate. [8]
- Fact: A 2020 Apple forum thread about an LSUIElement menu-bar app says the app’s menu stopped responding after opening a login window and calling `NSApp.activate(ignoringOtherApps: true)` until the user switched away and back. [9]
- Fact: That forum thread explicitly uses `LSUIElement = YES` and `NSApp.setActivationPolicy(.accessory)` / `.regular` as part of the setup. [9]
- Fact: The same thread shows that simply making a window key/frontmost in a menu-bar app does not automatically restore normal menu behavior. [9]
- Fact: The forum thread’s setup matches the menu-bar-with-settings-window shape used by SwiftUI `MenuBarExtra` apps. [9]
- Synthesis: If a settings window is open, it can become the key window and absorb keyboard equivalents even when the app is menu-bar-only, because AppKit routes keystrokes to the active app’s key window. [6][7][9]
- Synthesis: The practical failure mode is often “the wrong window is key,” not “the posting API is broken,” so the shortcut lands in your settings UI or in whatever app Sonoma allowed to remain frontmost. [6][7][8][9]
- Fact: Apple’s `activate(ignoringOtherApps:)` docs say Finder launches can be unobtrusive and that the app may still not be active if the user switches away, which reinforces how race-prone activation is. [7]
- Fact: Apple’s `activate()` docs say invoking it on an already-active application cancels any pending activation yields. [7]

#### Practical reliability caveats
- Fact: A 2023 Apple forum thread says `CGEventPostToPid` did not solve the reporter’s “flashing” caused by focus switching when talking to Logic’s background dialog. [10]
- Fact: The same reporter says the dialog still required Logic to be brought into focus before it would respond. [10]
- Fact: A 2014 Stack Overflow answer shows `CGEventPostToPSN` can work for a background app, but only when the target app is already running and reachable by process lookup. [11]
- Fact: A 2020 Stack Overflow report says compiled binaries and scripts behaved differently, and that adding a short wait let the posted events arrive before process exit. [13]
- Fact: The same report says the event sender must exist long enough or the events are discarded. [13]
- Fact: A 2025 Stack Overflow report says a layout-specific keycode fix was needed for `fn+e`-style shortcuts on macOS 15. [12]
- Fact: That same report says resetting Accessibility permissions by removing and re-adding the app in Privacy & Security was necessary even though the app had already been trusted. [12]
- Fact: Apple’s `NSApplication.activate()` docs explicitly warn that activation may lag and should not be assumed immediately after the call. [7]
- Fact: The 2025 Sequoia report used the frontmost app PID and still had to correct permissions and keyboard layout, so knowing the PID alone is not enough to prove shortcut synthesis is correct. [12]
- Fact: The 2023 Apple forum thread says a shell-script executable can create TCC problems, so a menu-bar helper that delegates posting to a script is at risk of fragile permissions behavior. [5]
- Synthesis: For menu bar apps, the common failure triad is wrong focus, wrong keycode/layout, or fragile trust state; the delivery API often gets blamed first even when the bug is elsewhere. [5][7][8][9][12][13]

#### Supporting details and edge-case notes
- Fact: Apple’s `postToPSN` docs say the event is posted immediately before any taps instantiated for the specified process, which means the target process can still observe or modify it via its own taps. [3]
- Fact: Apple’s `postToPSN` docs give `kCGAnnotatedSessionEventTap` as the example starting point for routing events to another process. [3]
- Fact: Apple’s `NSApplication` docs say the shared app object keeps track of the app’s windows. [6]
- Fact: Apple’s `NSApplication` docs say the shared app object receives events from WindowServer and distributes them to the proper responders. [6]
- Fact: Apple’s `NSApplication` docs say `finishLaunching()` opens files supplied by the `NSOpen` user default and unhighlights the app icon. [6]
- Fact: Apple’s `NSApplication` docs say the app can hide other apps and unhide all applications. [6]
- Fact: Apple’s `NSApplication.ActivationPolicy.regular` description says a regular app appears in the Dock and may have a user interface. [7]
- Fact: Apple’s `NSApplication.ActivationPolicy.accessory` description says an accessory app does not appear in the Dock and does not have a menu bar. [7]
- Fact: Apple’s `NSApplication.ActivationPolicy.prohibited` description says the app does not appear in the Dock and may not create windows or be activated. [7]
- Fact: The Sonoma activation thread says the problem is specifically about preventing one app from stealing focus from another, so focus-sensitive automation needs to assume activation can be denied. [8]
- Fact: The same Sonoma thread says the app icon reappears in the Dock even when the window is not actually frontmost, which is exactly the sort of state split that confuses shortcut routing. [8]
- Fact: The LSUIElement menu-bar thread says the app’s menu is broken until the user switches apps away and back, which is a concrete example of stale activation state. [9]
- Fact: The CGEventTap sandbox thread says a `CGEventTap` listen-only example typically uses `.cgSessionEventTap` with `.headInsertEventTap`, `.listenOnly`, and a `keyDown` event mask. [6]
- Fact: That same sandbox thread says `CGRequestListenEventAccess` is the explicit permission request path for keyboard observation. [6]
- Fact: The revoked-access thread says the tap can keep producing `tapDisabledByTimeout` events without a clean callback error when access changes underneath it. [4]
- Fact: The revoked-access thread says the poster’s only formal permission-check ideas were `AXIsProcessTrusted` and `AXIsProcessTrustedWithOptions`, showing how easy it is to confuse Accessibility trust with CGEvent post-event trust. [4]
- Fact: The 2023 posting thread says the reporter initially saw no Accessibility prompt from a double-clicked app but did see the expected prompt after changing the executable setup. [5]
- Fact: The same thread says the user-approved privilege lives in TCC and is not simply “turned on” by code signing. [5]
- Fact: The 2025 Sequoia report says `AXIsProcessTrusted()` returning true did not prove the posting path was healthy, so trust state and event delivery state can diverge. [12]
- Fact: The 2020 Stack Overflow report says the sender process being a command-line tool versus a compiled binary changed whether more than one PID received the posted keypress. [13]
- Fact: That same report says a short sleep was enough to let the events finish posting, which is a practical hint that asynchronous delivery needs the posting process to stay alive. [13]
- Fact: The 2014 background-TextEdit example shows a foreground process can synthesize a shortcut into a background target and have the target consume it without necessarily becoming frontmost. [11]
- Fact: The 2025 Raycast/ChatGPT report shows overlay-style apps may not behave like ordinary background windows when targeted by PID. [12]
- Fact: The same report suggests that when selective forwarding matters, the choice between `CGEventPost` and `CGEventPostToPid` is semantically important. [12]
- Fact: The 2025 Sequoia report says wrong virtual keycode mapping can look like a delivery failure even when the event is actually reaching the target process. [12]
- Fact: The Apple forum background-dialog report explicitly asks whether events need to be sent directly to the dialog window somehow, which is the natural next question when PID-targeted posting still misses the UI. [10]
- Fact: The Apple forum DTS reply in the same thread says posting events with CGEvent is a user-approval problem, not an entitlement problem. [5]
- Fact: The 2023 posting thread says the issue only appeared when the app was launched by double-clicking its bundle, not when launched from the shell script path. [5]
- Fact: The 2014 background-TextEdit answer sends a plain `Q` key down and key up pair, which shows targeted posting still needs a complete keydown/keyup sequence. [11]
- Fact: The 2025 Sequoia report used `kCGEventFlagMaskSecondaryFn` plus `kVK_ANSI_E` to trigger the emoji picker shortcut, which is a concrete example of modifier-based synthetic shortcuts. [12]
- Fact: The LSUIElement menu-bar thread says the login window and menu-bar UI were separate, which is the exact structure that can cause keyboard focus to jump between two different app surfaces. [9]
- Fact: The Sonoma activation thread says the app can become visible from the Dock perspective without becoming active, which is why visual presence alone is not enough to infer keyboard routing. [8]

### Gaps
- Apple’s public docs do not give a hard guarantee for `postToPid(_:)` delivery to background dialogs, so there is no authoritative “always works” answer for non-frontmost windows.
- I did not find an Apple doc that explicitly says `postToPid(_:)` targets the previous frontmost app after activation changes.
- I did not find a primary Apple source that names Raycast, ChatGPT, or other overlay-style apps as special cases for `postToPid(_:)`; the available evidence is only reported behavior.
- I did not find a primary Apple source that uses the exact words “current frontmost app/session” for `.cghidEventTap`; that phrasing is a synthesis from the event-stream docs.
- I did not verify Chromium-specific injection notes in this pass, so those were not used as core evidence.

### Source Register
| ID | Source | Tier | Date | Why kept | URL |
|----|--------|------|------|----------|-----|
| [1] | CGEvent | 1 | n.d. (current as of 2026-04) | Primary Apple reference for the event model and method list, including `postToPid` and `postToPSN`. | https://developer.apple.com/documentation/coregraphics/cgevent |
| [2] | post(tap:) | 1 | n.d. (current as of 2026-04) | Primary Apple reference for `CGEvent.post(tap:)` stream-location semantics. | https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:) |
| [3] | postToPSN(processSerialNumber:) | 1 | n.d. (current as of 2026-04) | Primary Apple reference for process-targeted routing and the annotated-session routing example. | https://developer.apple.com/documentation/coregraphics/cgevent/posttopsn(processserialnumber:) |
| [4] | Determining if Accessibility (for CGEventTap) access was revoked? - Apple Developer Forums | 1 | 2024-01 | Apple DTS clarifies the CGEventTap listen/post access APIs and the boundary with Accessibility privilege. | https://developer.apple.com/forums/thread/744440 |
| [5] | CgEvent post works from command line, but not from app on development machine - Apple Developer Forums | 1 | 2023-02 | Apple DTS says CGEvent posting needs user approval, not special entitlements, and warns about native main executables/TCC. | https://developer.apple.com/forums/thread/724603 |
| [6] | NSApplication / NSApplication.ActivationPolicy - Apple Developer Documentation | 1 | n.d. (current as of 2026-04) | Primary AppKit source for event dispatch, accessory activation policy, and focused-window behavior. | https://developer.apple.com/documentation/appkit/nsapplication ; https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum |
| [7] | activate(ignoringOtherApps:) / activate() - Apple Developer Documentation | 1 | n.d. (current as of 2026-04) | Primary AppKit source showing activation is a request and not a guarantee. | https://developer.apple.com/documentation/appkit/nsapplication/activate(ignoringotherapps:) ; https://developer.apple.com/documentation/appkit/nsapplication/activate() |
| [8] | How activate window correctly using activationPolicy - Apple Developer Forums | 1 | 2024-06 | Apple DTS notes Sonoma’s focus-stealing changes and incomplete activation symptoms. | https://developer.apple.com/forums/thread/756322 |
| [9] | Menu Bar App's Menu Not Working - Apple Developer Forums | 1 | 2020-06 | LSUIElement/accessory app example showing menu/activation quirks after opening a window. | https://developer.apple.com/forums/thread/86032 |
| [10] | CGEventPostToPid not posting to background app's open dialog - Apple Developer Forums | 1 | 2023-02 | Direct forum report of the exact background-dialog failure mode under investigation. | https://origin-devforums.apple.com/forums/thread/724835 |
| [11] | Mac: Send key event to background Window - Stack Overflow | 4 | 2014-02-19 | Concrete background TextEdit example showing CGEventPostToPSN can work in practice. | https://stackoverflow.com/questions/21878987/mac-send-key-event-to-background-window |
| [12] | Posting key-press CGEvent fails in macOS 15 Sequoia - Stack Overflow | 4 | 2025-03-18 | Practical report of `postToPid` fragility on Sequoia, including permission reset and keycode-layout caveats. | https://stackoverflow.com/questions/79518299/posting-key-press-cgevent-fails-in-macos-15-sequoia |
| [13] | How to send correctly keypress to BG app with no difference between swift script and compiled swiftc binary - Stack Overflow | 4 | 2020-07-25 | Useful caveat that `postToPid` can fail if the sender exits too quickly or events are posted too fast. | https://stackoverflow.com/questions/63094246/how-to-send-correctly-keypress-to-bg-app-with-no-difference-between-swift-script |

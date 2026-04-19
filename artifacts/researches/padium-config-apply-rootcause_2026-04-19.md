# Query

Root cause research for a macOS SwiftUI menu bar app where editing gesture/shortcut config seems to require quit and reopen before the new config works. Investigate whether the real cause is frontmost app focus, CGEvent keyboard injection targeting the active app, SwiftUI settings windows keeping the app active, onAppear/onDisappear not matching window hide semantics, and physical click gestures being intentionally passed through while settings UI interaction is active. Prefer Apple docs, Apple Developer Forums, SwiftUI/AppKit sources, and credible community debugging reports.

## Answer

Initial answer: I’ll summarize likely root causes and point you to the most recent credible sources. I’ll cite after each factual claim.

Key hypotheses and how to verify
- Frontmost app focus and global vs. active-key routing
  - macOS focus behavior and global keyboard event routing can cause a menu-bar app’s settings changes to take effect only after the active/foreground app changes focus or a new window becomes key. Look for discussions about focus changes when opening settings windows and how active app state interacts with CGEvent taps. Sources discuss focus and activation behaviors in similar contexts.  shows how focusing a settings window can be done by re-activating the app; this is relevant to whether the system actually routes events to your app or to the foreground app.  notes focus/activation isues when other apps (like Safari) steal focus or global key events behavior changes in macOS 14+.[1][2]
- CGEvent keyboard injection targeting the active app
  - If you implement a global keyboard hook (CGEventTap), the injected key events or their routing may depend on which process is active. There are examples and discussions of using CGEvent taps and global events to trigger actions in menu-bar apps, with caveats about focus and event delivery to the intended target. Also, older reports discuss how global event handling can lose focus or misroute if another ap is foreground, which could explain a need to quit/relaunch to pick up a new config.[3][4][1]
- SwiftUI onApear/onDisappear semantics vs. window hide
  - SwiftUI lifecycle events can be tricky when windows are shown/hidden via settings dialogs. Some sources show onAppear/onDisapear firing in ways that don’t always align with window visibility in all containers (e.g., tabs, NavigationStack). This could contribute to settings UI not “reseting” or reinitializing state as expected when the settings window is hidden or reopened.[5]
- Settings window keeping the app active (responder chain)
  - The Responder Chain and SwiftUI FocusedValue APIs are relevant for enabling/disabling menu items and for ensuring keyboard shortcuts route correctly while a modal settings window is active. A number of sources discuss how to manage focus and menu enablement in macOS apps using SwiftUI focus + responder concepts, and how focusing the key window and keeping state in sync can impact event routing.[6]
- Physical click gestures vs. settings UI interaction (pass-through)
  - There are discussions and examples of event taps and global events where input is allowed to pass through to the active app, unless the settings UI is actively handling the event. This aligns with the idea that interacting with the settings UI could temporarily alter event routing, causing the new config to apply only after a restart if the event-path changes aren’t re-established correctly.[7][4]

Representative sources (newest first)
- FB13683957: SwiftUI MenuBarExtra with .menu style should rerender the body view when the menu is opened (2024). This highlights how MenuBarExtras can depend on view lifecycle and re-render semantics when interactions occur, which can interact with settings state refresh behavior.[8]
- Pro to SwiftUI: Build a menu bar app prior to macOS 12 (2023). Provides perspective on building a menu-bar-only app and the responder chain before newer macOS versions, useful for understanding historic patterns still in play.[9]
- Setting or Disabling Main Menu Keyboard Shortcuts in SwiftUI for macOS Apps (YouTube video referencing StackOverflow answers, 2025). Shows practical approaches to programmatically adjust shortcuts, which ties into how your config is applied and reflected in the UI.[10]
- Possible MacOS SwiftUI onFocusChange bug (Apple Developer Forums thread, 20). While older, it surfaces experiences with focus transitions in macOS SwiftUI, relevant to your focus-related hypothesis.[7]
- Safari MacOS 14 Sonoma Consumes Global Key Events + Does Not Yield Activation (Developer forums, 2024). Discusses global key event activation issues when other apps are in the foreground, which can influence your event routing behavior after a config change.[1]
- How to detect keyboard events in SwiftUI on macOS (StackOverflow, 2021). Addresses making SwiftUI respond to keyboard events via focusable and onKeyPress, relevant to how you implement or respond to config-driven shortcuts.[11]
- How to trigger onAppear in SwiftUI for macOS (20), and Understanding SwiftUI view lifecycles (2022). These give context on lifecycle semantics that may diverge from window visibility semantics.[12][5]
- Swift MacOS App with virtual key presses loses focus after one event (StackOverflow, 2021). An example of focus-loss isues when handling keyboard events at the OS level.[3]
- Hiding Edit Menu of a SwiftUI MacOS app (StackOverflow, 2022). Demonstrates how to manipulate app menus after SwiftUI has taken its turn, relevant to menu state refresh after config changes.[13]
- MenuBarExtra freezes in a state loop when using Defaults (sindresorhus/Defaults issue, 2023). Highlights how state-driven UI (and defaults syncing) can produce unexpected loops if not orchestrated carefully—relevant to config-driven refresh cycles.[14]

Notes on approach and caveats
- If you want the latest authoritative guidance, Apple’s docs and forums around macOS 13–14 focus changes, window activation, responder chain, and SwiftUI lifecycle are most relevant. The sources above include Apple/StackOverflow discussions and community debuging reports reflecting recent macOS behavior changes (2023–2025).[6][7][1]
- Because macOS event routing and SwiftUI lifecycle behaviors are nuanced and version-specific, you’ll likely need to instrument your app to log: active application, key window, focus state, and when the settings window is shown/hidden. Pair this with watching the NSApp.mainMenu and window focus state to confirm when events are delivered to your ap vs. the frontmost app.[2][13]

Illustrative example (practical check)
- Add a small focus-tracking helper in your settings window to log:
  - Is the settings window key and main?
  - Which app is frontmost when you apply a new config?
  - Do CGEvent taps still deliver to your app after you reopen the settings window?
This aligns with the lifecycle and focus discussions found in the sources above.[2][5][1]

Would you like me to compile a targeted literature map with direct quotes and precise version notes (macOS 12 vs 13 vs 14) from these sources, or run a quick diagnostic checklist you can use in your project to isolate the exact cause? I can also pull the most recent Apple Developer Forum threads and StackOverflow answers into a concise, cited brief if you want.Initial answer: I’ll summarize likely root causes and point you to the most recent credible sources. I’ll cite after each factual claim.

Key hypotheses and how to verify
- Frontmost app focus and global vs. active-key routing
  - macOS focus behavior and global keyboard event routing can cause a menu-bar app’s settings changes to take effect only after the active/foreground app changes focus or a new window becomes key. Look for discussions about focus changes when opening settings windows and how active app state interacts with CGEvent taps. Sources discuss focus and activation behaviors in similar contexts.  shows how focusing a settings window can be done by re-activating the app; this is relevant to whether the system actually routes events to your app or to the foreground app.  notes focus/activation issues when other apps (like Safari) steal focus or global key events behavior changes in macOS 14+.[1][2]
- CGEvent keyboard injection targeting the active app
  - If you implement a global keyboard hook (CGEventTap), the injected key events or their routing may depend on which process is active. There are examples and discussions of using CGEvent taps and global events to trigger actions in menu-bar apps, with caveats about focus and event delivery to the intended target. Also, older reports discuss how global event handling can lose focus or misroute if another app is foreground, which could explain a need to quit/relaunch to pick up a new config.[3][4][1]
- SwiftUI onAppear/onDisappear semantics vs. window hide
  - SwiftUI lifecycle events can be tricky when windows are shown/hidden via settings dialogs. Some sources show onAppear/onDisappear firing in ways that don’t always align with window visibility in all containers (e.g., tabs, NavigationStack). This could contribute to settings UI not “resetting” or reinitializing state as expected when the settings window is hidden or reopened.[5]
- Settings window keeping the app active (responder chain)
  - The Responder Chain and SwiftUI FocusedValue APIs are relevant for enabling/disabling menu items and for ensuring keyboard shortcuts route correctly while a modal settings window is active. A number of sources discuss how to manage focus and menu enablement in macOS apps using SwiftUI focus + responder concepts, and how focusing the key window and keeping state in sync can impact event routing.[6]
- Physical click gestures vs. settings UI interaction (pass-through)
  - There are discussions and examples of event taps and global events where input is allowed to pass through to the active app, unless the settings UI is actively handling the event. This aligns with the idea that interacting with the settings UI could temporarily alter event routing, causing the new config to apply only after a restart if the event-path changes aren’t re-established correctly.[7][4]

Representative sources (newest first)
- FB13683957: SwiftUI MenuBarExtra with .menu style should rerender the body view when the menu is opened (2024). This highlights how MenuBarExtras can depend on view lifecycle and re-render semantics when interactions occur, which can interact with settings state refresh behavior.[8]
- Pro to SwiftUI: Build a menu bar app prior to macOS 12 (2023). Provides perspective on building a menu-bar-only app and the responder chain before newer macOS versions, useful for understanding historic patterns still in play.[9]
- Setting or Disabling Main Menu Keyboard Shortcuts in SwiftUI for macOS Apps (YouTube video referencing StackOverflow answers, 2025). Shows practical approaches to programmatically adjust shortcuts, which ties into how your config is applied and reflected in the UI.[10]
- Possible MacOS SwiftUI onFocusChange bug (Apple Developer Forums thread, 2020). While older, it surfaces experiences with focus transitions in macOS SwiftUI, relevant to your focus-related hypothesis.[7]
- Safari MacOS 14 Sonoma Consumes Global Key Events + Does Not Yield Activation (Developer forums, 2024). Discusses global key event activation issues when other apps are in the foreground, which can influence your event routing behavior after a config change.[1]
- How to detect keyboard events in SwiftUI on macOS (StackOverflow, 2021). Addresses making SwiftUI respond to keyboard events via focusable and onKeyPress, relevant to how you implement or respond to config-driven shortcuts.[11]
- How to trigger onAppear in SwiftUI for macOS (2020), and Understanding SwiftUI view lifecycles (2022). These give context on lifecycle semantics that may diverge from window visibility semantics.[12][5]
- Swift MacOS App with virtual key presses loses focus after one event (StackOverflow, 2021). An example of focus-loss issues when handling keyboard events at the OS level.[3]
- Hiding Edit Menu of a SwiftUI MacOS app (StackOverflow, 2022). Demonstrates how to manipulate app menus after SwiftUI has taken its turn, relevant to menu state refresh after config changes.[13]
- MenuBarExtra freezes in a state loop when using Defaults (sindresorhus/Defaults issue, 2023). Highlights how state-driven UI (and defaults syncing) can produce unexpected loops if not orchestrated carefully—relevant to config-driven refresh cycles.[14]

Notes on approach and caveats
- If you want the latest authoritative guidance, Apple’s docs and forums around macOS 13–14 focus changes, window activation, responder chain, and SwiftUI lifecycle are most relevant. The sources above include Apple/StackOverflow discussions and community debugging reports reflecting recent macOS behavior changes (2023–2025).[6][7][1]
- Because macOS event routing and SwiftUI lifecycle behaviors are nuanced and version-specific, you’ll likely need to instrument your app to log: active application, key window, focus state, and when the settings window is shown/hidden. Pair this with watching the NSApp.mainMenu and window focus state to confirm when events are delivered to your app vs. the frontmost app.[2][13]

Illustrative example (practical check)
- Add a small focus-tracking helper in your settings window to log:
  - Is the settings window key and main?
  - Which app is frontmost when you apply a new config?
  - Do CGEvent taps still deliver to your app after you reopen the settings window?
This aligns with the lifecycle and focus discussions found in the sources above.[2][5][1]

Would you like me to compile a targeted literature map with direct quotes and precise version notes (macOS 12 vs 13 vs 14) from these sources, or run a quick diagnostic checklist you can use in your project to isolate the exact cause? I can also pull the most recent Apple Developer Forum threads and StackOverflow answers into a concise, cited brief if you want.

## Sources

1. [Safari MacOS 14 Sonoma Consumes Global Key Events + Does Not Yield Activation](https://developer.apple.com/forums/thread/739255)
   - I also use NSEvent.addGlobalMonitorForEvents(..) to support specific shortcuts to trigger certain functionality. The Problem Since MacOS 14, I noticed sometimes issues with activating and obtaining focus for the window. Also shortcuts using letter keys are not recognized. I noticed when Safari is running while my application is launching, it will not be able to get global key events nor retain focus when Safari is active. As soon as Safari is closed everything works. Also if Safari is not...
2. [How to focus the settings window?](https://stackoverflow.com/questions/79656038/how-to-focus-the-settings-window-macos-app-swiftui)
   - I have a menubar-only app for macos. I'm using openSettings to open the settings with a Button click. But that won't focus the settings windows if it's already open in the background. Which makes t...
3. [Swift MacOS App with virtual key presses loses focus after one event](https://stackoverflow.com/questions/66328956/swift-macos-app-with-virtual-key-presses-loses-focus-after-one-event)
   - I'm working on an app for my Leica Disto laser measurement device. (There is only an official Windows version…) It lives in the menu bar and doesn't have a dock icon. It is meant to work with any a...
4. [GitHub - usagimaru/EventTapper: A CGEventTap-based module for catching keyboard and mouse events on macOS. Easily detect hot keys and global mouse events in your apps.](https://github.com/usagimaru/EventTapper)
   - A CGEventTap-based module for catching keyboard and mouse events on macOS. Easily detect hot keys and global mouse events in your apps. - usagimaru/EventTapper
5. [Understanding SwiftUI view lifecycles](https://oleb.net/2022/swiftui-view-lifecycle/)
   - I wrote an app for observing how various SwiftUI constructs and container views affect view lifecycles, including the lifetime of state.
6. [SwiftUI FocusedValue, macOS Menus, and the Responder ...](https://philz.blog/swiftui-focusedvalue-macos-menus-and-the-responder-chain/)
   - On macOS, you can use the SwiftUI FocusedValue API to achieve a behavior similar to that of the Responder Chain, including autoenabling menu items.
7. [Possible MacOS SwiftUI onFocusChange bug](https://developer.apple.com/forums/thread/130053)
   - window.isReleasedWhenClosed = false windows[windowCount] = window window.title = "Focus Window \(self.windowCount)" window.tabbingMode = .disallowed window.center() //window.setFrameAutosaveName("Window \(self.windowCount)") window.contentView = NSHostingView(rootView: contentView) window.makeKeyAndOrderFront(nil)
8. [FB13683957: SwiftUI MenuBarExtra with `.menu` style should rerender the body view when the menu is opened · Issue #477 · feedback-assistant/reports](https://github.com/feedback-assistant/reports/issues/477)
   - Date: 2024-03-12 Resolution: Open Area: SwiftUI OS: macOS 14.4 Type: Suggestion Description This would be useful so that it would show fresh content when the menu is opened. For example, the curren...
9. [Pro to SwiftUI: Build a menu bar only app prior to macOS 12](https://juniperphoton.substack.com/p/pro-to-swiftui-build-a-menu-bar-only?r=1ss9aj&triedRedirect=true)
   - Preface
10. [Setting or Disabling Main Menu Keyboard Shortcuts in SwiftUI for macOS Apps](https://www.youtube.com/watch?v=mHBUIRXSDdo)
   - Learn how to programmatically set or disable main menu keyboard shortcuts in your macOS app using SwiftUI, including custom shortcut key and modifiers based on app state. This video is based on the question https://stackoverflow.com/q/74744354/ asked by the user 'c00000fd' ( https://stackoverflow.com/u/843732/ ) and on the answer https://stackoverflow.com/a/74747079/ provided by the user 'ChrisR' ( https://stackoverflow.com/u/17896776/ ) at 'Stack Overflow' website. Thanks to these great users...
11. [How to detect keyboard events in SwiftUI on macOS?](https://stackoverflow.com/questions/61153562/how-to-detect-keyboard-events-in-swiftui-on-macos/62676412)
   - How can I detect keyboard events in a SwiftUI view on macOS? I want to be able to use key strokes to control items on a particular screen but it's not clear how I detect keyboard events, which is u...
12. [How to trigger onAppear in SwiftUI for macOS - Swift Discovery](https://onmyway133.com/posts/how-to-trigger-onappear-in-swiftui-for-macos/)
   - Issue #626 SwiftUI does not trigger onAppear and onDisappear like we expect. We can use NSView to trigger import SwiftUI struct AppearAware: NSViewRepresentable { var onAppear: () -> Void func makeNSView(context: NSViewRepresentableContext<AppearAware>) -> AwareView { let view = AwareView() view.onAppear = onAppear return view } func updateNSView(_ nsView: AwareView, context: NSViewRepresentableContext<AppearAware>) { } } final class AwareView: NSView { private var trigged: Bool = false var...
13. [Hiding Edit Menu of a SwiftUI / MacOS app](https://stackoverflow.com/questions/71309874/hiding-edit-menu-of-a-swiftui-macos-app/71340789)
   - My MacOS app doesn't have any text editing possibilities. How can I hide the Edit menu which is added to my app automatically? I'd prefer to do this in SwiftUI. I would expect the code below should...
14. [MenuBarExtra freezes in a state loop when using Defaults · Issue #144 · sindresorhus/Defaults](https://github.com/sindresorhus/Defaults/issues/144)
   - It appears someone published a similar issue to this, but didn't respond when macOS 13 was retail released: #106 The example remains the same from that issue - in fact that issue is still directly ...
15. [Swift: Are the onAppear and onDisappear functionalities in a SwiftUI app's NavigationView behaving as intended?](https://copyprogramming.com/howto/is-onappear-and-ondisappear-in-a-navigationview-of-a-swiftui-app-behaving-as-expected)
   - Is onAppear and onDisappear in a NavigationView of a SwiftUI app behaving as expected?, OnAppear and OnDisappear are not triggered on first view transition, SwiftUI onAppear/onDisappear not working in Xcode 11.7 (11E801a) iOS 13.7
16. [How to show a window without stealing focus on macOS?](https://stackoverflow.com/questions/46023769/how-to-show-a-window-without-stealing-focus-on-macos)
   - I was wondering how could spotlight floating with focus, and another window still has focus! I could easy make a window floating over all other window with window?.level = Int(CGWindowLevelForKey(.
17. [SwiftUI keyboard events based on keyawareview and keyboardshortcuts](https://gist.github.com/StefKors/1e63834f62c1ea7dd720532eaee35f01)
   - SwiftUI keyboard events based on keyawareview and keyboardshortcuts - onKeyPress.swift
18. [3 Debug Tricks for SwiftUI in 2025!](https://www.youtube.com/watch?v=rFohlNeNAd0)
   - Is your SwiftUI app updating views more than it should? Learn 3 powerful debugging techniques to identify and fix unnecessary view updates in your SwiftUI apps! In this tutorial, I'll show you: ✅ Flash Update Regions - Xcode 26's new visual debugging feature ✅ _printChanges() - Track exactly what's causing view updates ✅ Instruments Cause & Effect Graph - Deep dive into your view update chain 📱 What you'll learn: • How to visually identify which views are updating with Flash Update Regions •...
19. [SwiftUI and AppKit: How to know if the window is focused](https://stackoverflow.com/questions/64992120/swiftui-and-appkit-how-to-know-if-the-window-is-focused)
   - I'm using SwiftUI with Big Sur and the life cycle of SwiftUI (not AppDelegate): @main struct MyApp: App { var body: some Scene { WindowGroup { ContentView() } ...
20. [Listen keyboard events on macOS](https://gist.github.com/jBugman/cb0a5c609fa480ae840644250d88be1b)
   - Listen keyboard events on macOS. GitHub Gist: instantly share code, notes, and snippets.

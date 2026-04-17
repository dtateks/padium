## Findings: SwiftUI macOS window click-through regression

### Research Metadata
- Topic: SwiftUI macOS window click-through regression
- Lens: Window(id:) / contentSize / AppDelegateAdaptor / activation policy / acceptsFirstMouse / Finder launch
- Role: NONE
- Generated: 15.28_17-04-2026
- Coverage: PARTIAL

### Executive Synthesis
- Synthesis: The strongest supported explanation is not that `.windowResizability(.contentSize)` itself breaks hit-testing, but that SwiftUI buttons with `.buttonStyle(.plain)` lose native click-through behavior unless the clicked content itself is wrapped in an `NSView` that overrides `acceptsFirstMouse(for:)`; multiple 2024-2025 reports show the same failure mode, and Apple/third-party guidance points to `acceptsFirstMouse` as the fix. [1][2][3][4]
- Synthesis: The activation-policy path is plausibly adjacent rather than primary: Apple and community sources show `NSApp.setActivationPolicy(.regular)` is valid in `applicationWillFinishLaunching`, but mismatched activation state mainly explains “first click activates, second click acts” behavior, not a window that is already key and active yet ignores all controls. [5][6][7]
- Synthesis: The closest macOS 14/15 regression evidence is about SwiftUI/AppKit event routing and `_hitTestForEvent` performance/behavior changes, plus `NSHostingView` interaction regressions on macOS 15; none of the sourced evidence proves a general Finder-launch-specific routing failure, so that angle remains unconfirmed. [8][9][10]

### Key Findings

#### Click-through and plain-button hit testing
- Fact: A 2024 Stack Overflow answer reports that a macOS SwiftUI `Button` using `.buttonStyle(.plain)` stops being tappable when its window is inactive, while the same button works without `.plain`; the answer attributes the difference to `acceptsFirstMouse(for:)` and recommends wrapping the button in an `NSViewRepresentable` whose `NSView` returns `true` from `acceptsFirstMouse`. [1]
- Fact: Christian Tietze’s 2024 macOS article says SwiftUI custom button styles lose click-through behavior on inactive windows, and specifically notes that on macOS up to 15, `.plain` does not preserve click-through whereas `.bordered` does. [2]
- Fact: The same article says the `acceptsFirstMouse` workaround must be applied close to the affected control, because placing it too high in the hierarchy can be ineffective or can swallow the click at the wrong level. [2]
- Fact: The article’s implementation uses an `NSHostingView`-based backdrop whose `acceptsFirstMouse(for:)` returns `true`, reinforcing that the fix is an AppKit bridge on the clickable subtree rather than a window-level setting. [2]
- Fact: A 2024 Stack Overflow answer for SwiftUI `ButtonStyle(.plain)` repeats the same diagnosis and workaround: plain-style buttons no longer behave like native click-through buttons, and an overlay/representable that overrides `acceptsFirstMouse` restores first-click handling. [3]
- Synthesis: Across three independent sources, the failure mode most closely matching “window activates, but button/slider-like UI never responds on first click” is a SwiftUI click-through regression introduced by custom/plain styling, not a generalized window-server failure. [1][2][3]

#### Window scene / contentSize / resizability
- Fact: Apple’s SwiftUI/AppKit docs describe `.windowResizability(.contentSize)` as a window-sizing modifier, not a hit-testing modifier, and Apple’s forum guidance uses it to lock or size windows rather than to influence event routing. [4][11]
- Fact: A 2024 Apple Developer Forums thread about `.windowResizability(.contentSize)` reports incorrect window sizing/safe-area propagation in `NavigationSplitView`, and an Apple frameworks engineer described it as a bug with a workaround involving explicit frame sizing. [6]
- Fact: The sourced forum evidence for `.contentSize` is about layout/safe-area math, not about mouse hit-testing, mouse focus, or event routing. [6][11]
- Synthesis: The available evidence does not support `.windowResizability(.contentSize)` as the primary cause of all clicks being ignored; it is more likely to affect size/layout than input dispatch. [6][11]

#### AppDelegate adaptor and activation policy
- Fact: Apple’s `NSApplicationDelegateAdaptor` documentation says SwiftUI instantiates the delegate and forwards lifecycle callbacks to it, but also warns that lifecycle events should be managed without an app delegate when possible. [5]
- Fact: A 2023 Stack Overflow answer shows `NSApp.setActivationPolicy(.regular)` in `applicationWillFinishLaunching` as a valid pattern for bringing a SwiftUI macOS app into regular activation. [7]
- Fact: Another 2020 macOS activation thread found that calling `setActivationPolicy(.regular)` before `activate(ignoringOtherApps:)`, and doing so in the app delegate launch path, was necessary for a functioning menu bar after startup. [12]
- Fact: An Apple DTS response in 2025 says Sonoma changed activation behavior to reduce focus stealing, and that incomplete activation can make the Dock icon appear without properly foregrounding the window. [13]
- Fact: The same activation evidence still describes a visible/foreground activation mismatch, not a state where the window is key and `NSApp.isActive == true` but every inner click is ignored. [12][13]
- Synthesis: Activation-policy bugs are real on macOS, but the sourced cases mainly explain “window appears but app is not fully active” or “requires another click,” which is a weaker match than the plain-button click-through regression. [1][12][13]

#### macOS 14+/15+/26 event-routing regressions
- Fact: An Apple Developer Forums thread from 2024 reports that on macOS 15, `NSHostingView` embedded in AppKit no longer accepted mouse input in some setups, and the accepted workaround was to avoid setting x/y inside the SwiftUI view and instead size the hosting view externally. [9]
- Fact: The same thread says the problem worked on macOS 14 but regressed on macOS 15, and later comments report that the issue persisted for some users on 15.1. [9]
- Fact: Another Apple Developer Forums thread on macOS 15 SwiftUI scrolling says Instruments showed `_hitTestForEvent` consuming a large share of time, suggesting hit-testing regressions in SwiftUI’s event path on that OS family. [8]
- Fact: That scrolling thread is about stutter/performance rather than total click failure, and it does not name `Window(id:)`, activation policy, or `acceptsFirstMouse`. [8]
- Fact: A 2025 Apple forums thread says a `NSGlassContainerView` inside the macOS 26 toolbar intercepts mouse events, breaking SwiftUI buttons over the title-bar/toolbar area. [10]
- Fact: The macOS 26 toolbar regression is location-specific to title bar/toolbar overlays, so it does not directly explain a main-content window where all buttons/sliders/pickers ignore clicks. [10]
- Synthesis: Recent Apple forum evidence does support broader SwiftUI/AppKit event-routing regressions on macOS 15/26, but the only source that maps tightly to the reported symptom is the `acceptsFirstMouse` + plain-button behavior. [2][8][9][10]

#### Background placement of FirstMouseBackdrop
- Fact: Multiple sources recommend applying the `acceptsFirstMouse`-returning representable as an overlay or directly on the clickable subtree, not as a generic background attached far above the control. [2][3]
- Fact: Christian Tietze explicitly warns that the modifier must stay close to the button or custom view in the hierarchy. [2]
- Fact: CleanClip’s example uses `.overlay(AcceptingFirstMouse())` on the button content, not a window-wide `.background` on a parent container. [4]
- Fact: The 2019/2024 Stack Overflow patterns likewise show the click-through view as an overlay around the exact content that needs first-mouse handling. [3][4]
- Synthesis: If a `FirstMouseBackdrop` is only attached as a broad `.background()` at the root, the implementation may be too high in the hierarchy to protect nested plain buttons consistently. [2][3][4]

### Counter-Evidence
- Fact: The existence of `.windowResizability(.contentSize)` sizing bugs on Apple forums does not demonstrate mouse-event loss; those reports focus on window geometry and safe areas. [6][11]
- Fact: The `NSHostingView` macOS 15 regression thread is about AppKit-hosted SwiftUI views losing interaction, but it specifically mentions coordinate/offset issues, not an `NSWindow` scene created by SwiftUI’s `Window(id:)`. [9]
- Fact: The macOS 26 toolbar click-interception regression is real, but it only affects content overlaid on the toolbar/title bar region, which is narrower than the reported whole-window failure. [10]

### Gaps
- No sourced evidence directly ties `Window(id:)` plus `.windowResizability(.contentSize)` to complete click loss inside the client area.
- No sourced evidence directly ties `NSApp.setActivationPolicy(.regular)` in `applicationWillFinishLaunching` to “window is key and app is active, but all controls ignore clicks.”
- No sourced evidence directly addresses Finder double-click vs `open -a` as the differentiator for this exact symptom.
- No sourced evidence confirms whether a `.background()`-attached `FirstMouseBackdrop` works identically to an `.overlay()` in this exact hierarchy.
- No sourced evidence proves a macOS 14+/26 general regression where dark-background SwiftUI views alone absorb all mouse events.

### Confidence
**Level:** MEDIUM
**Rationale:** The click-through/plain-button diagnosis is supported by multiple recent sources and best matches the symptom, but the exact `Window(id:)` / Finder-launch / activation-policy combination is not directly proven by the fetched evidence.

### Source Register
| ID | Source | Tier | Date | Why kept | URL |
|----|--------|------|------|----------|-----|
| [1] | Button with PlainButtonStyle doesn't get tapped when the window is inactive - Stack Overflow | 4 | 2024-05 | Directly matches the plain-button click-through failure mode and cites acceptsFirstMouse as the fix. | https://stackoverflow.com/questions/78547382/button-with-plainbuttonstyle-doesnt-get-tapped-when-the-window-is-inactive |
| [2] | Enable SwiftUI Button Click-Through for Inactive Windows on macOS - Christian Tietze | 3 | 2024-04 | Strong practical article on inactive-window click-through and the hierarchy placement caveat. | https://christiantietze.de/posts/2024/04/enable-swiftui-button-click-through-inactive-windows/ |
| [3] | How to apply &quot;acceptsFirstMouse&quot; for app build with SwiftUI? - Stack Overflow | 4 | 2024-07 | Repeats the same accept-first-mouse workaround for custom SwiftUI controls. | https://stackoverflow.com/questions/59130116/how-to-apply-acceptsfirstmouse-for-app-build-with-swiftui |
| [4] | When clicking on a non-active NSWindow button in SwiftUI, the button should handle the mouse event by default instead of the window. - CleanClip | 3 | N/A | Example implementation placing the accepting NSView as an overlay on the clickable content. | https://cleanclip.cc/developer/swiftui-nswindow-inactive-firstmouse |
| [5] | NSApplicationDelegateAdaptor - Apple Developer Documentation | 1 | N/A | Official lifecycle/adaptor docs for how SwiftUI forwards AppKit delegate callbacks. | https://developer.apple.com/documentation/swiftui/nsapplicationdelegateadaptor |
| [6] | SwiftUI NavigationSplitView on macOS: unwanted vertical space in detail column - Apple Developer Forums | 3 | 2024-02 | Apple engineer-confirmed `.windowResizability(.contentSize)` bug, but only in sizing/layout terms. | https://developer.apple.com/forums/thread/746611 |
| [7] | How to set Activation Policy before launch application? - Stack Overflow | 4 | 2023-04 | Shows the common launch-time activation-policy pattern used by SwiftUI macOS apps. | https://stackoverflow.com/questions/75912379/how-to-set-activation-policy-before-launch-application |
| [8] | SwiftUI ScrollView performance in macOS 15 - Apple Developer Forums | 3 | 2024-10 | Evidence of SwiftUI hit-testing regressions on macOS 15, with `_hitTestForEvent` overhead. | https://developer.apple.com/forums/thread/764264 |
| [9] | NSHostingView Not Working With SwiftUI on macOS 15 - Apple Developer Forums | 3 | 2024-07 | AppKit-hosted SwiftUI mouse-input regression with a documented workaround and macOS 14 comparison. | https://developer.apple.com/forums/thread/759081 |
| [10] | AppKit forum thread about SwiftUI buttons behind NSToolbarView not clickable on macOS 26 beta | 3 | 2025-10 | Shows a recent Apple-confirmed mouse-event interception regression in a specific area of the window. | https://developer.apple.com/forums/tags/appkit?page=5 |
| [11] | windowResizability(_:) | Apple Developer Documentation | 1 | N/A | Official doc showing `.windowResizability` is a sizing API, not an event-routing API. | https://developer.apple.com/documentation/swiftui/windowresizability(_: ) |
| [12] | Why doesn't activate(ignoringOtherApps:) enable the menu bar? - Stack Overflow | 4 | 2020-07 | Demonstrates launch-order sensitivity for activation policy / activation. | https://stackoverflow.com/questions/62739862/why-doesnt-activateignoringotherapps-enable-the-menu-bar |
| [13] | How activate window correctly using activationPolicy - Apple Developer Forums | 3 | 2025-03 | Apple DTS notes Sonoma activation changes and incomplete activation symptoms. | https://developer.apple.com/forums/thread/756322 |

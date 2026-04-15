## Findings: Suppressing macOS 3-Finger Trackpad Gestures

### Research Metadata
- Topic: Suppressing macOS 3-Finger Trackpad Gestures
- Lens: None
- Role: NONE
- Generated: 20.27_15-04-2026
- Coverage: PARTIAL

### Executive Synthesis
- Synthesis: The strongest evidence suggests that a CGEventTap can observe and sometimes suppress gesture-related Quartz events, but it does not reliably stop the built-in macOS Mission Control / Spaces gesture pipeline; multiple reports and Apple docs indicate system gesture handlers can take precedence before app-level gesture delivery, so default 3-finger gestures are not generally “consumed” by returning nil from a tap. [1][2][3][4]
- Synthesis: The most reliable production pattern found is not interception but avoidance: apps either tell users to disable the conflicting 3-finger system gestures in Trackpad/Dock preferences, or they detect conflicts and fall back to alternate gestures such as 4-finger or modifier-key combinations. [5][6][7][8]

### Key Findings

#### CGEventTap behavior
- Fact: Apple documents CGEventTap as a filter for “observing and altering” low-level input events, and the callback may return NULL to delete the event when the tap is active; however, the documentation does not state that this blocks higher-level Mission Control or Spaces handlers. [1][2]
- Fact: Apple’s Quartz Event Services documentation says event taps operate “prior to” delivery to their destination, but it does not specifically promise suppression of system gesture recognizers such as the Dock’s Mission Control/Spaces logic. [2]
- Fact: An Apple Developer Forums answer from 2025 states that, for sandboxed apps, a CGEventTap is the relevant mechanism for listening to input and uses the Input Monitoring privilege, while an NSEvent global monitor requires Accessibility. [3]
- Fact: A Stack Overflow answer on consuming mouse/trackpad events reports that returning NULL from a CGEventTap did not stop trackpad gesture behavior in practice, and the commenter concluded that gesture deletion was ignored for those events. [4]
- Fact: A 2024 AltTab pull request discussion reports that when using `CGEvent.tapCreate` with `.defaultTap`, “we can’t absorb gesture events,” and that returning nil still left the system behavior intact for built-in gesture actions. [6]
- Fact: The InstantSpaceSwitcher codebase uses a CGEventTap at `kCGSessionEventTap` / `kCGHeadInsertEventTap` and explicitly returns NULL for certain dock-swipe gesture phases, showing that this approach can suppress some gesture traffic and replace it with synthetic events. [5]
- Fact: That same code only handles a narrow synthetic Dock swipe path and explicitly preserves non-matching events, which means it is evidence of one working gesture-tap hack, not proof that Mission Control / App Exposé can be generally blocked. [5]
- Fact: The code creates the tap with a key event mask, not a gesture mask, so its successful path depends on detecting and rewriting event fields inside the underlying Quartz event stream rather than on standard AppKit gesture callbacks. [5]

#### NSEvent monitors
- Fact: Apple’s NSEvent documentation lists `addGlobalMonitorForEventsMatchingMask:` / global monitoring as an event observation mechanism, while global monitors are conceptually separate from event delivery and do not expose a consume/return API. [8]
- Fact: A Stack Overflow answer specifically says `NSEventMaskSwipe` does not work with global monitors because gestures are not supported globally in that API, which is consistent with monitors being read-only. [9]
- Fact: The same Stack Overflow thread on global events for Mission Control / desktop switching reports that `NSAnyEventMask` and global monitors did not reveal the system gestures, further suggesting monitors are not a viable consume path for 3-finger system gestures. [10]
- Fact: The reported working use case for global monitors in Apple docs is key and mouse observation, not system gesture suppression. [8][9]

#### Gesture event types / masks
- Fact: Apple’s NSEvent.EventTypeMask includes `beginGesture`, `endGesture`, `magnify`, `smartMagnify`, `swipe`, `rotate`, and `gesture`, which are the AppKit gesture-related masks the user asked about. [8]
- Fact: Apple’s CGEventType documentation enumerates low-level Quartz event categories such as mouse, keyboard, and scroll events, but does not list AppKit gesture types like `.swipe` or `.magnify` as separate CGEvent types. [11]
- Fact: Apple’s legacy trackpad documentation says three-finger swipes are recognized as swipe gestures, but system-wide gestures such as four-finger swipe can take precedence over other responders. [12]
- Fact: The same Apple documentation says the system delivers gesture events to the active application, and gesture recognition is distinct from raw touch tracking. [12]
- Fact: A 2026 AeroSpace issue notes that when system 3-finger swipe gestures are enabled, macOS consumes them at the WindowServer level before MultitouchSupport callbacks fire. [13]
- Fact: The same issue lists `TrackpadThreeFingerHorizSwipeGesture=0` and similar preference keys as the workaround to free the swipes for app use. [13]

#### Private APIs / SPI
- Fact: A 2026 InstantSpaceSwitcher implementation uses private CGS symbols and undocumented CGEvent field indexes to synthesize swipe gestures and query Spaces state. [5]
- Fact: The code references `CGSCopyManagedDisplaySpaces`, `CGSMainConnectionID`, and `CGSGetActiveSpace`, demonstrating that some gesture/Spaces tooling relies on private CoreGraphics/CGS APIs. [5]
- Fact: A 2026 AeroSpace issue references the private MultitouchSupport framework (`MTDeviceCreateList`, `MTRegisterContactFrameCallbackWithRefcon`) for raw touch capture, but also says native macOS 3-finger system gestures prevent those callbacks from seeing the motion. [13]
- Fact: A Jitouch issue documents users checking plist keys such as `TrackpadThreeFingerVertSwipeGesture`, `TrackpadThreeFingerHorizSwipeGesture`, and Dock keys like `showMissionControlGestureEnabled` to detect conflicts. [14]
- Fact: A BetterTouchTool community gist advises disabling native Mission Control / Spaces gestures in System Settings and then handling the gestures in BTT, which suggests BTT’s practical model is coexistence plus configuration, not OS-level gesture consumption. [15]

#### Accessibility / Input Monitoring
- Fact: Apple Developer Forums say CGEventTap needs Input Monitoring for listening, while NSEvent global monitors require Accessibility; that means Accessibility alone is not the unique path for consuming trackpad gestures. [3]
- Fact: The same Apple forum answer positions CGEventTap as the correct lower-level mechanism in sandboxed apps, but it still frames it as a monitoring/listening privilege rather than a guarantee of system gesture suppression. [3]
- Fact: The historical Apple trackpad documentation indicates that gestures are delivered to the active application and system gestures can supersede app responders, which makes Accessibility APIs insufficient as a replacement for a true gesture-blocking primitive. [12]

#### BetterTouchTool / Jitouch / alternatives
- Fact: Jitouch’s support page says some gestures interfere with App Exposé and recommends disabling App Exposé or changing it from three fingers to four fingers. [16]
- Fact: Jitouch’s support page also says the issue is “likely to be caused by Event Taps,” and recommends using the default actions for space switching rather than custom shortcuts when conflicts occur. [16]
- Fact: Jitouch issue #43 records the exact default preference keys for 3-finger drag, 3-finger horizontal swipe, 3-finger vertical swipe, and 4-finger horizontal swipe, confirming that users often resolve conflicts by editing preferences rather than intercepting events. [14]
- Fact: A BetterTouchTool action reference includes explicit actions like “Disable Gesture Recognition” and “Mission Control,” which shows BTT manages conflict by suppressing its own recognition or remapping actions, not by public macOS gesture interception APIs. [17]
- Fact: A BetterTouchTool community gist tells users to disable “Swipe between full-screen apps” and Mission Control in Trackpad settings on the host machine before using BTT gestures for remote control. [15]
- Fact: An open-source MiddleDrag project says it uses private MultitouchSupport to intercept raw touch data before the system gesture recognizer processes it, while leaving Mission Control and Exposé functional. [18]
- Fact: That MiddleDrag README claims it “works alongside system gestures,” which is evidence that raw-touch interception can coexist with native gestures but does not prove it can block them. [18]
- Fact: A 2026 AltTab discussion says BTT exists as a workaround for activating features with touchpad gestures, but the comments still point to system preference conflicts as the main obstacle. [19]

#### System Preferences / defaults keys
- Fact: Multiple dotfiles and docs list the relevant preference keys under `com.apple.AppleMultitouchTrackpad`, including `TrackpadThreeFingerHorizSwipeGesture`, `TrackpadThreeFingerVertSwipeGesture`, `TrackpadFourFingerHorizSwipeGesture`, and `TrackpadThreeFingerDrag`. [14][20][21]
- Fact: A nix-darwin module documents the semantic values for these keys: for example, three-finger horizontal swipe can be 0/1/2, and three-finger vertical swipe can be 0/2, with 2 enabling the native full-screen app / Mission Control behaviors. [21]
- Fact: The same module says four-finger vertical swipe defaults to 2 and that when both three- and four-finger vertical swipes are enabled, the three-finger variant takes precedence. [21]
- Fact: A BetterTouchTool-related discussion says overriding the three-finger swipe preference via `defaults write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerHorizSwipeGesture 0` changed the plist value but did not stop the gesture in practice on macOS 15, and `killall Dock` did not help. [19]
- Fact: A gist of macOS defaults shows `showAppExposeGestureEnabled` and `showMissionControlGestureEnabled` live under `com.apple.dock`, and `mru-spaces` / `enterMissionControlByTopWindowDrag` are separate Dock preferences. [20]
- Fact: An older gist says `defaults write com.apple.dock mcx-expose-disabled -bool TRUE` was used to disable Mission Control-by-drag behavior, but a comment reports that it no longer worked on Big Sur. [22]
- Fact: Another issue thread says `showMissionControlGestureEnabled` and `showAppExposeGestureEnabled` can be detected from `com.apple.dock`, but writing the plist did not reliably override the active gesture binding on newer macOS versions. [19]

#### macOS version considerations
- Fact: A Stack Overflow answer from 2011 said returning NULL from an event tap did not block gestures on OS X 10.6, implying old macOS versions already had limitations for gesture suppression. [4]
- Fact: A 2013 Stack Overflow answer says global monitor swipe support was absent by design at that time. [9]
- Fact: A 2016 Apple trackpad doc archive still describes system-wide gestures as taking precedence over responder-chain handling. [12]
- Fact: A 2024 AltTab discussion says on modern macOS the built-in gesture conflicts remained severe enough that the feature was disabled by default. [6]
- Fact: A 2026 AeroSpace issue says the WindowServer consumes the gesture before MultitouchSupport callbacks on current macOS, showing the same class of problem still exists in 2026. [13]

### Counter-Evidence
- Fact: InstantSpaceSwitcher demonstrates that a CGEventTap can, at least for Dock swipe gestures, intercept, return NULL, and replace the gesture with a synthetic event stream that the Dock honors. [5]
- Fact: That project specifically reports no SIP disable requirement and uses only public CGEventTap/CGEventPost APIs plus undocumented field indexes, which is a concrete success case for a narrowly defined swipe path. [5]
- Fact: The project’s success is limited to horizontal space switching behavior and does not establish a universal solution for Mission Control or App Exposé gestures. [5]

### Gaps
- No primary Apple source was found that explicitly states whether `.cghidEventTap` or `.cgSessionEventTap` can block Mission Control / App Exposé gesture recognizers specifically.
- No verified source was found showing a public API that reliably suppresses default 3-finger Mission Control / Spaces gestures across macOS 12–15.
- No authoritative source was found proving Accessibility permission alone can consume or cancel these gestures.
- No open-source project was found that clearly and reproducibly blocks the system Mission Control / App Exposé gestures while keeping custom 3-finger app actions active on current macOS.
- Some evidence is indirect or anecdotal because Apple’s relevant docs are sparse and several community reports rely on reverse-engineering or conflict workarounds.

### Confidence
**Level:** MEDIUM
**Rationale:** There is strong convergence across Apple docs, Apple forums, Stack Overflow, and multiple gesture-app repositories that global gesture consumption is limited and that defaults/preferences are the practical workaround; however, direct primary evidence for “can this specific tap consume Mission Control?” was not found, and some evidence is anecdotal or reverse-engineered.

### Source Register
| ID | Source | Tier | Date | Why kept | URL |
|----|--------|------|------|----------|-----|
| [1] | CGEventTapCallBack | 1 | N/A | Primary Apple callback contract stating NULL deletes events for active filters | https://developer.apple.com/documentation/coregraphics/cgeventtapcallback |
| [2] | Quartz Event Services | 1 | N/A | Primary Apple overview of event taps as filters before delivery | https://developer.apple.com/documentation/coregraphics/quartz_event_services |
| [3] | Apple Developer Forums: Accessibility permission in sandboxed apps | 1 | 2025-03 | Primary forum guidance on CGEventTap vs NSEvent monitors and Input Monitoring | https://developer.apple.com/forums/thread/707680 |
| [4] | Consuming OSX mouse/trackpad events with an event tap | 4 | 2010-12 | Community report that returning NULL did not block gesture events in practice | https://stackoverflow.com/questions/4518559/consuming-osx-mouse-trackpad-events-with-an-event-tap |
| [5] | InstantSpaceSwitcher/ISS.c | 3 | 2026-03 | Working open-source example of CGEventTap-based gesture rewriting | https://github.com/jurplel/InstantSpaceSwitcher/blob/main/Sources/ISS/ISS.c |
| [6] | AltTab Swipe Gestures PR discussion | 3 | 2024-12 | Community evidence that default taps could not absorb gesture events reliably | https://github.com/lwouis/alt-tab-macos/pull/3926 |
| [7] | AeroSpace issue #2014 | 3 | 2026-03 | Current report that macOS consumes 3-finger swipes before MultitouchSupport callbacks | https://github.com/nikitabobko/AeroSpace/issues/2014 |
| [8] | NSEvent.EventTypeMask | 1 | N/A | Primary Apple list of gesture-related NSEvent masks | https://developer.apple.com/documentation/appkit/nsevent/eventtypemask |
| [9] | How to monitor for swipe gesture globally in OS X | 4 | 2013-06 | Community evidence that global monitors do not support swipe gestures | https://stackoverflow.com/questions/17152287/how-to-monitor-for-swipe-gesture-globally-in-os-x |
| [10] | Global events for Show desktop, show notification center, etc. in cocoa | 4 | 2014-04 | Community evidence that global monitors and event taps struggled to reveal system gestures | https://stackoverflow.com/questions/23339424/global-events-for-show-desktop-show-notification-center-etc-in-cocoa |
| [11] | CGEventType | 1 | N/A | Primary Apple list of low-level Quartz event types | https://developer.apple.com/documentation/coregraphics/cgeventtype |
| [12] | Handling Trackpad Events | 1 | 2016-09 | Apple’s archived trackpad gesture docs on system gesture precedence | https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html |
| [13] | AeroSpace issue #2014 | 3 | 2026-03 | Same issue also notes disabling TrackpadThreeFinger* prefs frees the swipes | https://github.com/nikitabobko/AeroSpace/issues/2014 |
| [14] | Jitouch issue #43 | 3 | 2022-10 | Tracks exact defaults keys used to detect gesture conflicts | https://github.com/JitouchApp/Jitouch/issues/43 |
| [15] | BetterTouchTool community gist | 3 | 2020-07 | Practical guidance to disable native gestures and route actions through BTT | https://gist.github.com/findmory/82593b407ef436fe8a39f1bbb6802690 |
| [16] | Jitouch support page | 3 | N/A | Direct vendor support guidance on App Exposé conflicts and workarounds | http://www.jitouch.com/support/ |
| [17] | BetterTouchTool Action JSON Definitions | 2 | N/A | Official BTT docs showing gesture disable/remap actions | http://docs.folivora.ai/docs/actions/action-definitions/ |
| [18] | MiddleDrag README | 3 | 2025-11 | Open-source example claiming raw-touch interception while leaving native gestures functional | https://github.com/NullPointerDepressiveDisorder/MiddleDrag |
| [19] | AltTab issue #3926 / related comments | 3 | 2024-12 | Evidence that writing prefs did not reliably override gesture binding on newer macOS | https://github.com/lwouis/alt-tab-macos/pull/3926 |
| [20] | macOS Preferences Defaults gist | 3 | 2020-06 | Lists Dock and trackpad defaults keys relevant to gestures | https://gist.github.com/ChristopherA/98628f8cd00c94f11ee6035d53b0d3c6 |
| [21] | nix-darwin trackpad defaults module | 2 | N/A | Documents semantic values/defaults for trackpad gesture preference keys | https://github.com/LnL7/nix-darwin/blob/master/modules/system/defaults/trackpad.nix |
| [22] | Disable Mission Control animation gist | 3 | 2019-02 | Historical system defaults workaround and later report of breakage | https://gist.github.com/qutek/8ab7f265b4337861b1ecf8d6b953801a |

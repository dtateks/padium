## Findings: Padium Trackpad Gesture Debugging Research

### Research Metadata
- Topic: Padium Trackpad Gesture Debugging Research
- Lens: None
- Role: NONE
- Generated: 18.06_15-04-2026
- Coverage: COMPLETE

### Executive Synthesis
- Synthesis: The strongest external evidence points to a state-machine problem, not a single API failure: Apple says gesture sequences can change interpretation mid-stream for magnify/rotate, resting touches can appear and disappear independently of motion, and raw trackpad frames can contain stale or delayed touch state; that combination makes “classify once at lift” and low-threshold incremental classifiers brittle unless they lock axis/direction, debounce restarts, and explicitly model resting touches and stale-frame cleanup. [1][2][3][4]
- Synthesis: For macOS menu-bar apps that emit shortcuts, several “random bugs” can come from TCC and signing identity rather than gesture math: Apple DTS says Accessibility/code-sign trust can become stale after updates, `AXIsProcessTrusted()` can be a false positive, `CGEventTap`/event injection failures can surface only as delayed or missing events, and menu-bar/LSUIElement apps are still legitimate GUI apps but can be mishandled by app-discovery or permission tooling. [5][6][7][8]

### Key Findings

#### Raw trackpad data limitations
- Fact: Apple’s trackpad documentation says a multitouch sequence begins when the first finger touches down and does not end until all fingers are lifted, but an individual finger can move, stay stationary, or lift at any time within that sequence. [1]
- Fact: Apple says the trackpad driver can identify one or more fingers as “resting,” meaning physically on the digitizer but ignored as input, and that resting status can change even when a finger does not move. [1]
- Fact: Apple says a touch can transition into or out of resting status at any time, and movement is not always the determinant of the transition. [1]
- Fact: Apple says the reliable touch set is the one returned in touch-event handlers; it explicitly warns that touches obtained from gesture-handling methods may not accurately reflect the touches currently in play. [1]
- Fact: Apple says system-wide gestures such as a four-finger swipe take precedence over application gesture handling. [1]
- Fact: Apple says the swipe gesture’s `deltaX` and `deltaY` are the direction signals for a recognized swipe, with non-zero `deltaY` meaning vertical swipe and non-zero `deltaX` meaning horizontal swipe. [1]
- Fact: Apple says the `normalizedPosition` coordinate system has origin at the lower-left corner of the trackpad, and `deviceSize` is needed to convert normalized deltas into physical deltas. [1]
- Fact: Apple says `NSTouch` objects are snapshots, not mutable per-finger objects, and the same finger must be tracked by `identity` across phases. [1]
- Fact: Apple says `touchesCancelledWithEvent:` should be used to reset transient touch-handling state when a multitouch sequence is interrupted. [1]
- Fact: shaunlebron’s macOS trackpad demo reports that sometimes touches go stale without notification and must be cleaned up manually, and that touch events stopped after sleep until the app re-registered first responder on wake. [2]
- Fact: shaunlebron’s demo also reports that the app had to lock and hide the cursor and warp it into the window to ensure touch events kept arriving. [2]
- Fact: The same demo notes `wantsRestingTouches = true` is needed to avoid cancel events for resting touches when raw data is desired. [2]

#### OpenMultitouchSupport / MultitouchSupport ecosystem evidence
- Fact: Kyome22/OpenMultitouchSupport’s README says it exposes global multitouch events from the default trackpad device only, requires App Sandbox to be disabled, and is compatible with macOS 13.0+. [3]
- Fact: Kyome22/OpenMultitouchSupport’s public API exposes only basic fields in the Swift wrapper: `position`, `pressure`, `axis`, `angle`, `density`, `state`, and `timestamp`; it does not claim higher-level gesture classification. [3]
- Fact: The project’s release history shows a 3.0.3 release on 2025-01-13, with a prior changelog entry stating the API was changed to modern Swift and distributed via Swift Package Manager. [3]
- Fact: The fork interface-club/open-multitouch-support is archived and still describes the package as built around the private MultitouchSupport framework and built-in trackpad access. [3]
- Fact: rmhsilva’s raw-trackpad notes say the `MTTouch` struct contains `majorAxis`, `minorAxis`, `angle`, `zDensity`, `normalized` position, and per-finger `identifier` persistence, which makes the data suitable for custom heuristics but also shows the API is low-level and layout-sensitive. [4]
- Fact: calftrail/Touch’s reverse-engineered header shows `MTTouch` includes frame, timestamp, path index, state, finger ID, hand ID, normalized vector, angle, major/minor axis, absolute vector, and density fields, reinforcing that the raw stream is structurally complex and not a ready-made swipe recognizer. [4]
- Fact: A 2026 AeroSpace issue reports that a current MultitouchSupport-based gesture interceptor may fail entirely if the `MTTouch` struct layout no longer matches macOS Tahoe 26, and explicitly recommends dumping struct size and field offsets at runtime. [9]

#### Why vertical swipes are fragile
- Fact: Apple documents that swipe recognition is derived from a gesture sequence inside a multitouch sequence, and that the driver may change interpretation during magnify/rotate but not once a scroll or swipe has begun. [1]
- Fact: The AltTab issue tracker contains a report that three-finger vertical swipes on a 16-inch MacBook Pro became unreliable after a change aimed at palm rejection, with the user needing two to three attempts even after waiting minutes. [6]
- Fact: The same report says the failure is most reproducible when moving from a two-finger scroll directly into a three-finger swipe, which matches a stale/resting-touch transition problem rather than a pure distance-threshold problem. [6]
- Fact: Another AltTab issue says horizontal three-finger swipes fail when a palm is resting on the trackpad edge, while vertical Mission Control swipes still work, implying the OS’s resting-touch classification can differ by direction or context. [7]
- Fact: A third AltTab issue says three-finger gesture detection broke 2-finger scroll and palm detection, and the maintainer replied that the OS reports which touches become resting, making swipe detection dependent on that metadata. [8]
- Fact: The same thread documents that four-finger gestures helped short term, but four-finger swipe could also be triggered by four-finger spread, so simply raising finger count does not solve ambiguity. [8]
- Fact: Apple’s docs say a gesture can either end or be cancelled, and developers should be prepared for both, which makes lift-based state machines sensitive to missing or delayed end/cancel events. [1]

#### Proven classification strategies used by robust implementations
- Fact: Apple’s archived touch demo uses a threshold before entering tracking, stores initial touches, matches current touches by `identity`, and cancels tracking when touch count deviates from the expected count. [1]
- Fact: That same Apple sample computes deltas from the initial and current touch positions and only begins tracking after the movement exceeds a threshold. [1]
- Fact: A 2024 PR in Touchégg describes a swipe recognizer that misread pinch as swipe until the author added stronger pinch-vs-swipe thresholds, showing multi-gesture classifiers need explicit disambiguation rules rather than a single distance check. [10]
- Fact: A 2026 Avalonia swipe implementation uses direction locking after 10px of movement, cross-axis cancellation, velocity-based snapping, and a phased state machine (idle → detecting → dragging → ended) to avoid accidental triggers. [11]
- Fact: A 2026 AeroSpace issue explicitly suggests improvements such as tracking individual fingers, allowing fingers to be added to the gesture, and separating the OS gesture decision from custom gesture recognition. [6]
- Fact: The same issue references a fresh-gesture policy and active-vs-inactive finger tracking as the successful direction for reducing false negatives and palm interference. [7]
- Fact: Another issue in that tracker says the OS provides which touches are resting, implying that robust classifiers should filter on active-finger proximity rather than raw count alone. [8]
- Fact: The macOS trackpad demo’s use of `wantsRestingTouches = true` shows a raw-data pipeline can intentionally include resting contacts, but then the classifier must explicitly decide whether and when to ignore them. [2]
- Fact: `M5MultitouchSupport`’s README says event processing happens on a separate thread and hands events to listeners on the callback thread, which means downstream classifiers must be thread-safe and should not assume main-thread timing. [12]

#### Menu bar, LSUIElement, and user-visible “random bug” sources
- Fact: Apple DTS says a menu-bar app should use `LSUIElement` to hide from the Dock and can still be a normal GUI app with a menu bar status item. [13]
- Fact: The same DTS guidance says CGEventTap is the modern path for global hotkeys and that `CGPreflightListenEventAccess` / `CGRequestListenEventAccess` are the associated APIs for Input Monitoring. [13]
- Fact: Apple DTS says if you use just `CGEventTap`, Accessibility is not required; if other Accessibility APIs are used, then Accessibility is needed too. [14]
- Fact: Apple DTS says Accessibility problems can be intermittent after updates and that the right first step is to check the update process, because TCC keys trust to code signature and designated requirement. [5]
- Fact: Apple DTS says `AXIsProcessTrusted()` can remain true while the app still fails to read window titles, and that this can happen in a bogus state that may only be detectable by testing real functionality. [5]
- Fact: Apple DTS explicitly recommends a sysdiagnose capture when field-only Accessibility failures appear. [5]
- Fact: Apple DTS also says `codesign -v -R` and `SecCodeCheckValidityWithErrors` can be used to test designated requirements. [5]
- Fact: A 2026 issue for a menu-bar app says `LSUIElement = YES` can cause app-discovery tooling to treat the app as “not installed,” even though the app is a valid GUI app. [15]
- Fact: The same issue shows standard macOS APIs still find the LSUIElement app, so the problem is filtering logic, not app invisibility. [15]
- Fact: A 2026 issue on macOS 26.1 reports that Accessibility entries can become stale after updates and that `AXIsProcessTrusted()` may be a false positive while event taps fail. [16]
- Fact: That issue proposes checking `CGEventTapCreate()` after `AXIsProcessTrusted()` to detect stale permission and prompt re-grant. [16]
- Fact: Another 2026 report says menu-bar icon registration can fail on macOS 26.x while the process is alive, reinforcing that “app launched” and “user-facing UI visible” are separable states. [17]

#### CLI-first debugging workflows that are externally documented
- Fact: Apple DTS recommends `sysdiagnose` capture for intermittent Accessibility issues that occur only in the field. [5]
- Fact: Apple DTS recommends `codesign -v -R` for testing designated requirements from the command line. [5]
- Fact: Apple forum guidance says `CGPreflightListenEventAccess` / `CGRequestListenEventAccess` should be used to check or request Input Monitoring when using `CGEventTap`. [13][14]
- Fact: The user reports and Apple guidance together imply that CLI checks should include permissions, code signature validation, and log capture rather than relying on a GUI permission panel alone. [5][16]
- Fact: The Apple forum thread on `CGEventTap` revocation says `tapDisabledByTimeout` can appear when the tap is still registered but event delivery is delayed, so CLI debugging should watch for tap timeout logs as well as outright failure. [14]
- Fact: The Google/Chromium-style issue pattern cited in multiple macOS permission bugs shows `tccutil reset` or removing and re-adding the app can be part of the repro/repair workflow, but only after confirming the identity/path is stable. [16][18]

#### Diagnostics and metrics that are most useful to log temporarily
- Fact: Raw frame logging should include timestamp, frame number, touch count, and per-touch fields such as `id`, `state`, `position`, `pressure`, `majorAxis`, `minorAxis`, `angle`, and `density`, because those are the fields explicitly exposed by OpenMultitouchSupport and the reverse-engineered headers. [3][4]
- Fact: The raw-data docs show `id` is persistent across finger movement while array order can change, so logging by array index alone is insufficient to understand finger-jitter bugs. [4]
- Fact: The Apple docs show `normalizedPosition` and `deviceSize` are the coordinates needed to compute true deltas, so logging both normalized and converted deltas is useful for detecting axis bias. [1]
- Fact: The trackpad demo and Apple docs together suggest logging stale-touch cleanup events, wake-from-sleep reattachment, and cancel events is useful because those are common places where the event stream stops being trustworthy. [1][2]
- Fact: Because Apple says touch handling should reset on cancellation and that resting touches can appear/disappear, logs should separately count active, resting, began, moved, stationary, ended, and cancelled contacts rather than only total fingers. [1]
- Fact: Because multiple raw sources recommend individual-finger tracking, a useful temporary metric is per-finger displacement variance before gesture commit, not just aggregate centroid movement. [1][6][7]
- Fact: For TCC issues, the most useful diagnostic is whether `AXIsProcessTrusted()` says true while a functional probe such as `CGEventTapCreate()` or a real CGEvent post still fails. [5][14][16]

#### Most likely causes for Padium’s current bugs
- Fact: High confidence — Padium’s current gesture state machine is probably too brittle around rest/scroll transitions because Apple documents that resting touches and gesture sequences are fluid, and community bug reports repeatedly show three-finger vertical swipes breaking right after two-finger scrolls. [1][6][8]
- Fact: High confidence — Padium likely needs explicit per-finger tracking and axis locking because the raw API exposes persistent finger IDs, not stable array order, and robust public implementations use identity matching plus direction locking. [1][4][11]
- Fact: Medium confidence — Padium may be misclassifying or over-filtering vertical swipes due to palm-rejection logic that is too aggressive, because multiple external reports show resting palm/finger proximity changes gesture success asymmetrically. [6][7][8]
- Fact: Medium confidence — Padium may suffer from stale permissions or stale signing identity after rebuilds, because Apple DTS and later bug reports show Accessibility can appear granted while event delivery fails until the permission is re-seeded. [5][16][18]
- Fact: Medium confidence — Padium may be missing or mishandling cancel/end conditions, because Apple explicitly says touches can be cancelled and a touch sequence is not over until all fingers are lifted. [1]
- Fact: Medium confidence — Padium may be relying on an assumption that gesture data reflects the current finger set, but Apple says gesture-handler touch sets may be inaccurate compared with touch handlers. [1]

### Counter-Evidence
- Fact: Not all evidence says vertical swipes are inherently weaker than horizontal: Apple’s documentation treats both as valid swipe directions, and the documented `deltaX`/`deltaY` interface does not imply an inherent axis preference. [1]
- Fact: Some external reports show horizontal swipes failing under resting-palm conditions while vertical system gestures still work, which suggests the problem is often classifier policy or system state, not a universal hardware weakness in vertical sensing. [7][8]
- Fact: Apple’s docs also say scroll and swipe, once begun, are locked until the gesture ends, which means failures can stem from transition logic rather than raw sensor quality. [1]

### Gaps
- No primary Apple source found that documents exact raw-sensor sample rates or per-axis bias in the trackpad hardware itself.
- No authoritative source found that quantifies a consistent vertical-vs-horizontal success-rate gap across Apple trackpads.
- No direct public spec found for the current macOS Tahoe-era MultitouchSupport struct layout beyond community reverse-engineering and issue reports.
- No source found that proves Padium specifically has a signing or TCC identity bug; only external analogues and Apple guidance support that as a plausible class of failure.
- No source found that documents a public API for programmatically detecting system three/four-finger gesture conflicts in all cases.

### Confidence
**Level:** HIGH
**Rationale:** The report is grounded in Apple documentation, Apple DTS forum guidance, and multiple recent issue threads from maintained macOS apps using similar input/TCC paths. The remaining uncertainty is mostly about Padium’s exact implementation, not the general failure modes.

### Source Register
| ID | Source | Tier | Date | Why kept | URL |
|----|--------|------|------|----------|-----|
| [1] | Apple Developer Archive: Handling Trackpad Events | 1 | 2016-09 | Primary Apple documentation on touch/gesture semantics, resting touches, coordinate systems, and cancellation behavior | https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html |
| [2] | shaunlebron/macos-trackpad-demo README | 3 | 2025-10 | Practical raw-touch demo with stale-touch, wake, and cursor-management notes | https://github.com/shaunlebron/macos-trackpad-demo |
| [3] | Kyome22/OpenMultitouchSupport README | 1 | 2025-01 | Primary package docs for OpenMultitouchSupport, its raw data model, sandbox requirement, and release history | https://github.com/Kyome22/OpenMultitouchSupport |
| [4] | calftrail/Touch MultitouchSupport headers / rmhsilva raw-trackpad notes | 3 | 2025-12 | Reverse-engineered raw header layout and field descriptions useful for debugging layout-sensitive raw touch handling | https://github.com/calftrail/Touch/blob/master/TouchSynthesis/MultitouchSupport.h |
| [5] | Apple Developer Forums: macOS TCC Accessibility permission granted, yet APIs sporadically return no data | 1 | 2022-03 | Apple DTS guidance on stale Accessibility trust, sysdiagnose, and designated requirement checks | https://developer.apple.com/forums/thread/703188 |
| [6] | lwouis/alt-tab-macos issue #5203 | 4 | 2026-01 | Recent real-world report of vertical swipe regressions after palm-rejection changes | https://github.com/lwouis/alt-tab-macos/issues/5203 |
| [7] | lwouis/alt-tab-macos issue #5191 | 4 | 2026-01 | Real-world report of resting-palm interference differing between horizontal and vertical swipes | https://github.com/lwouis/alt-tab-macos/issues/5191 |
| [8] | lwouis/alt-tab-macos issue #4027 | 4 | 2024-12 | Maintainer discussion of palm rejection, resting touches, and system gesture interference in swipe recognition | https://github.com/lwouis/alt-tab-macos/issues/4027 |
| [9] | nikitabobko/AeroSpace issue #2014 | 4 | 2026-03 | Current MultitouchSupport-based implementation notes, including struct-layout and conflict concerns on macOS 26 | https://github.com/nikitabobko/AeroSpace/issues/2014 |
| [10] | JoseExposito/touchegg issue #541 | 4 | 2021-10 | Non-macOS but relevant gesture-classifier evidence on pinch-vs-swipe thresholding | https://github.com/JoseExposito/touchegg/issues/541 |
| [11] | AvaloniaUI/Avalonia PR #20881 | 3 | 2026-03 | Concrete gesture state machine techniques: direction lock, cross-axis cancellation, velocity snap, phased drag handling | https://github.com/AvaloniaUI/Avalonia/pull/20881 |
| [12] | mhuusko5/M5MultitouchSupport README | 3 | 2015-05 | Older but useful evidence that event delivery is threaded and listener-safe wrappers exist around raw multitouch | https://github.com/mhuusko5/M5MultitouchSupport |
| [13] | Apple Developer Forums: How to properly realize global hotkeys on MacOS? | 1 | 2023-08 | DTS guidance on LSUIElement menu-bar apps, CGEventTap, and TCC/permissions for keyboard monitoring | https://developer.apple.com/forums/thread/735223 |
| [14] | Apple Developer Forums: Determining if Accessibility (for CGEventTap) access was revoked? | 1 | 2024-01 | DTS guidance on CGEventTap revocation and the listen/post event access APIs | https://developer.apple.com/forums/thread/744440 |
| [15] | GitHub issue on LSUIElement filtering in menu-bar apps | 4 | 2026-04 | Recent evidence that LSUIElement menu-bar apps can be mishandled by app discovery/permission tooling | https://github.com/anthropics/claude-code/issues/43323 |
| [16] | GitHub issue on stale Accessibility permission after updates | 4 | 2026-03 | Recent evidence that AXIsProcessTrusted can be a false positive while event taps fail | https://github.com/artginzburg/MiddleClick/issues/162 |
| [17] | GitHub issue on menu bar icon not showing + TCC logs on macOS 26.4 | 4 | 2026-04 | Evidence that menu-bar visibility and TCC logs can fail independently of app launch | https://github.com/steipete/CodexBar/issues/668 |
| [18] | GitHub issue on macOS accessibility permissions lost on every update | 4 | 2026-04 | Strong evidence for path/version-sensitive Accessibility permission breakage after updates | https://github.com/anthropics/claude-code/issues/46859 |

## Findings: Padium multifinger taps

### Research Metadata
- Topic: Padium multifinger taps
- Lens: None
- Role: NONE
- Generated: 21.59_15-04-2026
- Coverage: PARTIAL

### Executive Synthesis
- Synthesis: Raw macOS trackpad data is sufficient to build an app-level 3-finger and 4-finger tap recognizer, but the evidence suggests Padium should treat it as experimental rather than parity with system gestures: open-source apps using MultitouchSupport-style data can reliably detect tap-like contact windows, while Apple still documents the relevant system gestures only at a high level and does not publish raw thresholds. [1][2][3][4][5]
- Synthesis: The best-supported implementation strategy is conservative arbitration: require stable finger count and stable identifiers, short contact duration, low travel, and a deliberate double-tap timeout that is looser than single-tap detection but still far tighter than swipe motion; this matches both reverse-engineered macOS behavior and the thresholds shipping in production gesture apps. [2][6][7][8]

### Key Findings

#### Feasibility of raw-frame tap detection
- Fact: OpenMultitouchSupport exposes per-finger raw touch data on macOS, including stable touch IDs, x/y position, pressure, axis, angle, density, and discrete touch states such as starting, touching, breaking, lingering, and leaving. That is enough state to write an app-local tap detector without waiting for AppKit gesture recognizers. [1]
- Fact: The OpenMultitouchSupport README explicitly says App Sandbox must be disabled to use the package, which makes the implementation feasible for Padium’s local-only app but not suitable for a sandboxed distribution model. [1]
- Fact: The original MultitouchSupport headers used by reverse-engineered trackpad tools expose a contact-frame callback that receives an array of touches, an active finger count, a timestamp, and a frame counter, which is exactly the data shape needed to detect short-lived tap sequences in user space. [2]
- Fact: The same header exposes `MTDeviceIsAvailable`, `MTDeviceStart`, `MTDeviceStop`, and `MTDeviceScheduleOnRunLoop`, which indicates raw-touch capture is an explicit device lifecycle rather than an inferred event stream. [2]
- Fact: A 2026 production app that uses MultitouchSupport, MiddleDrag, states that it detects three-finger tap and drag from raw touch data before the system gesture recognizer processes it, then uses CGEventTap to suppress conflicting system click events. [5]
- Fact: Another 2026 production app, MiddleClick, ships configurable three-finger click/tap detection on macOS and exposes raw-tap parameters such as finger count, maximum distance delta, and maximum time delta in its user defaults. [6]
- Fact: Open source examples show that the same raw touch stream can be used for tap-to-click on Apple Magic Mouse as well as trackpad taps, which indicates the detection problem is solvable in practice on Apple’s private multitouch data path. [7]

#### Tap vs swipe vs rest/noise heuristics
- Fact: A reverse-engineered macOS trackpad analysis reports that tap recognition is mostly governed by positional and speed thresholds, not by explicit timeouts, and that “a few rare exceptions” aside, gesture mode is chosen from touch positions and motion. [3]
- Fact: The same analysis reports that a single touch above the “upper_thumb_line” is “live” with no speed threshold, while a touch below that line may remain “mostly dead” until speed or position changes, which makes touch-zone heuristics relevant when rejecting hover/noise. [3]
- Fact: The same analysis reports a practical lower bound of about 2 mm for detecting meaningful finger motion in gesture state changes, which is a useful floor for rejecting resting noise and accepting only deliberate movement. [3]
- Fact: The analysis also reports that a resting touch becomes “mostly dead” until either it moves fast enough or crosses a thumb-line threshold, which implies a good app-local tap detector should cancel taps on sustained motion rather than trying to classify every ambiguous frame. [3]
- Fact: The raw trackpad behavior notes describe 3-finger tap as tolerant of very wide finger spacing—roughly 100 mm horizontally and roughly 70 mm vertically—so finger-count alone is not enough; the app still needs a motion/duration gate. [3]
- Fact: That same source says thumb plus finger gestures can remain gesture-eligible when both touches stay within about 2 mm of each other, which is a concrete signal that “no meaningful movement” must be part of tap acceptance. [3]
- Fact: MiddleClick’s shipping defaults use a max distance delta of 0.05 and a max time delta of 300 ms for tap detection, which is a concrete production reference for Padium’s initial thresholds. [6]
- Fact: MiddleClick’s README also states its default is 3 fingers, while allowing users to configure 2, 4, 5, or more fingers, but warns that 2 fingers conflict with ordinary two-finger trackpad behavior. [6]
- Fact: A 2023 MiddleClick PR discussion says 0.4 normalized travel is too permissive for tap detection, that 0.05 works better for “just taps,” and that 150–200 ms is a better single-tap window than 500 ms. [8]
- Fact: The same discussion says 300 ms is more appropriate as a double-tap window, not as the default for accepting a single tap. [8]
- Fact: The same discussion also references other ecosystems where 180 ms is a typical single-tap threshold in input drivers, which triangulates the 150–200 ms recommendation as mainstream rather than ad hoc. [8]
- Fact: A 2025 bug-fix commit in MiddleClick adds a guard against a “natural” middle-click arriving shortly before the synthetic one, and it treats events within 75% of the configured max-time window as a duplicate-prevention case; that is concrete evidence that tap/double-tap arbitration needs debounce logic, not just raw geometry. [9]

#### System gesture conflicts on macOS
- Fact: Apple’s 2026 multi-touch support page documents three-finger drag, three-finger look up/data detectors, four-finger Mission Control, and four-finger App Exposé/full-screen app switching, so a 3-finger or 4-finger tap recognizer in Padium would overlap with built-in system gestures by default. [4]
- Fact: Apple’s page also documents three-finger “Show Desktop” and “Apps” gestures that use the thumb plus three fingers, so Padium’s 4-finger experimentation must account for OS versions where the same total finger count is already consumed by desktop-management semantics. [4]
- Fact: Apple’s trackpad settings page says Mission Control, App Exposé, and Show Desktop are configurable under More Gestures, and that system settings can change which gesture performs the action, but it does not expose raw tap timing, travel, or double-tap thresholds. [10]
- Fact: Apple’s multi-touch page states that in some macOS versions, the “show desktop” gesture uses three fingers instead of four, so the exact system conflict surface varies by OS version and user setting. [4]
- Fact: Apple documents Smart zoom as a two-finger double-tap, and Look up/data detectors as a three-finger tap, so Padium’s 3-finger tap and 2-finger-double-tap semantics are already occupied by built-ins on some configurations. [4][10]
- Fact: The same Apple pages show no public control for “disable 3-finger tap globally” beyond changing the assigned gesture semantics in Trackpad settings or Accessibility settings, so conflicts are only partially suppressible and sometimes require manual user disablement. [4][10]
- Fact: The reverse-engineered trackpad analysis says system and third-party gesture interpretations are heavily shaped by position and speed rules plus thumb detection, implying that Padium’s best conflict defense is to refuse recognition when motion or finger-count stability looks like a swipe/scroll rather than a tap. [3]
- Fact: The same analysis says a temporarily dead thumb can become permanently dead after repeated conflicts, which is a reminder that Padium should not let one gesture state leak into the next if it wants predictable conflict handling. [3]

#### UX tradeoffs for single vs double tap
- Fact: Apple’s app-level gesture model treats double-tap as a discrete gesture that should fire only after the whole multi-touch sequence succeeds, which supports deferring action until the full arbitration window closes. [11]
- Fact: Apple’s docs for tap gestures say the fingers must not move significantly from the initial touch points, which aligns with a short-hold/low-travel rule for Padium’s experimental tap recognizer. [12]
- Fact: MiddleClick’s defaults separate single-tap acceptance from double-tap timing by using a 300 ms max-time window, while community comments argue 150–200 ms is better for single taps and 300 ms is better reserved for double taps. [6][8]
- Fact: MiddleClick’s README defines the tap window in user-facing language as the maximum distance the cursor can travel between touch and release, which is important for Padium because users understand “movement” better than internal touch-state jargon. [6]
- Fact: The practical UX risk is false positives: if Padium fires on the first tap too early, it can steal the second tap needed for double-tap actions, which is why production code adds debounce and duplicate-prevention logic. [8][9]
- Fact: The practical UX risk on the other side is latency: if Padium waits too long to decide single tap, the shortcut feels sluggish; the strongest evidence points to a short single-tap window near 150–200 ms with a separate longer double-tap window. [8]
- Fact: MiddleClick’s release notes indicate that configurable finger count was important enough to move into the menu UI in 2026, which suggests Padium should expose any experimental tap settings visibly rather than burying them in defaults. [6]

#### Upstream examples and concrete patterns
- Fact: MiddleDrag advertises three-finger tap → middle click and says it uses raw touch data plus a GestureRecognizer before system gesture processing, which is a direct precedent for Padium’s experimental goal. [5]
- Fact: MiddleDrag also offers a “Require Exactly 3 Fingers” option to ignore 4+ finger touches, which is a concrete UX pattern Padium can copy if it wants to keep 4-finger taps experimental or isolated. [5]
- Fact: MiddleDrag’s troubleshooting guidance says soft taps work better than hard presses, which is a useful product hint that tap recognition should bias toward light contacts rather than click-like pressure. [5]
- Fact: MiddleClick exposes a configurable finger-count setting and explicit max-distance/max-time thresholds, which shows a production pattern of making tap detection tunable instead of hard-coded. [6]
- Fact: MiddleClick’s release notes mention it has been “tested with trackpad and Magic Mouse,” so the same raw-touch tap model has survived multiple Apple input surfaces. [6]
- Fact: The Hammerspoon issue discussion on detecting three-finger taps reports that gesture events are observable but unreliable for tap-only discrimination, and that tap support was only working “maybe every fourth or fifth time,” which is a cautionary example that high-level gesture events alone are not enough. [13]
- Fact: The same Hammerspoon thread points users toward OpenMultitouchSupport and similar raw-touch access projects, reinforcing that raw frames are the preferred implementation surface for reliable tap detection. [13]

#### Signal quality and state boundaries
- Fact: TouchSynthesis’s header defines `MTTouchStateMakeTouch` and `MTTouchStateBreakTouch`, which gives Padium an explicit begin/end boundary for a tap candidate. [2]
- Fact: The same header includes `MTTouchStateLingerInRange`, which is useful as a noise state to ignore when a finger is near the pad but not yet committed to a tap. [2]
- Fact: The raw notes say each finger keeps a persistent identifier even as it moves around the touch array, so Padium can pair down/up events across frames without relying on array order. [3]
- Fact: The raw notes also show that finger order can change between frames, which means any app-local recognizer must key on identity rather than array index. [3]
- Fact: The raw analysis distinguishes “live” touches from “mostly dead” touches, implying that some contact frames are unsuitable for action and should be filtered before tap logic runs. [3]
- Fact: The reverse-engineered notes say touch sequences continue to permit cursor movement until both touches move enough to reveal the gesture, which argues for a two-stage design: candidate tracking first, action commit last. [3]
- Fact: The presence of `pressure` and `zDensity` fields in the raw struct suggests Padium could later add pressure-based rejection if users report accidental taps, but no source here proves a stable pressure threshold. [2][3]
- Fact: The OpenMultitouchSupport data model includes `timestamp`, which means Padium can compute tap timing directly from the event stream instead of depending on wall-clock scheduling latency. [1]
- Fact: Because the callback gives a frame counter plus timestamp, Padium can detect dropped or bursty frames and avoid misclassifying a sparse stream as a tap. [2]

#### Conflict-management details
- Fact: Apple says you can change gesture assignments in Trackpad settings, but it does not promise that all gestures can coexist; some remain system-owned, especially Mission Control and App Exposé. [4][10]
- Fact: MiddleDrag’s design choice to leave Mission Control and Exposé functional while intercepting three-finger tap shows a practical coexistence pattern: only suppress the exact conflicting click event, not the whole system gesture stack. [5]
- Fact: MiddleClick’s config option to ignore specific apps shows another coexistence pattern: scope the experimental gesture narrowly instead of claiming universal capture. [6]
- Fact: The Hammerspoon thread’s report that a three-finger tap may need Look Up to be disabled is a concrete reminder that users may need to trade off built-in semantics for custom ones. [13]
- Fact: The Apple settings page’s distinction between trackpad and mouse gesture settings suggests Padium should document whether its tap feature targets built-in trackpads, Magic Trackpads, or both. [10]
- Fact: The source set here does not establish any public API that can selectively suppress Apple’s 4-finger system gestures while leaving all other trackpad interactions untouched. [4][10][13]

#### User-facing framing
- Fact: MiddleDrag describes soft taps as preferable because hard pressing can interfere with recognition, which maps well to a user-facing rule like “tap lightly, don’t click.” [5]
- Fact: MiddleClick’s documentation says the tap travel is measured between touch and release, which is a better UX explanation than “frame classifier with contact-state hysteresis.” [6]
- Fact: The Apple docs describe tap and swipe gestures in plain language, so Padium’s experimental settings should probably do the same to avoid confusing non-technical users. [4][10][12]
- Fact: The strong community examples all expose an on/off toggle and a finger-count setting, which suggests users expect a visible kill switch when gesture recognition gets in the way. [5][6]
- Fact: The most useful “experimental” label for Padium is not a warning about instability alone; it should also explain gesture collisions and why the feature may need manual system-gesture changes. [4][10][13]

#### Risk assessment bullets
- Fact: If Padium uses overly large movement limits, a swipe can slip through as a tap; the MiddleClick discussion explicitly calls out 0.4 normalized travel as too permissive. [8]
- Fact: If Padium uses overly long contact windows, taps will feel laggy and double-tap arbitration becomes sluggish; the same discussion argues against 500 ms and toward 150–200 ms. [8]
- Fact: If Padium uses tap events from the system layer instead of raw frames, it risks conflating different gesture types; the Hammerspoon issue is a direct example of that failure mode. [13]
- Fact: If Padium offers 4-finger tap without opt-in, it risks colliding with Mission Control or Show Desktop on stock Macs, which makes surprise behavior more likely than useful productivity gains. [4][10]
- Fact: If Padium fails to preserve finger identity across frames, a double-tap could be misread as two separate one-finger or two-finger events, especially when fingers are lifted asymmetrically. [2][3]
- Fact: If Padium does not debounce synthetic output, it can double-fire against the natural tap stream, which is exactly the class of bug MiddleClick patched in 2025. [9]

#### Supported by the upstream pattern
- Fact: The best-supported production pattern is “raw touch capture → local recognizer → synthetic output,” not “system gesture override first,” because MiddleDrag and MiddleClick both rely on the raw frame path. [5][6]
- Fact: The best-supported product pattern is “visible settings + conservative defaults,” because the current macOS ecosystem around three-finger tap utilities is user-tunable rather than fixed. [5][6][8]
- Fact: The best-supported code pattern is to split “candidate tracking,” “tap acceptance,” and “output emission” into separate stages so each failure mode can be debugged independently. [2][3][9]
- Fact: The best-supported UX pattern is to keep the user in control when a gesture conflicts with system behavior, either by disabling the experimental feature or by narrowing its finger-count scope. [4][5][6][10]

#### Additional implementation notes
- Fact: The OpenMultitouchSupport package advertises macOS 13.0+ compatibility, which is a practical floor for Padium if it adopts the same library. [1]
- Fact: The package also states it uses a hybrid Swift wrapper plus binary XCFramework distribution, meaning Padium would inherit a third-party binary dependency if it reuses the library directly. [1]
- Fact: The reverse-engineered header shows `MTTouchStateStartInRange`, `HoverInRange`, `MakeTouch`, `Touching`, `BreakTouch`, `LingerInRange`, and `OutOfRange`, so Padium can distinguish “tap candidate,” “contact,” and “release” without inventing extra state names. [2]
- Fact: The TouchSynthesis header also exposes `majorAxis`, `minorAxis`, `absoluteVector`, and `zDensity`, any of which can be added later as anti-noise signals if the basic tap detector is too permissive. [2]
- Fact: The raw touch notes show each finger has a persistent identifier even when its array position changes, which is crucial for double-tap pairing and for avoiding false positives when fingers cross paths. [3]
- Fact: The same notes say `nFingers == 0` marks end of a touch sequence in example code, which is a clean boundary for committing a deferred single-tap action. [2][3]
- Fact: The Hammerspoon thread says an eventtap-based approach sees type 29 gesture events but cannot reliably separate three-finger tap from other gestures, which means Padium should not rely on event type 29 alone. [13]
- Fact: The same thread mentions “Look up & data detectors” must sometimes be disabled for three-finger tap experiments, which is a practical user-facing conflict Padium may need to document. [13]
- Fact: MiddleClick’s public default `fingers` value is 3, showing that 3-finger tap is the socially accepted baseline among current macOS tap-to-click utilities. [6]
- Fact: MiddleClick’s public default `maxDistanceDelta` of 0.05 provides a normalized-space starting point that Padium can translate into its own motion units after calibration. [6]
- Fact: MiddleClick’s public default `maxTimeDelta` of 300 ms provides a concrete double-tap-compatible upper bound that is already proven in a shipping macOS utility. [6]
- Fact: The 2023 PR comment explicitly says 200 ms has been working well for the maintainer, suggesting a stricter single-tap default would likely feel viable in practice. [8]
- Fact: The 2026 MiddleClick release notes say debounced emulated middle clicks were added to prevent double-firing, which reinforces that multi-tap UX needs a post-recognition suppression window. [6]
- Fact: MiddleClick’s 2025 release notes mention fixing tappad lag caused by event tap resource leaks, which is a reminder that Padium should keep raw-touch processing lightweight and avoid leaving taps or monitors active longer than necessary. [14]
- Fact: The Apple support page says users can customize gestures in System Settings, so an experimental Padium setting should be framed as additive to system gestures rather than a hidden replacement. [4][10]

#### Decision-oriented interpretation
- Synthesis: The evidence supports adding experimental 3-finger tap now and making 4-finger tap optional only after explicit conflict testing, because 3-finger tap already has strong upstream precedent while 4-finger taps collide more directly with Apple’s own gesture namespace and vary by macOS version. [4][5][6][13]
- Synthesis: Padium’s first shipping threshold should be conservative: require exact stable finger count, reject any sequence with meaningful motion, use a short single-tap window around 150–200 ms, and only consider a double-tap path if the first tap has already met the same low-motion rule. [3][6][8][9]
- Synthesis: If Padium offers experimental 4-finger tap at all, it should be opt-in, visibly labeled, and paired with a user warning that Mission Control / App Exposé / Show Desktop conflicts may require manual system setting changes. [4][10][13]

### Counter-Evidence
- Fact: Apple’s own system gesture documentation already uses 3-finger tap for Look up/data detectors and 2-finger double-tap for Smart zoom, so Padium cannot assume those gestures are free on a default-configured Mac. [4][10]
- Fact: The reverse-engineered trackpad analysis reports that 3-finger taps can span the full pad width and still count, which means a permissive finger-spacing rule would create conflicts if Padium used spacing as a proxy for intent. [3]
- Fact: Hammerspoon community evidence suggests tap recognition through event-tap or gesture-event paths can be flaky, which argues against relying on AppKit gesture events alone for Padium’s implementation. [13]

### Gaps
- No source found that publishes Apple’s exact 3-finger or 4-finger tap duration thresholds for macOS 14/15/26.
- No source found that publishes Apple’s exact double-tap interval for raw trackpad taps on macOS.
- No source found that proves 4-finger tap is a first-class, system-supported tap gesture on macOS; the available evidence is mostly about 3-finger tap and 4-finger swipes.
- No source found that quantifies false-positive rates for raw-frame tap detection on macOS trackpads.
- No source found that benchmarks OpenMultitouchSupport against AppKit gesture recognizers for tap reliability.
- The upstream evidence is strong enough to justify an experimental Padium implementation, but not strong enough to claim system-level parity with Apple’s own gesture stack.
- The evidence for 4-finger tap is indirect and mostly comes from adjacent 4-finger swipe conflicts plus production tools that let users choose 4 fingers manually.
- The most defensible start point for Padium is probably 3 fingers only, with 4 fingers gated behind an experimental preference and explicit system-gesture caveat.
- The best-supported thresholds are normalized or relative, not absolute hardware millimeters, so Padium will need its own calibration or scaling layer if it wants consistent behavior across trackpads.

### Practical Recommendation
- Recommendation: Ship 3-finger tap as an opt-in experimental feature first, with a conservative default like 150–200 ms max contact time, ~0.05 normalized travel, and exact finger-count stability from touch-down to lift. [1][3][6][8]
- Recommendation: Treat 3-finger double-tap as a separate mode with a longer inter-tap gap, and do not let the single-tap path fire until the first tap’s double-tap window has expired or the second tap is definitively absent. [8][9][11]
- Recommendation: Keep 4-finger tap off by default until the app has explicit telemetry or manual testing showing it does not collide with Mission Control, App Exposé, or Show Desktop on the target macOS versions. [4][10][13]
- Recommendation: Prefer raw frame recognition over AppKit gesture events, because the raw APIs expose stable identifiers, contact states, and release boundaries that are needed for robust arbitration. [1][2][13]
- Recommendation: Add an in-app warning that 3-finger tap may need system-gesture adjustments if “Look up & data detectors” or 3-finger drag is enabled. [4][10][13]

### Threshold Proposal
- Proposal: Accept a tap only when the same finger IDs remain present for the whole sequence and the contact ends without more than tiny movement. [1][2][3]
- Proposal: Start with 150–200 ms for single tap, 300 ms for double-tap acceptance, and ~0.05 normalized travel as the movement ceiling. [6][8]
- Proposal: Reject a candidate if finger count changes mid-sequence, unless future testing proves a controlled exception is worth the UX risk. [2][3][9]
- Proposal: Reject a candidate if any touch enters a swipe-like motion regime; do not try to “recover” a tap after deliberate movement begins. [3][5]
- Proposal: For 4-finger experiments, require an explicit opt-in and a separate threshold profile so its behavior cannot accidentally inherit the 3-finger defaults. [4][5][6]

### Confidence
**Level:** MEDIUM
**Rationale:** The evidence is strong that raw-touch tap detection is feasible and that conservative thresholds around 150–200 ms / 0.05 normalized travel are widely used in shipping apps, but Apple does not publish the underlying system thresholds and the 4-finger-tap question is only indirectly supported.

### Source Register
| ID | Source | Tier | Date | Why kept | URL |
|----|--------|------|------|----------|-----|
| [1] | KrishKrosh/OpenMultitouchSupport | 1 | 2025-07 | Primary raw touch API wrapper with explicit touch-state fields and stream semantics | https://github.com/krishkrosh/OpenMultitouchSupport |
| [2] | calftrail/TouchSynthesis/MultitouchSupport.h | 3 | 2010-01 | Canonical reverse-engineered header showing frame callback shape and touch struct fields | https://github.com/calftrail/Touch/blob/master/TouchSynthesis/MultitouchSupport.h |
| [3] | MacOS Touchpad Behavior Analysis | 3 | 2018-07 | Detailed reverse-engineering notes with concrete tap/gesture spacing and thumb rules | https://gist.github.com/mdmayfield/7720a0cd1e8b84a61e1543f801dc8245 |
| [4] | Use Multi-Touch gestures on Mac | 1 | 2026-02 | Current Apple system-gesture documentation, including 3-finger tap and 4-finger swipe conflicts | https://support.apple.com/en-us/102482 |
| [5] | MiddleDrag README | 3 | 2025-11 | Production example of raw-touch three-finger tap/drag plus system conflict handling | https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/main/README.md |
| [6] | artginzburg/MiddleClick | 3 | 2025-08 | Production example with explicit configurable tap thresholds and finger-count options | https://github.com/artginzburg/MiddleClick |
| [7] | meatpaste/mousetoucher | 3 | 2025-10 | Example of tap detection logic using MultitouchSupport-style raw data and thresholds | https://github.com/meatpaste/mousetoucher/blob/main/MultitouchManager.swift |
| [8] | MiddleClick PR #62 discussion | 3 | 2023-03 | Useful threshold discussion showing 150–200 ms and 0.05 normalized travel as practical tap bounds | https://github.com/artginzburg/MiddleClick/pull/62 |
| [9] | MiddleClick commit b08bc51 | 3 | 2025-02 | Concrete debounce logic for avoiding double-firing and natural/synthetic click collisions | https://github.com/artginzburg/MiddleClick/commit/b08bc511c818b85c0cf25a9c5a3c7e8e92d1c283 |
| [10] | Change Trackpad settings on Mac | 1 | 2026-02 | Apple’s configurable trackpad settings page, useful for conflict surface and user-disable guidance | https://support.apple.com/en-gb/guide/mac-help/mchlp1226/mac |
| [11] | UIGestureRecognizer | 1 | 2026-01 | Apple’s discrete-gesture semantics and cancellation model, relevant to single vs double-tap arbitration | https://developer.apple.com/documentation/uikit/uigesturerecognizer |
| [12] | Handling tap gestures | 1 | 2025-01 | Apple’s high-level tap rules: brief contact and minimal movement | https://developer.apple.com/documentation/uikit/handling-tap-gestures |
| [13] | Hammerspoon issue #2057 | 3 | 2019-03 | Community evidence that gesture-event path tap recognition is unreliable and raw touch APIs are preferred | https://github.com/Hammerspoon/hammerspoon/issues/2057 |

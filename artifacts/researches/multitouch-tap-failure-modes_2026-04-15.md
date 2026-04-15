## Findings: How to reliably detect 3-finger and 4-finger taps on macOS trackpad using raw MultitouchSupport/OpenMultitouchSupport touch frames

### Research Metadata
- Topic: How to reliably detect 3-finger and 4-finger taps on macOS trackpad using raw MultitouchSupport/OpenMultitouchSupport touch frames
- Lens: Practical debugging - why would tap detection completely fail to fire even though swipe detection works fine with the same touch source?
- Role: NONE
- Generated: 23.11_15-04-2026
- Coverage: PARTIAL

### Executive Synthesis
- Synthesis: The strongest evidence points to tap detection failing in practice when developers treat raw touch frames as if they were clean click lifecycles: MiddleClick’s maintainer explicitly found that a 500ms-only distance check let fingers rest arbitrarily long and still fire, while 0.4 normalized distance was loose enough to admit swipe-like motion, so the useful tap filter must combine both duration and travel constraints. [1][2]
- Synthesis: OpenMultitouchSupport exposes state transitions such as making, touching, breaking, lingering, and leaving, but the documentation does not define a single canonical tap lifecycle; production apps instead layer their own heuristics on top, which is why swipe detection can keep working while tap detection silently fails if candidate start/stop states, timeout logic, or lift detection are wrong. [3][4][5]
- Synthesis: The practical failure pattern is consistent across MiddleClick and MiddleDrag documentation: lingering/resting fingers, extra fingers, system-gesture conflicts, and stale permission / event-tap failures can all make an apparently valid tap never resolve into a click, even though the same raw source still emits swipe-capable motion frames. [1][2][6][7]

### Key Findings

#### Raw-frame tap failure modes
- Fact: MiddleClick’s tap logic originally allowed fingers to rest on the trackpad for an arbitrary amount of time because the time limit only gated distance, not total dwell time; the merged fix explicitly added a duration check to stop those false positives. [1]
- Fact: MiddleClick’s issue thread says a 0.4 normalized distance threshold is too permissive because it allows swipe motion to still count as a tap, while 0.05 worked better for distinguishing taps from swipes. [1]
- Fact: The same MiddleClick discussion says 500ms is “a lot” for a tap and that 150ms–200ms worked better in practice for tap detection. [1]
- Fact: MiddleClick’s README in 2026 ships with default tap thresholds of 0.05 max distance delta and 300ms max time delta, showing the project still kept a relatively permissive default duration even after the stricter community suggestions. [2]
- Fact: MiddleClick’s README notes that the user can configure 4, 5, or even 10 fingers for the click gesture, but warns that using 2 fingers conflicts with normal two-finger right-click and single-finger clicks. [2]
- Fact: MiddleClick issue #161 reports a real-world false positive pattern where an accidental resting thumb and finger on the trackpad causes a middle click, showing that lingering contact is not just a theoretical problem. [8]
- Fact: MiddleClick issue #162 reports a false-negative-style reliability failure after app updates: macOS can silently invalidate Accessibility permission so `AXIsProcessTrusted()` still returns true while the event tap actually fails, making the app appear nonfunctional. [7]
- Fact: MiddleDrag’s README says “soft taps” are preferred because pressing down hard may still trigger Mission Control, which is a concrete example of gesture coexistence causing tap recognition to be disrupted by system gesture behavior. [6]
- Fact: MiddleDrag documents a `Require Exactly 3 Fingers` option whose stated purpose is to ignore 4+ finger touches, which is a direct mitigation for accidental extra contacts that would otherwise confuse a 3-finger tap detector. [6]

#### Touch-state semantics
- Fact: OpenMultitouchSupport’s published state enum includes `notTouching`, `starting`, `hovering`, `making`, `touching`, `breaking`, `lingering`, and `leaving`. [3]
- Fact: OpenMultitouchSupport’s README exposes raw touch data as `OMSTouchData` with per-touch id, position, pressure, axis, angle, density, state, and timestamp, but it does not prescribe any tap-recognition algorithm. [3]
- Fact: The library README says it is meant to “access raw data of the multitouch trackpad,” which means tap detection remains an application-level decision, not a framework-provided click event. [3]
- Fact: The current README excerpt does not define whether `making` or `touching` should be treated as the first tap-candidate state, nor whether `breaking` or `lingering` should be counted as a definitive finger-down state. [3]
- Fact: Because the framework documentation only lists states, production code must infer when a finger is “down,” when a tap candidate starts, and when a touch has truly ended. [3]

#### Production-app tap heuristics
- Fact: MiddleClick’s 2023 tap fix changed the implementation so the finger count and motion were evaluated together with duration, instead of only looking at motion distance after the fact. [1]
- Fact: MiddleClick’s discussion says the gesture should count as a tap only when the max travel between touch and release stays under the configured normalized threshold. [1][2]
- Fact: MiddleClick’s README defines max distance delta as the maximum cursor travel between touch and release for a tap to be valid, and it explicitly states the position is normalized from 0 to 1. [2]
- Fact: MiddleClick’s README defines max time delta as the maximum interval in milliseconds between touch and release for a tap to be valid. [2]
- Fact: MiddleDrag’s README keeps tap behavior intentionally simple: a three-finger tap becomes middle click, while a three-finger drag becomes middle drag, implying separate arbitration between a short tap and a motion-bearing gesture. [6]
- Fact: MiddleDrag’s settings expose drag sensitivity separately from tap recognition, which suggests the app treats tap/drag separation as a distinct state machine problem rather than a single threshold. [6]

#### Threshold practice: maximumTravel and duration
- Fact: MiddleClick issue #62 says 0.4 normalized distance was too high because it allowed swipes to register as taps. [1]
- Fact: MiddleClick issue #62 says 0.05 normalized distance worked better for taps than 0.4. [1]
- Fact: MiddleClick issue #62 says 150ms–200ms was a better tap-duration range than 500ms. [1]
- Fact: MiddleClick’s README adopted 0.05 as the default max distance delta, matching the community’s “better for just taps” recommendation. [2]
- Fact: MiddleClick’s README still kept 300ms as the default max time delta, which is looser than the 150ms–200ms values preferred in the issue discussion. [1][2]
- Fact: MiddleClick’s own docs therefore show a split: travel threshold moved very strict, but duration remained comparatively permissive. [1][2]
- Fact: The source set does not contain a canonical Apple or framework-authoritative recommended value for 0.05 normalized distance or 200ms duration. [1][2][3]

#### Empty-frame / lift behavior
- Fact: OpenMultitouchSupport’s public README does not state that an empty `[]` frame reliably means all fingers are lifted. [3]
- Fact: The README also does not document any guarantee that lingering or leaving states must be followed immediately by an empty frame. [3]
- Fact: Because the library only exposes states and timestamps, a tap detector cannot assume that the absence of touches is always represented by an empty frame in the published docs. [3]
- Fact: The available evidence in this source set does not confirm the edge-case behavior of lingering or leaving without an empty frame. [3]

### Counter-Evidence
- Fact: MiddleClick’s issue #162 shows that even when the touch heuristics are correct, the app can still appear broken because macOS may report Accessibility as trusted while the event tap itself is stale; that means a tap detector can fail for reasons unrelated to finger-state logic. [7]
- Fact: MiddleDrag’s troubleshooting says app updates may require re-granting Accessibility permission, and it advises toggling the app off/on and restarting after updates. [6]

### Gaps
- The fetched OpenMultitouchSupport docs do not explain which states should begin a tap candidate or which states should count as an authoritative finger-down signal.
- The fetched sources do not prove whether `[]` is a guaranteed all-fingers-up marker versus just one representation of a no-touch frame.
- No primary-source documentation was found for BetterTouchTool’s raw-frame tap heuristics; only indirect references appeared.
- No direct source was found that defines an Apple-recommended 200ms threshold for raw MultitouchSupport tap detection.
- No direct source was found that resolves whether `making` or `touching` should be the first state used to start a tap candidate in a robust detector.

### Confidence
**Level:** MEDIUM
**Rationale:** The report is grounded in official repository READMEs and issue/PR discussions from the relevant production apps, but the core framework semantics for state transitions and empty-frame guarantees were not documented in the fetched primary source, so some operational conclusions remain bounded by indirect evidence.

### Source Register
| ID | Source | Tier | Date | Why kept | URL |
|----|--------|------|------|----------|-----|
| [1] | artginzburg/MiddleClick PR #62 Improve the detection of taps | 3 | 2023-03 | Direct discussion of failing tap heuristics, including distance and duration thresholds, from a production tap app maintainer thread. | https://github.com/artginzburg/MiddleClick/pull/62 |
| [2] | artginzburg/MiddleClick README | 1 | 2026-04 | Official app documentation with current default thresholds and finger-count behavior. | https://github.com/artginzburg/MiddleClick |
| [3] | Kyome22/OpenMultitouchSupport README | 1 | 2025-01 | Official wrapper documentation exposing raw touch states and fields. | https://github.com/Kyome22/OpenMultitouchSupport |
| [4] | KrishKrosh/OpenMultitouchSupport repository page | 1 | 2025-07 | Current fork confirms the same state set (`notTouching` through `leaving`) and modern packaging details. | https://github.com/krishkrosh/OpenMultitouchSupport |
| [5] | MiddleDrag repository page | 3 | 2025-11 | Production app README shows separate tap vs drag handling and practical coexistence guidance. | https://github.com/NullPointerDepressiveDisorder/MiddleDrag |
| [6] | MiddleDrag README | 3 | 2025-11 | Detailed feature/troubleshooting text about three-finger tap, drag, soft taps, and exactly-3-finger filtering. | https://github.com/NullPointerDepressiveDisorder/MiddleDrag/blob/main/README.md |
| [7] | artginzburg/MiddleClick issue #162 | 3 | 2026-03 | Real-world failure mode where permissions appear valid but event taps fail. | https://github.com/artginzburg/MiddleClick/issues/162 |
| [8] | artginzburg/MiddleClick issue list | 3 | 2026-03 | Confirms an active false-positive report: accidental resting thumb/finger causing middle click. | https://github.com/artginzburg/MiddleClick/issues |

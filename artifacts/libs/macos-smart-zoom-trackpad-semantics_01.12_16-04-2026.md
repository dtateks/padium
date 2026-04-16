## Findings: macOS Smart Zoom trackpad semantics

### Research Metadata
- Question: What exact macOS trackpad preference key/value controls the built-in Smart Zoom gesture (two-finger double-tap), and how apps/tools detect or disable it
- Type: MIXED
- Target: macOS Trackpad preferences and gesture detection behavior
- Version Scope: Apple Support pages published 2026-02-24; community defaults mappings and nix-darwin module as of 2026-04-16; no single Apple public doc found that names the defaults key directly
- Generated: 01.12_16-04-2026
- Coverage: COMPLETE for the preference key/value; PARTIAL for native app detection internals

### Direct Answer
- Fact: The built-in Smart Zoom trackpad gesture is controlled by `com.apple.AppleMultitouchTrackpad` key `TrackpadTwoFingerDoubleTapGesture`, where `1` enables Smart Zoom and `0` disables it [1][2][3].
- Fact: Apple’s public support docs describe Smart Zoom as “Double-tap with two fingers,” but do not name the underlying defaults key [1].
- Fact: App/tool-level detection is usually indirect: utilities read/write the Trackpad preferences domain, while app code observes the resulting gesture behavior rather than a special “smart zoom” event type in the public docs [2][3].

### Key Findings
#### Smart Zoom preference key/value

**Claim**: The concrete preference knob for trackpad Smart Zoom is `TrackpadTwoFingerDoubleTapGesture` in `com.apple.AppleMultitouchTrackpad`; the enabled value is `1` and the disabled value is `0` [2][3].

**Evidence** ([article section “Smart zoom / Double-tap with two fingers”](https://zenn.dev/usagimaru/articles/a524d547233f94?locale=en#smart-zoom-%2F-double-tap-with-two-fingers) [2]):
```text
## Smart zoom / Double-tap with two fingers

-   TrackpadTwoFingerDoubleTapGesture = 1
```

**Evidence** ([trackpad.nix#L168-L176](https://github.com/LnL7/nix-darwin/blob/master/modules/system/defaults/trackpad.nix#L168-L176) [3]):
```nix
system.defaults.trackpad.TrackpadTwoFingerDoubleTapGesture = mkOption {
  type = types.nullOr types.bool; default = null;
  description = ''
    Whether to enable smart zoom when double-tapping with two fingers.

    The default is false.
  '';
};
```

**Explanation**: The Zenn mapping gives the exact key/value pair observed in Trackpad defaults, and nix-darwin confirms the semantic meaning: a boolean toggle for Smart Zoom. Together, they support the implementation choice to treat `1` as enabled and `0` as disabled.

#### Apple-facing contract for the gesture

**Claim**: Apple documents Smart Zoom as a two-finger double-tap gesture on trackpads, and says users can turn gestures off in Trackpad settings, but does not expose the plist key name in the support page [1].

**Evidence** ([Apple Support: Use Multi-Touch gestures on Mac](https://support.apple.com/en-us/102482) [1]):
```text
**Smart zoom**

Double-tap with two fingers to zoom in and back out of a webpage or PDF.
```

**Evidence** ([same page](https://support.apple.com/en-us/102482) [1]):
```text
For more information about these gestures, choose System Settings (or System Preferences) from the Apple menu , then click Trackpad. There you can turn a gesture off, change the type of gesture, and learn which gestures work with your Mac.
```

**Explanation**: Apple confirms the gesture semantics and that it is user-toggleable in Trackpad settings, but the support page stops short of documenting the defaults domain/key pair.

#### How tools typically detect or disable it

**Claim**: The practical way to detect or disable Smart Zoom in tooling is to inspect or mutate the Trackpad preference domain for `TrackpadTwoFingerDoubleTapGesture`, usually via `defaults` or preference APIs; community references consistently group it under `com.apple.AppleMultitouchTrackpad` [2][3].

**Evidence** ([article section “Basic defaults”](https://zenn.dev/usagimaru/articles/a524d547233f94?locale=en#basic-defaults) [2]):
```text
# Trackpad settings file 1
defaults read com.apple.AppleMultitouchTrackpad
```

**Evidence** ([trackpad.nix#L168-L176](https://github.com/LnL7/nix-darwin/blob/master/modules/system/defaults/trackpad.nix#L168-L176) [3]):
```nix
system.defaults.trackpad.TrackpadTwoFingerDoubleTapGesture = mkOption {
  type = types.nullOr types.bool; default = null;
  description = ''
    Whether to enable smart zoom when double-tapping with two fingers.

    The default is false.
  '';
};
```

**Explanation**: These sources support a tooling strategy of reading/writing the preference value rather than trying to detect a separate low-level “smart zoom” event. The public Apple docs define the user-visible gesture; the defaults mapping exposes the machine-visible control.

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | Apple Support Smart Zoom entry | Defines the gesture as a two-finger double-tap and says it is configurable in Trackpad settings. | [1] |
| 2 | `com.apple.AppleMultitouchTrackpad` defaults domain | Community defaults inventories show the Trackpad preferences live in this domain. | [2] |
| 3 | `TrackpadTwoFingerDoubleTapGesture` | Concrete Smart Zoom toggle mapped as a boolean-style preference; `1` enables the gesture. | [2][3] |

### Caveats and Gaps
- Apple’s public support docs do not name the plist key, so the exact key/value comes from community defaults inventories and config modules rather than Apple-authored contract text [1][2][3].
- I did not find a public Apple document describing an event-type API that reports “Smart Zoom” as a distinct low-level gesture; the evidence here supports preference-based detection/disablement only [1][2][3].

### Confidence
**Level:** HIGH
**Rationale:** The key/value mapping is consistent across multiple independent sources, including a defaults inventory and a typed config module; Apple’s docs corroborate the user-visible gesture semantics.

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | docs | Apple Support: Use Multi-Touch gestures on Mac | Published 2026-02-24 | Authoritative gesture semantics and user-facing toggle description | [support.apple.com/en-us/102482](https://support.apple.com/en-us/102482) |
| [2] | secondary | Zenn article: macOS Trackpad Settings and Values | Published 2023-01-18; fetched 2026-04-16 | Concrete Trackpad defaults mapping, including Smart Zoom key/value | [zenn.dev/usagimaru/articles/a524d547233f94](https://zenn.dev/usagimaru/articles/a524d547233f94?locale=en) |
| [3] | code | nix-darwin `modules/system/defaults/trackpad.nix` | master as fetched 2026-04-16 | Typed declaration confirming Smart Zoom key semantics in a real configuration module | [github.com/LnL7/nix-darwin/blob/master/modules/system/defaults/trackpad.nix](https://github.com/LnL7/nix-darwin/blob/master/modules/system/defaults/trackpad.nix#L168-L176) |

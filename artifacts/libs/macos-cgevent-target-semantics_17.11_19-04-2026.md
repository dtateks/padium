## Findings: CoreGraphics CGEvent target semantics for synthetic keyboard events on macOS

### Direct Answer
- Fact: `CGEvent.post(tap:)` posts a Quartz event into the event stream at the specified tap location, and Apple’s contract says the event is inserted immediately before any taps at that location and then passes through those taps; it does **not** name a target process itself, so delivery still follows the normal event-stream routing for that location rather than an app-specific destination [1].
- Fact: Apple’s documented app-specific routing API is `postToPSN(processSerialNumber:)`, whose discussion explicitly says it posts a Quartz event “for a specific application” and exists so an app can tap at `kCGAnnotatedSessionEventTap` and repost to another desired process; `postToPid(_:)` exists as a modern API surface on `CGEvent`, but the retrieved Apple docs snippet exposes only the signature, not an equivalent discussion block [2][3].
- Fact: Apple’s available primary evidence here does **not** establish that `postToPid(_:)` reliably delivers synthetic keyboard shortcuts to a background or non-focused target app. The strongest Apple-adjacent evidence in this set is a DTS-threaded case where global `CGEvent` posting started working only after Accessibility/TCC issues were fixed, while the same developer separately reported that `CGEventPostToPid` “doesn't seem to work” for avoiding focus switching [4].
- Fact: For a menu bar / accessory app sending keys **inside its own process**, Apple Developer Forums guidance points away from CoreGraphics injection and toward AppKit event delivery: `NSApplication.sendEvent(_:)`, with a follow-up that `NSApplication.postEvent(_:atStart:)` is generally preferable [5].
- Synthesis: For a Swift menu bar/accessory app like Padium, the upstream evidence supports two distinct semantics: use `CGEvent.post(tap:)` when you want to inject into the system event stream subject to TCC and normal focus routing, and use in-process AppKit event posting when the target is your own app window/view. The evidence gathered here does **not** justify treating `postToPid(_:)` as a dependable “send shortcut to arbitrary background app” primitive [1][2][4][5].

### Key Findings
#### `post(tap:)` targets a stream location, not a process

**Claim**: Apple defines `post(tap:)` as insertion into the Quartz event stream at a chosen `CGEventTapLocation`, not as direct delivery to a chosen application [1].

**Evidence** ([`CGEvent.post(tap:)` docs](https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:)) [1]):
```text
# post(tap:)

Posts a Quartz event into the event stream at a specified location.

func post(tap: CGEventTapLocation)

## Parameters

tap The location at which to post the event. Pass one of the constants listed in CGEventTapLocation.

## Discussion
This function posts the specified event immediately before any event taps instantiated for that location, and the event passes through any such taps.
```

**Explanation**: Apple’s wording is about stream placement. The API chooses a tap location like HID, session, or annotated session; it does not take a PID or otherwise promise app-specific targeting.

- Trace: The related `CGEventTapLocation` docs define the locations as system ingress points, with `cghidEventTap` at HID entry, `cgSessionEventTap` at login-session entry, and `cgAnnotatedSessionEventTap` where events have been annotated to flow to an application [3].

#### Tap locations describe routing stage boundaries

**Claim**: Apple documents `cgAnnotatedSessionEventTap` as the point where session events have already been annotated for application delivery, which is the load-bearing distinction for understanding when app-specific rerouting is possible [3].

**Evidence** ([`CGEventTapLocation` docs](https://developer.apple.com/documentation/coregraphics/cgeventtaplocation) [3]):
```text
CGEventTapLocation.cghidEventTap
Specifies that an event tap is placed at the point where HID system events enter the window server.

CGEventTapLocation.cgSessionEventTap
Specifies that an event tap is placed at the point where HID system and remote control events enter a login session.

CGEventTapLocation.cgAnnotatedSessionEventTap
Specifies that an event tap is placed at the point where session events have been annotated to flow to an application.
```

**Explanation**: This is the closest Apple contract text to “target semantics.” `cghidEventTap` and `cgSessionEventTap` are pre-delivery stream stages; `cgAnnotatedSessionEventTap` is later, after the system has annotated the event for app delivery.

#### Apple’s explicit per-application routing discussion is on `postToPSN`, not `post(tap:)`

**Claim**: Apple’s only explicit routing-policy discussion in the retrieved docs is on `postToPSN(processSerialNumber:)`, which says the API posts to a specific application and gives the concrete example of tapping annotated-session events and reposting to another process [2].

**Evidence** ([`CGEvent.postToPSN(processSerialNumber:)` docs](https://developer.apple.com/documentation/coregraphics/cgevent/posttopsn(processserialnumber:)?changes=_5__4) [2]):
```text
# postToPSN(processSerialNumber:)

Posts a Quartz event into the event stream for a specific application.

func postToPSN(processSerialNumber: UnsafeMutableRawPointer?)

## Parameters

processSerialNumber The process to receive the event.

## Discussion
This function makes it possible for an application to establish an event routing policy, for example, by tapping events at the kCGAnnotatedSessionEventTap location and then posting the events to another desired process.
This function posts the specified event immediately before any event taps instantiated for the specified process, and the event passes through any such taps.
```

**Explanation**: Apple explicitly ties per-app routing to `postToPSN`, not to `post(tap:)`. The example matters because it shows the intended conceptual model: observe at the annotated-session stage, then reroute to another process.

- Caveat: Apple’s current `postToPid(_:)` page snippet retrieved here exposes only the signature, so this artifact cannot claim Apple published the same discussion text for PID-based routing without additional primary evidence [6].

#### `postToPid(_:)` is present, but the retrieved Apple docs do not describe its delivery guarantees

**Claim**: The Apple documentation retrieved for `postToPid(_:)` confirms the API exists, but the captured public snippet includes only the function signature and no discussion about focus, background delivery, or keyboard-shortcut guarantees [6].

**Evidence** ([`CGEvent.postToPid(_:)` docs](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:/)) [6]):
```text
# postToPid(_:)

func postToPid(_ pid: pid_t)
```

**Explanation**: That is enough to prove the API surface exists, but not enough to prove semantics beyond “there is a PID-taking variant.” Any stronger claim about keyboard routing behavior would exceed the available source support.

#### Apple’s general event model still centers foreground/app-delivery flow

**Claim**: Apple’s `CGEvent` overview describes Quartz events as entering the window server, being annotated, and then being dispatched to the target process’s run-loop port, which reinforces that normal event posting participates in a system-managed delivery pipeline rather than direct method-like invocation of another app [7].

**Evidence** ([`CGEvent` overview](https://developer.apple.com/documentation/coregraphics/cgevent) [7]):
```text
A typical event in macOS originates when the user manipulates an input device such as a mouse or a keyboard.
The device driver associated with that device, through the I/O Kit, creates a low-level event, puts it in the window server’s event queue, and notifies the window server.
The window server creates a Quartz event, annotates the event, and dispatches the event to the appropriate run-loop port of the target process.
```

**Explanation**: This is Apple’s architectural backdrop for the target question. It supports “system stream then target-process dispatch,” which is consistent with `post(tap:)` being stream insertion and with per-process rerouting being a separate API concern.

#### Apple forum guidance for own-app delivery uses AppKit, not CGEvent posting

**Claim**: When the target is your own macOS app, Apple Developer Forums guidance recommends creating an `NSEvent` and using `NSApplication.sendEvent(_:)`, with a follow-up recommendation that `NSApplication.postEvent(_:atStart:)` is preferable in general [5].

**Evidence** ([Apple Developer Forums thread 739637](https://developer.apple.com/forums/thread/739637) [5]):
```text
You could create an NSEvent and use the sendEvent method of NSApplication.

Afterthought: although -[NSApplication sendEvent:] seems to work OK for simulating keyboard events, it's probably preferable in general to use -[NSApplication postEvent:atStart:]. The latter works better for mouse events.
```

**Explanation**: For menu bar/accessory apps, this is the strongest Apple-adjacent answer when the event is intended for the app itself. It avoids accessibility-style global synthesis and uses the app’s own event queue.

#### Accessibility/TCC governs CGEvent posting, and background retargeting remains unsupported by the gathered evidence

**Claim**: Apple DTS states that posting with `CGEvent` requires user approval in Privacy & Security and points to `CGPreflightPostEventAccess` / `CGRequestPostEventAccess`; in the same Apple forums evidence set, a developer who fixed posting permissions still reported that `CGEventPostToPid` did not solve sending keys without switching focus [4].

**Evidence** ([Apple Developer Forums thread 724603](https://developer.apple.com/forums/thread/724603) [4]):
```text
Posting events with CGEvent does not require any specific entitlements. It does, however, require user approval in System Settings > Privacy & Security.
CG has two APIs that can help here:

- CGPreflightPostEventAccess
- CGRequestPostEventAccess

...

Please note that I've opened a new post regarding sending events without switching focus to avoid the flashing using CGEventPostToPid, which doesn't seem to work.
```

**Explanation**: The DTS answer is authoritative for the TCC requirement. The follow-on user report is not a platform contract, but it is still relevant negative evidence: within the gathered Apple-forums material, there is no confirmed success story establishing `postToPid` as a reliable background-shortcut delivery mechanism.

#### Sandbox and privilege context still limit synthetic event generation

**Claim**: Apple DTS explicitly said in 2015 that App Sandbox could not allow `CGEventPost` because that would let the app defeat sandbox restrictions; a later DTS note says sandboxed apps gained Input Monitoring access for `CGEventTap` from macOS 10.15, but event generation was not confirmed there [8].

**Evidence** ([Apple Developer Forums thread 28605](https://developer.apple.com/forums/thread/28605) [8]):
```text
So I was wondering - is there a way to do this inside the sandbox?

No.

...

There’s no point filing an enhancement request for access to
CGEventPost
because such access would allow your app to defeat the sandbox entirely.

...

Starting with 10.15 a sandboxed app can use APIs like CGEventTap to monitor input events as long as the user approves that in Security > Security & Privacy > Privacy > Input Monitoring.

I think the same logic applies to event generation but I haven’t actually researched that privilege in detail.
```

**Explanation**: This is historical but material context. It supports caution about assuming sandbox/menu-bar accessory apps have broad synthetic-event targeting powers, especially for cross-app delivery.

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `CGEvent` overview | Hardware event enters window server, becomes Quartz event, gets annotated, then dispatched to target process | [7] |
| 2 | `CGEvent.post(tap:)` | Synthetic event is inserted into the event stream at a chosen tap location and passes through taps there | [1] |
| 3 | `CGEventTapLocation` | Tap location determines whether insertion is at HID ingress, session ingress, or annotated-for-app-delivery stage | [3] |
| 4 | `CGEvent.postToPSN(processSerialNumber:)` | Apple-documented per-application rerouting path; can repost annotated-session events to another desired process | [2] |
| 5 | `CGEvent.postToPid(_:)` | PID-targeted API exists, but retrieved Apple snippet gives no discussion of guarantees | [6] |
| 6 | `NSApplication.sendEvent` / `postEvent` | For own-app synthetic input, forum guidance uses AppKit queueing instead of CoreGraphics injection | [5] |

### Change Context
- History: Apple DTS said in 2015 that sandboxed apps could not use `CGEventPost` as an allowed sandbox capability because it would defeat sandbox isolation [8].
- History: By 2022, Apple DTS said sandboxed apps could obtain Input Monitoring for `CGEventTap` on macOS 10.15+, but explicitly did **not** confirm equivalent researched behavior for event generation [8].

### Caveats and Gaps
- Apple’s JavaScript-gated docs made `webfetch` incomplete for some pages; this artifact uses Apple documentation excerpts surfaced by Apple search/result pages where the text was visible, plus full Apple Developer Forums pages.
- I did not retrieve an Apple-primary discussion block for `postToPid(_:)`; only the existence/signature is confirmed from the available docs snippet [6].
- I did not find Apple-primary evidence in this pass proving that `postToPid(_:)` can or cannot deliver keyboard shortcuts to a background app in all cases. The evidence here supports caution, not a universal impossibility claim.
- I found no Apple-primary source in this pass specifically addressing `LSUIElement` menu bar apps. The menu-bar/accessory relevance here is inferred from the in-process AppKit guidance and the same TCC/sandbox rules applying to app bundles generally.

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | docs | Apple docs: `CGEvent.post(tap:)` | Apple docs as indexed 2026-04-19 | Primary contract text for stream-post semantics | https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:) |
| [2] | docs | Apple docs: `CGEvent.postToPSN(processSerialNumber:)` | Apple docs as indexed 2026-04-19 | Primary contract text for specific-application routing semantics | https://developer.apple.com/documentation/coregraphics/cgevent/posttopsn(processserialnumber:)?changes=_5__4 |
| [3] | docs | Apple docs: `CGEventTapLocation` | Apple docs as indexed 2026-04-19 | Primary definitions of HID/session/annotated-session tap stages | https://developer.apple.com/documentation/coregraphics/cgeventtaplocation |
| [4] | forum | Apple Developer Forums thread 724603 | Feb 2023 | DTS guidance for TCC requirements and relevant forum evidence about `CGEventPostToPid` not solving background delivery in one real case | https://developer.apple.com/forums/thread/724603 |
| [5] | forum | Apple Developer Forums thread 739637 | Oct 2023 / Jan 2024 follow-up | Apple-forums guidance for in-process synthetic input using AppKit instead of CoreGraphics posting | https://developer.apple.com/forums/thread/739637 |
| [6] | docs | Apple docs: `CGEvent.postToPid(_:)` | Apple docs as indexed 2026-04-19 | Confirms API existence but not detailed semantics in retrieved snippet | https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:/) |
| [7] | docs | Apple docs: `CGEvent` overview | Apple docs as indexed 2026-04-19 | Primary architectural description of event creation, annotation, and dispatch to target process | https://developer.apple.com/documentation/coregraphics/cgevent |
| [8] | forum | Apple Developer Forums thread 28605 | Dec 2015, May 2022 update | Historical sandbox and privilege context from Apple DTS | https://developer.apple.com/forums/thread/28605 |

## Findings: KeyboardShortcuts 2.4.0 / shortcut interception behavior

### Research Metadata
- Question: Does `KeyboardShortcuts.Recorder` or stored shortcuts intercept physical keyboard shortcuts, when does the library register/consume hotkeys, can assigning a shortcut stop the original key from reaching other apps/system, and how should shortcuts be stored for later synthetic emission without handlers?
- Type: MIXED
- Target: sindresorhus/KeyboardShortcuts 2.4.0
- Version Scope: Upstream repository docs/code as indexed from `main`; behavior is the library’s implementation that ships in 2.4.0 unless changed later.
- Generated: 18.41_15-04-2026
- Coverage: COMPLETE

### Direct Answer
- Fact: `KeyboardShortcuts.Recorder` is a storage/configuration UI; it does not itself register a keyboard-hotkey listener. Actual event registration happens only when a shortcut has active handlers such as `onKeyDown`, `onKeyUp`, or the stream APIs. [1][2][3]
- Fact: Stored shortcuts are persisted in `UserDefaults` under `KeyboardShortcuts_<name>` and can be read later with `getShortcut(for:)` or `Name.shortcut`; storage alone does not imply any global hook is active. [2][4][5]
- Fact: The library registers OS-level hotkeys via Carbon `RegisterEventHotKey` only after a shortcut has active handlers, and it unregisters them when no active handlers remain or the shortcut is disabled. [2][6][7]
- Fact: By design, `KeyboardShortcuts` is a global keyboard-shortcut library; once you register a handler for a shortcut, that shortcut is captured by the library’s hotkey machinery rather than being left purely as inert stored data. The documentation and code do not show any separate “store-only” path beyond reading/writing the shortcut value. [1][2][4][5]
- Synthesis: For later synthetic emission, the recommended pattern is to persist the shortcut with `Recorder`/`Name.shortcut` and later retrieve it with `KeyboardShortcuts.getShortcut(for:)` or `KeyboardShortcuts.Shortcut(name:)`; do not add `onKeyUp`/`onKeyDown`/stream handlers if you only want storage, because those handlers are what cause registration. [1][2][4][5]

### Key Findings
#### 1) Recorder and stored values are storage/UI, not the trigger path

**Claim**: The recorder is presented as a UI for selecting a shortcut; the library docs pair it with storage and later retrieval, not with automatic event interception. [1][4][5]

**Evidence** ([readme.md](https://github.com/sindresorhus/keyboardshortcuts/blob/main/readme.md) [1]):
```swift
KeyboardShortcuts.Recorder("Toggle Unicorn Mode:", name: .toggleUnicornMode)

KeyboardShortcuts.onKeyUp(for: .toggleUnicornMode) { [self] in
		isUnicornMode.toggle()
}
```

**Explanation**: The recorder example only declares the settings UI. The separate `onKeyUp` example is where behavior is attached, showing that storage and handling are distinct steps. The docs also say a `Name` becomes usable in the recorder and in `onKeyUp()` only after registration. [1][4]

#### 2) What actually registers global hotkeys

**Claim**: `onKeyUp(for:)` registers the shortcut lazily only when there is an active handler; the registration path fetches the stored shortcut and calls `registerIfNeeded(for:)`. [2][6][7]

**Evidence** ([KeyboardShortcuts.swift#L561-L577](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L561-L577) [2]):
```swift
public static func onKeyUp(for name: Name, action: @escaping () -> Void) {
	keyUpHandlers[name, default: []].append(action)
	registerIfNeeded(for: name)
}

nonisolated private static let userDefaultsPrefix = "KeyboardShortcuts_"
```

**Explanation**: Adding a handler appends it to the handler table, then attempts registration. Merely having a stored shortcut does not execute this code path. [2]

**Claim**: Registration itself is Carbon-based `RegisterEventHotKey`, and the library installs hot-key and raw-key event types only in the hotkey implementation. [6]

**Evidence** ([HotKey.swift#L94-L110](https://github.com/sindresorhus/keyboardshortcuts/blob/main/Sources/KeyboardShortcuts/HotKey.swift#L94-L110) [6]):
```swift
private let hotKeyEventTypes = [
	EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
	EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
]

private let rawKeyEventTypes = [
	EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventRawKeyDown)),
```

**Explanation**: The library’s event plumbing is tied to Carbon keyboard/hotkey events. This is the mechanism used when shortcuts are actively registered. [6]

#### 3) When the library consumes or releases the shortcut

**Claim**: The hotkey handler returns `noErr` for recognized hotkey/raw-key events, which means the library handles those events internally rather than passing them through untouched. [6]

**Evidence** ([HotKey.swift#L352-L360](https://github.com/sindresorhus/keyboardshortcuts/blob/main/Sources/KeyboardShortcuts/HotKey.swift#L352-L360) [6]):
```swift
guard let event else {
	return OSStatus(eventNotHandledErr)
}

switch Int(GetEventKind(event)) {
case kEventHotKeyPressed, kEventHotKeyReleased:
	return handleHotKeyEvent(event)
case kEventRawKeyDown, kEventRawKeyUp:
	return handleRawKeyEvent(event)
```

**Explanation**: Once the library has registered a hotkey, matching keyboard events are processed by its handler path. This is the relevant upstream behavior for “swallowed” shortcuts: registration introduces a global hotkey consumer path. [6][7]

#### 4) Does assigning a shortcut in-app stop the original shortcut from reaching other apps/system?

**Claim**: The upstream code shows that assigning a shortcut only persists it; the shortcut becomes system-intercepting only when the app registers a handler for that shortcut. The source does not show a store-only assignment path that would independently seize the key. [2][4][5][6][7]

**Evidence** ([Name.swift#L81-L89](https://github.com/sindresorhus/keyboardshortcuts/blob/main/Sources/KeyboardShortcuts/Name.swift#L81-L89) [4]):
```swift
@MainActor
public var shortcut: Shortcut? {
	get {
		KeyboardShortcuts.getShortcut(for: self)
	}
	nonmutating set {
		KeyboardShortcuts.setShortcut(newValue, for: self)
	}
}
```

**Explanation**: Setting `Name.shortcut` only routes to storage. The registration path is elsewhere and depends on active handlers. So the assignment itself is not the evidence of interception; handler registration is. [2][4][7]

#### 5) Recommended store-only pattern for later synthetic emission

**Claim**: For storage-only use, persist the shortcut with `Recorder`/`Name.shortcut`, then read it back with `KeyboardShortcuts.getShortcut(for:)` or `Shortcut(name:)` when you need to synthesize an emission. [1][4][5]

**Evidence** ([KeyboardShortcuts.swift#L465-L472](https://github.com/sindresorhus/keyboardshortcuts/blob/main/Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L465-L472) [5]):
```swift
public static func getShortcut(for name: Name) -> Shortcut? {
	if case .shortcut(let shortcut) = storedShortcut(for: name) {
		return shortcut
	}

	return nil
}
```

**Evidence** ([Shortcut.swift#L69-L77](https://github.com/sindresorhus/keyboardshortcuts/blob/main/Sources/KeyboardShortcuts/Shortcut.swift#L69-L77) [3]):
```swift
@MainActor
public init?(name: Name) {
	guard let shortcut = getShortcut(for: name) else {
		return nil
	}

	self = shortcut
}
```

**Explanation**: These APIs retrieve stored data without adding a handler. That is the store-only path you want if the goal is later synthetic emission rather than live shortcut listening. [3][5]

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `KeyboardShortcuts.Recorder` | Presents recording UI and writes user choice to storage | [1][4] |
| 2 | `Name.shortcut` / `setShortcut(for:)` | Persists or retrieves the assigned shortcut in `UserDefaults` | [2][4][5] |
| 3 | `onKeyUp(for:)` / `onKeyDown(for:)` / stream APIs | Adds active handler and triggers lazy registration | [2][7] |
| 4 | `registerIfNeeded(for:)` → `HotKey.register` | Creates Carbon hotkey registration when a shortcut has an active handler | [2][6][7] |
| 5 | `handleHotKeyEvent` / `handleRawKeyEvent` | Recognized keyboard events are consumed by the library’s hotkey machinery | [6] |

### Caveats and Gaps
- The upstream docs/code clearly show storage vs. handler registration, but they do not explicitly state in prose that “the original physical shortcut will not reach other apps” in all cases; that conclusion follows from the Carbon hotkey registration path and should be treated as behavior of registered shortcuts, not of storage alone. [2][6][7]
- This research used the public upstream repository as indexed for 2.4.0 behavior; if your local dependency is patched or vendored, verify the exact tag/commit before relying on this answer. [1][2]

### Confidence
**Level:** HIGH
**Rationale:** The key claims are directly supported by the README and by the library’s own storage/registration code paths; the only caveat is that the docs do not spell out the system-level “swallow” effect in a single sentence, so that part is inferred from the hotkey registration mechanism rather than quoted verbatim. [1][2][6]

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | docs | README examples for recorder and key-up handling | main / public upstream docs | Shows recorder is for UI/storage and handlers are separate | https://github.com/sindresorhus/keyboardshortcuts/blob/main/readme.md |
| [2] | code | `Sources/KeyboardShortcuts/KeyboardShortcuts.swift` | main / registration and storage APIs | Governs handler-triggered lazy registration and UserDefaults storage | https://github.com/sindresorhus/keyboardshortcuts/blob/main/Sources/KeyboardShortcuts/KeyboardShortcuts.swift |
| [3] | code | `Sources/KeyboardShortcuts/Shortcut.swift` | main / shortcut initializer | Shows stored shortcut can be retrieved without a handler | https://github.com/sindresorhus/keyboardshortcuts/blob/main/Sources/KeyboardShortcuts/Shortcut.swift |
| [4] | code | `Sources/KeyboardShortcuts/Name.swift` | main / property accessors | Shows `shortcut` property is storage-only access | https://github.com/sindresorhus/keyboardshortcuts/blob/main/Sources/KeyboardShortcuts/Name.swift |
| [5] | code | `Sources/KeyboardShortcuts/KeyboardShortcuts.swift` | main / `getShortcut(for:)` | Confirms stored shortcut retrieval path | https://github.com/sindresorhus/keyboardshortcuts/blob/main/Sources/KeyboardShortcuts/KeyboardShortcuts.swift |
| [6] | code | `Sources/KeyboardShortcuts/HotKey.swift` | main / Carbon hotkey plumbing | Confirms the library registers and consumes keyboard events through Carbon hotkeys | https://github.com/sindresorhus/keyboardshortcuts/blob/main/Sources/KeyboardShortcuts/HotKey.swift |
| [7] | code | `Sources/KeyboardShortcuts/KeyboardShortcuts.swift` | main / enable-disable / stream registration hooks | Confirms registration happens when active handlers exist and can be disabled/unregistered | https://github.com/sindresorhus/keyboardshortcuts/blob/main/Sources/KeyboardShortcuts/KeyboardShortcuts.swift |

### Evidence Appendix
```swift
// Storage-only retrieval path
public static func getShortcut(for name: Name) -> Shortcut? {
	if case .shortcut(let shortcut) = storedShortcut(for: name) {
		return shortcut
	}

	return nil
}

@MainActor
public init?(name: Name) {
	guard let shortcut = getShortcut(for: name) else {
		return nil
	}

	self = shortcut
}
```

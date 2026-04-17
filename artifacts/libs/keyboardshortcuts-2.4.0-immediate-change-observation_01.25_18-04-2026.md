## Findings: KeyboardShortcuts 2.4.0 / immediate recorder-change observation

### Research Metadata
- Question: In KeyboardShortcuts 2.4.0, what is the best-supported immediate-change observation mechanism for `Recorder(for:name) { _ in ... }`, and is `UserDefaults.didChangeNotification` sufficient for per-shortcut refresh?
- Type: CONCEPTUAL
- Target: sindresorhus/KeyboardShortcuts 2.4.0
- Version Scope: release tag `2.4.0` resolved to commit `1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27`
- Generated: 01.25_18-04-2026
- Coverage: COMPLETE

### Direct Answer
- Fact: The strongest public immediate-change hook in 2.4.0 is the recorder’s own `onChange` callback; the API documents it as firing when the shortcut is changed/removed by the user, and the Cocoa implementation calls it after every save, including clear-to-nil. [1][2]
- Fact: If Padium needs an observer outside the recorder itself, the library posts `KeyboardShortcuts_shortcutByNameDidChange` after every set/disable/remove write and includes the affected `Name` in `userInfo`, so listeners can filter per shortcut. [3]
- Fact: `UserDefaults.didChangeNotification` is too broad for precise per-shortcut refresh here: Apple documents it as a process-local “setting changed” notification, while KeyboardShortcuts 2.4.0 explicitly marks proper `UserDefaults` observation as TODO and does not use it for recorder refresh. [3][4]
- Synthesis: For this bug, relying only on `UserDefaults.didChangeNotification` is insufficient and bug-prone; use `Recorder(..., onChange:)` at the row site when possible, otherwise observe the library’s custom change notification and match the shortcut name. [1][2][3][4]

### Key Findings
#### Row-local immediate hook

**Claim**: `Recorder(for:name:onChange:)` is the supported immediate-change callback in 2.4.0, and it is meant for both changes and removals. [1]

**Evidence** ([`Sources/KeyboardShortcuts/Recorder.swift#L92-L100`](https://github.com/sindresorhus/KeyboardShortcuts/blob/1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27/Sources/KeyboardShortcuts/Recorder.swift#L92-L100) [1]):
```swift
/**
- Parameter name: Strongly-typed keyboard shortcut name.
- Parameter onChange: Callback which will be called when the keyboard shortcut is changed/removed by the user. This can be useful when you need more control. For example, when migrating from a different keyboard shortcut solution and you need to store the keyboard shortcut somewhere yourself instead of relying on the built-in storage. However, it's strongly recommended to just rely on the built-in storage when possible.
*/
public init(
	for name: KeyboardShortcuts.Name,
	onChange: ((KeyboardShortcuts.Shortcut?) -> Void)? = nil
)
```

**Explanation**: This is the public, row-local contract. For a SwiftUI settings row, the `onChange` closure is the immediate place to react without waiting for any broader defaults observer.

#### Clear emits the same callback

**Claim**: Clearing the recorder still flows through the same callback as assigning a shortcut. [2]

**Evidence** ([`Sources/KeyboardShortcuts/RecorderCocoa.swift#L155-L166`](https://github.com/sindresorhus/KeyboardShortcuts/blob/1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27/Sources/KeyboardShortcuts/RecorderCocoa.swift#L155-L166) [2]):
```swift
public func controlTextDidChange(_ object: Notification) {
	if stringValue.isEmpty {
		saveShortcut(nil)
	}

	showsCancelButton = !stringValue.isEmpty

	if stringValue.isEmpty {
		// Hack to ensure that the placeholder centers after the above `showsCancelButton` setter.
		focus()
	}
}
```

**Evidence** ([`Sources/KeyboardShortcuts/RecorderCocoa.swift#L344-L346`](https://github.com/sindresorhus/KeyboardShortcuts/blob/1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27/Sources/KeyboardShortcuts/RecorderCocoa.swift#L344-L346) [2]):
```swift
private func saveShortcut(_ shortcut: Shortcut?) {
	setShortcut(shortcut, for: shortcutName)
	onChange?(shortcut)
}
```

**Explanation**: A clear writes `nil`, then calls `onChange(nil)`. That gives the app an immediate, row-local signal for both assignment and removal.

#### Library-owned cross-row observation

**Claim**: The package’s own persistence path emits a custom notification after every shortcut write/removal, not `UserDefaults.didChangeNotification`. [3]

**Evidence** ([`Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L495-L521`](https://github.com/sindresorhus/KeyboardShortcuts/blob/1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27/Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L495-L521) [3]):
```swift
static func userDefaultsDidChange(name: Name) {
	// TODO: Use proper UserDefaults observation instead of this.
	NotificationCenter.default.post(name: .shortcutByNameDidChange, object: nil, userInfo: ["name": name])
}

static func userDefaultsSet(name: Name, shortcut: Shortcut) {
	guard let encoded = try? JSONEncoder().encode(shortcut).toString else {
		return
	}

	if let oldShortcut = getShortcut(for: name) {
		unregister(oldShortcut)
	}

	register(shortcut)
	UserDefaults.standard.set(encoded, forKey: userDefaultsKey(for: name))
	userDefaultsDidChange(name: name)
}

static func userDefaultsDisable(name: Name) {
	guard let shortcut = getShortcut(for: name) else {
		return
	}

	UserDefaults.standard.set(false, forKey: userDefaultsKey(for: name))
	unregister(shortcut)
	userDefaultsDidChange(name: name)
}

static func userDefaultsRemove(name: Name) {
	guard let shortcut = getShortcut(for: name) else {
		return
	}

	UserDefaults.standard.removeObject(forKey: userDefaultsKey(for: name))
	unregister(shortcut)
	userDefaultsDidChange(name: name)
}
```

**Explanation**: The library itself publishes a custom notification after each write path and explicitly flags generic `UserDefaults` observation as unfinished. That makes the custom notification the supported upstream observation point for cross-row refresh.

#### Why generic `UserDefaults.didChangeNotification` is not enough

**Claim**: Apple’s generic defaults-change notification is process-wide and only says “some setting changed,” so it does not identify which shortcut row changed. [4]

**Evidence** ([Apple Developer Documentation](https://docs.developer.apple.com/tutorials/data/documentation/foundation/userdefaults/didchangenotification.md) [4]):
```text
Posted when the current process changes the value of a setting.

When you write a new value to a setting, or remove an existing value, the system
generates this notification to alert you that your app’s settings changed.
```

**Explanation**: That notification is broad by design. It is fine for “something in defaults changed,” but it is not a precise per-shortcut signal and does not carry the `KeyboardShortcuts.Name` that Padium needs to refresh one row immediately and deterministically.

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `KeyboardShortcuts.Recorder(..., onChange:)` | User changes or clears the shortcut in the settings row | [1][2] |
| 2 | `saveShortcut(_:)` | Library persists the new value (or `nil`) and invokes the row-local callback immediately | [2] |
| 3 | `userDefaultsSet` / `userDefaultsDisable` / `userDefaultsRemove` | Library writes storage and posts `.shortcutByNameDidChange` with the affected `Name` | [3] |
| 4 | External observers | Filter the custom notification by `name` to update only the affected shortcut row | [3] |
| 5 | `UserDefaults.didChangeNotification` | Fires for any setting change in the process, but carries no shortcut identity | [4] |

### Caveats and Gaps
- The upstream source does not show any dedicated per-shortcut `UserDefaults` key-path observation API in 2.4.0; the only supported upstream immediate signals are the recorder callback and the package’s custom notification. [1][2][3]
- If Padium already owns its own shortcut state, the recorder callback is the cleanest option; if not, the custom notification is the safer external observer than a generic defaults notification. [1][3][4]

### Confidence
**Level:** HIGH
**Rationale:** The recorder API docs, the Cocoa implementation, and the storage/update path all line up: immediate row-local callback first, custom name-scoped notification second, generic defaults notification not used by the library. [1][2][3][4]

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | code | `Sources/KeyboardShortcuts/Recorder.swift` | tag `2.4.0` → `1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27` | Public SwiftUI recorder API and `onChange` contract for changed/removed shortcuts | https://github.com/sindresorhus/KeyboardShortcuts/blob/1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27/Sources/KeyboardShortcuts/Recorder.swift#L92-L100 |
| [2] | code | `Sources/KeyboardShortcuts/RecorderCocoa.swift` | tag `2.4.0` → `1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27` | Shows clear-to-nil and callback invocation in the Cocoa recorder | https://github.com/sindresorhus/KeyboardShortcuts/blob/1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27/Sources/KeyboardShortcuts/RecorderCocoa.swift#L155-L166 |
| [3] | code | `Sources/KeyboardShortcuts/KeyboardShortcuts.swift` | tag `2.4.0` → `1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27` | Governs storage writes and the custom `shortcutByNameDidChange` notification | https://github.com/sindresorhus/KeyboardShortcuts/blob/1aef85578fdd4f9eaeeb8d53b7b4fc31bf08fe27/Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L495-L521 |
| [4] | docs | Apple Developer Documentation: `UserDefaults.didChangeNotification` | Retrieved 2026-04-18 | Defines the generic defaults-change notification and its scope | https://docs.developer.apple.com/tutorials/data/documentation/foundation/userdefaults/didchangenotification.md |

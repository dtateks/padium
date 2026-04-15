## Findings: KeyboardShortcuts 2.4.0 / recorder change observation

### Research Metadata
- Question: In KeyboardShortcuts 2.4.0, what is the supported API for reacting immediately when a Recorder changes or clears a shortcut binding? Need exact API shape and whether it can observe per-name changes on macOS.
- Type: CONCEPTUAL
- Target: sindresorhus/KeyboardShortcuts 2.4.0
- Version Scope: Upstream macOS source as of commit `81caa542dc81b058a2c30daab3cb2fbd6a90db7b` (main branch snapshot used to verify the 2.4.0 API surface)
- Generated: 21.41_15-04-2026
- Coverage: COMPLETE

### Direct Answer
- Fact: The supported immediate-change hook is `NotificationCenter` observation of `.shortcutByNameDidChange`; the notification carries the changed `KeyboardShortcuts.Name` in `userInfo`, so consumers can filter per name. [1][2][3]
- Fact: The Cocoa recorder (`RecorderCocoa`) subscribes to that notification only when it is in `.name` storage mode, then refreshes its displayed value only if the notification’s name matches its bound `shortcutName`. [3]
- Fact: There is no dedicated per-name callback API on the macOS public surface in 2.4.0; the docs expose `Recorder`, `RecorderCocoa`, `onKeyDown`, `onKeyUp`, `events(for:)`, and `repeatingKeyDownEvents(for:)`, while the change notification is the observation mechanism used internally by the package UI components. [1][2][3][4]

### Key Findings
#### Public API shape

**Claim**: The public docs show `Recorder` for binding edits, but no dedicated “shortcut changed” closure API; the usable immediate reaction point is the change notification path. [1]

**Evidence** ([readme.md#L33-L54](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/readme.md#L33-L54) [1]):
```swift
KeyboardShortcuts.Recorder("Toggle Unicorn Mode:", name: .toggleUnicornMode)
```

**Explanation**: The README documents the recorder UI and the runtime key handlers separately, but does not provide a per-name change callback on the public SwiftUI API. That leaves notification observation as the supported immediate reaction mechanism. [1][3][4]

#### Notification contract

**Claim**: The library posts `.shortcutByNameDidChange` after updating stored shortcut state, with the affected name in `userInfo`. [2]

**Evidence** ([KeyboardShortcuts.swift#L642-L651](https://github.com/sindresorhus/KeyboardShortcuts/blob/81caa542dc81b058a2c30daab3cb2fbd6a90db7b/Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L642-L651) [2]):
```swift
static func userDefaultsDidChange(name: Name) {
	// TODO: Use proper UserDefaults observation instead of this.
	NotificationCenter.default.post(name: .shortcutByNameDidChange, object: nil, userInfo: [NotificationUserInfoKey.name: name])
}

private static func updateStoredShortcut(for name: Name, update: () -> Void) {
	unregisterIfNeeded(for: name)
	update()
	registerIfNeeded(for: name)
	userDefaultsDidChange(name: name)
}
```

**Explanation**: Any recorder-driven save/clear funnels through `updateStoredShortcut`, which posts the notification after the store change. The notification is therefore the immediate event to observe for slot configuration changes. [2]

#### Per-name filtering on macOS

**Claim**: Yes, per-name observation is possible on macOS by checking the notification’s extracted `KeyboardShortcuts.Name` against the name you care about. [3]

**Evidence** ([RecorderCocoa.swift#L241-L259](https://github.com/sindresorhus/KeyboardShortcuts/blob/81caa542dc81b058a2c30daab3cb2fbd6a90db7b/Sources/KeyboardShortcuts/RecorderCocoa.swift#L241-L259) [3]):
```swift
private func setUpEvents() {
	guard storageMode == .name else {
		return
	}

	shortcutsNameChangeObserver = NotificationCenter.default.addObserver(forName: .shortcutByNameDidChange, object: nil, queue: nil) { [weak self] notification in
		let nameInNotification = notification.keyboardShortcutsName

		Task { @MainActor [weak self] in
			guard
				let self,
				let nameInNotification,
				nameInNotification == shortcutName
			else {
				return
			}

			updateStringValue()
		}
	}
}
```

**Explanation**: The package’s own Cocoa recorder uses a global notification and then filters to a single bound name. That means observation is per-name in practice, but not via separate per-name notification types or a dedicated per-name callback API. [3]

#### Notification name / payload helpers

**Claim**: The notification payload is structured for name-based filtering via convenience accessors. [3][4]

**Evidence** ([ViewModifiers.swift#L101-L107](https://github.com/sindresorhus/KeyboardShortcuts/blob/81caa542dc81b058a2c30daab3cb2fbd6a90db7b/Sources/KeyboardShortcuts/ViewModifiers.swift#L101-L107) [4]):
```swift
.onReceive(NotificationCenter.default.publisher(for: .shortcutByNameDidChange)) {
	guard $0.keyboardShortcutsName == name else {
		return
	}

	triggerRefresh.toggle()
}
```

**Explanation**: The SwiftUI wrapper also subscribes globally and filters by the emitted name, confirming the intended contract for immediate UI refresh on a specific slot. [3][4]

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `KeyboardShortcuts.Recorder` / `RecorderCocoa` | User changes or clears the binding | [1][3] |
| 2 | `updateStoredShortcut(for:update:)` | Library unregisters/re-registers and persists the new state | [2] |
| 3 | `.shortcutByNameDidChange` | Library posts a global change notification with the affected `Name` | [2] |
| 4 | `notification.keyboardShortcutsName == shortcutName` | Consumers filter to the one slot they care about | [3][4] |

### Caveats and Gaps
- The library’s own source calls this notification-based approach a stopgap (`TODO: Use proper UserDefaults observation instead of this.`), so the supported API is notification observation rather than a first-class per-name callback. [2]
- I did not find a dedicated public modifier or closure like `onShortcutChange(for:)`; if one exists in a newer release, it is not part of the verified 2.4.0 surface used here. [1][2][3][4]

### Confidence
**Level:** HIGH
**Rationale:** The recorder implementation and SwiftUI wrapper both show the same change contract: a single notification plus name filtering. The docs do not advertise any stronger dedicated per-name callback API. [1][2][3][4]

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | docs | README usage/API sections | main branch docs for 2.4.0-era package | Shows the public recorder/handler surface and absence of a dedicated change callback in docs | https://github.com/sindresorhus/KeyboardShortcuts/blob/main/readme.md |
| [2] | code | `Sources/KeyboardShortcuts/KeyboardShortcuts.swift` | `81caa542dc81b058a2c30daab3cb2fbd6a90db7b#L642-L651` | Governs the actual change notification emitted after storing shortcut updates | https://github.com/sindresorhus/KeyboardShortcuts/blob/81caa542dc81b058a2c30daab3cb2fbd6a90db7b/Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L642-L651 |
| [3] | code | `Sources/KeyboardShortcuts/RecorderCocoa.swift` | `81caa542dc81b058a2c30daab3cb2fbd6a90db7b#L241-L259` | Shows the supported per-name filtering pattern used by the library’s own Cocoa recorder | https://github.com/sindresorhus/KeyboardShortcuts/blob/81caa542dc81b058a2c30daab3cb2fbd6a90db7b/Sources/KeyboardShortcuts/RecorderCocoa.swift#L241-L259 |
| [4] | code | `Sources/KeyboardShortcuts/ViewModifiers.swift` | `81caa542dc81b058a2c30daab3cb2fbd6a90db7b#L101-L107` | Shows SwiftUI observing the same notification and filtering by name | https://github.com/sindresorhus/KeyboardShortcuts/blob/81caa542dc81b058a2c30daab3cb2fbd6a90db7b/Sources/KeyboardShortcuts/ViewModifiers.swift#L101-L107 |

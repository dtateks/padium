## Findings: KeyboardShortcuts 2.4.0 / recorder-to-getShortcut visibility

### Research Metadata
- Question: Do `KeyboardShortcuts.Recorder` updates become immediately visible to `KeyboardShortcuts.getShortcut(for:)`, or does the library cache shortcut values / require change handlers?
- Type: CONCEPTUAL
- Target: sindresorhus/KeyboardShortcuts 2.4.0
- Version Scope: Upstream public repository behavior reflected in 2.4.0 docs/code; verified against current upstream source as evidence for the 2.4.0 API contract.
- Generated: 21.26_15-04-2026
- Coverage: COMPLETE

### Direct Answer
- Fact: `Recorder` writes the selected shortcut to shared storage, and `getShortcut(for:)` reads that stored value directly; the library does not show a separate cache layer between them. A newly recorded shortcut should therefore be visible to `getShortcut(for:)` immediately after the write completes. [1][2][3]
- Fact: `onKeyDown` / `onKeyUp` are for runtime shortcut handling, not for persistence; they register hotkeys when present, but they are not required for `getShortcut(for:)` to reflect the saved value. [1][2][4]
- Synthesis: If a changed shortcut only becomes visible after app relaunch, the stale value is more likely in Padium’s own state/update flow than in `KeyboardShortcuts` itself, because the library’s documented read path is storage-backed rather than cached-in-memory. [1][2][3]

### Key Findings
#### Recorder writes, getShortcut reads

**Claim**: The public API separates recording/storage from retrieval; `Name.shortcut` setter persists, and `getShortcut(for:)` returns the stored shortcut directly. [2][3]

**Evidence** ([Name.swift#L81-L89](https://github.com/sindresorhus/keyboardshortcuts/blob/main/Sources/KeyboardShortcuts/Name.swift#L81-L89) [2]):
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

**Evidence** ([KeyboardShortcuts.swift#L465-L472](https://github.com/sindresorhus/keyboardshortcuts/blob/main/Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L465-L472) [3]):
```swift
public static func getShortcut(for name: Name) -> Shortcut? {
	if case .shortcut(let shortcut) = storedShortcut(for: name) {
		return shortcut
	}

	return nil
}
```

**Explanation**: The setter calls `setShortcut(...)`, while the getter immediately consults `storedShortcut(for:)`. Nothing in these paths indicates a separate cached copy that would delay visibility until relaunch. [2][3]

#### Recorder is UI/storage, not a requirement for runtime reads

**Claim**: The recorder is documented as the UI used to pick a shortcut; the runtime handlers are separate APIs. [1]

**Evidence** ([readme.md#L13-L20](https://github.com/sindresorhus/keyboardshortcuts/blob/main/readme.md#L13-L20) [1]):
```swift
KeyboardShortcuts.Recorder("Toggle Unicorn Mode:", name: .toggleUnicornMode)

KeyboardShortcuts.onKeyUp(for: .toggleUnicornMode) { [self] in
	isUnicornMode.toggle()
}
```

**Explanation**: The docs present recording and handling as different steps. That supports the conclusion that `Recorder` is not the mechanism that makes `getShortcut(for:)` work; it only updates stored state. [1][2][3]

#### Handlers are for interception, not persistence

**Claim**: `onKeyUp(for:)` registers behavior and triggers hotkey setup, but it is not needed just to read the stored shortcut. [4]

**Evidence** ([KeyboardShortcuts.swift#L561-L577](https://github.com/sindresorhus/keyboardshortcuts/blob/main/Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L561-L577) [4]):
```swift
public static func onKeyUp(for name: Name, action: @escaping () -> Void) {
	keyUpHandlers[name, default: []].append(action)
	registerIfNeeded(for: name)
}

nonisolated private static let userDefaultsPrefix = "KeyboardShortcuts_"
```

**Explanation**: Registration is tied to adding handlers. That is orthogonal to `getShortcut(for:)`, which reads persisted data and does not depend on handler registration. [3][4]

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `KeyboardShortcuts.Recorder` | User chooses a shortcut in the UI | [1][2] |
| 2 | `Name.shortcut` setter / `setShortcut(for:)` | Selected shortcut is persisted | [2] |
| 3 | `getShortcut(for:)` | Stored shortcut is read back immediately | [3] |
| 4 | `onKeyUp(for:)` / `onKeyDown(for:)` | Optional runtime handler registration and hotkey setup | [1][4] |

### Caveats and Gaps
- I did not find evidence of any in-library shortcut cache that would intentionally delay `getShortcut(for:)`; the available code points to direct storage reads. [2][3]
- This answers library behavior, not Padium’s own view/update timing. If Padium reads the shortcut only once into local state, that code could still make the UI or emitter appear stale even though the library is up to date. [1][2][3]

### Confidence
**Level:** HIGH
**Rationale:** The decisive APIs are small and directly show persistence plus immediate retrieval, with no visible cache boundary. The only remaining uncertainty is Padium-side state propagation, not KeyboardShortcuts behavior. [2][3][4]

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | docs | README usage examples | main / public upstream docs | Shows recorder and handler are separate concepts | https://github.com/sindresorhus/keyboardshortcuts/blob/main/readme.md |
| [2] | code | `Sources/KeyboardShortcuts/Name.swift` | main | Shows `shortcut` setter delegates to storage | https://github.com/sindresorhus/keyboardshortcuts/blob/main/Sources/KeyboardShortcuts/Name.swift |
| [3] | code | `Sources/KeyboardShortcuts/KeyboardShortcuts.swift` | main | Shows `getShortcut(for:)` reads stored value directly | https://github.com/sindresorhus/keyboardshortcuts/blob/main/Sources/KeyboardShortcuts/KeyboardShortcuts.swift |
| [4] | code | `Sources/KeyboardShortcuts/KeyboardShortcuts.swift` | main | Shows handler registration is separate from storage | https://github.com/sindresorhus/keyboardshortcuts/blob/main/Sources/KeyboardShortcuts/KeyboardShortcuts.swift |

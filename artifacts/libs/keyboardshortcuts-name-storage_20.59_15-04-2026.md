## Findings: KeyboardShortcuts `Name` registration vs stored shortcut lookup

### Research Metadata
- Question: When using `KeyboardShortcuts.Name("someName")`, does the name need to be registered at app startup for `KeyboardShortcuts.getShortcut(for:)` to return the stored value?
- Type: IMPLEMENTATION
- Target: sindresorhus/KeyboardShortcuts 2.4.0
- Version Scope: Upstream `main` at commit `81caa542dc81b058a2c30daab3cb2fbd6a90db7b` (used as the source for the 2.4.0 implementation behavior)
- Generated: 20.59_15-04-2026
- Coverage: COMPLETE

### Direct Answer
- Fact: No. `KeyboardShortcuts.getShortcut(for:)` reads the stored value directly from `UserDefaults` via the name’s raw value; it does not require the name to have been registered in advance. If you create the same `KeyboardShortcuts.Name("gesture.threeFingerSwipeLeft")` later, `getShortcut(for:)` returns the stored shortcut as long as that key exists in `UserDefaults`. [1][2]
- Fact: The `Name` initializer does trigger `KeyboardShortcuts.initialize()`, but that initializes the library’s hotkey center, not the stored-shortcut lookup path. The stored-value path is separate and works from the name alone. [2][3][4]
- Synthesis: For your use case, creating the `Name` in the recorder view and recreating the same `Name` later in another code path is sufficient for retrieval; there is no separate “register once at startup” requirement for `getShortcut(for:)`. [1][2][3]

### Key Findings
#### Stored lookup is keyed only by `rawValue`

**Claim**: `getShortcut(for:)` resolves the shortcut by reading the `UserDefaults` key derived from `name.rawValue`, then decoding the stored value; it does not consult any registration table. [1]

**Evidence** ([Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L467-L475](https://github.com/sindresorhus/KeyboardShortcuts/blob/81caa542dc81b058a2c30daab3cb2fbd6a90db7b/Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L467-L475) [1]):
```swift
public static func getShortcut(for name: Name) -> Shortcut? {
	if case .shortcut(let shortcut) = storedShortcut(for: name) {
		return shortcut
	}

	return nil
}
```

**Evidence** ([Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L614-L636](https://github.com/sindresorhus/KeyboardShortcuts/blob/81caa542dc81b058a2c30daab3cb2fbd6a90db7b/Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L614-L636) [1]):
```swift
private static func userDefaultsValue(for name: Name) -> Any? {
	UserDefaults.standard.object(forKey: userDefaultsKey(for: name))
}

private static func storedShortcut(for name: Name) -> StoredShortcut {
	guard let storedValue = userDefaultsValue(for: name) else {
		return .missing
	}

	if let isEnabled = storedValue as? Bool, !isEnabled {
		return .disabled
	}

	guard
		let shortcutString = storedValue as? String,
		let data = shortcutString.data(using: .utf8),
		let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data)
	else {
		return .missing
	}

	return .shortcut(shortcut)
}
```

**Explanation**: The lookup is purely storage-backed. A later call using a freshly constructed `Name` with the same `rawValue` hits the same `UserDefaults` key, so the earlier recorder interaction is enough to persist the shortcut for later retrieval. No registration state is consulted here. [1]

#### `Name` construction is not a prerequisite for lookup, but it does initialize the library

**Claim**: `KeyboardShortcuts.Name.init(_:)` stores the raw string, optionally seeds an initial shortcut, and then calls `KeyboardShortcuts.initialize()` on the main actor. [2]

**Evidence** ([Sources/KeyboardShortcuts/Name.swift#L32-L53](https://github.com/sindresorhus/KeyboardShortcuts/blob/81caa542dc81b058a2c30daab3cb2fbd6a90db7b/Sources/KeyboardShortcuts/Name.swift#L32-L53) [2]):
```swift
nonisolated
public init(_ name: String, initial initialShortcut: Shortcut? = nil) {
	runtimeWarn(
		KeyboardShortcuts.isValidShortcutName(name),
		"The keyboard shortcut name must not contain a dot (.)."
	)

	self.rawValue = name
	self.initialShortcut = initialShortcut

	if let initialShortcut {
		KeyboardShortcuts.setInitialShortcutIfNeeded(
			initialShortcut,
			forRawValue: name
		)
	}

	Task { @MainActor in
		KeyboardShortcuts.initialize()
	}
}
```

**Explanation**: This shows initialization is a side effect of constructing a `Name`, but the code does not require a pre-registered static name to make `getShortcut(for:)` work. The key point is that lookup uses `rawValue`, not a startup registry. [2][1]

#### `Shortcut(name:)` is just a convenience wrapper around the same storage lookup

**Claim**: `KeyboardShortcuts.Shortcut.init?(name:)` returns the stored shortcut by delegating to `getShortcut(for:)`; it does not require a prior explicit registration step. [3][1]

**Evidence** ([Sources/KeyboardShortcuts/Shortcut.swift#L69-L79](https://github.com/sindresorhus/KeyboardShortcuts/blob/81caa542dc81b058a2c30daab3cb2fbd6a90db7b/Sources/KeyboardShortcuts/Shortcut.swift#L69-L79) [3]):
```swift
@MainActor
public init?(name: Name) {
	guard let shortcut = getShortcut(for: name) else {
		return nil
	}

	self = shortcut
}
```

**Explanation**: This initializer is proof that the library treats storage retrieval as a standalone operation. It is equivalent to calling `getShortcut(for:)` and wrapping the result. [3][1]

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `KeyboardShortcuts.Name.init(_:)` | Stores `rawValue`, may seed an initial shortcut, and kicks `initialize()` | [2] |
| 2 | `KeyboardShortcuts.setShortcut(_:for:)` / `Recorder` | User selection is persisted into `UserDefaults` under the name-derived key | [1][2] |
| 3 | `KeyboardShortcuts.getShortcut(for:)` | Reads `UserDefaults` by `name.rawValue` and decodes the stored shortcut | [1] |
| 4 | `KeyboardShortcuts.Shortcut.init?(name:)` | Convenience wrapper that returns the same stored shortcut result | [3] |

### Caveats and Gaps
- The public source does not describe any special behavior for names containing dots beyond a warning that they are invalid; your example `gesture.threeFingerSwipeLeft` would violate the library’s stated constraint. The retrieval answer above still holds for the storage mechanism, but the name itself is documented as invalid. [2]
- This answer is based on upstream commit `81caa542dc81b058a2c30daab3cb2fbd6a90db7b`, which is the repository state I inspected for the 2.4.0 implementation behavior. [1][2][3]

### Confidence
**Level:** HIGH
**Rationale:** The decisive lookup path is explicit in code: `getShortcut(for:)` reads `UserDefaults` directly, while `Name.init(_:)` only initializes the library as a side effect. No separate registration gate appears on the storage retrieval path. [1][2][3]

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | code | `Sources/KeyboardShortcuts/KeyboardShortcuts.swift` | `81caa542dc81b058a2c30daab3cb2fbd6a90db7b` | Governs storage lookup and `UserDefaults` keying | [file](https://github.com/sindresorhus/KeyboardShortcuts/blob/81caa542dc81b058a2c30daab3cb2fbd6a90db7b/Sources/KeyboardShortcuts/KeyboardShortcuts.swift) |
| [2] | code | `Sources/KeyboardShortcuts/Name.swift` | `81caa542dc81b058a2c30daab3cb2fbd6a90db7b` | Shows `Name` initialization behavior and startup initialization side effect | [file](https://github.com/sindresorhus/KeyboardShortcuts/blob/81caa542dc81b058a2c30daab3cb2fbd6a90db7b/Sources/KeyboardShortcuts/Name.swift) |
| [3] | code | `Sources/KeyboardShortcuts/Shortcut.swift` | `81caa542dc81b058a2c30daab3cb2fbd6a90db7b` | Shows `Shortcut(name:)` delegates to stored lookup | [file](https://github.com/sindresorhus/KeyboardShortcuts/blob/81caa542dc81b058a2c30daab3cb2fbd6a90db7b/Sources/KeyboardShortcuts/Shortcut.swift) |

## Findings: KeyboardShortcuts dot-name validation and storage behavior

### Research Metadata
- Question: In KeyboardShortcuts v2.4.0, what does `isValidShortcutName()` check, does it only warn or also block persistence, what exact code does `userDefaultsKey(for:)` use, can dots prevent persistence or cause clearing on restart, and is there any conflict with UserDefaults key-path behavior?
- Type: IMPLEMENTATION
- Target: sindresorhus/KeyboardShortcuts v2.4.0
- Version Scope: Upstream `main` source used to explain the v2.4.0 implementation behavior; `Name.init(_:)`, `isValidShortcutName(_:)`, `runtimeWarn`, and `userDefaultsKey(for:)` are the governing code paths.
- Generated: 21.08_15-04-2026
- Coverage: COMPLETE

### Direct Answer
- Fact: `isValidShortcutName(_:)` is a pure predicate that returns `!name.contains(".")`; it does not itself block persistence. The `runtimeWarn(...)` wrapper only emits a debug-time warning/assertion, while the `Name` initializer still stores `rawValue`, optionally seeds `initialShortcut`, and continues initialization. [1][2][3]
- Fact: `userDefaultsKey(forRawValue:)` uses the raw value directly with a fixed prefix: `"KeyboardShortcuts_\(rawValue)"`. There is no dot-mangling, escaping, or transformation of the name before storage. [1]
- Fact: Dots do not appear to make the shortcut fail to persist or be cleared on restart through the storage code path; persistence is keyed by the exact raw string, and the library only warns that dots are invalid because the name is used as a key path for observation. [1][2][3]
- Fact: There is no evidence in the source that UserDefaults key-path behavior is involved here. The library is not using key-path-based `UserDefaults` access; it is using `object(forKey:)`, `set(_:forKey:)`, and `removeObject(forKey:)` with a plain string key. [1]

### Key Findings
#### `isValidShortcutName(_:)` only validates for a dot

**Claim**: The validation function is exactly `!name.contains(".")`. It is a boolean check only. [1]

**Evidence** ([Sources/KeyboardShortcuts/Utilities.swift#L360-L367](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/Utilities.swift#L360-L367) [1]):
```swift
extension KeyboardShortcuts {
	nonisolated static func isValidShortcutName(_ name: String) -> Bool {
		!name.contains(".")
	}
}
```

**Explanation**: The predicate rejects any string containing a dot and nothing else. No persistence logic exists in this function.

#### `runtimeWarn` warns in debug only; it does not stop the initializer

**Claim**: `runtimeWarn` is a debug-only warning/assert helper. In `DEBUG`, it logs a fault (or asserts on non-OSLog builds) when the condition is false; outside `DEBUG`, it compiles away. The `Name` initializer still proceeds afterward. [2][3]

**Evidence** ([Sources/KeyboardShortcuts/Utilities.swift#L296-L311](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/Utilities.swift#L296-L311) [2]):
```swift
@_transparent
@usableFromInline
nonisolated func runtimeWarn(
	_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String
) {
#if DEBUG
#if canImport(OSLog)
	let condition = condition()
	if !condition {
		os_log(
			.fault,
			dso: dynamicSharedObject,
			log: OSLog(subsystem: "com.apple.runtime-issues", category: "KeyboardShortcuts"),
			"%@",
			message()
		)
	}
#else
	assert(condition(), message())
#endif
#endif
}
```

**Evidence** ([Sources/KeyboardShortcuts/Name.swift#L22-L47](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/Name.swift#L22-L47) [3]):
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

**Explanation**: The warning happens before assignment, but it is not a guard/throw/precondition that returns early. So an invalid dotted name still becomes the `rawValue` and the initializer continues.

#### UserDefaults key format is a direct prefix + raw value

**Claim**: Storage keys are built as `KeyboardShortcuts_<rawValue>` with no transformation of the shortcut name. [1]

**Evidence** ([Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L296-L305](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L296-L305) [1]):
```swift
nonisolated private static let userDefaultsPrefix = "KeyboardShortcuts_"

nonisolated static func userDefaultsKey(forRawValue rawValue: String) -> String {
	"\(userDefaultsPrefix)\(rawValue)"
}

private static func userDefaultsKey(for shortcutName: Name) -> String {
	userDefaultsKey(forRawValue: shortcutName.rawValue)
}
```

**Explanation**: The stored key is a plain string concatenation. A dotted name becomes a key containing dots, but nothing in this code alters it.

#### Persistence and restart behavior do not depend on the dot check

**Claim**: Persistence uses the exact key from `userDefaultsKey(for:)`, and removal only happens when the app explicitly calls `setShortcut(nil, for:)`/`reset`/`removeObject`, not because the name contains a dot. [1][3]

**Evidence** ([Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L356-L370](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L356-L370) [1]):
```swift
public static func setShortcut(_ shortcut: Shortcut?, for name: Name) {
	if let shortcut {
		userDefaultsSet(name: name, shortcut: shortcut)
		return
	}

	if name.initialShortcut != nil {
		userDefaultsDisable(name: name)
	} else {
		userDefaultsRemove(name: name)
	}
}
```

**Evidence** ([Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L329-L354](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/KeyboardShortcuts.swift#L329-L354) [1]):
```swift
static func userDefaultsSet(name: Name, shortcut: Shortcut) {
	guard let encoded = encodedShortcutForStorage(shortcut) else {
		return
	}

	updateStoredShortcut(for: name) {
		UserDefaults.standard.set(encoded, forKey: userDefaultsKey(for: name))
	}
}

static func userDefaultsRemove(name: Name) {
	guard userDefaultsValue(for: name) != nil else {
		return
	}

	updateStoredShortcut(for: name) {
		UserDefaults.standard.removeObject(forKey: userDefaultsKey(for: name))
	}
}
```

**Explanation**: The library explicitly writes and removes the entry by exact key. Nothing here clears a shortcut on restart because of dots; a restart simply re-reads the same `UserDefaults` key.

#### The dot warning is about observation/key-path semantics, not storage

**Claim**: The source explicitly says the dot restriction exists because the name is used as a key path for observation. [3]

**Evidence** ([Sources/KeyboardShortcuts/Name.swift#L10-L20](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/Name.swift#L10-L20) [3]):
```swift
/**
	- Parameter name: Name of the shortcut.
	- Parameter initialShortcut: Optional initial key combination. Do not set this unless it's essential. Users find it annoying when random apps steal their existing keyboard shortcuts. It's generally better to show a welcome screen on the first app launch that lets the user set the shortcut.
	- Important: The name must not contain a dot (`.`) because it is used as a key path for observation.
*/
```

**Explanation**: This is the only stated reason for the dot ban. It points to observation mechanics, not `UserDefaults` persistence.

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `KeyboardShortcuts.Name.init(_:)` | Emits a debug-time warning if the name contains `.`, then still stores `rawValue` and continues | [2][3] |
| 2 | `userDefaultsKey(forRawValue:)` | Builds `KeyboardShortcuts_<rawValue>` directly | [1] |
| 3 | `setShortcut(_:for:)` / `userDefaultsSet(name:shortcut:)` | Writes the encoded shortcut string to `UserDefaults` under that exact key | [1] |
| 4 | `getShortcut(for:)` / `storedShortcut(for:)` | Reads the same exact key back on restart and decodes it | [1] |

### Caveats and Gaps
- The repository docs say dots are invalid because the name is used as a key path for observation, but I did not find evidence that dotted names break `UserDefaults` persistence itself. The storage code strongly suggests they do not. [1][3]
- `runtimeWarn` is clearly debug-only in the inspected source. If a build configuration strips `DEBUG`, the warning disappears entirely; persistence behavior still remains unchanged. [2]

### Confidence
**Level:** HIGH
**Rationale:** The relevant code paths are explicit and short: `isValidShortcutName(_:)`, `runtimeWarn`, `Name.init(_:)`, and `userDefaultsKey(forRawValue:)` directly answer all four questions. [1][2][3]

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | code | `Sources/KeyboardShortcuts/KeyboardShortcuts.swift` | `main` / current upstream implementation used for v2.4.0 behavior | Governs key format, persistence, and read/write behavior | [file](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/KeyboardShortcuts.swift) |
| [2] | code | `Sources/KeyboardShortcuts/Utilities.swift` | `main` / current upstream implementation used for v2.4.0 behavior | Defines `runtimeWarn` and `isValidShortcutName(_:)` | [file](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/Utilities.swift) |
| [3] | code | `Sources/KeyboardShortcuts/Name.swift` | `main` / current upstream implementation used for v2.4.0 behavior | Shows the warning call and the documented reason for the dot restriction | [file](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/Name.swift) |

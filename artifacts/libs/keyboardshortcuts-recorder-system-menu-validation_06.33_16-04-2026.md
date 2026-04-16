## Findings: KeyboardShortcuts `Recorder` and system menu-item shortcut validation

### Research Metadata
- Question: In `KeyboardShortcuts` v2.4.0, does `Recorder` block system-reserved menu shortcuts like `Cmd+V`, can that validation be disabled, and what public API/configuration controls it?
- Type: CONCEPTUAL
- Target: sindresorhus/KeyboardShortcuts 2.4.0
- Version Scope: Upstream `main` source/docs used as evidence for the 2.4.0 API surface
- Generated: 06.33_16-04-2026
- Coverage: PARTIAL

### Direct Answer
- Fact: I did not find any public API, configuration flag, or documented option in `KeyboardShortcuts` 2.4.0 that disables a built-in “system menu item shortcut” validation in `Recorder`. The public `Recorder` API is for choosing and storing a shortcut, and the inspected source/docs do not expose a bypass for allowing reserved app-menu combinations like `Cmd+V`. [1][2][3]
- Fact: The library’s documented validation is about shortcut-name strings containing `.` (used as key paths for observation), not about key-combination conflicts with menu items. The source I inspected shows `isValidShortcutName(_:)` only checks for dots, and `Name.init` merely warns; it does not enforce or configure menu-shortcut conflict policy. [3][4]
- Synthesis: If you need to permit `Cmd+V`-style assignments, `KeyboardShortcuts` does not appear to provide a supported toggle for that in 2.4.0; you would need either a different recording layer or custom shortcut UI/validation outside this package. [1][2][3][4]

### Key Findings
#### Recorder API surface does not expose a menu-shortcut bypass

**Claim**: The public recorder initializers expose `name`, `shortcut`, and `onChange`, but no validation-policy knob for allowing system menu items. [1][2]

**Evidence** ([Recorder.swift#L136-L163](https://raw.githubusercontent.com/sindresorhus/KeyboardShortcuts/main/Sources/KeyboardShortcuts/Recorder.swift#L136-L163) [1]):
```swift
public required init(
	for name: Name,
	onChange: ((_ shortcut: Shortcut?) -> Void)? = nil
)

public required init(
	shortcut: Shortcut?,
	onChange: ((_ shortcut: Shortcut?) -> Void)? = nil
)

public init(
	for name: KeyboardShortcuts.Name,
	onChange: ((KeyboardShortcuts.Shortcut?) -> Void)? = nil
)

public init(
	shortcut: Binding<KeyboardShortcuts.Shortcut?>,
	onChange: ((KeyboardShortcuts.Shortcut?) -> Void)? = nil
)
```

**Explanation**: These signatures show the recorder’s configuration surface. None of the public initializers accept a policy object, validation callback, or “allow system shortcuts” option. [1]

#### The documented validation is for shortcut names, not menu-item conflicts

**Claim**: The only explicit validation I found in the package source is the shortcut-name dot check; it does not mention menu items or reserved key equivalents. [3][4]

**Evidence** ([Utilities.swift#L360-L367](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/Utilities.swift#L360-L367) [3]):
```swift
extension KeyboardShortcuts {
	nonisolated static func isValidShortcutName(_ name: String) -> Bool {
		!name.contains(".")
	}
}
```

**Evidence** ([Name.swift#L22-L47](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/Name.swift#L22-L47) [4]):
```swift
nonisolated
public init(_ name: String, initial initialShortcut: Shortcut? = nil) {
	runtimeWarn(
		KeyboardShortcuts.isValidShortcutName(name),
		"The keyboard shortcut name must not contain a dot (.)."
	)

	self.rawValue = name
	self.initialShortcut = initialShortcut
```

**Explanation**: This validation is about the shortcut identifier string, not the assigned key combination. The source does not show any parallel check for reserved menu-item equivalents such as `Cmd+V`. [3][4]

#### No documented switch to disable shortcut validation

**Claim**: The public docs/examples show `Recorder` plus `onKeyUp`/`onKeyDown` registration, but not any API to disable validation or opt into overriding menu item shortcuts. [2]

**Evidence** ([readme.md#L13-L20](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/readme.md#L13-L20) [2]):
```swift
KeyboardShortcuts.Recorder("Toggle Unicorn Mode:", name: .toggleUnicornMode)

KeyboardShortcuts.onKeyUp(for: .toggleUnicornMode) { [self] in
	isUnicornMode.toggle()
}
```

**Explanation**: The README presents recording and handling as separate steps, and does not document a validation override. The package’s public surface in the inspected source likewise lacks a disable/allow option. [1][2][3][4]

### Execution Trace
| Step | Symbol / Artifact | What happens here | Source IDs |
|------|-------------------|-------------------|------------|
| 1 | `KeyboardShortcuts.Recorder` | Presents shortcut-recording UI with storage/callback options | [1][2] |
| 2 | `KeyboardShortcuts.Name.init(_:)` | Validates only that the name string contains no dot | [3][4] |
| 3 | `KeyboardShortcuts.setShortcut(_:for:)` | Persists the chosen shortcut | [3][4] |
| 4 | Public API surface | No exposed flag/callback is present to disable or relax menu-shortcut validation | [1][2][3][4] |

### Caveats and Gaps
- I did not find a source statement explicitly saying “`Cmd+V` is blocked because it conflicts with a system menu item.” The conclusion is therefore negative evidence: the public source/docs do not expose a bypass or configuration option for such validation. [1][2][3][4]
- If a menu-shortcut restriction exists, it is likely inside recorder UI internals not surfaced by public API; that would require deeper source inspection of the recorder implementation or a runtime test to confirm. [1][2]

### Confidence
**Level:** MEDIUM
**Rationale:** The public API is clearly visible and shows no control for disabling validation, but I did not locate an explicit source line that names system-menu-item shortcut rejection as a feature. The answer is strongest on “no public bypass exposed,” weaker on the exact internal enforcement mechanism. [1][2][3][4]

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | code | `Sources/KeyboardShortcuts/Recorder.swift` | `main` | Public recorder initializer surface | [raw source](https://raw.githubusercontent.com/sindresorhus/KeyboardShortcuts/main/Sources/KeyboardShortcuts/Recorder.swift) |
| [2] | docs | `readme.md` | `main` | Public examples show intended API usage | [file](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/readme.md) |
| [3] | code | `Sources/KeyboardShortcuts/Utilities.swift` | `main` | Governs the only explicit validation found | [file](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/Utilities.swift) |
| [4] | code | `Sources/KeyboardShortcuts/Name.swift` | `main` | Shows validation is warning-only and name-related | [file](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/Sources/KeyboardShortcuts/Name.swift) |

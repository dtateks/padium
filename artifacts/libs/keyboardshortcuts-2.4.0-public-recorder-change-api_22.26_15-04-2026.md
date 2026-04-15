## Findings: KeyboardShortcuts 2.4.0 / public recorder change API

### Research Metadata
- Question: What is the best public integration pattern to react immediately when a `KeyboardShortcuts.Recorder` changes or clears a binding, without using private notifications or broad `UserDefaults` observation?
- Type: CONCEPTUAL
- Target: sindresorhus/KeyboardShortcuts 2.4.0
- Version Scope: Upstream `main` source for the 2.4.0-era API surface, verified from current package source and README
- Generated: 22.26_15-04-2026
- Coverage: COMPLETE

### Direct Answer
- Fact: Yes — the public API exposes `KeyboardShortcuts.Recorder(..., onChange: ((KeyboardShortcuts.Shortcut?) -> Void)? = nil)` in both SwiftUI and AppKit forms, and it also exposes a binding-based initializer `KeyboardShortcuts.Recorder(shortcut: Binding<KeyboardShortcuts.Shortcut?>, onChange: ...)` for app-managed storage. [1][2]
- Fact: For Padium’s settings rows, the best public pattern is to switch each row to the binding-based recorder and update runtime slot activity from the row’s `Binding<KeyboardShortcuts.Shortcut?>` / `onChange` callback, scoped per row. [2]
- Fact: If Padium keeps built-in `name` storage, the public `onChange` closure on `Recorder(..., name:, onChange:)` is still the supported immediate hook for that row; the library’s SwiftUI wrapper forwards user edits and clears through that closure. [1]

### Key Findings
#### Public recorder signatures

**Claim**: The public SwiftUI recorder has an `onChange` callback, and the binding form is public too. [1]

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

**Explanation**: This is the public hook Padium can use without relying on internal notifications. The binding initializer is the cleanest option when the app wants immediate row-local updates from the recorder itself. [1]

#### AppKit recorder signatures

**Claim**: The AppKit recorder exposes the same public `onChange` shape. [2]

**Evidence** ([RecorderCocoa.swift#L125-L155](https://raw.githubusercontent.com/sindresorhus/KeyboardShortcuts/main/Sources/KeyboardShortcuts/RecorderCocoa.swift#L125-L155) [2]):
```swift
public required init(
	for name: Name,
	onChange: ((_ shortcut: Shortcut?) -> Void)? = nil
)

public required init(
	shortcut: Shortcut?,
	onChange: ((_ shortcut: Shortcut?) -> Void)? = nil
)
```

**Explanation**: Both UI front ends provide the same callback semantics, so the recommended integration does not depend on SwiftUI versus AppKit. [2]

#### Library-owned update path

**Claim**: The SwiftUI wrapper already forwards recorder edits to `onChange`, and the binding form updates the bound value directly. [1]

**Evidence** ([Recorder.swift#L13-L41](https://raw.githubusercontent.com/sindresorhus/KeyboardShortcuts/main/Sources/KeyboardShortcuts/Recorder.swift#L13-L41) [1]):
```swift
final class Coordinator {
	var shortcutBinding: Binding<Shortcut?>?
	var onChange: ((_ shortcut: Shortcut?) -> Void)?

	func handleChange(_ shortcut: Shortcut?) {
		shortcutBinding?.wrappedValue = shortcut
		onChange?(shortcut)
	}
}
```

**Explanation**: The public SwiftUI recorder is already structured to propagate changes into a `Binding<Shortcut?>` and/or a callback, which is exactly the scoped signal Padium needs for each settings row. [1]

### Recommended integration pattern
| Need | Public API | Recommendation |
|------|------------|----------------|
| App owns per-slot shortcut state | `KeyboardShortcuts.Recorder("…", shortcut: $slotShortcut, onChange: ...)` | Use one `@State` / model binding per row and update runtime active slots from the callback. |
| App uses built-in `KeyboardShortcuts.Name` storage | `KeyboardShortcuts.Recorder("…", name: slotName, onChange: ...)` | Keep built-in storage, but treat `onChange` as the row-local immediate refresh trigger. |
| AppKit row | `KeyboardShortcuts.RecorderCocoa(for:onChange:)` or `shortcut:onChange:` | Use the same per-row callback pattern in AppKit settings views. |

### Caveats and Gaps
- The public API gives row-local callbacks, not a separate per-name observer type. That means Padium should wire the callback where the recorder is created, instead of listening globally. [1][2]
- The callback only fires for user edits made through the recorder; if shortcut state changes outside the recorder, Padium still needs a separate source of truth for those writes. [1][2]

### Confidence
**Level:** HIGH
**Rationale:** The public SwiftUI and AppKit source both expose `onChange` on the recorder initializers, and the SwiftUI implementation forwards changes directly through that callback and/or binding. [1][2]

### Source Register
| ID | Kind | Source | Version / Ref | Why kept | URL |
|----|------|--------|---------------|----------|-----|
| [1] | code | `Sources/KeyboardShortcuts/Recorder.swift` | `main` | Shows public SwiftUI recorder initializers and binding/callback plumbing | [raw source](https://raw.githubusercontent.com/sindresorhus/KeyboardShortcuts/main/Sources/KeyboardShortcuts/Recorder.swift) |
| [2] | code | `Sources/KeyboardShortcuts/RecorderCocoa.swift` | `main` | Shows public AppKit recorder initializers with `onChange` | [raw source](https://raw.githubusercontent.com/sindresorhus/KeyboardShortcuts/main/Sources/KeyboardShortcuts/RecorderCocoa.swift) |

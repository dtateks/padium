import Foundation
import KeyboardShortcuts

// Single mapping surface for gesture-slot → KeyboardShortcuts.Name.
// All raw Name definitions live here; no other file creates Names ad hoc.
// Persistence is owned by KeyboardShortcuts via UserDefaults.
struct ShortcutRegistry: Sendable {
    static func name(for slot: GestureSlot) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("gesture.\(slot.rawValue)")
    }

    /// Per-slot UserDefaults key that records whether the bound shortcut
    /// also requires the Fn (globe) modifier. `KeyboardShortcuts.Shortcut`
    /// stores only Carbon modifiers (⌘⌥⌃⇧) and silently drops Fn, so
    /// Padium persists the bit alongside it for emission.
    static func fnUserDefaultsKey(for slot: GestureSlot) -> String {
        "padium.shortcut.fn.\(slot.rawValue)"
    }

    /// Read the persisted Fn modifier flag for a slot. Defaults to false.
    static func fnModifier(for slot: GestureSlot) -> Bool {
        UserDefaults.standard.bool(forKey: fnUserDefaultsKey(for: slot))
    }

    /// Persist the Fn modifier flag for a slot. Removes the key when
    /// false so absence and `false` collapse to the same observed state.
    static func setFnModifier(_ value: Bool, for slot: GestureSlot) {
        let key = fnUserDefaultsKey(for: slot)
        if value {
            UserDefaults.standard.set(true, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

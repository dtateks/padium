import Foundation
import KeyboardShortcuts

// Single mapping surface for gesture-slot → KeyboardShortcuts.Name.
// All raw Name definitions live here; no other file creates Names ad hoc.
// Persistence is owned by KeyboardShortcuts via UserDefaults.
struct ShortcutRegistry: Sendable {
    static func name(for slot: GestureSlot) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("gesture.\(slot.rawValue)")
    }
}

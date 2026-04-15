import AppKit
import KeyboardShortcuts

// Abstraction over the actual key-event posting mechanism.
// Exists so tests can inject a fake sender without requiring a real CGEvent session.
protocol ShortcutSending: AnyObject {
    func send(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool
}

// Posts a CGEvent key-down + key-up pair for the given shortcut.
// Requires Accessibility permission for synthetic events to reach other apps.
final class CGEventShortcutSender: ShortcutSending {
    func send(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        let keyCode = CGKeyCode(shortcut.carbonKeyCode)
        let flags = CGEventFlags(shortcut.modifiers)
        guard
            let src = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}

// Looks up the configured shortcut for a gesture slot and posts it.
// Returns false without crashing when the slot has no shortcut bound.
@MainActor
final class ShortcutEmitter {
    private let sender: any ShortcutSending

    init(sender: any ShortcutSending = CGEventShortcutSender()) {
        self.sender = sender
    }

    @discardableResult
    func emitConfiguredShortcut(for slot: GestureSlot) -> Bool {
        let name = ShortcutRegistry.name(for: slot)
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else {
            return false
        }
        return sender.send(shortcut)
    }
}

private extension CGEventFlags {
    init(_ modifiers: NSEvent.ModifierFlags) {
        self.init()
        if modifiers.contains(.command) { insert(.maskCommand) }
        if modifiers.contains(.shift) { insert(.maskShift) }
        if modifiers.contains(.option) { insert(.maskAlternate) }
        if modifiers.contains(.control) { insert(.maskControl) }
    }
}

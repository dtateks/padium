import AppKit
import Carbon
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
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            return false
        }

        for step in ShortcutEventSequence.steps(for: shortcut) {
            guard let event = CGEvent(
                keyboardEventSource: src,
                virtualKey: step.keyCode,
                keyDown: step.isKeyDown
            ) else {
                return false
            }

            event.flags = step.flags
            event.post(tap: .cghidEventTap)
        }

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

struct ShortcutEventStep: Equatable, Sendable {
    let keyCode: CGKeyCode
    let isKeyDown: Bool
    let flags: CGEventFlags
}

enum ShortcutEventSequence {
    static func steps(for shortcut: KeyboardShortcuts.Shortcut) -> [ShortcutEventStep] {
        let modifiers = modifierDescriptors(for: shortcut.modifiers)
        let fullFlags = CGEventFlags(shortcut.modifiers)
        let keyCode = CGKeyCode(shortcut.carbonKeyCode)

        var steps: [ShortcutEventStep] = []
        var activeFlags = CGEventFlags()

        for modifier in modifiers {
            activeFlags.insert(modifier.flag)
            steps.append(ShortcutEventStep(keyCode: modifier.keyCode, isKeyDown: true, flags: activeFlags))
        }

        steps.append(ShortcutEventStep(keyCode: keyCode, isKeyDown: true, flags: fullFlags))
        steps.append(ShortcutEventStep(keyCode: keyCode, isKeyDown: false, flags: fullFlags))

        for modifier in modifiers.reversed() {
            activeFlags.remove(modifier.flag)
            steps.append(ShortcutEventStep(keyCode: modifier.keyCode, isKeyDown: false, flags: activeFlags))
        }

        return steps
    }

    private static func modifierDescriptors(for modifiers: NSEvent.ModifierFlags) -> [ModifierDescriptor] {
        var descriptors: [ModifierDescriptor] = []

        if modifiers.contains(.command) {
            descriptors.append(ModifierDescriptor(keyCode: CGKeyCode(kVK_Command), flag: .maskCommand))
        }
        if modifiers.contains(.shift) {
            descriptors.append(ModifierDescriptor(keyCode: CGKeyCode(kVK_Shift), flag: .maskShift))
        }
        if modifiers.contains(.option) {
            descriptors.append(ModifierDescriptor(keyCode: CGKeyCode(kVK_Option), flag: .maskAlternate))
        }
        if modifiers.contains(.control) {
            descriptors.append(ModifierDescriptor(keyCode: CGKeyCode(kVK_Control), flag: .maskControl))
        }

        return descriptors
    }

    private struct ModifierDescriptor {
        let keyCode: CGKeyCode
        let flag: CGEventFlags
    }
}

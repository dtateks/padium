import AppKit
import Carbon
import KeyboardShortcuts

@MainActor
protocol ShortcutEmitting: AnyObject {
    @discardableResult func emitConfiguredShortcut(for slot: GestureSlot) -> Bool
}

// Abstraction over the actual key-event posting mechanism.
// Exists so tests can inject a fake sender without requiring a real CGEvent session.
protocol ShortcutSending: AnyObject {
    func send(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool
}

// Posts a CGEvent key-down + key-up pair for the given shortcut.
// Requires Accessibility permission for synthetic events to reach other apps.
final class CGEventShortcutSender: ShortcutSending {
    private let stepPerformer: ((ShortcutEventStep) -> Bool)?

    init(stepPerformer: ((ShortcutEventStep) -> Bool)? = nil) {
        self.stepPerformer = stepPerformer
    }

    func send(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        let performStep: (ShortcutEventStep) -> Bool
        if let stepPerformer {
            performStep = stepPerformer
        } else {
            guard let src = CGEventSource(stateID: .hidSystemState) else {
                return false
            }

            performStep = { step in
                guard let event = CGEvent(
                    keyboardEventSource: src,
                    virtualKey: step.keyCode,
                    keyDown: step.isKeyDown
                ) else {
                    return false
                }

                event.flags = step.flags
                event.post(tap: .cghidEventTap)
                return true
            }
        }

        var activeModifierKeyCodes: [CGKeyCode] = []

        for step in ShortcutEventSequence.steps(for: shortcut) {
            guard performStep(step) else {
                releaseActiveModifiers(activeModifierKeyCodes: activeModifierKeyCodes, performStep: performStep)
                return false
            }

            guard modifierFlag(for: step.keyCode) != nil else {
                continue
            }

            if step.isKeyDown {
                activeModifierKeyCodes.append(step.keyCode)
            } else {
                activeModifierKeyCodes.removeAll { keyCode in
                    keyCode == step.keyCode
                }
            }

        }

        return true
    }

    private func releaseActiveModifiers(
        activeModifierKeyCodes: [CGKeyCode],
        performStep: (ShortcutEventStep) -> Bool
    ) {
        var remainingActiveModifierKeyCodes = activeModifierKeyCodes

        for keyCode in activeModifierKeyCodes.reversed() {
            guard modifierFlag(for: keyCode) != nil else {
                continue
            }

            remainingActiveModifierKeyCodes.removeAll { value in
                value == keyCode
            }

            let flags = remainingActiveModifierKeyCodes.reduce(into: CGEventFlags()) { partialResult, code in
                if let flag = modifierFlag(for: code) {
                    partialResult.insert(flag)
                }
            }

            _ = performStep(ShortcutEventStep(keyCode: keyCode, isKeyDown: false, flags: flags))
        }
    }

    private func modifierFlag(for keyCode: CGKeyCode) -> CGEventFlags? {
        switch keyCode {
        case CGKeyCode(kVK_Command):
            return .maskCommand
        case CGKeyCode(kVK_Shift):
            return .maskShift
        case CGKeyCode(kVK_Option):
            return .maskAlternate
        case CGKeyCode(kVK_Control):
            return .maskControl
        default:
            return nil
        }
    }
}

// Looks up the configured shortcut for a gesture slot and posts it.
// Returns false without crashing when the slot has no shortcut bound.
@MainActor
final class ShortcutEmitter: ShortcutEmitting {
    private let sender: any ShortcutSending

    init(sender: any ShortcutSending = CGEventShortcutSender()) {
        self.sender = sender
    }

    @discardableResult
    func emitConfiguredShortcut(for slot: GestureSlot) -> Bool {
        let name = ShortcutRegistry.name(for: slot)
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else {
            PadiumLogger.shortcut.notice(
                "TAP-DIAG: shortcut lookup missing slot=\(slot.rawValue, privacy: .public) frontmost=\(frontmostBundleIdentifier, privacy: .public) appActive=\(NSApp.isActive)"
            )
            return false
        }
        PadiumLogger.shortcut.notice(
            "TAP-DIAG: shortcut lookup slot=\(slot.rawValue, privacy: .public) keyCode=\(shortcut.carbonKeyCode) modifiers=\(shortcut.carbonModifiers) frontmost=\(frontmostBundleIdentifier, privacy: .public) appActive=\(NSApp.isActive)"
        )
        return sender.send(shortcut)
    }
}


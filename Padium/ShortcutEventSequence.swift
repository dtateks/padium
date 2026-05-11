import AppKit
import Carbon
import KeyboardShortcuts

/// One unit of work in the synthetic key-event stream that posts a shortcut:
/// a single key-down or key-up `CGEvent` with the modifier flags that should
/// be active when it fires.
struct ShortcutEventStep: Equatable, Sendable {
    let keyCode: CGKeyCode
    let isKeyDown: Bool
    let flags: CGEventFlags
}

/// Pure step-sequence math for shortcut emission. Given a
/// `KeyboardShortcuts.Shortcut`, returns the ordered list of key-down /
/// key-up events that posts the chord with explicit modifier transitions
/// before and after the main key — required so AppKit / Carbon receive
/// the same flag-bracketed sequence that a real keystroke produces, not
/// a `.cgAnnotatedSessionEventTap`-style aggregated flag mask that some
/// frontmost apps (notably AppKit text editors) interpret incorrectly.
///
/// Stays separate from `CGEventShortcutSender` because the step generation
/// is a pure function — no `CGEventSource`, no event posting, no system
/// state. Tests in `ShortcutEmitterTests` exercise this directly via
/// `ShortcutEventSequence.steps(for:)`.
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

private extension CGEventFlags {
    init(_ modifiers: NSEvent.ModifierFlags) {
        self.init()
        if modifiers.contains(.command) { insert(.maskCommand) }
        if modifiers.contains(.shift) { insert(.maskShift) }
        if modifiers.contains(.option) { insert(.maskAlternate) }
        if modifiers.contains(.control) { insert(.maskControl) }
    }
}

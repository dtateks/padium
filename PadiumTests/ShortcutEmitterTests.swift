import Testing
@testable import Padium
import Carbon
import KeyboardShortcuts

// A test double that records whether a shortcut send was attempted.
final class RecordingShortcutSender: ShortcutSending, @unchecked Sendable {
    private(set) var sentShortcuts: [KeyboardShortcuts.Shortcut] = []

    func send(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        sentShortcuts.append(shortcut)
        return true
    }
}

struct ShortcutEmitterTests {
    // An unbound slot must return false without crashing or mutating state.
    @Test @MainActor func unboundSlotReturnsFalse() {
        let sender = RecordingShortcutSender()
        let emitter = ShortcutEmitter(sender: sender)
        // Ensure the slot has no shortcut bound (cleared in test suite).
        KeyboardShortcuts.setShortcut(nil, for: ShortcutRegistry.name(for: .fourFingerSwipeDown))
        let result = emitter.emitConfiguredShortcut(for: .fourFingerSwipeDown)
        #expect(result == false)
        #expect(sender.sentShortcuts.isEmpty)
    }

    // A bound slot must call the sender and return true.
    @Test @MainActor func boundSlotReturnsTrueAndCallsSender() {
        let sender = RecordingShortcutSender()
        let emitter = ShortcutEmitter(sender: sender)
        let name = ShortcutRegistry.name(for: .threeFingerSwipeLeft)
        let shortcut = KeyboardShortcuts.Shortcut(.f13, modifiers: [])
        KeyboardShortcuts.setShortcut(shortcut, for: name)
        defer { KeyboardShortcuts.setShortcut(nil, for: name) }
        let result = emitter.emitConfiguredShortcut(for: .threeFingerSwipeLeft)
        #expect(result == true)
        #expect(sender.sentShortcuts.count == 1)
    }

    // Calling emit for every slot with no bound shortcuts must never crash.
    @Test @MainActor func allUnboundSlotsDoNotCrash() {
        let sender = RecordingShortcutSender()
        let emitter = ShortcutEmitter(sender: sender)
        for slot in GestureSlot.allCases {
            KeyboardShortcuts.setShortcut(nil, for: ShortcutRegistry.name(for: slot))
        }
        for slot in GestureSlot.allCases {
            let result = emitter.emitConfiguredShortcut(for: slot)
            #expect(result == false)
        }
        #expect(sender.sentShortcuts.isEmpty)
    }

    @Test func shortcutEventSequenceWrapsMainKeyWithModifierTransitions() {
        let shortcut = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .shift])
        let steps = ShortcutEventSequence.steps(for: shortcut)

        #expect(steps.map(\.keyCode) == [
            CGKeyCode(kVK_Command),
            CGKeyCode(kVK_Shift),
            CGKeyCode(shortcut.carbonKeyCode),
            CGKeyCode(shortcut.carbonKeyCode),
            CGKeyCode(kVK_Shift),
            CGKeyCode(kVK_Command)
        ])
        #expect(steps.map(\.isKeyDown) == [true, true, true, false, false, false])
    }

    @Test func shortcutEventSequenceWithoutModifiersUsesMainKeyOnly() {
        let shortcut = KeyboardShortcuts.Shortcut(.f13, modifiers: [])
        let steps = ShortcutEventSequence.steps(for: shortcut)

        #expect(steps == [
            ShortcutEventStep(keyCode: CGKeyCode(shortcut.carbonKeyCode), isKeyDown: true, flags: []),
            ShortcutEventStep(keyCode: CGKeyCode(shortcut.carbonKeyCode), isKeyDown: false, flags: [])
        ])
    }
}

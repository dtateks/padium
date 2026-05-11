import Testing
@testable import Padium
import Foundation
import KeyboardShortcuts

@MainActor
struct ShortcutHotKeyGuardTests {

    @Test func shortcutHotKeyGuardKeepsRecordedShortcutFromBecomingActiveHotKey() {
        let preservedConfig = GestureConfigurationPreserver()
        defer { _ = preservedConfig }

        let slot = GestureSlot.threeFingerSwipeLeft
        let name = ShortcutRegistry.name(for: slot)
        let shortcut = KeyboardShortcuts.Shortcut(.f13, modifiers: [])

        ShortcutHotKeyGuard.install()

        // Recorder flow performs setShortcut → register → notification.
        KeyboardShortcuts.setShortcut(shortcut, for: name)

        // After the guard runs, the shortcut must still be persisted...
        #expect(KeyboardShortcuts.getShortcut(for: name) == shortcut)
        // ...but must NOT be an active global hotkey, or else Padium-frontmost
        // emissions of this chord would be swallowed until quit+reopen.
        #expect(KeyboardShortcuts.isEnabled(for: name) == false)
    }

    @Test func shortcutHotKeyGuardDisablesPreExistingStoredShortcuts() {
        let preservedConfig = GestureConfigurationPreserver()
        defer { _ = preservedConfig }

        let slot = GestureSlot.threeFingerSwipeRight
        let name = ShortcutRegistry.name(for: slot)
        let shortcut = KeyboardShortcuts.Shortcut(.f14, modifiers: [.command])
        KeyboardShortcuts.setShortcut(shortcut, for: name)

        // Force a registered hotkey before the guard sees it.
        KeyboardShortcuts.onKeyDown(for: name) {}
        defer { KeyboardShortcuts.removeHandler(for: name) }

        ShortcutHotKeyGuard.disableAllRegisteredGestureShortcuts()

        #expect(KeyboardShortcuts.getShortcut(for: name) == shortcut)
        #expect(KeyboardShortcuts.isEnabled(for: name) == false)
    }
}

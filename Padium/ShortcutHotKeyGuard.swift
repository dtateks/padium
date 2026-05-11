import Foundation
import KeyboardShortcuts

/// Keeps the `KeyboardShortcuts` package from ever registering a Carbon
/// hotkey for any gesture-bound shortcut.
///
/// Padium uses `KeyboardShortcuts` only as a UI recorder and persistent
/// storage for each gesture's shortcut. It never wants those shortcuts to
/// live as active global hotkeys. When they do, two things go wrong:
///
/// 1. The hotkey is owned by Padium's own Carbon event dispatcher, so any
///    real physical press of that chord is swallowed inside Padium instead
///    of reaching the user's app.
/// 2. Padium's own synthetic `CGEvent` chord (emitted by `ShortcutEmitter`)
///    is posted into the HID event stream while Padium is frontmost; the
///    registered Carbon hotkey intercepts it and the target app never sees
///    the shortcut — the user then has to quit/reopen Padium to clear the
///    hotkey registration and recover the expected behaviour.
///
/// The guard walks every `GestureSlot` at startup and explicitly calls
/// `KeyboardShortcuts.disable(...)` on each so any shortcut that was
/// written during a prior run never becomes an active hotkey. It then
/// watches for any new writes the Recorder performs via `setShortcut`:
/// those writes call `register(...)` unconditionally before posting the
/// change notification, so after each change we immediately disable the
/// just-registered name by name.
@MainActor
enum ShortcutHotKeyGuard {
    private static var isInstalled = false
    private static var observer: NSObjectProtocol?

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        disableAllRegisteredGestureShortcuts()

        observer = NotificationCenter.default.addObserver(
            forName: PadiumNotification.keyboardShortcutDidChange,
            object: nil,
            queue: nil
        ) { notification in
            let rawName = (notification.userInfo?["name"] as? KeyboardShortcuts.Name)?.rawValue
            MainActor.assumeIsolated {
                handleShortcutChange(changedRawName: rawName)
            }
        }
    }

    static func disableAllRegisteredGestureShortcuts() {
        // Drop any legacy handlers Padium might have accumulated (we don't
        // use them) and explicitly disable every gesture name so each
        // configured shortcut is stripped from the Carbon hotkey registry.
        KeyboardShortcuts.removeAllHandlers()
        KeyboardShortcuts.disable(allGestureShortcutNames)
    }

    private static func handleShortcutChange(changedRawName: String?) {
        // Recorder writes call `register(_:)` before notifying, which re-adds
        // the hotkey. Immediately remove it again so the user's configured
        // chord never lives as an active global hotkey inside Padium.
        if let changedRawName {
            KeyboardShortcuts.disable([KeyboardShortcuts.Name(changedRawName)])
            return
        }

        KeyboardShortcuts.disable(allGestureShortcutNames)
    }

    private static var allGestureShortcutNames: [KeyboardShortcuts.Name] {
        GestureSlot.allCases.map(ShortcutRegistry.name(for:))
    }
}

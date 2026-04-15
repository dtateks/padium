import AppKit
import Foundation

/// Saves, disables, and restores macOS system trackpad gesture preferences.
///
/// On `suppress()`: reads current values, backs them up to UserDefaults, writes 0 to each
/// trackpad gesture key and false to Dock gesture keys, then restarts the Dock.
/// On `restore()`: writes back the saved values and restarts the Dock.
///
/// Backup is persisted so that even after a crash the next launch can restore original settings.
@MainActor
final class SystemGestureManager {

    static let shared = SystemGestureManager()

    private let trackpadDomain = "com.apple.AppleMultitouchTrackpad"
    private let dockDomain = "com.apple.dock"
    private let backupKey = "padium.systemGestureBackup"

    private let trackpadKeys = [
        "TrackpadThreeFingerHorizSwipeGesture",
        "TrackpadThreeFingerVertSwipeGesture",
        "TrackpadFourFingerHorizSwipeGesture",
        "TrackpadFourFingerVertSwipeGesture",
    ]

    private let dockBoolKeys = [
        "showMissionControlGestureEnabled",
        "showAppExposeGestureEnabled",
    ]

    private(set) var isSuppressed = false

    // MARK: - Public

    /// Disable all system trackpad gestures that conflict with Padium.
    /// Saves original values first so they can be restored.
    func suppress() {
        saveBackup()
        writeDisabledValues()
        restartDock()
        isSuppressed = true
        PadiumLogger.gesture.info("System gestures suppressed")
    }

    /// Restore original system trackpad gesture settings.
    func restore() {
        guard let backup = loadBackup() else {
            PadiumLogger.gesture.warning("No system gesture backup found; skipping restore")
            return
        }
        writeRestoredValues(backup)
        clearBackup()
        restartDock()
        isSuppressed = false
        PadiumLogger.gesture.info("System gestures restored")
    }

    /// If a backup exists from a previous session (crash recovery), restore it.
    func restoreIfNeeded() {
        guard loadBackup() != nil else { return }
        PadiumLogger.gesture.notice("Found stale system gesture backup from previous session; restoring")
        restore()
    }

    // MARK: - Backup persistence

    private func saveBackup() {
        var backup: [String: Any] = [:]

        let trackpadPrefs = UserDefaults.standard.persistentDomain(forName: trackpadDomain) ?? [:]
        for key in trackpadKeys {
            backup["trackpad.\(key)"] = trackpadPrefs[key] as? Int ?? 0
        }

        let dockPrefs = UserDefaults.standard.persistentDomain(forName: dockDomain) ?? [:]
        for key in dockBoolKeys {
            backup["dock.\(key)"] = dockPrefs[key] as? Bool ?? true
        }

        UserDefaults.standard.set(backup, forKey: backupKey)
    }

    private func loadBackup() -> [String: Any]? {
        UserDefaults.standard.dictionary(forKey: backupKey)
    }

    private func clearBackup() {
        UserDefaults.standard.removeObject(forKey: backupKey)
    }

    // MARK: - Write preferences

    private func writeDisabledValues() {
        for key in trackpadKeys {
            shellDefaults(write: trackpadDomain, key: key, value: "-int 0")
        }
        for key in dockBoolKeys {
            shellDefaults(write: dockDomain, key: key, value: "-bool false")
        }
    }

    private func writeRestoredValues(_ backup: [String: Any]) {
        for key in trackpadKeys {
            let value = backup["trackpad.\(key)"] as? Int ?? 0
            shellDefaults(write: trackpadDomain, key: key, value: "-int \(value)")
        }
        for key in dockBoolKeys {
            let value = backup["dock.\(key)"] as? Bool ?? true
            shellDefaults(write: dockDomain, key: key, value: "-bool \(value ? "true" : "false")")
        }
    }

    // MARK: - Shell helpers

    /// Uses `defaults write` because `UserDefaults.setPersistentDomain` for system domains
    /// does not reliably propagate to the running Dock/WindowServer on modern macOS.
    private func shellDefaults(write domain: String, key: String, value: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", domain, key] + value.split(separator: " ").map(String.init)
        try? task.run()
        task.waitUntilExit()
    }

    private func restartDock() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        try? task.run()
        task.waitUntilExit()
    }
}

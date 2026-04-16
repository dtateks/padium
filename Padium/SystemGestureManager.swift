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

    private static let trackpadKeys = [
        "TrackpadTwoFingerDoubleTapGesture",
        "TrackpadThreeFingerHorizSwipeGesture",
        "TrackpadThreeFingerVertSwipeGesture",
        "TrackpadFourFingerHorizSwipeGesture",
        "TrackpadFourFingerVertSwipeGesture",
    ]

    private static let verticalTrackpadKeys: Set<String> = [
        "TrackpadThreeFingerVertSwipeGesture",
        "TrackpadFourFingerVertSwipeGesture",
    ]

    private static let dockBoolKeys = [
        "showMissionControlGestureEnabled",
        "showAppExposeGestureEnabled",
    ]

    private(set) var isSuppressed = false

    // MARK: - Public

    /// Disable only the system gestures that conflict with configured Padium slots.
    /// Saves original values first so they can be restored.
    func suppress(conflictingSettings: [SystemGestureSetting], allSettings: [SystemGestureSetting]) {
        let disabledPreferenceKeys = Self.disabledPreferenceKeys(for: conflictingSettings, allSettings: allSettings)
        guard !disabledPreferenceKeys.trackpadKeys.isEmpty || !disabledPreferenceKeys.dockKeys.isEmpty else {
            isSuppressed = false
            return
        }

        saveBackup()
        writeDisabledValues(trackpadKeys: disabledPreferenceKeys.trackpadKeys, dockKeys: disabledPreferenceKeys.dockKeys)
        restartDock()
        isSuppressed = true
        PadiumLogger.gesture.info("System gestures suppressed")
    }

    /// Restore original system trackpad gesture settings.
    func restore() {
        guard let backup = loadBackup() else {
            isSuppressed = false
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
        for key in Self.trackpadKeys {
            backup["trackpad.\(key)"] = trackpadPrefs[key] as? Int ?? 0
        }

        let dockPrefs = UserDefaults.standard.persistentDomain(forName: dockDomain) ?? [:]
        for key in Self.dockBoolKeys {
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

    private func writeDisabledValues(trackpadKeys: Set<String>, dockKeys: Set<String>) {
        for key in trackpadKeys {
            shellDefaults(write: trackpadDomain, key: key, value: "-int 0")
        }
        for key in dockKeys {
            shellDefaults(write: dockDomain, key: key, value: "-bool false")
        }
    }

    private func writeRestoredValues(_ backup: [String: Any]) {
        for key in Self.trackpadKeys {
            let value = backup["trackpad.\(key)"] as? Int ?? 0
            shellDefaults(write: trackpadDomain, key: key, value: "-int \(value)")
        }
        for key in Self.dockBoolKeys {
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

    static func disabledPreferenceKeys(
        for conflictingSettings: [SystemGestureSetting],
        allSettings: [SystemGestureSetting]
    ) -> (trackpadKeys: Set<String>, dockKeys: Set<String>) {
        let trackpadKeys = Set(conflictingSettings.map(\.key))

        // Only disable Dock gesture keys (Mission Control / App Exposé) when ALL
        // enabled vertical system gestures are being suppressed. The Dock keys are
        // global — they control gestures for every finger count. If only one
        // finger-count variant is configured in Padium, leave Dock keys alone so
        // the other variant still triggers Mission Control / App Exposé.
        let enabledVerticalKeys = Set(
            allSettings
                .filter { $0.isEnabled && verticalTrackpadKeys.contains($0.key) }
                .map(\.key)
        )
        let allVerticalSuppressed = !enabledVerticalKeys.isEmpty
            && enabledVerticalKeys.isSubset(of: trackpadKeys)
        let dockKeys = allVerticalSuppressed ? Set(Self.dockBoolKeys) : []

        return (trackpadKeys, dockKeys)
    }
}

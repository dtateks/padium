import AppKit
import Foundation

@MainActor
protocol SystemGestureManaging: AnyObject {
    var isSuppressed: Bool { get }
    func suppress(conflictingSettings: [SystemGestureSetting])
    func restore()
    func restoreIfNeeded()
}

/// Saves, disables, and restores macOS system trackpad gesture preferences
/// strictly for the specific (finger-count × direction) variants that the
/// user has bound in Padium.
///
/// Padium has NO mandate to silence Mission Control or App Exposé. Those
/// are global, finger-count-agnostic Dock-domain toggles
/// (`showMissionControlGestureEnabled`, `showAppExposeGestureEnabled`)
/// that the user owns. If Padium disables them as a side effect of binding
/// a 3-finger gesture, the user later switching macOS to a 4-finger
/// Mission Control gesture will silently break because the Dock keys are
/// still false — which is the bug we're fixing.
///
/// Scoping contract:
///   * `suppress(conflictingSettings:)` writes `-int 0` ONLY to the
///     trackpad-preference keys whose `conflictingSlots` include a slot
///     the user has bound. No other trackpad key is touched. No Dock
///     key is ever touched.
///   * The backup tracks per-key original values incrementally — new
///     conflicts get added on subsequent calls, vanished conflicts get
///     restored on the same call, without bouncing unrelated keys.
///   * Backup persists across launches so a crash mid-suppression
///     self-heals on next launch via `restoreIfNeeded()`.
///   * Legacy backups (pre-fix) that contain Dock-domain entries are
///     restored opportunistically on the next suppress/restore call so
///     the upgrade path itself fixes already-broken user settings.
@MainActor
final class SystemGestureManager: SystemGestureManaging {

    typealias DefaultsWriter = (_ domain: String, _ key: String, _ value: String) -> Void
    typealias DockRestarter = () -> Void
    typealias TrackpadPrefsReader = () -> [String: Any]

    static let shared = SystemGestureManager()

    private let trackpadDomain = "com.apple.AppleMultitouchTrackpad"
    private let dockDomain = "com.apple.dock"
    private let backupKey: String

    private static let trackpadKeyPrefix = "trackpad."
    private static let legacyDockKeyPrefix = "dock."

    private let writer: DefaultsWriter
    private let dockRestarter: DockRestarter
    private let trackpadPrefsReader: TrackpadPrefsReader

    private(set) var isSuppressed = false

    init(
        backupKey: String = "padium.systemGestureBackup",
        writer: DefaultsWriter? = nil,
        dockRestarter: DockRestarter? = nil,
        trackpadPrefsReader: TrackpadPrefsReader? = nil
    ) {
        self.backupKey = backupKey
        self.writer = writer ?? Self.shellDefaultsWriter
        self.dockRestarter = dockRestarter ?? Self.killDock
        self.trackpadPrefsReader = trackpadPrefsReader ?? {
            UserDefaults.standard.persistentDomain(forName: "com.apple.AppleMultitouchTrackpad") ?? [:]
        }
    }

    // MARK: - Public

    /// Reconcile the set of disabled trackpad-preference keys to exactly
    /// the conflicting Padium slots. Adds newly-conflicting keys to the
    /// suppression set and restores keys that are no longer conflicting,
    /// all in a single defaults-write pass — no Dock restart and no
    /// collateral writes to unrelated keys.
    func suppress(conflictingSettings: [SystemGestureSetting]) {
        let desiredKeys = Set(conflictingSettings.map(\.key))
        var backup = loadBackup() ?? [:]
        let currentlySuppressedKeys = Self.trackpadKeys(in: backup)

        let toDisable = desiredKeys.subtracting(currentlySuppressedKeys)
        let toRestore = currentlySuppressedKeys.subtracting(desiredKeys)

        if !toDisable.isEmpty {
            let trackpadPrefs = trackpadPrefsReader()
            for key in toDisable {
                // Default to 2 (enabled) when unset so a future restore
                // re-enables the gesture instead of leaving it at 0.
                backup[Self.trackpadKeyPrefix + key] = trackpadPrefs[key] as? Int ?? 2
            }
            for key in toDisable {
                writer(trackpadDomain, key, "-int 0")
            }
        }

        for key in toRestore {
            let compositeKey = Self.trackpadKeyPrefix + key
            let originalValue = backup[compositeKey] as? Int ?? 2
            writer(trackpadDomain, key, "-int \(originalValue)")
            backup.removeValue(forKey: compositeKey)
        }

        let dockRestartNeeded = restoreLegacyDockEntries(in: &backup)

        persist(backup: backup)

        if dockRestartNeeded {
            dockRestarter()
        }

        PadiumLogger.gesture.info(
            "System gestures suppressed: keys=\(desiredKeys.sorted(), privacy: .public) suppressed=\(self.isSuppressed)"
        )
    }

    /// Restore every key that Padium currently has stored as suppressed,
    /// including any legacy Dock-domain entries from a pre-fix backup.
    func restore() {
        guard let backup = loadBackup() else {
            isSuppressed = false
            return
        }
        var didRestartDock = false
        for (compositeKey, value) in backup {
            if compositeKey.hasPrefix(Self.trackpadKeyPrefix), let intValue = value as? Int {
                let key = String(compositeKey.dropFirst(Self.trackpadKeyPrefix.count))
                writer(trackpadDomain, key, "-int \(intValue)")
            } else if compositeKey.hasPrefix(Self.legacyDockKeyPrefix), let boolValue = value as? Bool {
                let key = String(compositeKey.dropFirst(Self.legacyDockKeyPrefix.count))
                writer(dockDomain, key, "-bool \(boolValue ? "true" : "false")")
                didRestartDock = true
            }
        }
        clearBackup()
        isSuppressed = false
        if didRestartDock {
            dockRestarter()
        }
        PadiumLogger.gesture.info("System gestures restored")
    }

    /// If a backup exists from a previous session (crash recovery), restore it.
    func restoreIfNeeded() {
        guard loadBackup() != nil else { return }
        PadiumLogger.gesture.notice("Found stale system gesture backup from previous session; restoring")
        restore()
    }

    // MARK: - Backup helpers

    private static func trackpadKeys(in backup: [String: Any]) -> Set<String> {
        Set(backup.keys.compactMap { compositeKey in
            guard compositeKey.hasPrefix(trackpadKeyPrefix) else { return nil }
            return String(compositeKey.dropFirst(trackpadKeyPrefix.count))
        })
    }

    private func loadBackup() -> [String: Any]? {
        UserDefaults.standard.dictionary(forKey: backupKey)
    }

    private func clearBackup() {
        UserDefaults.standard.removeObject(forKey: backupKey)
    }

    private func persist(backup: [String: Any]) {
        if backup.isEmpty {
            clearBackup()
            isSuppressed = false
        } else {
            UserDefaults.standard.set(backup, forKey: backupKey)
            isSuppressed = true
        }
    }

    /// Pre-fix builds also stashed Dock-domain bool keys in the backup
    /// (`showMissionControlGestureEnabled`, `showAppExposeGestureEnabled`).
    /// Restore and strip them on first suppress/restore after upgrade so
    /// an already-broken user setup self-heals without manual recovery.
    private func restoreLegacyDockEntries(in backup: inout [String: Any]) -> Bool {
        let dockKeys = backup.keys.filter { $0.hasPrefix(Self.legacyDockKeyPrefix) }
        guard !dockKeys.isEmpty else { return false }
        for compositeKey in dockKeys {
            let key = String(compositeKey.dropFirst(Self.legacyDockKeyPrefix.count))
            let value = backup[compositeKey] as? Bool ?? true
            writer(dockDomain, key, "-bool \(value ? "true" : "false")")
            backup.removeValue(forKey: compositeKey)
        }
        PadiumLogger.gesture.notice("Restored legacy Dock-domain backup entries (\(dockKeys.count, privacy: .public))")
        return true
    }

    // MARK: - Default shell-backed I/O

    /// Uses `defaults write` because `UserDefaults.setPersistentDomain` for system domains
    /// does not reliably propagate to the running Dock/WindowServer on modern macOS.
    private static let shellDefaultsWriter: DefaultsWriter = { domain, key, value in
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", domain, key] + value.split(separator: " ").map(String.init)
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            PadiumLogger.gesture.error("defaults write failed domain=\(domain, privacy: .public) key=\(key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private static let killDock: DockRestarter = {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            PadiumLogger.gesture.error("killall Dock failed: \(String(describing: error), privacy: .public)")
        }
    }
}

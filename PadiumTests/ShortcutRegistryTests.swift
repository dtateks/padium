import Testing
@testable import Padium
import KeyboardShortcuts

struct ShortcutRegistryTests {
    // Every slot must map to a stable, unique KeyboardShortcuts.Name.
    @Test func nameIsStableForSameSlot() {
        let first = ShortcutRegistry.name(for: .threeFingerSwipeLeft)
        let second = ShortcutRegistry.name(for: .threeFingerSwipeLeft)
        #expect(first == second)
    }

    @Test func namesAreDifferentAcrossSlots() {
        let allSlots = GestureSlot.allCases
        let names = allSlots.map { ShortcutRegistry.name(for: $0) }
        let uniqueNames = Set(names.map(\.rawValue))
        #expect(uniqueNames.count == allSlots.count)
    }

    // Name raw values must be the exact stable format "gesture.<slot.rawValue>".
    // A substring check would pass accidental formats like "gesture.foo.threeFingerSwipeLeft.bar".
    @Test func nameRawValueIsExactStableFormat() {
        for slot in GestureSlot.allCases {
            let name = ShortcutRegistry.name(for: slot)
            #expect(name.rawValue == "gesture.\(slot.rawValue)")
        }
    }

    // The ordered sequence of all-cases must be stable across calls
    // so that the settings UI never re-orders rows on re-launch.
    @Test func allCasesOrderIsStable() {
        let run1 = GestureSlot.allCases.map(\.rawValue)
        let run2 = GestureSlot.allCases.map(\.rawValue)
        #expect(run1 == run2)
    }

    @Test func higherFingerClickLabelsStayClickBased() {
        #expect(GestureSlot.threeFingerClick.displayName == "Click")
        #expect(GestureSlot.threeFingerDoubleClick.displayName == "Double Click")
        #expect(GestureSlot.fourFingerClick.displayName == "Click")
        #expect(GestureSlot.fourFingerDoubleClick.displayName == "Double Click")
    }

    @Test func higherFingerTouchDoubleTapLabelsStayTapBased() {
        #expect(GestureSlot.threeFingerDoubleTap.displayName == "Double Tap")
        #expect(GestureSlot.fourFingerDoubleTap.displayName == "Double Tap")
    }

    @Test func legacyClickRawValuesRemainStable() {
        #expect(GestureSlot.threeFingerClick.rawValue == "threeFingerTap")
        #expect(GestureSlot.threeFingerDoubleClick.rawValue == "threeFingerDoubleTap")
        #expect(GestureSlot.fourFingerClick.rawValue == "fourFingerTap")
        #expect(GestureSlot.fourFingerDoubleClick.rawValue == "fourFingerDoubleTap")
    }

    @Test func touchDoubleTapRawValuesAreDistinctFromLegacyClickKeys() {
        #expect(GestureSlot.threeFingerDoubleTap.rawValue == "threeFingerTouchDoubleTap")
        #expect(GestureSlot.fourFingerDoubleTap.rawValue == "fourFingerTouchDoubleTap")
    }

    @Test func oneAndTwoFingerDoubleTapLabelsStayTapBased() {
        #expect(GestureSlot.oneFingerDoubleTap.displayName == "Double Tap")
        #expect(GestureSlot.twoFingerDoubleTap.displayName == "Double Tap")
    }

    @Test @MainActor func suppressOnlyWritesTrackpadKeysForBoundSlots() {
        // Padium's suppression contract: only the trackpad-preference keys
        // whose conflictingSlots overlap with bound Padium slots get
        // disabled. Mission Control / App Exposé Dock-domain toggles are
        // user-owned and must never be touched, even when every vertical
        // trackpad variant is being suppressed at once.
        let recorder = SystemGestureWriteRecorder()
        let manager = recorder.makeManager(initialTrackpadPrefs: [
            "TrackpadThreeFingerVertSwipeGesture": 2,
            "TrackpadFourFingerVertSwipeGesture": 2,
        ])
        defer { recorder.clearBackup() }

        let conflicting = [
            SystemGestureSetting(
                key: "TrackpadThreeFingerVertSwipeGesture",
                title: "Mission Control / App Exposé (3 fingers)",
                isEnabled: true,
                conflictingSlots: [.threeFingerSwipeUp, .threeFingerSwipeDown]
            ),
            SystemGestureSetting(
                key: "TrackpadFourFingerVertSwipeGesture",
                title: "Mission Control / App Exposé (4 fingers)",
                isEnabled: true,
                conflictingSlots: [.fourFingerSwipeUp, .fourFingerSwipeDown]
            ),
        ]

        manager.suppress(conflictingSettings: conflicting)

        #expect(recorder.dockWrites.isEmpty)
        #expect(recorder.dockRestartCallCount == 0)
        #expect(Set(recorder.trackpadWrites.map(\.key)) == Set([
            "TrackpadThreeFingerVertSwipeGesture",
            "TrackpadFourFingerVertSwipeGesture",
        ]))
        #expect(recorder.trackpadWrites.allSatisfy { $0.value == "-int 0" })
    }

    @Test @MainActor func suppressIncrementallyAddsAndReleasesKeysWithoutTouchingOthers() {
        let recorder = SystemGestureWriteRecorder()
        let manager = recorder.makeManager(initialTrackpadPrefs: [
            "TrackpadThreeFingerHorizSwipeGesture": 2,
            "TrackpadFourFingerVertSwipeGesture": 2,
        ])
        defer { recorder.clearBackup() }

        let threeHoriz = SystemGestureSetting(
            key: "TrackpadThreeFingerHorizSwipeGesture",
            title: "Swipe between full-screen apps (3 fingers)",
            isEnabled: true,
            conflictingSlots: [.threeFingerSwipeLeft, .threeFingerSwipeRight]
        )
        let fourVert = SystemGestureSetting(
            key: "TrackpadFourFingerVertSwipeGesture",
            title: "Mission Control / App Exposé (4 fingers)",
            isEnabled: true,
            conflictingSlots: [.fourFingerSwipeUp, .fourFingerSwipeDown]
        )

        manager.suppress(conflictingSettings: [threeHoriz])
        #expect(recorder.suppressedTrackpadKeys() == Set(["TrackpadThreeFingerHorizSwipeGesture"]))

        manager.suppress(conflictingSettings: [threeHoriz, fourVert])
        #expect(recorder.suppressedTrackpadKeys() == Set([
            "TrackpadThreeFingerHorizSwipeGesture",
            "TrackpadFourFingerVertSwipeGesture",
        ]))

        recorder.trackpadWrites.removeAll()
        manager.suppress(conflictingSettings: [fourVert])
        #expect(recorder.suppressedTrackpadKeys() == Set(["TrackpadFourFingerVertSwipeGesture"]))
        // Releasing 3-finger horiz must restore its original value (2),
        // not leave it stuck at 0.
        #expect(recorder.trackpadWrites.contains { write in
            write.key == "TrackpadThreeFingerHorizSwipeGesture" && write.value == "-int 2"
        })
    }

    @Test @MainActor func suppressMigratesLegacyDockBackupOnUpgrade() {
        // Upgrade scenario: a pre-fix build wrote dock-key entries into
        // the backup. The first suppress/restore call on the new build
        // must restore those dock keys (to true) and strip them from the
        // backup so an already-broken user setup self-heals automatically.
        let recorder = SystemGestureWriteRecorder()
        recorder.setBackup([
            "trackpad.TrackpadThreeFingerHorizSwipeGesture": 2,
            "dock.showMissionControlGestureEnabled": true,
            "dock.showAppExposeGestureEnabled": true,
        ])
        let manager = recorder.makeManager()
        defer { recorder.clearBackup() }

        manager.suppress(conflictingSettings: [])

        #expect(recorder.dockRestartCallCount == 1)
        #expect(Set(recorder.dockWrites.map(\.key)) == Set([
            "showMissionControlGestureEnabled",
            "showAppExposeGestureEnabled",
        ]))
        #expect(recorder.dockWrites.allSatisfy { $0.value == "-bool true" })
        let remainingDockKeys = recorder.currentBackup()?.keys.filter { $0.hasPrefix("dock.") } ?? []
        #expect(remainingDockKeys.isEmpty)
    }
}

/// Captures every `defaults write` and Dock-restart call a
/// `SystemGestureManager` would issue, so tests can assert behavior
/// without mutating the user's real macOS preferences. Each instance
/// scopes itself to a unique UserDefaults backup key so suites can run
/// in parallel without interfering.
@MainActor
final class SystemGestureWriteRecorder {
    struct DefaultsWrite: Equatable {
        let domain: String
        let key: String
        let value: String
    }

    private let backupKey = "padium.test.systemGestureBackup.\(UUID().uuidString)"
    private(set) var trackpadDomainWrites: [DefaultsWrite] = []
    var trackpadWrites: [DefaultsWrite] {
        get { trackpadDomainWrites.filter { $0.domain == "com.apple.AppleMultitouchTrackpad" } }
        set {
            trackpadDomainWrites = newValue + trackpadDomainWrites.filter {
                $0.domain != "com.apple.AppleMultitouchTrackpad"
            }
        }
    }
    var dockWrites: [DefaultsWrite] {
        trackpadDomainWrites.filter { $0.domain == "com.apple.dock" }
    }
    private(set) var dockRestartCallCount = 0
    private var trackpadPrefs: [String: Any] = [:]

    func makeManager(initialTrackpadPrefs: [String: Any] = [:]) -> SystemGestureManager {
        trackpadPrefs = initialTrackpadPrefs
        return SystemGestureManager(
            backupKey: backupKey,
            writer: { [weak self] domain, key, value in
                self?.trackpadDomainWrites.append(DefaultsWrite(domain: domain, key: key, value: value))
            },
            dockRestarter: { [weak self] in
                self?.dockRestartCallCount += 1
            },
            trackpadPrefsReader: { [weak self] in
                self?.trackpadPrefs ?? [:]
            }
        )
    }

    func setBackup(_ backup: [String: Any]) {
        UserDefaults.standard.set(backup, forKey: backupKey)
    }

    func currentBackup() -> [String: Any]? {
        UserDefaults.standard.dictionary(forKey: backupKey)
    }

    func suppressedTrackpadKeys() -> Set<String> {
        let backup = currentBackup() ?? [:]
        return Set(backup.keys.compactMap { compositeKey in
            guard compositeKey.hasPrefix("trackpad.") else { return nil }
            return String(compositeKey.dropFirst("trackpad.".count))
        })
    }

    func clearBackup() {
        UserDefaults.standard.removeObject(forKey: backupKey)
    }
}

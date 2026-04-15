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

    @Test @MainActor func verticalSystemGestureSuppressionAlsoDisablesDockKeys() {
        let settings = [
            SystemGestureSetting(
                key: "TrackpadFourFingerVertSwipeGesture",
                title: "Mission Control / App Exposé (4 fingers)",
                isEnabled: true,
                conflictingSlots: [.fourFingerSwipeUp, .fourFingerSwipeDown]
            )
        ]

        let disabledPreferenceKeys = SystemGestureManager.disabledPreferenceKeys(for: settings)

        #expect(disabledPreferenceKeys.trackpadKeys == Set(["TrackpadFourFingerVertSwipeGesture"]))
        #expect(disabledPreferenceKeys.dockKeys == Set(["showAppExposeGestureEnabled", "showMissionControlGestureEnabled"]))
    }

    @Test @MainActor func horizontalSystemGestureSuppressionLeavesDockKeysEnabled() {
        let settings = [
            SystemGestureSetting(
                key: "TrackpadThreeFingerHorizSwipeGesture",
                title: "Swipe between full-screen apps (3 fingers)",
                isEnabled: true,
                conflictingSlots: [.threeFingerSwipeLeft, .threeFingerSwipeRight]
            )
        ]

        let disabledPreferenceKeys = SystemGestureManager.disabledPreferenceKeys(for: settings)

        #expect(disabledPreferenceKeys.trackpadKeys == Set(["TrackpadThreeFingerHorizSwipeGesture"]))
        #expect(disabledPreferenceKeys.dockKeys.isEmpty)
    }
}

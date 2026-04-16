import AppKit
import Foundation

struct PreemptionPolicy: Sendable {
    let supportedGestures: [String]
    let ownerNotice: String?
}

struct SystemGestureSetting: Identifiable, Sendable {
    let key: String
    let title: String
    let isEnabled: Bool
    /// Which Padium gesture slots this system gesture conflicts with.
    let conflictingSlots: [GestureSlot]

    var id: String { key }
}

@MainActor
final class PreemptionController {
    private let trackpadPreferenceDomain = "com.apple.AppleMultitouchTrackpad"

    func currentPolicy(activeSlots: Set<GestureSlot> = Set(GestureSlot.allCases)) -> PreemptionPolicy {
        let conflicts = conflictingSettings(for: activeSlots)
        let notice: String? = conflicts.isEmpty ? nil :
            "Some macOS trackpad gestures are still enabled and will fire alongside Padium. " +
            "Open System Settings → Trackpad → More Gestures and turn off the conflicting gestures listed below."
        return PreemptionPolicy(
            supportedGestures: GestureSlot.allCases.map(\.rawValue),
            ownerNotice: notice
        )
    }

    func currentSystemGestureSettings() -> [SystemGestureSetting] {
        [
            SystemGestureSetting(
                key: "TrackpadTwoFingerDoubleTapGesture",
                title: "Smart Zoom (2-finger double-tap)",
                isEnabled: isSystemGestureEnabled(forKey: "TrackpadTwoFingerDoubleTapGesture"),
                conflictingSlots: [.twoFingerDoubleTap]
            ),
            SystemGestureSetting(
                key: "TrackpadThreeFingerHorizSwipeGesture",
                title: "Swipe between full-screen apps (3 fingers)",
                isEnabled: isSystemGestureEnabled(forKey: "TrackpadThreeFingerHorizSwipeGesture"),
                conflictingSlots: [.threeFingerSwipeLeft, .threeFingerSwipeRight]
            ),
            SystemGestureSetting(
                key: "TrackpadThreeFingerVertSwipeGesture",
                title: "Mission Control / App Exposé (3 fingers)",
                isEnabled: isSystemGestureEnabled(forKey: "TrackpadThreeFingerVertSwipeGesture"),
                conflictingSlots: [.threeFingerSwipeUp, .threeFingerSwipeDown]
            ),
            SystemGestureSetting(
                key: "TrackpadFourFingerHorizSwipeGesture",
                title: "Swipe between full-screen apps (4 fingers)",
                isEnabled: isSystemGestureEnabled(forKey: "TrackpadFourFingerHorizSwipeGesture"),
                conflictingSlots: [.fourFingerSwipeLeft, .fourFingerSwipeRight]
            ),
            SystemGestureSetting(
                key: "TrackpadFourFingerVertSwipeGesture",
                title: "Mission Control / App Exposé (4 fingers)",
                isEnabled: isSystemGestureEnabled(forKey: "TrackpadFourFingerVertSwipeGesture"),
                conflictingSlots: [.fourFingerSwipeUp, .fourFingerSwipeDown]
            )
        ]
    }

    func conflictingSettings(for activeSlots: Set<GestureSlot> = Set(GestureSlot.allCases)) -> [SystemGestureSetting] {
        currentSystemGestureSettings().filter { setting in
            setting.isEnabled && !activeSlots.isDisjoint(with: setting.conflictingSlots)
        }
    }

    /// Returns the set of active Padium gesture slots that currently conflict with enabled system gestures.
    func conflictingSlots(for activeSlots: Set<GestureSlot> = Set(GestureSlot.allCases)) -> Set<GestureSlot> {
        var result = Set<GestureSlot>()
        for setting in conflictingSettings(for: activeSlots) {
            result.formUnion(setting.conflictingSlots.filter(activeSlots.contains))
        }
        return result
    }

    /// Open System Settings → Trackpad pane.
    func openTrackpadSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func isSystemGestureEnabled(forKey key: String) -> Bool {
        let value = UserDefaults.standard.persistentDomain(forName: trackpadPreferenceDomain)?[key] as? Int ?? 0
        return value != 0
    }
}

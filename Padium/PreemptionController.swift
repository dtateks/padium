import Foundation

struct PreemptionPolicy: Sendable {
    enum Strategy: String, Sendable {
        case suppress
        case manualDisable = "manual-disable"
    }

    let strategy: Strategy
    let supportedGestures: [String]
    let ownerNotice: String?
}

struct SystemGestureSetting: Identifiable, Sendable {
    let key: String
    let title: String
    let isEnabled: Bool

    var id: String { key }
}

enum PreemptionControllerError: LocalizedError, Sendable {
    case manualDisableRequired(String)

    var errorDescription: String? {
        switch self {
        case let .manualDisableRequired(notice): notice
        }
    }
}

@MainActor
final class PreemptionController {
    private let trackpadPreferenceDomain = "com.apple.AppleMultitouchTrackpad"

    private let currentOwnerNotice = "Padium cannot reliably override macOS swipe gestures on this machine. Before using Padium swipe slots, open System Settings → Trackpad → More Gestures and turn off Swipe between full-screen applications, Mission Control, and App Exposé. If you later enable any 3-finger swipe gesture in macOS, turn that off too. Keep those system gestures disabled while Padium is enabled."

    func currentPolicy() -> PreemptionPolicy {
        PreemptionPolicy(
            strategy: .manualDisable,
            supportedGestures: GestureSlot.allCases.map(\.rawValue),
            ownerNotice: currentOwnerNotice
        )
    }

    func currentSystemGestureSettings() -> [SystemGestureSetting] {
        [
            SystemGestureSetting(
                key: "TrackpadThreeFingerHorizSwipeGesture",
                title: "3-finger horizontal swipe",
                isEnabled: isSystemGestureEnabled(forKey: "TrackpadThreeFingerHorizSwipeGesture")
            ),
            SystemGestureSetting(
                key: "TrackpadThreeFingerVertSwipeGesture",
                title: "3-finger vertical swipe",
                isEnabled: isSystemGestureEnabled(forKey: "TrackpadThreeFingerVertSwipeGesture")
            ),
            SystemGestureSetting(
                key: "TrackpadFourFingerHorizSwipeGesture",
                title: "4-finger horizontal swipe",
                isEnabled: isSystemGestureEnabled(forKey: "TrackpadFourFingerHorizSwipeGesture")
            ),
            SystemGestureSetting(
                key: "TrackpadFourFingerVertSwipeGesture",
                title: "4-finger vertical swipe",
                isEnabled: isSystemGestureEnabled(forKey: "TrackpadFourFingerVertSwipeGesture")
            )
        ]
    }

    func disableSystemGesturesIfPossible() throws {
        guard currentSystemGestureSettings().contains(where: \.isEnabled) else { return }
        guard let ownerNotice = currentPolicy().ownerNotice else { return }
        throw PreemptionControllerError.manualDisableRequired(ownerNotice)
    }

    private func isSystemGestureEnabled(forKey key: String) -> Bool {
        let value = UserDefaults.standard.persistentDomain(forName: trackpadPreferenceDomain)?[key] as? Int ?? 0
        return value != 0
    }
}

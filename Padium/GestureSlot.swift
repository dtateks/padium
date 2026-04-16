import Foundation
import KeyboardShortcuts

enum GestureSlot: String, CaseIterable, Sendable {
    case oneFingerDoubleTap
    case twoFingerDoubleTap
    case threeFingerSwipeLeft
    case threeFingerSwipeRight
    case threeFingerSwipeUp
    case threeFingerSwipeDown
    case threeFingerTap
    case threeFingerDoubleTap
    case fourFingerSwipeLeft
    case fourFingerSwipeRight
    case fourFingerSwipeUp
    case fourFingerSwipeDown
    case fourFingerTap
    case fourFingerDoubleTap

    enum Kind: Sendable {
        case swipe
        case tap
        case doubleTap
    }

    var kind: Kind {
        switch self {
        case .oneFingerDoubleTap, .twoFingerDoubleTap,
             .threeFingerDoubleTap, .fourFingerDoubleTap:
            .doubleTap
        case .threeFingerSwipeLeft, .threeFingerSwipeRight,
             .threeFingerSwipeUp, .threeFingerSwipeDown,
             .fourFingerSwipeLeft, .fourFingerSwipeRight,
             .fourFingerSwipeUp, .fourFingerSwipeDown:
            .swipe
        case .threeFingerTap, .fourFingerTap:
            .tap
        }
    }

    var fingerCount: Int {
        switch self {
        case .oneFingerDoubleTap:
            1
        case .twoFingerDoubleTap:
            2
        case .threeFingerSwipeLeft, .threeFingerSwipeRight,
             .threeFingerSwipeUp, .threeFingerSwipeDown,
             .threeFingerTap, .threeFingerDoubleTap:
            3
        case .fourFingerSwipeLeft, .fourFingerSwipeRight,
             .fourFingerSwipeUp, .fourFingerSwipeDown,
             .fourFingerTap, .fourFingerDoubleTap:
            4
        }
    }

    var isTapGesture: Bool {
        kind == .tap || kind == .doubleTap
    }

    var tapSlot: GestureSlot? {
        switch self {
        case .oneFingerDoubleTap, .twoFingerDoubleTap:
            nil
        case .threeFingerTap, .threeFingerDoubleTap:
            .threeFingerTap
        case .fourFingerTap, .fourFingerDoubleTap:
            .fourFingerTap
        default:
            nil
        }
    }

    var doubleTapSlot: GestureSlot? {
        switch self {
        case .oneFingerDoubleTap:
            .oneFingerDoubleTap
        case .twoFingerDoubleTap:
            .twoFingerDoubleTap
        case .threeFingerTap, .threeFingerDoubleTap:
            .threeFingerDoubleTap
        case .fourFingerTap, .fourFingerDoubleTap:
            .fourFingerDoubleTap
        default:
            nil
        }
    }

    var displayName: String {
        switch self {
        case .oneFingerDoubleTap:    "Double Tap"
        case .twoFingerDoubleTap:    "Double Tap"
        case .threeFingerSwipeLeft:  "Swipe Left"
        case .threeFingerSwipeRight: "Swipe Right"
        case .threeFingerSwipeUp:    "Swipe Up"
        case .threeFingerSwipeDown:  "Swipe Down"
        case .threeFingerTap:        "Tap"
        case .threeFingerDoubleTap:  "Double Tap"
        case .fourFingerSwipeLeft:   "Swipe Left"
        case .fourFingerSwipeRight:  "Swipe Right"
        case .fourFingerSwipeUp:     "Swipe Up"
        case .fourFingerSwipeDown:   "Swipe Down"
        case .fourFingerTap:         "Tap"
        case .fourFingerDoubleTap:   "Double Tap"
        }
    }

    var sectionTitle: String {
        switch self {
        case .oneFingerDoubleTap:
            "1 Finger"
        case .twoFingerDoubleTap:
            "2 Finger"
        case .threeFingerSwipeLeft, .threeFingerSwipeRight,
             .threeFingerSwipeUp,   .threeFingerSwipeDown,
             .threeFingerTap,       .threeFingerDoubleTap:
            "3 Finger"
        case .fourFingerSwipeLeft, .fourFingerSwipeRight,
             .fourFingerSwipeUp,   .fourFingerSwipeDown,
             .fourFingerTap,       .fourFingerDoubleTap:
            "4 Finger"
        }
    }

    /// Whether this slot supports choosing between keyboard shortcut and middle click.
    var supportsActionKindChoice: Bool {
        kind == .tap
    }

    /// Resolves the effective action for this slot.
    /// Tap/doubleTap slots with `.middleClick` action kind are configured even without a shortcut.
    var isConfigured: Bool {
        if GestureActionStore.actionKind(for: self) == .middleClick { return true }
        return KeyboardShortcuts.getShortcut(for: ShortcutRegistry.name(for: self)) != nil
    }
}

// MARK: - Gesture Action Kind

enum GestureActionKind: String, CaseIterable, Sendable {
    case shortcut
    case middleClick
}

enum GestureActionStore {
    private static let prefix = "gesture.action."

    static func actionKind(for slot: GestureSlot) -> GestureActionKind {
        guard let raw = UserDefaults.standard.string(forKey: prefix + slot.rawValue),
              let kind = GestureActionKind(rawValue: raw) else {
            return .shortcut
        }
        return kind
    }

    static func setActionKind(_ kind: GestureActionKind, for slot: GestureSlot) {
        if kind == .shortcut {
            UserDefaults.standard.removeObject(forKey: prefix + slot.rawValue)
        } else {
            UserDefaults.standard.set(kind.rawValue, forKey: prefix + slot.rawValue)
        }
    }
}

import Foundation
import KeyboardShortcuts

enum GestureSlot: String, CaseIterable, Sendable {
    case oneFingerDoubleTap
    case twoFingerDoubleTap
    case threeFingerSwipeLeft
    case threeFingerSwipeRight
    case threeFingerSwipeUp
    case threeFingerSwipeDown
    case threeFingerClick = "threeFingerTap"
    case threeFingerDoubleClick = "threeFingerDoubleTap"
    case threeFingerDoubleTap = "threeFingerTouchDoubleTap"
    case fourFingerSwipeLeft
    case fourFingerSwipeRight
    case fourFingerSwipeUp
    case fourFingerSwipeDown
    case fourFingerClick = "fourFingerTap"
    case fourFingerDoubleClick = "fourFingerDoubleTap"
    case fourFingerDoubleTap = "fourFingerTouchDoubleTap"

    enum Kind: Sendable {
        case swipe
        case doubleTap
        case click
        case doubleClick
    }

    var kind: Kind {
        switch self {
        case .oneFingerDoubleTap, .twoFingerDoubleTap,
             .threeFingerDoubleTap, .fourFingerDoubleTap:
            .doubleTap
        case .threeFingerDoubleClick, .fourFingerDoubleClick:
            .doubleClick
        case .threeFingerSwipeLeft, .threeFingerSwipeRight,
             .threeFingerSwipeUp, .threeFingerSwipeDown,
             .fourFingerSwipeLeft, .fourFingerSwipeRight,
             .fourFingerSwipeUp, .fourFingerSwipeDown:
            .swipe
        case .threeFingerClick, .fourFingerClick:
            .click
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
             .threeFingerClick, .threeFingerDoubleClick,
             .threeFingerDoubleTap:
            3
        case .fourFingerSwipeLeft, .fourFingerSwipeRight,
             .fourFingerSwipeUp, .fourFingerSwipeDown,
             .fourFingerClick, .fourFingerDoubleClick,
             .fourFingerDoubleTap:
            4
        }
    }

    var isTapGesture: Bool {
        kind == .doubleTap || kind == .click || kind == .doubleClick
    }

    var isTouchTapGesture: Bool {
        kind == .doubleTap
    }

    var displayName: String {
        switch self {
        case .oneFingerDoubleTap:    "Double Tap"
        case .twoFingerDoubleTap:    "Double Tap"
        case .threeFingerSwipeLeft:  "Swipe Left"
        case .threeFingerSwipeRight: "Swipe Right"
        case .threeFingerSwipeUp:    "Swipe Up"
        case .threeFingerSwipeDown:  "Swipe Down"
        case .threeFingerClick:      "Click"
        case .threeFingerDoubleClick: "Double Click"
        case .threeFingerDoubleTap:  "Double Tap"
        case .fourFingerSwipeLeft:   "Swipe Left"
        case .fourFingerSwipeRight:  "Swipe Right"
        case .fourFingerSwipeUp:     "Swipe Up"
        case .fourFingerSwipeDown:   "Swipe Down"
        case .fourFingerClick:       "Click"
        case .fourFingerDoubleClick: "Double Click"
        case .fourFingerDoubleTap:   "Double Tap"
        }
    }

    /// Whether this slot supports choosing between keyboard shortcut and middle click.
    var supportsActionKindChoice: Bool {
        kind == .click
    }

    /// Resolves the effective action for this slot.
    /// Click slots with `.middleClick` action kind are configured even without a shortcut.
    var isConfigured: Bool {
        if supportsActionKindChoice && GestureActionStore.actionKind(for: self) == .middleClick {
            return true
        }
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

    static func userDefaultsKey(for slot: GestureSlot) -> String {
        prefix + slot.rawValue
    }

    static func actionKind(for slot: GestureSlot) -> GestureActionKind {
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey(for: slot)),
              let kind = GestureActionKind(rawValue: raw) else {
            return .shortcut
        }
        return kind
    }

    static func setActionKind(_ kind: GestureActionKind, for slot: GestureSlot) {
        let key = userDefaultsKey(for: slot)
        if kind == .shortcut {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(kind.rawValue, forKey: key)
        }
    }
}

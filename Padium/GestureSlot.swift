import Foundation

enum GestureSlot: String, CaseIterable, Sendable {
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
        case .threeFingerSwipeLeft, .threeFingerSwipeRight,
             .threeFingerSwipeUp, .threeFingerSwipeDown,
             .fourFingerSwipeLeft, .fourFingerSwipeRight,
             .fourFingerSwipeUp, .fourFingerSwipeDown:
            .swipe
        case .threeFingerTap, .fourFingerTap:
            .tap
        case .threeFingerDoubleTap, .fourFingerDoubleTap:
            .doubleTap
        }
    }

    var fingerCount: Int {
        switch self {
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
        case .threeFingerSwipeLeft:  "Swipe Left"
        case .threeFingerSwipeRight: "Swipe Right"
        case .threeFingerSwipeUp:    "Swipe Up"
        case .threeFingerSwipeDown:  "Swipe Down"
        case .threeFingerTap:        "Click"
        case .threeFingerDoubleTap:  "Double Click"
        case .fourFingerSwipeLeft:   "Swipe Left"
        case .fourFingerSwipeRight:  "Swipe Right"
        case .fourFingerSwipeUp:     "Swipe Up"
        case .fourFingerSwipeDown:   "Swipe Down"
        case .fourFingerTap:         "Click"
        case .fourFingerDoubleTap:   "Double Click"
        }
    }

    var sectionTitle: String {
        switch self {
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

}

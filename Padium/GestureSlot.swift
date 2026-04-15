import Foundation

enum GestureSlot: String, CaseIterable, Sendable {
    case threeFingerSwipeLeft
    case threeFingerSwipeRight
    case threeFingerSwipeUp
    case threeFingerSwipeDown
    case fourFingerSwipeLeft
    case fourFingerSwipeRight
    case fourFingerSwipeUp
    case fourFingerSwipeDown

    var displayName: String {
        switch self {
        case .threeFingerSwipeLeft:  "Swipe Left"
        case .threeFingerSwipeRight: "Swipe Right"
        case .threeFingerSwipeUp:    "Swipe Up"
        case .threeFingerSwipeDown:  "Swipe Down"
        case .fourFingerSwipeLeft:   "Swipe Left"
        case .fourFingerSwipeRight:  "Swipe Right"
        case .fourFingerSwipeUp:     "Swipe Up"
        case .fourFingerSwipeDown:   "Swipe Down"
        }
    }

    var sectionTitle: String {
        switch self {
        case .threeFingerSwipeLeft, .threeFingerSwipeRight,
             .threeFingerSwipeUp,   .threeFingerSwipeDown:
            "3 Finger"
        case .fourFingerSwipeLeft, .fourFingerSwipeRight,
             .fourFingerSwipeUp,   .fourFingerSwipeDown:
            "4 Finger"
        }
    }

}

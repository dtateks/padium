import Foundation

/// Stored user sensitivity setting + the pure math that maps it to live
/// swipe and tap-travel thresholds. Read from UserDefaults at every
/// classifier and engine call site, so sensitivity changes apply without
/// restarting the runtime.
enum GestureSensitivitySetting {
    static let minimumValue: Double = 0.0
    static let defaultValue: Double = 0.5
    static let maximumValue: Double = 1.0

    private static let userDefaultsKey = "gesture.sensitivity"
    private static let baseSensitivityBoost: Double = 0.2
    private static let minimumSwipeThreshold: Float = 0.04
    private static let maximumSwipeThreshold: Float = 0.10
    private static let minimumTapTravelThreshold: Float = 0.04
    private static let maximumTapTravelThreshold: Float = 0.07

    static func clamp(_ value: Double) -> Double {
        min(max(value, minimumValue), maximumValue)
    }

    static func storedValue(userDefaults: UserDefaults = .standard) -> Double {
        let value = userDefaults.object(forKey: userDefaultsKey) as? Double ?? defaultValue
        return clamp(value)
    }

    static func store(_ value: Double, userDefaults: UserDefaults = .standard) {
        userDefaults.set(clamp(value), forKey: userDefaultsKey)
    }

    static func clearStoredValue(userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: userDefaultsKey)
    }

    static func swipeThreshold(for sensitivity: Double) -> Float {
        let progress = Float(effectiveSensitivity(for: sensitivity))
        let range = maximumSwipeThreshold - minimumSwipeThreshold
        return maximumSwipeThreshold - (range * progress)
    }

    static func tapTravelThreshold(for sensitivity: Double) -> Float {
        let progress = Float(effectiveSensitivity(for: sensitivity))
        let range = maximumTapTravelThreshold - minimumTapTravelThreshold
        return minimumTapTravelThreshold + (range * progress)
    }

    static func effectiveSensitivity(for sensitivity: Double) -> Double {
        clamp(clamp(sensitivity) + baseSensitivityBoost)
    }

    static func currentSwipeThreshold(userDefaults: UserDefaults = .standard) -> Float {
        swipeThreshold(for: storedValue(userDefaults: userDefaults))
    }

    static func currentTapTravelThreshold(userDefaults: UserDefaults = .standard) -> Float {
        tapTravelThreshold(for: storedValue(userDefaults: userDefaults))
    }
}

/// Wall-clock gates for tap and double-tap recognition. Empirically derived
/// from macOS trackpad behavior — do NOT change without evidence.
enum GestureTapSettings {
    // 500ms supports both light taps (~100ms) and physical clicks (~300-500ms).
    static let maximumDuration: TimeInterval = 0.5
    static let doubleTapWindow: TimeInterval = 0.3
    // A deliberate finger tap lands and holds at its peak finger count for
    // at least ~50 ms. Palm grazes from typing are capacitive flickers
    // that appear and vanish within 10-30 ms because the palm never
    // actually rests on the sensor. 50 ms sits below the light-tap floor
    // (~80-120 ms observed on macOS trackpads) while rejecting flickers —
    // the same principle as libinput's `tap-minimum-time`. Evaluated
    // against the candidate's duration at its latest peak (re-anchored on
    // every peak upgrade) so the floor measures time at peak finger count,
    // not total sequence life.
    static let minimumStableDuration: TimeInterval = 0.05

    static func currentMaximumTravel(userDefaults: UserDefaults = .standard) -> Float {
        GestureSensitivitySetting.currentTapTravelThreshold(userDefaults: userDefaults)
    }
}

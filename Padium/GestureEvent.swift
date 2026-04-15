import Foundation

// A classified gesture event emitted by the gesture engine.
struct GestureEvent: Sendable {
    let slot: GestureSlot
    let timestamp: Date
}

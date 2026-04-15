import Foundation

// Boundary protocol: abstraction over raw multitouch frame producers.
protocol GestureSource: AnyObject, Sendable {
    func startListening() throws
    func stopListening()
    var touchFrameStream: AsyncStream<[TouchPoint]> { get }
}

// Raw touch point data passed from a GestureSource to the GestureClassifier.
// Fields mirror OMSTouchData so the classifier can apply state-gating and
// noise-rejection without importing OpenMultitouchSupport above the boundary.
struct TouchPoint: Sendable {
    let identifier: Int
    let normalizedX: Float
    let normalizedY: Float
    let pressure: Float
    let state: OMSTouchState
    // Total capacitance for this contact. Contacts with total < 0.03 are noise.
    let total: Float
    // Major axis of the contact ellipse in sensor units. Values > 30 indicate a palm.
    let majorAxis: Float
}

// Touch lifecycle state mirrored from OMSState so modules above the OMS boundary
// do not need to import OpenMultitouchSupport directly.
enum OMSTouchState: String, Sendable {
    case notTouching
    case starting
    case hovering
    case making
    case touching
    case breaking
    case lingering
    case leaving
}

import CoreGraphics

/// Marks CGEvents that Padium itself posts (e.g. synthetic middle clicks)
/// so the scroll-suppressor's event tap recognizes them and passes them
/// through instead of trying to interpret them as user-driven clicks.
///
/// Cross-cutting contract between two independent modules:
/// - `MiddleClickEmitter` calls `mark(_:)` on every synthesized down/up
///   `CGEvent` it posts.
/// - `ScrollSuppressor` calls `matches(_:)` on every left-mouse event the
///   CGEventTap sees and passes through any event that carries the mark
///   instead of interpreting it as a user-driven 3/4-finger click.
///
/// `0x50414449554D` decodes to ASCII "PADIUM" — chosen so the value is
/// recognizable in event dumps and unlikely to collide with other senders'
/// userData payloads.
enum PadiumSyntheticEventMarker {
    static let value: Int64 = 0x50414449554D

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: value)
    }

    static func matches(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == value
    }
}

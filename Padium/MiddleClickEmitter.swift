import AppKit
import Foundation

@MainActor
protocol MiddleClickEmitting: AnyObject {
    @discardableResult func emitMiddleClick() -> Bool
}

/// Posts a synthetic middle-click (button 2) at the current cursor position.
/// The down/up pair is marked with `PadiumSyntheticEventMarker` so the scroll
/// suppressor's event tap recognizes the click as Padium-originated and lets
/// it pass through untouched.
@MainActor
final class MiddleClickEmitter: MiddleClickEmitting {
    private static let buttonNumber = Int64(CGMouseButton.center.rawValue)

    @discardableResult
    func emitMiddleClick() -> Bool {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return false }
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        PadiumLogger.shortcut.notice(
            "TAP-DIAG: middle click frontmost=\(frontmostBundleIdentifier, privacy: .public) appActive=\(NSApp.isActive)"
        )
        let position = CGEvent(source: nil)?.location ?? .zero
        guard let down = CGEvent(mouseEventSource: src, mouseType: .otherMouseDown, mouseCursorPosition: position, mouseButton: .center),
              let up = CGEvent(mouseEventSource: src, mouseType: .otherMouseUp, mouseCursorPosition: position, mouseButton: .center)
        else {
            return false
        }

        Self.configure(down, clickState: 1)
        Self.configure(up, clickState: 1)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func configure(_ event: CGEvent, clickState: Int64) {
        event.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        PadiumSyntheticEventMarker.mark(event)
    }
}

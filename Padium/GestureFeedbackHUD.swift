import AppKit
import Foundation
import KeyboardShortcuts
import SwiftUI

/// Opt-in transient overlay that confirms which gesture fired and what
/// shortcut/action Padium emitted. Designed to be unobtrusive — a
/// non-activating floating panel at the bottom of the primary screen
/// that ignores hits and fades away after ~1 second.
@MainActor
protocol GestureFeedbackPresenting: AnyObject {
    func showFeedback(_ message: String)
}

@MainActor
final class GestureFeedbackHUD: GestureFeedbackPresenting {
    // `nonisolated(unsafe)` so deinit (nonisolated under Swift 6 strict
    // concurrency) can drop the panel + cancel the hide task. The panel and
    // task are otherwise only touched from MainActor methods.
    private nonisolated(unsafe) var panel: NSPanel?
    private nonisolated(unsafe) var hostingView: NSHostingView<GestureFeedbackView>?
    private nonisolated(unsafe) var hideTask: Task<Void, Never>?

    private static let displayDuration: Duration = .milliseconds(1100)

    deinit {
        // If the HUD is dropped while a panel is visible (rare — in production
        // AppState holds the HUD for the app's lifetime), make sure the panel
        // isn't left on screen and the deferred hide task can't fire against a
        // stale weak self.
        hideTask?.cancel()
        // NSPanel.orderOut must run on the main thread; deinit is nonisolated
        // under Swift 6 strict concurrency, so hop deliberately even if we are
        // already on main.
        let panelToHide = panel
        if let panelToHide {
            DispatchQueue.main.async {
                panelToHide.orderOut(nil)
            }
        }
    }

    func showFeedback(_ message: String) {
        let panel = ensurePanel()
        let hosting = ensureHostingView(in: panel)
        hosting.rootView = GestureFeedbackView(message: message)
        // The new rootView invalidates layout; force a layout pass so
        // fittingSize reflects the new message before we size the panel.
        // Without this, the first emission can land at the old empty-message
        // dimensions.
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        panel.setContentSize(CGSize(
            width: max(fitting.width, 180),
            height: max(fitting.height, 48)
        ))
        repositionAtBottomCenter(panel)
        panel.orderFrontRegardless()
        scheduleHide()
    }

    private func ensureHostingView(in panel: NSPanel) -> NSHostingView<GestureFeedbackView> {
        if let hostingView { return hostingView }
        let hosting = NSHostingView(rootView: GestureFeedbackView(message: ""))
        panel.contentView = hosting
        hostingView = hosting
        return hosting
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        self.panel = panel
        return panel
    }

    private func repositionAtBottomCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let panelFrame = panel.frame
        let visible = screen.visibleFrame
        let x = visible.midX - panelFrame.width / 2
        let y = visible.minY + 96
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.displayDuration)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }
}

private struct GestureFeedbackView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Pure formatter so the feedback string can be tested without driving a
/// real panel. MainActor-isolated because `KeyboardShortcuts.Shortcut`
/// description is MainActor-only.
@MainActor
enum GestureFeedbackMessage {
    static func format(slot: GestureSlot, action: GestureActionKind) -> String {
        let gesture = "\(slot.fingerCount)-finger \(slot.displayName.lowercased())"
        switch action {
        case .middleClick:
            return "\(gesture) → Middle Click"
        case .shortcut:
            return "\(gesture) → \(shortcutDescription(for: slot))"
        }
    }

    private static func shortcutDescription(for slot: GestureSlot) -> String {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: ShortcutRegistry.name(for: slot)) else {
            return "—"
        }
        return shortcut.description
    }
}

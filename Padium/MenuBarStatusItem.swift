import AppKit
import SwiftUI

/// Padium runs as `LSUIElement=true` (no Dock icon) and is launched
/// at login in the background. Without a status bar entry the user has
/// no way back to Settings after the window is dismissed except a full
/// app relaunch. This scene closes that gap.
@MainActor
struct MenuBarStatusItemContent: View {
    @Bindable var appState: AppState

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Label(
                MenuBarStatusPresentation.title(for: appState.runtimeStatus),
                systemImage: MenuBarStatusPresentation.symbolName(for: appState.runtimeStatus)
            )
            .disabled(true)

            Divider()

            Button(appState.isPaused ? "Resume Padium" : "Pause Padium") {
                appState.togglePaused()
            }
            .keyboardShortcut("p", modifiers: [.command])

            Button("Settings…") {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: [.command])

            Divider()

            Button("Quit Padium") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }

    private func openSettings() {
        openWindow(id: SettingsWindow.sceneID, value: SettingsWindow.value)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApplication.shared.windows
                .first { $0.identifier?.rawValue == SettingsWindow.sceneID }?
                .makeKeyAndOrderFront(nil)
        }
    }
}

enum MenuBarStatusPresentation {
    static func title(for status: RuntimeStatus) -> String {
        switch status {
        case .active:              "Active"
        case .degraded:            "Degraded"
        case .permissionsRequired: "Permissions required"
        case .paused:              "Paused"
        case .checking:            "Checking…"
        }
    }

    static func symbolName(for status: RuntimeStatus) -> String {
        switch status {
        case .active:              "checkmark.circle.fill"
        case .degraded:            "exclamationmark.triangle.fill"
        case .permissionsRequired: "lock.shield.fill"
        case .paused:              "pause.circle.fill"
        case .checking:            "hourglass"
        }
    }

    static func menuBarSymbolName(for status: RuntimeStatus) -> String {
        // The bar icon prefers a quiet, brand-stable hand-tap glyph when
        // everything is fine, switching to a louder warning glyph only when
        // user attention is required. This keeps the menu bar calm during
        // steady-state use while still surfacing degraded/permission states.
        // Paused gets its own glyph so users can tell at a glance from the
        // menu bar that gestures are intentionally off rather than broken.
        switch status {
        case .active:              "hand.tap.fill"
        case .degraded:            "exclamationmark.triangle.fill"
        case .permissionsRequired: "exclamationmark.shield.fill"
        case .paused:              "pause.circle"
        case .checking:            "hand.tap"
        }
    }
}

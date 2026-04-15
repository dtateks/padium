import SwiftUI

@main
struct PadiumApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Padium", systemImage: "hand.tap") {
            MenuBarContentView(appState: appState)
        }

        Window("Padium Settings", id: "settings") {
            SettingsContentView(appState: appState)
        }
        .defaultSize(width: 400, height: 500)
    }
}

struct MenuBarContentView: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enabled", isOn: $appState.isEnabled)
                .disabled(!appState.permissionState.isGranted)

            Divider()

            if !appState.permissionState.isGranted {
                Label("Permissions required", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            Button("Settings…") {
                appState.isSettingsPresented = true
            }
        }
        .padding(8)
        .onChange(of: appState.isSettingsPresented) { _, presented in
            if presented {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .onAppear {
            appState.refreshPermissions()
        }
    }
}

struct SettingsContentView: View {
    @Bindable var appState: AppState

    private let coordinator = PermissionCoordinator()

    var body: some View {
        TabView {
            PermissionsView(
                permissionState: appState.permissionState,
                systemGestureNotice: appState.systemGestureNotice,
                onOpenAccessibility: { coordinator.openAccessibilitySettings() },
                onOpenInputMonitoring: { coordinator.openInputMonitoringSettings() }
            )
            .tabItem { Label("Permissions", systemImage: "lock.shield") }

            SettingsView(appState: appState)
                .tabItem { Label("Gestures", systemImage: "hand.draw") }
        }
        .padding()
        .onDisappear {
            appState.isSettingsPresented = false
        }
    }
}

private extension PermissionState {
    var isGranted: Bool {
        self == .granted
    }
}

import SwiftUI

@main
struct PadiumApp: App {
    @State private var appState: AppState

    init() {
        let state = AppState()
        if !Self.isRunningUnderTestHarness {
            state.handleAppLaunch {
                NSApp.terminate(nil)
            }

            // Restore system gestures on any normal termination path.
            // Use both willTerminate (normal quit) and SIGTERM handler (force quit from Activity Monitor).
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                SystemGestureManager.shared.restore()
            }

            let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            src.setEventHandler {
                SystemGestureManager.shared.restore()
                exit(0)
            }
            src.resume()
            signal(SIGTERM, SIG_IGN)
            // Keep reference alive
            Self._sigtermSource = src
        }
        _appState = State(initialValue: state)
    }

    // Prevent ARC from releasing the SIGTERM source.
    nonisolated(unsafe) private static var _sigtermSource: DispatchSourceSignal?

    private static var isRunningUnderTestHarness: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

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

    private let settingsWindowTitle = "Padium Settings"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.isRunning {
                if appState.conflictingSlots.isEmpty {
                    Label("Running", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Label("Running — system gesture conflicts", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            } else if appState.permissionState == .denied {
                Label("Accessibility required", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            Button("Settings…", action: presentSettingsWindow)

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(8)
        .onAppear {
            appState.refreshPermissions()
        }
    }

    private func presentSettingsWindow() {
        appState.isSettingsPresented = true
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor in
            for _ in 0..<3 {
                if focusSettingsWindow() {
                    return
                }
                await Task.yield()
            }
        }
    }

    private func focusSettingsWindow() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.title == settingsWindowTitle }) else {
            return false
        }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return true
    }
}

struct SettingsContentView: View {
    @Bindable var appState: AppState

    var body: some View {
        TabView {
            PermissionsView(
                permissionState: appState.permissionState,
                systemGestureNotice: appState.systemGestureNotice,
                conflictingSettings: appState.systemGestureSettings(),
                onRequestAccessibility: { appState.requestAccessibility() },
                onOpenTrackpadSettings: { appState.openTrackpadSettings() },
                onRefreshConflicts: { appState.refreshSystemGestureConflicts() }
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

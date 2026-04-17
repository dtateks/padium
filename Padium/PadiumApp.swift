import SwiftUI

@main
struct PadiumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState: AppState

    init() {
        let state = AppState()
        if !Self.isRunningUnderTestHarness {
            state.handleAppLaunch {
                NSApp.terminate(nil)
            }

            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                UserDefaults.standard.synchronize()
                Self.restoreSystemGestures()
            }

            let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            src.setEventHandler {
                UserDefaults.standard.synchronize()
                Self.restoreSystemGesturesAndExit()
            }
            src.resume()
            signal(SIGTERM, SIG_IGN)
            Self._sigtermSource = src
        }
        _appState = State(initialValue: state)
    }

    nonisolated(unsafe) private static var _sigtermSource: DispatchSourceSignal?

    nonisolated private static func restoreSystemGestures() {
        Task { @MainActor in
            SystemGestureManager.shared.restore()
        }
    }

    nonisolated private static func restoreSystemGesturesAndExit() {
        Task { @MainActor in
            SystemGestureManager.shared.restore()
            NSApp.terminate(nil)
        }
    }

    private static var isRunningUnderTestHarness: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        Window("Padium", id: "settings") {
            SettingsContentView(appState: appState)
                .background(SettingsWindowBridge(appDelegate: appDelegate))
                .onAppear {
                    appDelegate.appState = appState
                    appState.isSettingsPresented = true
                }
                .onDisappear {
                    appState.isSettingsPresented = false
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .textEditing) {}
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .pasteboard) {}
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    var showSettingsWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        openSettingsWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appState?.refreshPermissions()
        guard !(appState?.isSettingsPresented ?? false) else { return }
        openSettingsWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func openSettingsWindow() {
        showSettingsWindow?()
    }
}

private struct SettingsWindowBridge: View {
    let appDelegate: AppDelegate

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                appDelegate.showSettingsWindow = { [openWindow] in
                    openWindow(id: "settings")
                    focusSettingsWindow()
                }
            }
    }
}

private func focusSettingsWindow() {
    DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

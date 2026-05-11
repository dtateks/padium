import AppKit
import SwiftUI

private let settingsWindowSceneID = "settings"
private let settingsWindowValue = "settings"

@main
struct PadiumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState: AppState

    init() {
        // Padium uses the KeyboardShortcuts package only for Recorder UI and
        // UserDefaults-backed shortcut storage. It never wants the package to
        // capture real keystrokes as global hotkeys — doing so would consume
        // keystrokes inside Padium (or any frontmost app when a hotkey is
        // active) and stop Padium's own synthetic keystrokes from reaching
        // the target app. See ShortcutHotKeyGuard for the per-name disable.
        ShortcutHotKeyGuard.install()

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
        WindowGroup("Padium", id: settingsWindowSceneID, for: String.self) { _ in
            SettingsContentView(appState: appState)
                .background(SettingsWindowBridge(appDelegate: appDelegate))
                .onAppear {
                    appDelegate.appState = appState
                    appState.isSettingsPresented = true
                }
                .onDisappear {
                    appState.isSettingsPresented = false
                }
        } defaultValue: {
            settingsWindowValue
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .textEditing) {}
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .pasteboard) {}
        }
    }
}

private struct SettingsWindowBridge: View {
    let appDelegate: AppDelegate

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .background(SettingsWindowObserver(appDelegate: appDelegate))
            .onAppear {
                appDelegate.showSettingsWindow = { [openWindow] in
                    openWindow(id: settingsWindowSceneID, value: settingsWindowValue)
                    focusSettingsWindow()
                }
            }
    }
}

private struct SettingsWindowObserver: NSViewRepresentable {
    let appDelegate: AppDelegate

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            appDelegate.observeSettingsWindow(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            appDelegate.observeSettingsWindow(window)
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

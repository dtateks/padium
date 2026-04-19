import SwiftUI
import KeyboardShortcuts

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

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    var showSettingsWindow: (() -> Void)?
    var rememberFrontmostApplicationHandler: (() -> Void)?
    var restorePreviousApplicationHandler: (() -> Void)?

    private weak var observedSettingsWindow: NSWindow?
    private var previouslyFrontmostExternalApplication: NSRunningApplication?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationDidChange(_:)),
            name: configurationDidChangeNotification,
            object: nil
        )
    }

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

    func observeSettingsWindow(_ window: NSWindow) {
        guard observedSettingsWindow !== window else { return }

        removeSettingsWindowObservers()

        observedSettingsWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsWindowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    private func openSettingsWindow() {
        rememberFrontmostExternalApplicationIfNeeded()
        showSettingsWindow?()
    }

    private func rememberFrontmostExternalApplicationIfNeeded() {
        if let rememberFrontmostApplicationHandler {
            rememberFrontmostApplicationHandler()
            return
        }

        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }

        previouslyFrontmostExternalApplication = frontmostApplication
    }

    private func restorePreviouslyFrontmostApplicationIfNeeded() {
        if let restorePreviousApplicationHandler {
            setAppInteractionActive(false)
            restorePreviousApplicationHandler()
            return
        }

        defer { previouslyFrontmostExternalApplication = nil }

        guard NSApp.isActive,
              let previousApplication = previouslyFrontmostExternalApplication,
              !previousApplication.isTerminated else {
            return
        }

        setAppInteractionActive(false)
        _ = previousApplication.activate(options: [])
    }

    private func setAppInteractionActive(_ isActive: Bool) {
        appState?.setAppInteractionActive(isActive)
    }

    private func removeSettingsWindowObservers() {
        guard let observedSettingsWindow else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: observedSettingsWindow)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedSettingsWindow)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: observedSettingsWindow)
        self.observedSettingsWindow = nil
    }

    @objc private func handleConfigurationDidChange(_ notification: Notification) {
        restorePreviouslyFrontmostApplicationIfNeeded()
    }

    @objc private func handleSettingsWindowDidBecomeKey(_ notification: Notification) {
        setAppInteractionActive(true)
    }

    @objc private func handleSettingsWindowDidResignKey(_ notification: Notification) {
        setAppInteractionActive(false)
    }

    @objc private func handleSettingsWindowWillClose(_ notification: Notification) {
        setAppInteractionActive(false)
        restorePreviouslyFrontmostApplicationIfNeeded()
        observedSettingsWindow = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: notification.object)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: notification.object)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: notification.object)
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
                    openWindow(id: "settings")
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

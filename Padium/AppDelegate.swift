import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    var showSettingsWindow: (() -> Void)?
    var rememberFrontmostApplicationHandler: (() -> Void)?
    var restorePreviousApplicationHandler: (() -> Void)?
    var closeStartupWindowsHandler: (() -> Void)?
    var launchAtLoginController: any LaunchAtLoginControlling = LaunchAtLoginManager()

    private weak var observedSettingsWindow: NSWindow?
    private var previouslyFrontmostExternalApplication: NSRunningApplication?
    private var shouldAutoOpenSettingsWindow = true
    private var hasPendingLaunchAtLoginApproval = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationDidChange(_:)),
            name: PadiumNotification.configurationDidChange,
            object: nil
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchedAtLogin = launchAtLoginController.wasLaunchedAtLogin
        shouldAutoOpenSettingsWindow = !launchedAtLogin

        if launchAtLoginController.ensureEnabled() == .requiresApproval {
            hasPendingLaunchAtLoginApproval = launchedAtLogin
            if !launchedAtLogin {
                launchAtLoginController.openSystemSettings()
            }
        }

        guard shouldAutoOpenSettingsWindow else {
            closeStartupWindows()
            return
        }

        openSettingsWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if hasPendingLaunchAtLoginApproval {
            hasPendingLaunchAtLoginApproval = false
            shouldAutoOpenSettingsWindow = true
            launchAtLoginController.openSystemSettings()
        }

        openSettingsWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appState?.refreshPermissions()

        guard shouldAutoOpenSettingsWindow else { return }
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

    private func closeStartupWindows() {
        if let closeStartupWindowsHandler {
            closeStartupWindowsHandler()
            return
        }

        Task { @MainActor in
            for window in NSApplication.shared.windows {
                window.close()
            }
        }
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

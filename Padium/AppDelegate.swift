import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

enum LaunchAtLoginRegistrationResult: Equatable {
    case enabled
    case requiresApproval
    case failed
}

@MainActor
protocol LaunchAtLoginControlling: AnyObject {
    var wasLaunchedAtLogin: Bool { get }
    func ensureEnabled() -> LaunchAtLoginRegistrationResult
    func openSystemSettings()
}

protocol LoginItemServiceControlling {
    var status: SMAppService.Status { get }
    func register() throws
}

extension SMAppService: LoginItemServiceControlling {}

@MainActor
final class LaunchAtLoginManager: LaunchAtLoginControlling {
    private let service: any LoginItemServiceControlling
    private let appleEventProvider: () -> NSAppleEventDescriptor?
    private let systemSettingsOpener: () -> Void

    init(
        service: any LoginItemServiceControlling = SMAppService.mainApp,
        appleEventProvider: @escaping () -> NSAppleEventDescriptor? = { NSAppleEventManager.shared().currentAppleEvent },
        systemSettingsOpener: @escaping () -> Void = SMAppService.openSystemSettingsLoginItems
    ) {
        self.service = service
        self.appleEventProvider = appleEventProvider
        self.systemSettingsOpener = systemSettingsOpener
    }

    var wasLaunchedAtLogin: Bool {
        guard let event = appleEventProvider() else {
            return false
        }

        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func ensureEnabled() -> LaunchAtLoginRegistrationResult {
        switch service.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            PadiumLogger.permission.notice("Launch at login requires user approval in System Settings")
            return .requiresApproval
        case .notRegistered, .notFound:
            return registerMainApp()
        @unknown default:
            PadiumLogger.permission.error(
                "Launch at login has unexpected status: \(String(describing: self.service.status), privacy: .public)"
            )
            return .failed
        }
    }

    func openSystemSettings() {
        systemSettingsOpener()
    }

    private func registerMainApp() -> LaunchAtLoginRegistrationResult {
        do {
            try service.register()
        } catch {
            return registrationResult(after: error)
        }

        return registrationResult(after: nil)
    }

    private func registrationResult(after error: (any Error)?) -> LaunchAtLoginRegistrationResult {
        switch service.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            PadiumLogger.permission.notice("Launch at login requires user approval in System Settings")
            return .requiresApproval
        case .notRegistered, .notFound:
            if let error {
                PadiumLogger.permission.error(
                    "Failed to enable launch at login: \(error.localizedDescription, privacy: .public)"
                )
            } else {
                PadiumLogger.permission.error("Launch at login registration did not enable the main app")
            }
            return .failed
        @unknown default:
            PadiumLogger.permission.error(
                "Launch at login has unexpected post-registration status: \(String(describing: self.service.status), privacy: .public)"
            )
            return .failed
        }
    }
}

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

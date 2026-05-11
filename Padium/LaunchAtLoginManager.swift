import AppKit
import ApplicationServices
import ServiceManagement

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

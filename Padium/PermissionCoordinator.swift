import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

enum PermissionState: Equatable, Sendable {
    case checking
    case granted
    case denied(accessibility: Bool, inputMonitoring: Bool)
}

protocol PermissionChecking {
    func isAccessibilityGranted() -> Bool
    func isInputMonitoringGranted() -> Bool
}

struct SystemPermissionChecker: PermissionChecking {
    func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    func isInputMonitoringGranted() -> Bool {
        CGPreflightListenEventAccess()
    }
}

@MainActor
final class PermissionCoordinator {
    private(set) var permissionState: PermissionState = .checking
    private let checker: PermissionChecking

    init(checker: PermissionChecking = SystemPermissionChecker()) {
        self.checker = checker
    }

    var isFullyGranted: Bool {
        permissionState == .granted
    }

    func checkPermissions() {
        let accessibility = checker.isAccessibilityGranted()
        let inputMonitoring = checker.isInputMonitoringGranted()

        if accessibility && inputMonitoring {
            permissionState = .granted
        } else {
            permissionState = .denied(accessibility: accessibility, inputMonitoring: inputMonitoring)
        }

        PadiumLogger.permission.info("Permission check: accessibility=\(accessibility) inputMonitoring=\(inputMonitoring)")
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}

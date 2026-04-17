import AppKit
import ApplicationServices
import Foundation
import os

enum PermissionState: Equatable, Sendable {
    case checking
    case granted
    case denied
}

protocol PermissionChecking {
    func isAccessibilityGranted() -> Bool
    func requestAccessibility()
}

struct SystemPermissionChecker: PermissionChecking {
    func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

@MainActor
final class PermissionCoordinator {
    private(set) var permissionState: PermissionState = .checking
    private let checker: PermissionChecking
    private var pollTimer: Timer?

    init(checker: PermissionChecking = SystemPermissionChecker()) {
        self.checker = checker
    }

    var isFullyGranted: Bool {
        permissionState == .granted
    }

    func checkPermissions() {
        let accessibility = checker.isAccessibilityGranted()
        permissionState = accessibility ? .granted : .denied
        PadiumLogger.permission.info("Permission check: accessibility=\(accessibility)")
    }

    /// Start polling AXIsProcessTrusted every 2s so UI updates after user grants in System Settings.
    func startPolling(onUpdate: @escaping @MainActor () -> Void) {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            // WHY Task { @MainActor } instead of `MainActor.assumeIsolated`:
            //
            // Foundation Timer's `@Sendable` block closure runs on the main
            // thread when the timer is scheduled on the main run loop — but
            // its Swift task executor is undefined. Calling
            // `MainActor.assumeIsolated` from this context crashed with
            // EXC_BAD_ACCESS inside `SerialExecutor._isSameExecutor` on the
            // macOS 26 SDK (Swift runtime nil-dereference when comparing
            // executors that aren't set up).
            //
            // `Task { @MainActor in ... }` explicitly hops to the main actor
            // executor, which is always valid. Symptom before the fix: app
            // died ~2s after launch (first timer tick), window stayed on
            // screen because AppKit had rendered it, but the process was gone
            // so clicks hit a corpse — user saw "drag works, click doesn't".
            Task { @MainActor in
                guard self != nil else { return }
                onUpdate()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func requestAccessibility() {
        checker.requestAccessibility()
    }
}

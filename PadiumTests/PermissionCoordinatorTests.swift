import Testing
@testable import Padium

struct PermissionCoordinatorTests {

    @Test @MainActor func initialPermissionStateIsChecking() {
        let coordinator = PermissionCoordinator(checker: MockPermissionChecker())
        #expect(coordinator.permissionState == .checking)
    }

    @Test @MainActor func accessibilityGrantedTransitionsToGranted() {
        let checker = MockPermissionChecker(accessibility: true)
        let coordinator = PermissionCoordinator(checker: checker)
        coordinator.checkPermissions()
        #expect(coordinator.permissionState == .granted)
    }

    @Test @MainActor func accessibilityDeniedTransitionsToDenied() {
        let checker = MockPermissionChecker(accessibility: false)
        let coordinator = PermissionCoordinator(checker: checker)
        coordinator.checkPermissions()
        #expect(coordinator.permissionState == .denied)
    }

    @Test @MainActor func permissionRevocationDetected() {
        let checker = MockPermissionChecker(accessibility: true)
        let coordinator = PermissionCoordinator(checker: checker)
        coordinator.checkPermissions()
        #expect(coordinator.permissionState == .granted)

        checker.accessibility = false
        coordinator.checkPermissions()
        #expect(coordinator.permissionState == .denied)
    }

    @Test @MainActor func isFullyGrantedReturnsTrueOnlyWhenGranted() {
        let checker = MockPermissionChecker(accessibility: true)
        let coordinator = PermissionCoordinator(checker: checker)
        #expect(coordinator.isFullyGranted == false)
        coordinator.checkPermissions()
        #expect(coordinator.isFullyGranted == true)
    }

    @Test @MainActor func requestAccessibilityDelegatesToChecker() {
        let checker = MockPermissionChecker(accessibility: false)
        let coordinator = PermissionCoordinator(checker: checker)
        coordinator.requestAccessibility()
        #expect(checker.requestAccessibilityCallCount == 1)
    }

    @Test @MainActor func checkPermissionsTracksInputMonitoringAndPostEventAccess() {
        let checker = MockPermissionChecker(
            accessibility: true,
            inputMonitoring: false,
            postEvents: true
        )
        let coordinator = PermissionCoordinator(checker: checker)

        coordinator.checkPermissions()

        #expect(coordinator.permissionState == .granted)
        #expect(coordinator.inputMonitoringState == .denied)
        #expect(coordinator.postEventState == .granted)
        #expect(coordinator.hasOutputAccess == true)
        #expect(coordinator.hasInputMonitoringAccess == false)
    }

    @Test @MainActor func requestMissingPermissionsDelegatesOnlyMissingCapabilities() {
        let checker = MockPermissionChecker(
            accessibility: true,
            inputMonitoring: false,
            postEvents: false
        )
        let coordinator = PermissionCoordinator(checker: checker)
        coordinator.checkPermissions()

        coordinator.requestMissingPermissions()

        #expect(checker.requestAccessibilityCallCount == 0)
        #expect(checker.requestListenEventAccessCallCount == 1)
        #expect(checker.requestPostEventAccessCallCount == 1)
    }
}

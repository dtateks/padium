import Testing
@testable import Padium
import AppKit
import Foundation
import ServiceManagement

@MainActor
struct LaunchAtLoginManagerTests {
    @Test func ensureEnabledSkipsRegistrationWhenAlreadyEnabled() {
        let service = StubLoginItemService(status: .enabled)
        let manager = LaunchAtLoginManager(
            service: service,
            appleEventProvider: { nil },
            systemSettingsOpener: {}
        )

        #expect(manager.ensureEnabled() == .enabled)
        #expect(service.registerCallCount == 0)
    }

    @Test func ensureEnabledRegistersMainAppWhenNotRegistered() {
        let service = StubLoginItemService(status: .notRegistered)
        service.registerHandler = {
            service.status = .enabled
        }
        let manager = LaunchAtLoginManager(
            service: service,
            appleEventProvider: { nil },
            systemSettingsOpener: {}
        )

        #expect(manager.ensureEnabled() == .enabled)
        #expect(service.registerCallCount == 1)
    }

    @Test func ensureEnabledReturnsRequiresApprovalWhenRegistrationNeedsApproval() {
        let service = StubLoginItemService(status: .notRegistered)
        service.registerHandler = {
            service.status = .requiresApproval
        }
        let manager = LaunchAtLoginManager(
            service: service,
            appleEventProvider: { nil },
            systemSettingsOpener: {}
        )

        #expect(manager.ensureEnabled() == .requiresApproval)
        #expect(service.registerCallCount == 1)
    }

    @Test func detectsLaunchAtLoginAppleEvent() {
        let service = StubLoginItemService(status: .enabled)
        let appleEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        appleEvent.setParam(
            NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem),
            forKeyword: AEKeyword(keyAEPropData)
        )
        let manager = LaunchAtLoginManager(
            service: service,
            appleEventProvider: { appleEvent },
            systemSettingsOpener: {}
        )

        #expect(manager.wasLaunchedAtLogin == true)
    }
}

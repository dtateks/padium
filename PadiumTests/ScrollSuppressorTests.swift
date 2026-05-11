import Testing
@testable import Padium
import AppKit
import CoreGraphics
import Foundation

@MainActor
struct ScrollSuppressorTests {

    private final class SlotRecorder: @unchecked Sendable {
        var slots: [GestureSlot] = []
    }

    private final class ManualPhysicalClickScheduler: PhysicalClickScheduling {
        final class ScheduledWork: PhysicalClickScheduledWork {
            private(set) var isCancelled = false

            func cancel() {
                isCancelled = true
            }
        }

        private struct ScheduledAction {
            let fireDate: Date
            let work: ScheduledWork
            let action: @Sendable () -> Void
        }

        private(set) var now: Date
        private var scheduledActions: [ScheduledAction] = []

        init(now: Date = Date(timeIntervalSinceReferenceDate: 0)) {
            self.now = now
        }

        @discardableResult
        func schedule(after delay: TimeInterval, action: @escaping @Sendable () -> Void) -> any PhysicalClickScheduledWork {
            let work = ScheduledWork()
            scheduledActions.append(
                ScheduledAction(
                    fireDate: now.addingTimeInterval(delay),
                    work: work,
                    action: action
                )
            )
            return work
        }

        func advance(by delay: TimeInterval) {
            now = now.addingTimeInterval(delay)
            runDueActions()
        }

        private func runDueActions() {
            while let index = nextDueActionIndex() {
                let scheduledAction = scheduledActions.remove(at: index)
                if !scheduledAction.work.isCancelled {
                    scheduledAction.action()
                }
                scheduledActions.removeAll { $0.work.isCancelled }
            }
        }

        private func nextDueActionIndex() -> Int? {
            scheduledActions.indices
                .filter { !scheduledActions[$0].work.isCancelled && scheduledActions[$0].fireDate <= now }
                .min { scheduledActions[$0].fireDate < scheduledActions[$1].fireDate }
        }
    }

    @Test func physicalThreeFingerClickEmitsConfiguredSlotAndSuppressesPair() {
        let suppressor = ScrollSuppressor()
        suppressor.currentFingerCount = 3
        suppressor.isMultitouchActive = true
        let recorder = SlotRecorder()
        suppressor.setPhysicalClickHandler { event in
            recorder.slots.append(event.slot)
        }

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown),
            configuredClickSlotsResolver: { _ in (.threeFingerClick, nil) }
        ) {
        case .suppress:
            break
        case .passThrough:
            Issue.record("Expected left mouse down to be suppressed")
        }
        #expect(recorder.slots == [.threeFingerClick])

        switch suppressor.eventDisposition(
            for: .leftMouseUp,
            event: makeLeftClickEvent(.leftMouseUp),
            configuredClickSlotsResolver: { _ in (nil, nil) }
        ) {
        case .suppress:
            break
        case .passThrough:
            Issue.record("Expected left mouse up to be suppressed")
        }
    }

    @Test func physicalThreeFingerClickWaitsForDoubleClickWindowBeforeSingleClick() {
        let scheduler = ManualPhysicalClickScheduler()
        let suppressor = ScrollSuppressor(clickScheduler: scheduler)
        suppressor.currentFingerCount = 3
        suppressor.isMultitouchActive = true
        let recorder = SlotRecorder()
        suppressor.setPhysicalClickHandler { event in
            recorder.slots.append(event.slot)
        }

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown),
            configuredClickSlotsResolver: { _ in (.threeFingerClick, .threeFingerDoubleClick) }
        ) {
        case .suppress:
            break
        case .passThrough:
            Issue.record("Expected left mouse down to be suppressed")
        }
        #expect(recorder.slots.isEmpty)

        switch suppressor.eventDisposition(
            for: .leftMouseUp,
            event: makeLeftClickEvent(.leftMouseUp),
            configuredClickSlotsResolver: { _ in (nil, nil) }
        ) {
        case .suppress:
            break
        case .passThrough:
            Issue.record("Expected left mouse up to be suppressed")
        }

        scheduler.advance(by: NSEvent.doubleClickInterval + 0.01)
        #expect(recorder.slots == [.threeFingerClick])
    }

    @Test func physicalFourFingerDoubleClickEmitsConfiguredDoubleClickSlot() {
        let scheduler = ManualPhysicalClickScheduler()
        let suppressor = ScrollSuppressor(clickScheduler: scheduler)
        suppressor.currentFingerCount = 4
        suppressor.isMultitouchActive = true
        let recorder = SlotRecorder()
        suppressor.setPhysicalClickHandler { event in
            recorder.slots.append(event.slot)
        }

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown),
            configuredClickSlotsResolver: { _ in (.fourFingerClick, .fourFingerDoubleClick) }
        ) {
        case .suppress:
            break
        case .passThrough:
            Issue.record("Expected first click to be suppressed")
        }
        switch suppressor.eventDisposition(
            for: .leftMouseUp,
            event: makeLeftClickEvent(.leftMouseUp),
            configuredClickSlotsResolver: { _ in (nil, nil) }
        ) {
        case .suppress:
            break
        case .passThrough:
            Issue.record("Expected first click up to be suppressed")
        }

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown, clickState: 2),
            configuredClickSlotsResolver: { _ in (.fourFingerClick, .fourFingerDoubleClick) }
        ) {
        case .suppress:
            break
        case .passThrough:
            Issue.record("Expected second click to be suppressed")
        }
        #expect(recorder.slots == [.fourFingerDoubleClick])

        switch suppressor.eventDisposition(
            for: .leftMouseUp,
            event: makeLeftClickEvent(.leftMouseUp),
            configuredClickSlotsResolver: { _ in (nil, nil) }
        ) {
        case .suppress:
            break
        case .passThrough:
            Issue.record("Expected second click up to be suppressed")
        }

        scheduler.advance(by: NSEvent.doubleClickInterval + 0.01)
        #expect(recorder.slots == [.fourFingerDoubleClick])
    }

    @Test func configuredPhysicalClickPassesThroughWithoutActiveMultitouch() {
        let cases: [(fingerCount: Int, single: GestureSlot, double: GestureSlot)] = [
            (3, .threeFingerClick, .threeFingerDoubleClick),
            (4, .fourFingerClick, .fourFingerDoubleClick)
        ]

        for testCase in cases {
            let suppressor = ScrollSuppressor()
            let recorder = SlotRecorder()
            suppressor.currentFingerCount = testCase.fingerCount
            suppressor.isMultitouchActive = false
            suppressor.setPhysicalClickHandler { event in
                recorder.slots.append(event.slot)
            }

            switch suppressor.eventDisposition(
                for: .leftMouseDown,
                event: makeLeftClickEvent(.leftMouseDown),
                configuredClickSlotsResolver: { _ in (testCase.single, testCase.double) }
            ) {
            case .passThrough:
                break
            case .suppress:
                Issue.record("Expected configured click down to pass through without active multitouch")
            }

            switch suppressor.eventDisposition(
                for: .leftMouseUp,
                event: makeLeftClickEvent(.leftMouseUp),
                configuredClickSlotsResolver: { _ in (nil, nil) }
            ) {
            case .passThrough:
                break
            case .suppress:
                Issue.record("Expected configured click up to pass through without active multitouch")
            }

            #expect(recorder.slots.isEmpty)
            #expect(suppressor.shouldAllowTouchTap(fingerCount: testCase.fingerCount, at: Date()) == true)
        }
    }

    @Test func configuredPhysicalClickPassesThroughWhileAppInteractionIsActive() {
        let suppressor = ScrollSuppressor()
        suppressor.currentFingerCount = 3
        suppressor.isMultitouchActive = true
        suppressor.setAppInteractionActive(true)
        let recorder = SlotRecorder()
        suppressor.setPhysicalClickHandler { event in
            recorder.slots.append(event.slot)
        }

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown),
            configuredClickSlotsResolver: { _ in (.threeFingerClick, .threeFingerDoubleClick) }
        ) {
        case .passThrough:
            break
        case .suppress:
            Issue.record("Expected configured click down to pass through while app interaction is active")
        }

        switch suppressor.eventDisposition(
            for: .leftMouseUp,
            event: makeLeftClickEvent(.leftMouseUp),
            configuredClickSlotsResolver: { _ in (nil, nil) }
        ) {
        case .passThrough:
            break
        case .suppress:
            Issue.record("Expected configured click up to pass through while app interaction is active")
        }

        #expect(recorder.slots.isEmpty)
        #expect(suppressor.shouldAllowTouchTap(fingerCount: 3, at: Date()) == true)
    }

    @Test func configuredPhysicalClickPassesThroughInSystemMenuBar() {
        let suppressor = ScrollSuppressor()
        suppressor.currentFingerCount = 3
        suppressor.isMultitouchActive = true
        let recorder = SlotRecorder()
        suppressor.setPhysicalClickHandler { event in
            recorder.slots.append(event.slot)
        }

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown, location: makeMenuBarClickLocation()),
            configuredClickSlotsResolver: { _ in (.threeFingerClick, .threeFingerDoubleClick) }
        ) {
        case .passThrough:
            break
        case .suppress:
            Issue.record("Expected configured click in system menu bar to pass through")
        }

        #expect(recorder.slots.isEmpty)
        #expect(suppressor.shouldAllowTouchTap(fingerCount: 3, at: Date()) == true)
    }

    @Test func unconfiguredPhysicalClickPassesThroughWithoutTouchTapDedupWindow() {
        let suppressor = ScrollSuppressor()
        suppressor.currentFingerCount = 3
        suppressor.isMultitouchActive = true

        switch suppressor.eventDisposition(
            for: .leftMouseDown,
            event: makeLeftClickEvent(.leftMouseDown),
            configuredClickSlotsResolver: { _ in (nil, nil) }
        ) {
        case .passThrough:
            break
        case .suppress:
            Issue.record("Expected unconfigured click down to pass through")
        }

        #expect(suppressor.shouldAllowTouchTap(fingerCount: 3, at: Date()) == true)
        #expect(suppressor.shouldAllowTouchTap(fingerCount: 4, at: Date()) == true)

        switch suppressor.eventDisposition(
            for: .leftMouseUp,
            event: makeLeftClickEvent(.leftMouseUp),
            configuredClickSlotsResolver: { _ in (nil, nil) }
        ) {
        case .passThrough:
            break
        case .suppress:
            Issue.record("Expected unconfigured click up to pass through")
        }
    }
}

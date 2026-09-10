import CoreServices
import Foundation
import XCTest
@testable import HippocampusKit

@MainActor
final class ApplicationTerminationRequestGateTests: XCTestCase {
    func test_core_quit_event_latches_one_quit_request() {
        let gate = ApplicationTerminationRequestGate()

        gate.requestQuitIfAppleEvent(event())

        XCTAssertEqual(gate.takeRequestedIntent(), .quit)
        XCTAssertNil(gate.takeRequestedIntent())
    }

    func test_nil_event_keeps_unrequested_termination_blocked() {
        let gate = ApplicationTerminationRequestGate()

        gate.requestQuitIfAppleEvent(nil)

        XCTAssertNil(gate.takeRequestedIntent())
    }

    func test_core_non_quit_event_keeps_termination_blocked() {
        let gate = ApplicationTerminationRequestGate()

        gate.requestQuitIfAppleEvent(event(eventID: AEEventID(kAEOpenApplication)))

        XCTAssertNil(gate.takeRequestedIntent())
    }

    func test_quit_id_with_wrong_event_class_keeps_termination_blocked() {
        let gate = ApplicationTerminationRequestGate()

        gate.requestQuitIfAppleEvent(event(eventClass: AEEventClass(kAEInternetSuite)))

        XCTAssertNil(gate.takeRequestedIntent())
    }

    func test_quit_event_does_not_overwrite_explicit_restart() {
        let gate = ApplicationTerminationRequestGate()
        gate.request(.restart)

        gate.requestQuitIfAppleEvent(event())

        XCTAssertEqual(gate.takeRequestedIntent(), .restart)
        XCTAssertNil(gate.takeRequestedIntent())
    }

    func test_non_quit_events_do_not_consume_explicit_restart() {
        let gate = ApplicationTerminationRequestGate()
        gate.request(.restart)

        gate.requestQuitIfAppleEvent(nil)
        gate.requestQuitIfAppleEvent(event(eventID: AEEventID(kAEOpenApplication)))
        gate.requestQuitIfAppleEvent(event(eventClass: AEEventClass(kAEInternetSuite)))

        XCTAssertEqual(gate.takeRequestedIntent(), .restart)
        XCTAssertNil(gate.takeRequestedIntent())
    }

    func test_explicit_restart_can_replace_latched_apple_quit() {
        let gate = ApplicationTerminationRequestGate()
        gate.requestQuitIfAppleEvent(event())

        gate.request(.restart)

        XCTAssertEqual(gate.takeRequestedIntent(), .restart)
        XCTAssertNil(gate.takeRequestedIntent())
    }

    func test_explicit_quit_and_apple_quit_do_not_leave_a_second_request() {
        let gate = ApplicationTerminationRequestGate()
        gate.request(.quit)

        gate.requestQuitIfAppleEvent(event())

        XCTAssertEqual(gate.takeRequestedIntent(), .quit)
        XCTAssertNil(gate.takeRequestedIntent())
    }

    private func event(
        eventClass: AEEventClass = AEEventClass(kCoreEventClass),
        eventID: AEEventID = AEEventID(kAEQuitApplication)
    ) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: eventClass,
            eventID: eventID,
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }
}

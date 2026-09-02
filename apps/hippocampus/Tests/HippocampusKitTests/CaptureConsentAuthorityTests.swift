// SPDX-License-Identifier: TBD-private
import Foundation
import XCTest
@testable import HippocampusKit

final class CaptureConsentAuthorityTests: XCTestCase {
    private var sandbox: URL!
    private var stateURL: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        stateURL = sandbox.appendingPathComponent("capture-consent.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func testEnablePublishesGenerationAndOwner() throws {
        let authority = CaptureConsentAuthority(
            stateURL: stateURL,
            ownerProcessID: 4242,
            ownerStartTimeUs: 123_000_456
        )

        try authority.enable(generationID: "generation-7")

        let state = try CaptureConsentAuthority.readState(at: stateURL)
        XCTAssertEqual(state.enabled, true)
        XCTAssertEqual(state.generation, "generation-7")
        XCTAssertEqual(state.ownerProcessID, 4242)
        XCTAssertEqual(state.ownerStartTimeUs, 123_000_456)
    }

    func testDisableRevokesPriorGeneration() throws {
        let authority = CaptureConsentAuthority(
            stateURL: stateURL,
            ownerProcessID: 4242,
            ownerStartTimeUs: 123_000_456
        )
        try authority.enable(generationID: "generation-7")

        try authority.disable()

        let state = try CaptureConsentAuthority.readState(at: stateURL)
        XCTAssertEqual(state.enabled, false)
        XCTAssertNil(state.generation)
        XCTAssertEqual(state.ownerProcessID, 4242)
    }

    func testEnableFailsWhenSignedAppGroupIsUnavailable() {
        let authority = CaptureConsentAuthority(
            stateURL: nil,
            ownerProcessID: 4242,
            ownerStartTimeUs: 123_000_456
        )

        XCTAssertThrowsError(try authority.enable(generationID: "generation-8")) {
            XCTAssertEqual($0 as? CaptureConsentError, .appGroupUnavailable)
        }
        XCTAssertNoThrow(try authority.disable())
    }

    func testMissingOrDeadOwnerFailsClosed() {
        XCTAssertFalse(CaptureConsentAuthority.allowsCapture(
            state: nil,
            ownerIdentityMatches: { _, _ in true }
        ))
        XCTAssertFalse(CaptureConsentAuthority.allowsCapture(
            state: CaptureConsentState(
                enabled: true,
                generation: "generation-7",
                ownerProcessID: 4242,
                ownerStartTimeUs: 123_000_456
            ),
            ownerIdentityMatches: { _, _ in false }
        ))
    }

    func testReusedOwnerPIDWithDifferentStartTimeFailsClosed() {
        let state = CaptureConsentState(
            enabled: true,
            generation: "generation-7",
            ownerProcessID: 4242,
            ownerStartTimeUs: 123_000_456
        )

        XCTAssertTrue(CaptureConsentAuthority.allowsCapture(
            state: state,
            ownerIdentityMatches: { pid, startTime in
                pid == 4242 && startTime == 123_000_456
            }
        ))
        XCTAssertFalse(CaptureConsentAuthority.allowsCapture(
            state: state,
            ownerIdentityMatches: { pid, startTime in
                pid == 4242 && startTime == 999_000_000
            }
        ))
    }

    func testAppGroupIdentityRequiresNonemptyBundleMetadata() {
        XCTAssertEqual(
            AppGroupIdentity.identifier(infoDictionary: [
                AppGroupIdentity.infoPlistKey: "A1B2C3D4E5.ai.hippocampus",
            ]),
            "A1B2C3D4E5.ai.hippocampus"
        )
        XCTAssertNil(AppGroupIdentity.identifier(infoDictionary: [:]))
        XCTAssertNil(AppGroupIdentity.identifier(infoDictionary: [
            AppGroupIdentity.infoPlistKey: "  ",
        ]))
    }
}

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
        let authority = CaptureConsentAuthority(stateURL: stateURL, ownerProcessID: 4242)

        try authority.enable(generationID: "generation-7")

        let state = try CaptureConsentAuthority.readState(at: stateURL)
        XCTAssertEqual(state.enabled, true)
        XCTAssertEqual(state.generation, "generation-7")
        XCTAssertEqual(state.ownerProcessID, 4242)
    }

    func testDisableRevokesPriorGeneration() throws {
        let authority = CaptureConsentAuthority(stateURL: stateURL, ownerProcessID: 4242)
        try authority.enable(generationID: "generation-7")

        try authority.disable()

        let state = try CaptureConsentAuthority.readState(at: stateURL)
        XCTAssertEqual(state.enabled, false)
        XCTAssertNil(state.generation)
        XCTAssertEqual(state.ownerProcessID, 4242)
    }

    func testMissingOrDeadOwnerFailsClosed() {
        XCTAssertFalse(CaptureConsentAuthority.allowsCapture(
            state: nil,
            ownerIsAlive: { _ in true }
        ))
        XCTAssertFalse(CaptureConsentAuthority.allowsCapture(
            state: CaptureConsentState(
                enabled: true,
                generation: "generation-7",
                ownerProcessID: 4242
            ),
            ownerIsAlive: { _ in false }
        ))
    }
}

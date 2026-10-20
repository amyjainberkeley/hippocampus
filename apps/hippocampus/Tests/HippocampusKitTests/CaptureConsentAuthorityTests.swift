// SPDX-License-Identifier: Apache-2.0
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

    // MARK: Where the container is (reports/e2e, finding 7)

    /// A development build started with a throwaway home, as every test gate
    /// starts it, keeps consent in that home. macOS's answer, the real
    /// account's container, is never asked for.
    func testADevelopmentBuildKeepsConsentUnderItsOwnHome() throws {
        let home = sandbox.appendingPathComponent("home", isDirectory: true)
        let development: [String: Any] = [
            AppGroupIdentity.infoPlistKey: "group.ai.hippocampus",
            DevelopmentFileKeyMode.infoPlistKey: true,
        ]

        let container = try XCTUnwrap(AppGroupIdentity.containerURL(
            infoDictionary: development,
            home: home,
            systemContainer: { _ in
                XCTFail("a development build must not ask for the account's own container")
                return URL(fileURLWithPath: "/nonexistent/real-account-container", isDirectory: true)
            }
        ))
        XCTAssertEqual(
            container.standardizedFileURL.path,
            home.appendingPathComponent("Library/Group Containers/group.ai.hippocampus").standardizedFileURL.path
        )

        let authority = CaptureConsentAuthority(
            stateURL: container.appendingPathComponent(CaptureConsentAuthority.filename),
            ownerProcessID: 4242,
            ownerStartTimeUs: 1
        )
        try authority.enable(generationID: "generation-1")
        let written = home.appendingPathComponent("Library/Group Containers/group.ai.hippocampus/capture-consent.json")
        XCTAssertEqual(try CaptureConsentAuthority.readState(at: written).generation, "generation-1")
        let mode = try FileManager.default.attributesOfItem(atPath: written.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    /// A release build uses the signed group's container macOS names, which
    /// the Safari extension reads too, wherever HOME points.
    func testAReleaseBuildUsesTheContainerMacOSNames() {
        let system = URL(fileURLWithPath: "/Users/someone/Library/Group Containers/A1B2C3D4E5.ai.hippocampus")
        var asked: [String] = []
        let container = AppGroupIdentity.containerURL(
            infoDictionary: [AppGroupIdentity.infoPlistKey: "A1B2C3D4E5.ai.hippocampus"],
            home: sandbox,
            systemContainer: { identifier in
                asked.append(identifier)
                return system
            }
        )
        XCTAssertEqual(container, system)
        XCTAssertEqual(asked, ["A1B2C3D4E5.ai.hippocampus"])
        // A capability that isn't exactly `true` is a release build.
        XCTAssertEqual(AppGroupIdentity.containerURL(
            infoDictionary: [
                AppGroupIdentity.infoPlistKey: "A1B2C3D4E5.ai.hippocampus",
                DevelopmentFileKeyMode.infoPlistKey: "true",
            ],
            home: sandbox,
            systemContainer: { _ in system }
        ), system)
    }

    func testWithoutAGroupThereIsNoContainer() {
        XCTAssertNil(AppGroupIdentity.containerURL(
            infoDictionary: [DevelopmentFileKeyMode.infoPlistKey: true],
            home: sandbox,
            systemContainer: { _ in self.sandbox }
        ))
    }
}

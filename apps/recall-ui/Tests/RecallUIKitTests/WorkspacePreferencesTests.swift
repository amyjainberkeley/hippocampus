import Foundation
import XCTest
@testable import RecallUIKit

final class WorkspacePreferencesTests: XCTestCase {
    func testPreferencesButtonDoesNotUseAmbiguousBundleURLDispatch() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: package.appendingPathComponent(
            "Sources/RecallUI/Settings/WorkspacePreferencesButton.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("withApplicationAt:"))
        XCTAssertTrue(source.contains("WorkspacePreferencesRouter.shared.open"))
    }

    func testEveryDestinationUsesTheTypedPreferencesRoute() {
        XCTAssertEqual(WorkspacePreferencesDestination.allCases.map { $0.url.absoluteString }, [
            "hippocampus://preferences/general",
            "hippocampus://preferences/capture",
            "hippocampus://preferences/sources",
            "hippocampus://preferences/privacy",
            "hippocampus://preferences/advanced",
            "hippocampus://preferences/about",
        ])
    }

    func testOnlyTheRunningApplicationBundleIsEligibleForPreferences() {
        let installed = URL(fileURLWithPath: "/Applications/Hippocampus.app")
        XCTAssertEqual(WorkspacePreferencesDestination.hostApplication(bundleURL: installed), installed)
        XCTAssertNil(WorkspacePreferencesDestination.hostApplication(
            bundleURL: URL(fileURLWithPath: "/tmp/recall-ui")))
        XCTAssertNil(WorkspacePreferencesDestination.hostApplication(
            bundleURL: URL(string: "https://example.com/Hippocampus.app")!))
    }
}

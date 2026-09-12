import Foundation
import Darwin
import XCTest
@testable import RecallUIKit

final class WorkspacePreferencesRoutingTests: XCTestCase {
    private let bundle = URL(fileURLWithPath: "/Applications/Hippocampus.app")
    private var parent: URL { bundle.appendingPathComponent("Contents/MacOS/Hippocampus") }

    @MainActor
    func testParentLookupIgnoresTheBundlesCachedChildExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Hippocampus.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = macos.appendingPathComponent("Hippocampus")
        let child = macos.appendingPathComponent("recall-ui")
        try Data().write(to: parent)
        try Data().write(to: child)
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "ai.hippocampus.routing-test.\(UUID().uuidString)",
            "CFBundleExecutable": "recall-ui", "CFBundlePackageType": "APPL",
        ], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let cachedBundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertEqual(cachedBundle.executableURL?.resolvingSymlinksInPath(), child.resolvingSymlinksInPath())
        XCTAssertEqual(WorkspacePreferencesRouter.parentExecutable(bundleURL: app), parent.resolvingSymlinksInPath())
        withExtendedLifetime(cachedBundle) {}
    }

    @MainActor
    func testProcessIdentityReadsActualTestProcessAndRejectsMissingPIDs() async throws {
        let executable = try XCTUnwrap(WorkspacePreferencesRouter.executableURL(processID: getpid()))
        XCTAssertTrue(executable.isFileURL)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        XCTAssertNil(WorkspacePreferencesRouter.executableURL(processID: 0))
        XCTAssertNil(WorkspacePreferencesRouter.executableURL(processID: Int32.max))
    }

    func testOnlyExactParentExecutablePreventsLaunch() throws {
        XCTAssertEqual(WorkspacePreferencesDestination.sources.routingPlan(
            bundleURL: bundle, runningExecutableURLs: [parent]), .notify(executable: parent))
        for running in [bundle.appendingPathComponent("Contents/MacOS/recall-ui"),
                        URL(fileURLWithPath: "/Applications/Backup.app/Contents/MacOS/Hippocampus")] {
            XCTAssertEqual(WorkspacePreferencesDestination.sources.routingPlan(
                bundleURL: bundle, runningExecutableURLs: [running]),
                .launch(executable: parent, arguments: ["--open-preferences", "sources"]))
        }
    }

    func testPendingExactParentLaunchDoesNotLaunchAgain() {
        XCTAssertEqual(WorkspacePreferencesDestination.privacy.routingPlan(
            bundleURL: bundle, runningExecutableURLs: [], launchedExecutableURL: parent), .notify(executable: parent))
    }

    func testUnbundledRecallCannotLaunchSomeOtherInstallation() {
        XCTAssertNil(WorkspacePreferencesDestination.sources.routingPlan(
            bundleURL: URL(fileURLWithPath: "/tmp/debug/recall-ui"), runningExecutableURLs: []))
    }

    func testEveryLaunchArgumentIsCanonicalAndContentFree() {
        for destination in WorkspacePreferencesDestination.allCases {
            XCTAssertEqual(destination.routingPlan(bundleURL: bundle, runningExecutableURLs: []),
                           .launch(executable: parent, arguments: ["--open-preferences", destination.rawValue]))
        }
    }
}

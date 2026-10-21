import Foundation
import XCTest
@testable import RecallUIKit

final class WorkspacePreferencesTests: XCTestCase {
    func testTheWindowOpensPreferencesOnlyThroughTheTypedRouter() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = package.appendingPathComponent("Sources/RecallUI")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("withApplicationAt:"), file.lastPathComponent)
        }
        for file in ["MCIRecallApp.swift", "MemoryWorkspaceView.swift"] {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains("WorkspacePreferencesRouter.shared.open"), file)
        }
    }

    func testEveryDestinationUsesTheTypedPreferencesRoute() {
        XCTAssertEqual(WorkspacePreferencesDestination.allCases.map { $0.url.absoluteString }, [
            "hippocampus://preferences/general",
            "hippocampus://preferences/capture",
            "hippocampus://preferences/sources",
            "hippocampus://preferences/privacy",
            "hippocampus://preferences/advanced",
            "hippocampus://preferences/about",
            "hippocampus://setup/browser-extension",
        ])
    }

    /// Add Browser Extension… (SPEC 3.5) asks the exact app that started the
    /// window for setup's panel through the same typed route as a pane: a
    /// notification to that app's own executable while it runs, else that
    /// executable launched with the panel's name. Never a link.
    func testSetupsBrowserExtensionPanelGoesThroughTheTypedRoute() {
        let bundle = URL(fileURLWithPath: "/Applications/Hippocampus.app")
        let parent = bundle.appendingPathComponent("Contents/MacOS/Hippocampus").resolvingSymlinksInPath()
        let destination = WorkspacePreferencesDestination.browserExtension
        XCTAssertEqual(destination.routingPlan(bundleURL: bundle, runningExecutableURLs: [parent]),
                       .notify(executable: parent))
        XCTAssertEqual(destination.routingPlan(bundleURL: bundle, runningExecutableURLs: []),
                       .launch(executable: parent, arguments: ["--open-preferences", "browser-extension"]))
        let id = UUID()
        XCTAssertEqual(destination.notificationInfo(id: id), ["section": "browser-extension", "request_id": id.uuidString])
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

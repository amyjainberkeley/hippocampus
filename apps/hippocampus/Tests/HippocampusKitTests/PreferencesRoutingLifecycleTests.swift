// SPDX-License-Identifier: TBD-private
import XCTest

/// Structural checks for the executable's lifecycle; route behavior is tested
/// separately without launching the app or touching owner preferences.
final class PreferencesRoutingLifecycleTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: package.appendingPathComponent("Sources/Hippocampus/\(name)"), encoding: .utf8)
    }

    private func method(_ declaration: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: declaration))
        let end = try XCTUnwrap(source.range(of: "\n    }", range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.upperBound])
    }

    func testPreferencesDependenciesHaveOneAppDelegateOwnerSharedWithMenu() throws {
        let app = try source("HippocampusApp.swift")
        let boundary = try XCTUnwrap(app.range(of: "final class AppDelegate:"))
        let delegate = String(app[boundary.lowerBound...])
        let scene = String(app[..<boundary.lowerBound])
        for constructor in ["PreferencesStore()", "LoginItemViewModel(service: SMLoginItemService())", "SparkleUpdaterService()"] {
            XCTAssertEqual(app.components(separatedBy: constructor).count - 1, 1, constructor)
            XCTAssertTrue(delegate.contains(constructor), constructor)
            XCTAssertFalse(scene.contains(constructor), constructor)
        }
        for dependency in ["preferencesStore", "loginItemVM", "updater"] {
            XCTAssertTrue(scene.contains("\(dependency): appDelegate.\(dependency)"), dependency)
        }
        XCTAssertFalse(scene.contains("configurePreferencesController()"))
    }

    func testPreferencesConfigureSynchronouslyAtLaunchBeforeAsyncWork() throws {
        let app = try source("HippocampusApp.swift")
        let launch = try method("func applicationDidFinishLaunching(", in: app)
        let configure = try XCTUnwrap(launch.range(of: "configurePreferencesController()"))
        let task = try XCTUnwrap(launch.range(of: "Task {"))
        XCTAssertLessThan(configure.lowerBound, task.lowerBound)
    }

    func testColdPreferencesRouteConfiguresBeforeShowingOnlyRequestedPane() throws {
        let app = try source("HippocampusApp.swift")
        let handler = try method("func application(_ application: NSApplication, open urls: [URL])", in: app)
        let start = try XCTUnwrap(handler.range(of: "case .openPreferences(let section):"))
        let end = try XCTUnwrap(handler.range(of: "\n            case ", range: start.upperBound..<handler.endIndex))
        let branch = String(handler[start.upperBound..<end.lowerBound])
        XCTAssertEqual(branch.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }, [
            "configurePreferencesController()",
            "PreferencesWindowController.shared.show(section: section)",
        ])
    }

    func testControllerConfigurationIsOneShotAndDoesNotRunConsentActions() throws {
        let app = try source("HippocampusApp.swift")
        let configure = try method("private func configurePreferencesController()", in: app)
        XCTAssertTrue(configure.contains("guard !preferencesControllerConfigured else { return }"))
        XCTAssertTrue(configure.contains("preferencesControllerConfigured = true"))
        XCTAssertTrue(configure.contains("PreferencesWindowController.shared.configure("))
        XCTAssertFalse(configure.contains("startUpdater()"))
        XCTAssertFalse(configure.contains("markPrompted()"))
        XCTAssertFalse(configure.contains("installSessionContext"))
        XCTAssertFalse(configure.contains("setCaptureEnabled("))
    }

    func testSourcesKeepsExistingConsentViewAndSingleSectionType() throws {
        let window = try source("PreferencesWindow.swift")
        XCTAssertTrue(window.contains("case .sources: SessionContextPreferencesView(supervisor: supervisor)"))
        XCTAssertFalse(window.contains("enum PreferencesSection:"))
        XCTAssertTrue(window.contains("extension PreferencesSection {"))
    }
}

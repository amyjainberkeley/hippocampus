import XCTest
@testable import OnboardingKit

/// Rules that live in the view files, which tests cannot import.
final class OnboardingSourceScanTests: XCTestCase {
    private func sources() throws -> [(name: String, text: String)] {
        let root = onboardingPackageRoot.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return try files.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testSetupNeverAsksForCalendarOrContacts() throws {
        for (name, text) in try sources() {
            for call in ["EKEventStore", "CNContactStore", "requestFullAccessToEvents", "requestAccess(for:"] {
                XCTAssertFalse(text.contains(call), "\(name) mentions \(call)")
            }
        }
    }

    func testKeySetupStartsWhenPermissionsAppears() throws {
        let slide = try String(
            contentsOf: onboardingPackageRoot.appendingPathComponent("Sources/Onboarding/Slides/PermissionsSlide.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(slide.contains(".task {\n            await prepareBrainVM.generateKey()\n        }"))
    }

    func testViewModelsKeepTheirStoresInMemoryUnlessSetupPassesTheFiles() throws {
        for file in ["FourScreenFlowViewModel.swift", "OnboardingFlowViewModel.swift"] {
            let text = try String(
                contentsOf: onboardingPackageRoot.appendingPathComponent("Sources/OnboardingKit/\(file)"),
                encoding: .utf8
            )
            XCTAssertTrue(text.contains("stateStore: any OnboardingStateStore = InMemoryOnboardingStateStore()"), file)
            XCTAssertFalse(text.contains("= FileOnboardingStateStore()"), "\(file): a default that writes the person's file")
        }
        let app = try String(
            contentsOf: onboardingPackageRoot.appendingPathComponent("Sources/Onboarding/OnboardingApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(app.contains("stateStore: FileOnboardingStateStore()"), "setup itself keeps its place")
    }

    func testNoTestWritesADefaultsSuite() throws {
        // A suite leaves a file in the person's ~/Library/Preferences, and
        // CFFIXED_USER_HOME does not move it.
        let needle = "UserDefaults(" + "suiteName"
        let root = onboardingPackageRoot.appendingPathComponent("Tests")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains(needle), url.lastPathComponent)
        }
    }

    func testClosingTheWindowEndsSetup() throws {
        let app = try String(
            contentsOf: onboardingPackageRoot.appendingPathComponent("Sources/Onboarding/OnboardingApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(app.contains(
            "func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {\n        true\n    }"
        ))
    }

    func testOnlyAChildProcessAsksForScreenRecording() throws {
        for (name, text) in try sources() where name != "OnboardingEntryPoint.swift" {
            let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            XCTAssertFalse(code.contains { $0.contains("CGRequestScreenCaptureAccess(") }, name)
        }
    }
}

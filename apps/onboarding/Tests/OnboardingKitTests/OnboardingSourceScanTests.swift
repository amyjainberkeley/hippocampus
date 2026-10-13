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

    func testOnlyAChildProcessAsksForScreenRecording() throws {
        for (name, text) in try sources() where name != "OnboardingEntryPoint.swift" {
            let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            XCTAssertFalse(code.contains { $0.contains("CGRequestScreenCaptureAccess(") }, name)
        }
    }
}

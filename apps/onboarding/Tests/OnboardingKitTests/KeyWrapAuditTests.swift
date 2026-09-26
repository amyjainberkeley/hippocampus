import XCTest
@testable import OnboardingKit

final class KeyWrapAuditTests: XCTestCase {
    func test_onboarding_reports_reference_without_claiming_a_successful_probe() {
        let report = KeyWrapAuditor.keychainReferenceReport()

        XCTAssertEqual(report.implementationName, "macOS file-based Keychain")
        XCTAssertEqual(report.severity, .production)
        XCTAssertFalse(report.sealed)
        XCTAssertTrue(report.identifier.contains("ai.hippocampus.brain"))
        XCTAssertTrue(report.identifier.contains("database-key-v1"))
        XCTAssertTrue(report.notes.contains(where: { $0.contains("not authorized") }))
    }

    func test_in_memory_report_is_development_only() {
        let report = KeyWrapAuditor.inMemoryReport()

        XCTAssertEqual(report.severity, .devOnly)
        XCTAssertEqual(report.reveal, .none)
    }
}

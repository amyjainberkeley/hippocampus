// SPDX-License-Identifier: TBD-private
import XCTest

final class TroubleshootMenuTests: XCTestCase {

    private var scriptPath: String? {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()  // HippocampusKitTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // apps/hippocampus/
            .deletingLastPathComponent()  // apps/
            .deletingLastPathComponent()  // repo root
        let candidate = repoRoot
            .appendingPathComponent("scripts")
            .appendingPathComponent("tcc-reset.sh")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate.path
        }
        return nil
    }

    func test_tcc_reset_script_exists_and_is_executable() throws {
        guard let path = scriptPath else {
            throw XCTSkip("tcc-reset.sh not found at expected repo location")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs[.posixPermissions] as? Int) ?? 0
        XCTAssertTrue(perms & 0o111 != 0, "tcc-reset.sh should be executable")
    }

    func test_tcc_reset_script_contains_all_services() throws {
        guard let path = scriptPath else {
            throw XCTSkip("tcc-reset.sh not found at expected repo location")
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(content.contains("tccutil reset ScreenCapture"), "Should reset ScreenCapture")
        XCTAssertTrue(content.contains("tccutil reset Accessibility"), "Should reset Accessibility")
        XCTAssertTrue(content.contains("tccutil reset SystemPolicyAllFiles"), "Should reset SystemPolicyAllFiles")
        XCTAssertTrue(content.contains("MCICaptureHelper"), "Should mention MCICaptureHelper grant instructions")
    }

    func test_feedback_mailto_url_is_valid() {
        let version = "0.1.0"
        let subject = "Hippocampus feedback v\(version)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "mailto:hippocampus@amyjainberkeley.com?subject=\(subject)"
        XCTAssertNotNil(URL(string: urlString), "Feedback mailto URL should be valid")
    }

    func test_feedback_mailto_url_with_special_version() {
        let version = "1.2.3-beta+build.42"
        let subject = "Hippocampus feedback v\(version)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "mailto:hippocampus@amyjainberkeley.com?subject=\(subject)"
        let url = URL(string: urlString)
        XCTAssertNotNil(url, "Feedback mailto URL should handle semver prerelease versions")
    }

    func test_settings_pane_urls_are_valid() {
        let panes = ["Privacy_ScreenCapture", "Privacy_Accessibility"]
        for pane in panes {
            let urlStr = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
            XCTAssertNotNil(URL(string: urlStr), "Settings URL for \(pane) should be valid")
        }
    }
}

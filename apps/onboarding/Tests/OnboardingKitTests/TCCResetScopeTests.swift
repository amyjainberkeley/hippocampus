import Foundation
import XCTest

/// `tccutil reset <service>` without a bundle id revokes that permission for
/// every app on the Mac. Every reset Hippocampus runs must name itself.
final class TCCResetScopeTests: XCTestCase {
    func testEveryTCCResetNamesHippocampus() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OnboardingKit/RealTCCPermission.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let resets = text.components(separatedBy: "\n").filter { $0.contains("[\"reset\"") }
        XCTAssertEqual(resets.count, 3, "update this test when resets are added or removed")
        for line in resets {
            XCTAssertTrue(line.contains("ai.hippocampus") || line.contains("bid]"), line)
        }
    }
}

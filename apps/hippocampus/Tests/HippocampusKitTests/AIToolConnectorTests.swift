import Foundation
import XCTest
@testable import HippocampusKit

final class AIToolConnectorTests: XCTestCase {
    func testRegistrationDoesNotRequestHooksOrTranscriptImports() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appendingPathComponent("agent")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
        let report = try await AIToolConnector(agentURL: agent, baseEnvironment: [:]).connectAll()
        XCTAssertEqual(report.components(separatedBy: "\n"), ["register-clients"])
    }
}

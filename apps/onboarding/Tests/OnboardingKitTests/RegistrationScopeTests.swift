import Foundation
import XCTest
@testable import OnboardingKit

final class RegistrationScopeTests: XCTestCase {
    func testRegistrationAndRecoveryCommandHaveNoImportSideEffects() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("registration-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appendingPathComponent("agent")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
        let registrar = DefaultClaudeCodeRegistrar(agentURL: agent)
        let report = try await registrar.register()
        XCTAssertEqual(report, "register-clients")
        XCTAssertEqual(registrar.manualCommand, "mci-agent register-clients")
    }

    func testSilentAgentDoesNotClaimVerifiedConnection() async throws {
        let report = try await DefaultClaudeCodeRegistrar(
            agentURL: URL(fileURLWithPath: "/usr/bin/true")
        ).register()
        XCTAssertTrue(report.contains("not been verified"))
    }
}

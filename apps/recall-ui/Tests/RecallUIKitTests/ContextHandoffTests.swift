import Foundation
import Testing
@testable import RecallUIKit

@Suite("Context handoff")
struct ContextHandoffTests {
    @Test("cancelled context requests terminate their local child promptly")
    func cancellationTerminatesChild() async throws {
        let command = ContextHandoffCommand(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"])
        let task = Task { try await ContextHandoffExporter.run(command: command, timeoutSeconds: 10) }
        try await Task.sleep(for: .milliseconds(100))
        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled child returned successfully")
        } catch is CancellationError {
            #expect(Date().timeIntervalSince(cancelledAt) < 2)
        }
    }
    @Test("what is asked goes on the child's standard input, and a locked memory is said as such")
    func inputGoesOnStandardInput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let echo = folder.appendingPathComponent("echo-agent")
        try "#!/bin/sh\ncat\n".write(to: echo, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: echo.path)
        let output = try await ContextHandoffExporter.run(
            command: ContextHandoffCommand(executableURL: echo, arguments: ["send-card", "--json"]),
            timeoutSeconds: 10, input: Data(#"{"to":"copy","question":"private words"}"#.utf8)
        )
        #expect(output == #"{"to":"copy","question":"private words"}"#)

        let locked = folder.appendingPathComponent("locked-agent")
        try "#!/bin/sh\ncat > /dev/null\nexit 10\n".write(to: locked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
        await #expect(throws: ContextHandoffError.memoryLocked) {
            try await ContextHandoffExporter.run(
                command: ContextHandoffCommand(executableURL: locked, arguments: []), timeoutSeconds: 10,
                input: Data("{}".utf8)
            )
        }
        // Commands that read no input keep their own failure.
        await #expect(throws: ContextHandoffError.commandFailed) {
            try await ContextHandoffExporter.run(
                command: ContextHandoffCommand(executableURL: locked, arguments: []), timeoutSeconds: 10
            )
        }
    }

    @Test("builds a bounded Markdown command for the bundled agent")
    func buildsBoundedMarkdownCommand() throws {
        let executable = URL(fileURLWithPath: "/Applications/Hippocampus.app/Contents/MacOS/recall-ui")
        let command = try ContextHandoffCommand.make(
            focus: "  HIP-204 launch owner  ",
            environment: ["MCI_DB_PATH": "/tmp/demo.sqlite"],
            recallExecutableURL: executable,
            isExecutable: { $0.path == "/Applications/Hippocampus.app/Contents/MacOS/mci-agent" }
        )

        #expect(command.executableURL.path == "/Applications/Hippocampus.app/Contents/MacOS/mci-agent")
        #expect(command.arguments == [
            "context",
            "--db-path", "/tmp/demo.sqlite",
            "--focus", "HIP-204 launch owner",
            "--max-tokens", "1200",
            "--max-evidence", "24",
            "--format", "markdown",
        ])
    }

    @Test("prefers an explicit development agent path")
    func prefersExplicitDevelopmentAgentPath() throws {
        let command = try ContextHandoffCommand.make(
            focus: "",
            environment: [
                "MCI_AGENT_PATH": "/tmp/dev/mci-agent",
                "MCI_DEVELOPMENT_FILE_KEY": "1",
            ],
            recallExecutableURL: URL(fileURLWithPath: "/tmp/recall-ui"),
            isExecutable: { $0.path == "/tmp/dev/mci-agent" }
        )

        #expect(command.executableURL.path == "/tmp/dev/mci-agent")
        #expect(!command.arguments.contains("--focus"))
        #expect(!command.arguments.contains("--db-path"))
    }

    @Test("fails closed when no trusted local agent executable exists")
    func rejectsMissingExecutable() {
        #expect(throws: ContextHandoffError.agentUnavailable) {
            try ContextHandoffCommand.make(
                focus: "current work",
                environment: [:],
                recallExecutableURL: URL(fileURLWithPath: "/tmp/recall-ui"),
                isExecutable: { _ in false }
            )
        }
    }
}

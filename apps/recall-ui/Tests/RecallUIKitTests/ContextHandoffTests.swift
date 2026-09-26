import Foundation
import Testing
@testable import RecallUIKit

@Suite("Context handoff")
struct ContextHandoffTests {
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

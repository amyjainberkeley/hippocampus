import Darwin
import Foundation
import OnboardingKit

@main
struct AIToolConnectorBehavior {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hippocampus-ai-connector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let childPID = root.appendingPathComponent("child.pid")
        let slowAgent = root.appendingPathComponent("slow-agent")
        try """
        #!/usr/bin/perl
        open my $pid_file, '>', '\(childPID.path)' or die $!;
        print $pid_file "$$\\n";
        close $pid_file;
        $SIG{TERM} = sub { exit 0 };
        sleep 5
        """.write(to: slowAgent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: slowAgent.path
        )

        let started = Date()
        do {
            _ = try await DefaultClaudeCodeRegistrar(
                agentURL: slowAgent,
                timeoutSeconds: 0.5
            ).register()
            fatalError("slow connector unexpectedly succeeded")
        } catch let error as ClaudeCodeRegistrarError {
            guard case .timedOut = error else {
                fatalError("expected timedOut, got \(error)")
            }
        }
        precondition(Date().timeIntervalSince(started) < 2, "connector timeout was not bounded")

        let receiptDeadline = Date().addingTimeInterval(0.5)
        while !FileManager.default.fileExists(atPath: childPID.path), Date() < receiptDeadline {
            try? await Task<Never, Never>.sleep(nanoseconds: 25_000_000)
        }
        let pid = try String(contentsOf: childPID, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let processIdentifier = Int32(pid) else {
            fatalError("connector did not publish a child pid")
        }
        precondition(kill(processIdentifier, 0) == -1 && errno == ESRCH, "timed-out connector is still alive")

        let noisyAgent = root.appendingPathComponent("noisy-agent")
        try """
        #!/usr/bin/perl
        for (my $i = 0; $i < 12000; $i++) {
          printf "connected-line-%05d.......................................................\\n", $i;
        }
        """.write(to: noisyAgent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: noisyAgent.path
        )

        let output = try await DefaultClaudeCodeRegistrar(
            agentURL: noisyAgent,
            timeoutSeconds: 5
        ).register()
        precondition(!output.isEmpty, "successful connector returned no user message")
        precondition(output.utf8.count <= 8_192, "connector output was not bounded")

        let failingAgent = root.appendingPathComponent("failing-agent")
        try """
        #!/bin/sh
        echo 'private/internal/path should stay hidden' >&2
        exit 7
        """.write(to: failingAgent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: failingAgent.path
        )
        do {
            _ = try await DefaultClaudeCodeRegistrar(
                agentURL: failingAgent,
                timeoutSeconds: 2
            ).register()
            fatalError("failing connector unexpectedly succeeded")
        } catch {
            precondition(
                !error.localizedDescription.contains("private/internal/path"),
                "raw connector stderr leaked into onboarding copy"
            )
        }

        print("PASS: AI tool connector timeout, cleanup, output, and error bounds")
    }
}

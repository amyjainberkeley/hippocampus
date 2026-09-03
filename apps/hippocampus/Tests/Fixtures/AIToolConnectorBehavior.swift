import Darwin
import Foundation
import HippocampusKit

@main
struct AIToolConnectorBehavior {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hippocampus-menu-connector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let childPID = root.appendingPathComponent("child.pid")
        let slowAgent = try executable(
            named: "slow-agent",
            in: root,
            source: """
            #!/usr/bin/perl
            open my $pid_file, '>', '\(childPID.path)' or die $!;
            print $pid_file "$$\\n";
            close $pid_file;
            $SIG{TERM} = sub { exit 0 };
            sleep 5
            """
        )

        let started = Date()
        do {
            _ = try await AIToolConnector(
                agentURL: slowAgent,
                baseEnvironment: [:],
                timeoutSeconds: 0.5
            ).connectAll()
            fatalError("slow connector unexpectedly succeeded")
        } catch let error as AIToolConnectorError {
            guard case .timedOut = error else {
                fatalError("expected timedOut, got \(error)")
            }
        }
        precondition(Date().timeIntervalSince(started) < 2, "menu connector timeout was not bounded")

        let pid = try String(contentsOf: childPID, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let processIdentifier = Int32(pid) else {
            fatalError("connector did not publish a child pid")
        }
        precondition(kill(processIdentifier, 0) == -1 && errno == ESRCH, "timed-out menu connector is still alive")

        let noisyAgent = try executable(
            named: "noisy-agent",
            in: root,
            source: """
            #!/usr/bin/perl
            for (my $i = 0; $i < 12000; $i++) {
              printf "connected-line-%05d.......................................................\\n", $i;
            }
            """
        )
        let output = try await AIToolConnector(
            agentURL: noisyAgent,
            baseEnvironment: [:],
            timeoutSeconds: 5
        ).connectAll()
        precondition(!output.isEmpty, "successful menu connector returned no user message")
        precondition(output.utf8.count <= 8_192, "menu connector output was not bounded")

        let failingAgent = try executable(
            named: "failing-agent",
            in: root,
            source: """
            #!/bin/sh
            echo 'private/internal/path should stay hidden' >&2
            exit 7
            """
        )
        do {
            _ = try await AIToolConnector(
                agentURL: failingAgent,
                baseEnvironment: [:],
                timeoutSeconds: 2
            ).connectAll()
            fatalError("failing connector unexpectedly succeeded")
        } catch {
            precondition(
                !error.localizedDescription.contains("private/internal/path"),
                "raw connector stderr leaked into user-facing copy"
            )
        }

        print("PASS: menu AI connector timeout, cleanup, output, and error bounds")
    }

    private static func executable(named name: String, in root: URL, source: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

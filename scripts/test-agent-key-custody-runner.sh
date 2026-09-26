#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER_SOURCE="$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/KeyCustodyCommandRunner.swift"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/key-custody-runner.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

cat > "$TEST_ROOT/noisy-agent.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for ((index = 0; index < 20000; index++)); do
    printf 'diagnostic-line-%05d-abcdefghijklmnopqrstuvwxyz\n' "$index" >&2
done
sleep 0.35
exit 17
EOF
chmod 700 "$TEST_ROOT/noisy-agent.sh"

cat > "$TEST_ROOT/TestMain.swift" <<'EOF'
import Foundation

@main
struct TestMain {
    static func main() async throws {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let tick = TickState()

        let result = try await Task { @MainActor in
            Task { @MainActor in
                try await Task.sleep(for: .milliseconds(50))
                tick.didTick = true
            }
            return try await KeyCustodyCommandRunner.run(
                executableURL: executableURL,
                arguments: [],
                environment: ProcessInfo.processInfo.environment
            )
        }.value

        guard tick.didTick else {
            throw TestFailure("runner blocked the main actor")
        }
        guard result.terminationStatus == 17 else {
            throw TestFailure("unexpected status: \(result.terminationStatus)")
        }
        guard result.diagnostic.utf8.count <= KeyCustodyCommandRunner.diagnosticLimit else {
            throw TestFailure("diagnostic exceeded the byte limit")
        }
        guard result.diagnostic.contains("diagnostic-line-") else {
            throw TestFailure("bounded diagnostic was empty")
        }

        let cancellationStart = ContinuousClock.now
        let cancellationTask = Task {
            try await KeyCustodyCommandRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                environment: ProcessInfo.processInfo.environment
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        cancellationTask.cancel()
        do {
            _ = try await cancellationTask.value
            throw TestFailure("cancelled runner returned a process result")
        } catch is CancellationError {
            // Expected.
        }
        guard ContinuousClock.now - cancellationStart < .seconds(2) else {
            throw TestFailure("cancelled runner did not terminate its child promptly")
        }

        print("PASS: noisy child completes without blocking the main actor")
        print("PASS: diagnostic capture is bounded")
        print("PASS: cancellation terminates the child process")
    }
}

@MainActor
final class TickState {
    var didTick = false
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
EOF

xcrun swiftc \
    -parse-as-library \
    -package-name Hippocampus \
    -strict-concurrency=complete \
    -warnings-as-errors \
    "$RUNNER_SOURCE" \
    "$TEST_ROOT/TestMain.swift" \
    -o "$TEST_ROOT/test-runner"

"$TEST_ROOT/test-runner" "$TEST_ROOT/noisy-agent.sh"

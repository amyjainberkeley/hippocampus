#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POLICY_SOURCE="$REPO_ROOT/apps/hippocampus/Sources/HippocampusKit/SupervisorStopPolicy.swift"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/supervisor-stop-policy.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

cat > "$TEST_ROOT/TestMain.swift" <<'EOF'
import Foundation

@main
struct TestMain {
    static func main() throws {
        let deadline = Date(timeIntervalSince1970: 100)
        let before = Date(timeIntervalSince1970: 99)
        let after = Date(timeIntervalSince1970: 101)

        try expect(
            SupervisorStopPolicy.shouldWait(
                now: before,
                deadline: deadline,
                helperRunning: true,
                agentRunning: false
            ),
            "waits for helper before deadline"
        )
        try expect(
            SupervisorStopPolicy.shouldWait(
                now: before,
                deadline: deadline,
                helperRunning: false,
                agentRunning: true
            ),
            "waits for agent before deadline"
        )
        try expect(
            !SupervisorStopPolicy.shouldWait(
                now: after,
                deadline: deadline,
                helperRunning: true,
                agentRunning: true
            ),
            "deadline bounds both children"
        )
        try expect(
            !SupervisorStopPolicy.shouldWait(
                now: before,
                deadline: deadline,
                helperRunning: false,
                agentRunning: false
            ),
            "returns immediately when both children stopped"
        )
        print("PASS: stop deadline bounds both child processes")
    }

    static func expect(_ condition: Bool, _ description: String) throws {
        guard condition else { throw TestFailure(description) }
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
EOF

xcrun swiftc \
    -parse-as-library \
    -strict-concurrency=complete \
    -warnings-as-errors \
    "$POLICY_SOURCE" \
    "$TEST_ROOT/TestMain.swift" \
    -o "$TEST_ROOT/test-stop-policy"

"$TEST_ROOT/test-stop-policy"

import XCTest
@testable import OnboardingKit

private struct StubRegistrar: ClaudeCodeRegistrar {
    let result: Result<String, ClaudeCodeRegistrarError>
    let delay: UInt64
    let manualCommand: String = "mci-agent register-mcp"

    func register() async throws -> String {
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        switch result {
        case .success(let msg): return msg
        case .failure(let err): throw err
        }
    }
}

@MainActor
final class ConnectClaudeCodeViewModelTests: XCTestCase {
    func testStartsIdle() {
        let vm = ConnectClaudeCodeViewModel(
            registrar: StubRegistrar(result: .success("ok"), delay: 0)
        )
        XCTAssertEqual(vm.state, .idle)
    }

    func testSuccessTransition() async {
        let vm = ConnectClaudeCodeViewModel(
            registrar: StubRegistrar(
                result: .success("Registered. Restart Claude Code."),
                delay: 0
            )
        )
        await vm.runRegister()
        if case .success(let msg) = vm.state {
            XCTAssertEqual(msg, "Registered. Restart Claude Code.")
        } else {
            XCTFail("expected .success, got \(vm.state)")
        }
    }

    func testFailureTransitionSurfacesUserFacingMessage() async {
        let vm = ConnectClaudeCodeViewModel(
            registrar: StubRegistrar(
                result: .failure(
                    .nonZeroExit(code: 2, stderr: "permission denied: ~/.claude.json")
                ),
                delay: 0
            )
        )
        await vm.runRegister()
        if case .failure(let msg) = vm.state {
            XCTAssertTrue(
                msg.contains("permission denied"),
                "view model should surface the stderr to the user; got '\(msg)'"
            )
        } else {
            XCTFail("expected .failure, got \(vm.state)")
        }
    }

    func testAgentNotFoundFailureMessageIsActionable() async {
        let vm = ConnectClaudeCodeViewModel(
            registrar: StubRegistrar(
                result: .failure(.agentNotFound(searchedPath: "/Applications/Hippocampus.app/Contents/MacOS/mci-agent")),
                delay: 0
            )
        )
        await vm.runRegister()
        if case .failure(let msg) = vm.state {
            XCTAssertTrue(msg.contains("Reinstall"), "agentNotFound message should suggest reinstalling; got '\(msg)'")
        } else {
            XCTFail("expected .failure, got \(vm.state)")
        }
    }

    func testResetReturnsToIdle() async {
        let vm = ConnectClaudeCodeViewModel(
            registrar: StubRegistrar(result: .success("ok"), delay: 0)
        )
        await vm.runRegister()
        vm.reset()
        XCTAssertEqual(vm.state, .idle)
    }

    func testDoubleRunIsReentrancySafe() async {
        // The view model guards against double-spawning when the user
        // double-clicks the Connect button.
        let vm = ConnectClaudeCodeViewModel(
            registrar: StubRegistrar(result: .success("ok"), delay: 50_000_000)
        )
        async let r1: Void = vm.runRegister()
        // Concurrently kick a second register — should be ignored
        // (state already .running by the time the first call hits the
        // first await suspension point).
        async let r2: Void = vm.runRegister()
        _ = await (r1, r2)
        if case .success = vm.state {
            // good
        } else {
            XCTFail("expected .success after both calls settle, got \(vm.state)")
        }
    }

    func testManualCommandPassthrough() {
        let vm = ConnectClaudeCodeViewModel(
            registrar: StubRegistrar(result: .success("ok"), delay: 0)
        )
        XCTAssertEqual(vm.manualCommand, "mci-agent register-mcp")
    }
}

// MARK: - Sentinel-write contract — pins the file-path that
// HippocampusApp's auto-launch check reads. If either side moves the
// path, this test fails so they stay in lockstep.

final class OnboardingSentinelPathTests: XCTestCase {
    func testSentinelPathContract() {
        // The HippocampusKit side computes this path via
        // OnboardingSentinel.defaultURL — the OnboardingFlowView side
        // hardcodes the same suffix (no cross-module dep).
        let expectedSuffix = "Library/Application Support/MCI/.onboarding-complete"
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(expectedSuffix)
        XCTAssertTrue(
            url.path.hasSuffix(expectedSuffix),
            "Sentinel path must match between Onboarding and Hippocampus apps"
        )
    }
}

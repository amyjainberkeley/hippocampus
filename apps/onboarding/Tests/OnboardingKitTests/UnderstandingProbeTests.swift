import XCTest
@testable import OnboardingKit

final class UnderstandingProbeTests: XCTestCase {
    private func availability(_ line: String) -> UnderstandingAvailability {
        UnderstandingProbe.availability(fromReadyLine: line)
    }

    func testAModelOnThisMacAnswersLikeAppleIntelligence() {
        XCTAssertEqual(availability(#"{"available":true,"ready":true}"#), .available)
        XCTAssertEqual(availability(#"{"available":true,"ready":true,"engine":"apple-foundation-models"}"#), .available)
        XCTAssertEqual(availability(#"{"available":true,"ready":true,"engine":"local:qwen3:4b"}"#), .available)
    }

    func testWithNeitherAppleIntelligenceNorAModelThereIsNoModel() {
        // What the mind says with no settings when neither answers.
        XCTAssertEqual(availability(#"{"available":false,"ready":true,"reason":"needs_apple_intelligence_or_local_model"}"#), .noModel)
        // A model server named in its settings that cannot answer.
        for reason in ["local_server_unreachable", "local_model_unset", "local_model_missing",
                       "local_model_not_local", "local_server_not_local"] {
            XCTAssertEqual(availability(#"{"available":false,"ready":true,"reason":"\#(reason)"}"#), .noModel, reason)
        }
        // A reason this version does not know, or a line it cannot read.
        XCTAssertEqual(availability(#"{"available":false,"ready":true,"reason":"something_new"}"#), .noModel)
        XCTAssertEqual(availability(""), .noModel)
    }

    func testAppleIntelligenceReasonsKeepTheirOwnLines() {
        XCTAssertEqual(availability(#"{"available":false,"ready":true,"reason":"model_not_ready"}"#), .preparing)
        // Only when it is set to use Apple Intelligence alone.
        XCTAssertEqual(availability(#"{"available":false,"ready":true,"reason":"apple_intelligence_off"}"#), .turnedOff)
        for reason in ["needs_macos_26", "device_not_eligible", "unavailable"] {
            XCTAssertEqual(availability(#"{"available":false,"ready":true,"reason":"\#(reason)"}"#), .unsupported, reason)
        }
    }

    func testAMissingBinaryAnswersNothing() async {
        let result = await UnderstandingProbe.check(mind: nil)
        XCTAssertEqual(result, .noModel)
    }

    func testTheChildGetsHomeSoItFindsTheModelSettings() {
        // The mind reads ~/Library/Application Support/MCI/model.json, as
        // it does when the agent starts it with PATH and HOME.
        XCTAssertEqual(
            UnderstandingProbe.environment(["HOME": "/Users/someone", "SECRET_TOKEN": "x", "PATH": "/opt/bin"]),
            ["PATH": "/usr/bin:/bin", "HOME": "/Users/someone"]
        )
        XCTAssertEqual(UnderstandingProbe.environment([:]), ["PATH": "/usr/bin:/bin"])
        XCTAssertEqual(UnderstandingProbe.environment(["HOME": ""]), ["PATH": "/usr/bin:/bin"])
    }

    func testTheCheckReadsTheChildsFirstLine() async throws {
        // A stand-in for hippocampus-mind that answers through a model on
        // this Mac only when it was given this process's HOME.
        let home = try XCTUnwrap(ProcessInfo.processInfo.environment["HOME"], "the test runs with HOME set")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("understanding-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mind = directory.appendingPathComponent("hippocampus-mind")
        let script = """
        #!/bin/sh
        if [ "$1" = "--serve" ] && [ "$HOME" = '\(home)' ]; then
          echo '{"ready":true,"available":true,"engine":"local:qwen3:4b"}'
        else
          echo '{"ready":true,"available":false,"reason":"needs_apple_intelligence_or_local_model"}'
        fi
        cat >/dev/null
        """
        try Data(script.utf8).write(to: mind)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mind.path)

        let result = await UnderstandingProbe.check(mind: mind, timeout: 10)
        XCTAssertEqual(result, .available)
    }
}

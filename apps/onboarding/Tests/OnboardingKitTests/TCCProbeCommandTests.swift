import XCTest
@testable import OnboardingKit

final class TCCProbeCommandTests: XCTestCase {
    private let program = "/Applications/Hippocampus.app/Contents/MacOS/onboarding"

    func testTheProbeExitsZeroWhenAllowedAndOneWhenNot() {
        let probe = [program, "--tcc-probe", "screen-recording"]
        XCTAssertEqual(TCCProbeCommand.exitCode(arguments: probe, preflight: { true }, request: { XCTFail(); return false }), 0)
        XCTAssertEqual(TCCProbeCommand.exitCode(arguments: probe, preflight: { false }, request: { XCTFail(); return false }), 1)
    }

    func testTheRequestAsksMacOSAndExits() {
        var asked = 0
        let request = [program, "--tcc-request", "screen-recording"]
        let code = TCCProbeCommand.exitCode(arguments: request, preflight: { XCTFail(); return false }, request: {
            asked += 1
            return false
        })
        XCTAssertEqual(code, 1)
        XCTAssertEqual(asked, 1)
    }

    func testAnyOtherCommandLineStartsTheApp() {
        for arguments in [[program], [program, "-NSDocumentRevisionsDebugMode", "YES"], []] {
            XCTAssertNil(TCCProbeCommand.exitCode(arguments: arguments, preflight: { true }, request: { true }))
        }
    }

    func testAProbeForAnythingElseIsAUsageError() {
        for arguments in [[program, "--tcc-probe"], [program, "--tcc-probe", "accessibility"],
                          [program, "--tcc-request", "screen-recording", "extra"]] {
            XCTAssertEqual(TCCProbeCommand.exitCode(arguments: arguments, preflight: { true }, request: { true }),
                           TCCProbeCommand.usageExitCode)
        }
    }

    // MARK: - The child probe

    private func probe(_ script: String, timeout: Duration = .seconds(3)) async -> Bool? {
        await ChildScreenRecordingProbe(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: timeout
        ).isGranted()
    }

    func testOnlyExitZeroOrOneIsAnAnswer() async {
        let granted = await probe("exit 0")
        let refused = await probe("exit 1")
        let other = await probe("exit 7")
        XCTAssertEqual(granted, true)
        XCTAssertEqual(refused, false)
        XCTAssertNil(other)
    }

    func testASignalOrATimeoutIsUnknown() async {
        let signaled = await probe("kill -TERM $$")
        XCTAssertNil(signaled)
        let started = Date()
        let slow = await probe("sleep 5", timeout: .milliseconds(300))
        XCTAssertNil(slow)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testNoBinaryIsUnknown() async {
        let missing = await ChildScreenRecordingProbe(executable: URL(fileURLWithPath: "/nonexistent/onboarding")).isGranted()
        let none = await ChildScreenRecordingProbe(executable: nil).isGranted()
        XCTAssertNil(missing)
        XCTAssertNil(none)
    }

    func testTheProbeRunsThisBinaryOnlyWhenItIsTheOnboardingBinary() throws {
        let directory = try temporaryDirectory()
        let binary = directory.appendingPathComponent("onboarding")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        XCTAssertEqual(OnboardingExecutable.current(arguments: [binary.path])?.path, binary.resolvingSymlinksInPath().path)
        XCTAssertEqual(
            OnboardingExecutable.current(arguments: ["./onboarding"], currentDirectory: directory.path)?.path,
            binary.resolvingSymlinksInPath().path
        )
        XCTAssertNil(OnboardingExecutable.current(arguments: ["/Applications/Hippocampus.app/Contents/MacOS/Hippocampus"]))
        XCTAssertNil(OnboardingExecutable.current(arguments: []))
    }

    func testTheEntryPointAnswersProbesBeforeAnyWindowAndWatchesItsParent() throws {
        let entry = try String(
            contentsOf: onboardingPackageRoot.appendingPathComponent("Sources/Onboarding/OnboardingEntryPoint.swift"),
            encoding: .utf8
        )
        let app = try String(
            contentsOf: onboardingPackageRoot.appendingPathComponent("Sources/Onboarding/OnboardingApp.swift"),
            encoding: .utf8
        )
        let probe = try XCTUnwrap(entry.range(of: "TCCProbeCommand.exitCode("))
        let watch = try XCTUnwrap(entry.range(of: "ParentProcessWatch"))
        let start = try XCTUnwrap(entry.range(of: "OnboardingApp.main()"))
        XCTAssertLessThan(probe.lowerBound, start.lowerBound)
        XCTAssertLessThan(watch.lowerBound, start.lowerBound)
        XCTAssertTrue(entry.contains("@main"))
        XCTAssertFalse(app.contains("@main"))
    }
}

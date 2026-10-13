// SPDX-License-Identifier: TBD-private
import Darwin
import Foundation
import XCTest
@testable import HippocampusKit

/// Quit stops the setup window and the main window too, and waits for them
/// (spec-shell S6.3).
@MainActor
final class StopWindowsForQuitTests: XCTestCase {
    func testQuitEndsASetupWindowThatIgnoresTheRequestToQuit() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("stop-windows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ready = folder.appendingPathComponent("ready")
        let onboarding = folder.appendingPathComponent("onboarding")
        try "#!/bin/sh\ntrap '' TERM\ntouch '\(ready.path)'\nwhile :; do sleep 0.05; done\n"
            .write(to: onboarding, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: onboarding.path)

        let locator = FakeBinaryLocator()
        locator.onboardingURL = onboarding
        let supervisor = ProcessSupervisor(
            locator: locator,
            keyStore: FakeKeyStore(),
            runtimeConfig: FakeRuntimeConfig(captureEnabled: false),
            topology: FakeSupervisorTopology(),
            keyCustodyPreparer: FakeKeyCustodyPreparer(),
            readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }
        )
        XCTAssertTrue(supervisor.openOnboarding(initialStep: "never-read"))
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(supervisor.onboardingIsRunning)

        let started = ContinuousClock.now
        await supervisor.stopWindowsForQuit(timeout: 0.2)

        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        XCTAssertFalse(supervisor.onboardingIsRunning)
        let stillThere = Process()
        stillThere.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        stillThere.arguments = ["-f", onboarding.path]
        stillThere.standardOutput = FileHandle.nullDevice
        try stillThere.run()
        stillThere.waitUntilExit()
        XCTAssertNotEqual(stillThere.terminationStatus, 0, "the setup window is gone")
    }

    func testAFailedLaunchIsNotKept() {
        let locator = FakeBinaryLocator()
        locator.onboardingURL = URL(fileURLWithPath: "/nonexistent/onboarding")
        let supervisor = ProcessSupervisor(
            locator: locator,
            keyStore: FakeKeyStore(),
            runtimeConfig: FakeRuntimeConfig(captureEnabled: false),
            topology: FakeSupervisorTopology(),
            keyCustodyPreparer: FakeKeyCustodyPreparer(),
            readinessTimeout: 0.1,
            captureStatusReader: { (nil, nil) }
        )
        XCTAssertFalse(supervisor.openOnboarding())
        XCTAssertFalse(supervisor.onboardingIsRunning)
    }
}

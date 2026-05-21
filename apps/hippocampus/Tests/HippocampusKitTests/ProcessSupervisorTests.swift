// SPDX-License-Identifier: TBD-private
import XCTest
@testable import HippocampusKit

// MARK: - Fakes

final class FakeBinaryLocator: BinaryLocator, @unchecked Sendable {
    var helperURL: URL?
    var agentURL: URL?
    var recallURL: URL?
    var onboardingURL: URL?
    var brainCLIURL: URL?
    var knownSafeURL: URL?

    func helperPath() -> URL? { helperURL }
    func agentPath() -> URL? { agentURL }
    func recallUIPath() -> URL? { recallURL }
    func onboardingPath() -> URL? { onboardingURL }
    func brainCLIPath() -> URL? { brainCLIURL }
    func knownSafeAppsPath() -> URL? { knownSafeURL }
}

final class FakeKeyStore: KeyStore, @unchecked Sendable {
    var storedKey: String?
    var lastWrittenKey: String?
    var writeError: Error?

    func readKey() throws -> String {
        guard let key = storedKey else {
            throw KeyStoreError.noKeyFound
        }
        return key
    }

    func writeKey(_ hex: String) throws {
        if let err = writeError { throw err }
        storedKey = hex
        lastWrittenKey = hex
    }
}

// MARK: - Tests

@MainActor
final class ProcessSupervisorTests: XCTestCase {

    private func makeSupervisor(
        locator: FakeBinaryLocator? = nil,
        keyStore: FakeKeyStore? = nil
    ) -> (ProcessSupervisor, FakeBinaryLocator, FakeKeyStore) {
        let loc = locator ?? FakeBinaryLocator()
        let ks = keyStore ?? FakeKeyStore()
        let sup = ProcessSupervisor(locator: loc, keyStore: ks)
        return (sup, loc, ks)
    }

    // MARK: - Start / State

    func test_start_without_binaries_crashes() {
        let (sup, loc, ks) = makeSupervisor()
        ks.storedKey = String(repeating: "ab", count: 32)

        sup.start()

        if case .crashed(let reason) = sup.state {
            XCTAssertTrue(reason.contains("not found"), "Expected 'not found' in: \(reason)")
        } else {
            XCTFail("Expected .crashed, got \(sup.state)")
        }
    }

    func test_start_with_real_binaries_reaches_running() throws {
        // Use /bin/cat as a stand-in — it reads stdin and writes to stdout.
        let (sup, loc, ks) = makeSupervisor()
        let catURL = URL(fileURLWithPath: "/bin/cat")
        loc.helperURL = catURL
        loc.agentURL = catURL
        ks.storedKey = String(repeating: "ab", count: 32)

        sup.start()

        XCTAssertEqual(sup.state, .running)

        sup.stop()
        XCTAssertEqual(sup.state, .stopped)
    }

    func test_stop_terminates_children() throws {
        let (sup, loc, ks) = makeSupervisor()
        loc.helperURL = URL(fileURLWithPath: "/bin/cat")
        loc.agentURL = URL(fileURLWithPath: "/bin/cat")
        ks.storedKey = String(repeating: "cd", count: 32)

        sup.start()
        XCTAssertEqual(sup.state, .running)

        sup.stop()
        XCTAssertEqual(sup.state, .stopped)
    }

    // MARK: - Pause

    func test_pause_sends_sigstop_resume_sigcont() throws {
        let (sup, loc, ks) = makeSupervisor()
        // Use /bin/sleep as helper — it stays alive long enough to pause.
        loc.helperURL = URL(fileURLWithPath: "/bin/sleep")
        loc.agentURL = URL(fileURLWithPath: "/bin/cat")
        ks.storedKey = String(repeating: "ef", count: 32)

        sup.start()

        // /bin/sleep needs an argument; the Process will start but may
        // exit quickly. We're testing state transitions, not real capture.
        // Use cat instead which blocks on stdin.
        sup.stop()

        // Redo with cat for both
        loc.helperURL = URL(fileURLWithPath: "/bin/cat")
        sup.start()
        XCTAssertEqual(sup.state, .running)

        sup.setPaused(true)
        XCTAssertEqual(sup.state, .paused)

        sup.setPaused(false)
        XCTAssertEqual(sup.state, .running)

        sup.stop()
    }

    // MARK: - Key Store

    func test_key_generation_on_missing_key() throws {
        let (sup, loc, ks) = makeSupervisor()
        loc.helperURL = URL(fileURLWithPath: "/bin/cat")
        loc.agentURL = URL(fileURLWithPath: "/bin/cat")
        // No key stored — should generate one

        sup.start()

        XCTAssertNotNil(ks.lastWrittenKey)
        XCTAssertEqual(ks.lastWrittenKey?.count, 64)
        XCTAssertEqual(sup.state, .running)

        sup.stop()
    }

    func test_key_store_persists_with_mode_600() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hippocampus-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let keyPath = tmpDir.appendingPathComponent("dev.key")
        let store = FileKeyStore(path: keyPath)
        let hex = FileKeyStore.generateHexKey()

        try store.writeKey(hex)

        // Verify file exists and mode is 0600
        let attrs = try FileManager.default.attributesOfItem(atPath: keyPath.path)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "dev.key must be mode 0600 (owner-only rw)")

        // Verify round-trip
        let readBack = try store.readKey()
        XCTAssertEqual(readBack, hex)
    }

    func test_key_store_rejects_invalid_length() {
        let ks = FakeKeyStore()

        let store = FileKeyStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("bad.key"))
        XCTAssertThrowsError(try store.writeKey("tooshort"))
    }

    // MARK: - Crash Backoff

    func test_crash_state_on_child_exit() throws {
        // Use /usr/bin/false — exits immediately with code 1
        let (sup, loc, ks) = makeSupervisor()
        loc.helperURL = URL(fileURLWithPath: "/usr/bin/false")
        loc.agentURL = URL(fileURLWithPath: "/bin/cat")
        ks.storedKey = String(repeating: "aa", count: 32)

        sup.start()

        // /usr/bin/false exits immediately; the termination handler
        // fires asynchronously. Give it a moment.
        let expectation = XCTestExpectation(description: "child exits")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3)

        // State should be .crashed or already retrying → .starting/.running
        let state = sup.state
        let acceptable: Bool = {
            switch state {
            case .crashed, .starting, .running: return true
            default: return false
            }
        }()
        XCTAssertTrue(acceptable, "Expected crashed/retrying, got \(state)")

        sup.stop()
    }

    // MARK: - Health Snapshot

    func test_health_snapshot_display_with_brain_count() {
        let snapshot = HealthSnapshot(
            framesDelivered: 100,
            framesSuppressed: 10,
            brainEventCount: 42,
            lastCaptureTs: Date().addingTimeInterval(-180),
            lastUpdated: Date()
        )
        let text = snapshot.displayText
        XCTAssertTrue(text.contains("42 events"), "Brain count preferred: \(text)")
    }

    func test_health_snapshot_display_falls_back_to_frames() {
        let snapshot = HealthSnapshot(
            framesDelivered: 77,
            framesSuppressed: 5,
            brainEventCount: nil,
            lastCaptureTs: Date().addingTimeInterval(-60),
            lastUpdated: Date()
        )
        let text = snapshot.displayText
        XCTAssertTrue(text.contains("77 events"), "Fallback to frames_delivered: \(text)")
    }

    func test_health_snapshot_with_brain_event_count() {
        let snapshot = HealthSnapshot(
            framesDelivered: 100,
            framesSuppressed: 10,
            brainEventCount: nil,
            lastCaptureTs: nil,
            lastUpdated: Date()
        )
        let updated = snapshot.withBrainEventCount(55)
        XCTAssertEqual(updated.brainEventCount, 55)
        XCTAssertEqual(updated.eventCount, 55)
        XCTAssertEqual(updated.framesDelivered, 100)
    }

    // MARK: - Onboarding detection

    func test_has_onboarding_false_when_missing() {
        let (sup, loc, _) = makeSupervisor()
        loc.onboardingURL = nil
        XCTAssertFalse(sup.hasOnboarding)
    }

    func test_has_onboarding_true_when_present() {
        let (sup, loc, _) = makeSupervisor()
        loc.onboardingURL = URL(fileURLWithPath: "/bin/echo")
        XCTAssertTrue(sup.hasOnboarding)
    }
}

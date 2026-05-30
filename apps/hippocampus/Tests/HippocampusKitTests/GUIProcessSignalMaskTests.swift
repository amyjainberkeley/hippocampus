// SPDX-License-Identifier: TBD-private
import XCTest

/// Pins the process-wide signal mask installed by
/// `HippocampusApp.AppDelegate.applicationDidFinishLaunching`.
///
/// `AppDelegate` lives in the `Hippocampus` executable target (not in
/// `HippocampusKit`), so we cannot `@testable import` it. We verify
/// the invariant by inspecting the source file directly — the same
/// pattern used by `MenuBarLifecycleTests` and `TroubleshootMenuTests`
/// for repo-level checks.
///
/// Regression context (cycle 8.23, 2026-05-29): after PR #254 shipped
/// the `applicationShouldTerminateAfterLastWindowClosed = false`
/// override (F1), the main `Hippocampus` GUI process STILL exited
/// cleanly within minutes of launch on a fresh install of `9fbfe352…`.
/// The helper + agent stayed alive (re-parented to launchd via the
/// supervisor's child re-spawn path), but the menu-bar `NSStatusItem`
/// — owned by SwiftUI's `MenuBarExtra` scene inside the main process
/// — disappeared again. No `DiagnosticReports/*.ips` was generated,
/// confirming the exit was NOT a crash (SIGSEGV/SIGABRT/SIGBUS would
/// all produce `.ips`).
///
/// Root cause: `SafariInboxReader.writeToSocket` uses raw `write(2)`
/// on a `SOCK_STREAM` AF_UNIX socket. When the agent's
/// `page_content.sock` listener is unbound during a supervisor retry
/// cycle, the in-flight `write()` from a SafariInboxReader drain
/// receives `EPIPE` AND `SIGPIPE`. With no process-wide `SIGPIPE`
/// mask, the default disposition terminates the process cleanly.
///
/// This test suite pins the `signal(SIGPIPE, SIG_IGN)` call in
/// `applicationDidFinishLaunching`. Removing it re-introduces the
/// cycle 8.22 / 8.23 main-GUI-death failure mode.
final class GUIProcessSignalMaskTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HippocampusKitTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // apps/hippocampus/
            .deletingLastPathComponent()  // apps/
            .deletingLastPathComponent()  // repo root
    }

    private var appDelegateSourcePath: String? {
        let candidate = repoRoot
            .appendingPathComponent(
                "apps/hippocampus/Sources/Hippocampus/HippocampusApp.swift"
            )
        return FileManager.default.fileExists(atPath: candidate.path)
            ? candidate.path : nil
    }

    // MARK: - SIGPIPE mask

    /// `AppDelegate.applicationDidFinishLaunching` MUST install
    /// `signal(SIGPIPE, SIG_IGN)`.
    ///
    /// Removing this re-introduces the cycle 8.23 main-GUI-death
    /// failure mode where `SafariInboxReader`'s raw `write(2)` to the
    /// agent's `page_content.sock` during a supervisor retry window
    /// raises `SIGPIPE` and terminates the main GUI process cleanly.
    func test_AppDelegate_masks_SIGPIPE_on_launch() throws {
        guard let path = appDelegateSourcePath else {
            throw XCTSkip("HippocampusApp.swift not found at expected repo location")
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(
            content.contains("signal(SIGPIPE, SIG_IGN)"),
            """
            AppDelegate.applicationDidFinishLaunching MUST install
            `signal(SIGPIPE, SIG_IGN)`. Without it, any raw `write(2)`
            to a Unix-domain socket whose peer has closed (e.g. mid-
            agent-restart) terminates the main GUI process cleanly,
            killing the menu-bar status item.
            """
        )
    }

    /// The `SIG_IGN` install MUST live in `applicationDidFinishLaunching`,
    /// not elsewhere — it must run before any pipe / socket / Process
    /// code path, otherwise an early `SIGPIPE` (e.g. during
    /// QuarantineUnlocker's `xattr` `Process` lifecycle, or
    /// SafariInboxReader's first drain after `supervisor.start()`) can
    /// still hit before the mask is installed.
    func test_SIGPIPE_mask_lives_in_applicationDidFinishLaunching() throws {
        guard let path = appDelegateSourcePath else {
            throw XCTSkip("HippocampusApp.swift not found at expected repo location")
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)

        guard let didFinishRange = content.range(
            of: "func applicationDidFinishLaunching"
        ) else {
            XCTFail("applicationDidFinishLaunching declaration not found")
            return
        }

        // Scan the next ~4000 chars of source for both the doc-context
        // and the actual call. 4000 covers the full method body comfortably
        // (the method's doc-comment + body is currently ~3500 chars).
        let tail = String(content[didFinishRange.upperBound...].prefix(4000))

        XCTAssertTrue(
            tail.contains("signal(SIGPIPE, SIG_IGN)"),
            """
            `signal(SIGPIPE, SIG_IGN)` MUST appear inside
            `applicationDidFinishLaunching`, before any pipe / socket /
            Process work. Source tail under the method marker:
            \(tail.prefix(500))…
            """
        )
    }
}

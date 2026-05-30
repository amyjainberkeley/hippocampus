// SPDX-License-Identifier: TBD-private
import XCTest

/// Pins the `AppDelegate` overrides that keep the main GUI process
/// alive across transient window closes.
///
/// `AppDelegate` lives in the `Hippocampus` executable target (not in
/// `HippocampusKit`), so we cannot `@testable import` it. We verify
/// the invariants by inspecting the source file directly — the same
/// pattern used by `TroubleshootMenuTests` for repo-level checks.
///
/// Regression context (cycle 8.22, 2026-05-29): on a fresh install of
/// the cycle 8.22 DMG, after onboarding completed and recording
/// started, the main `Hippocampus` GUI process exited cleanly with no
/// crash report. `MCICaptureHelper` + `mci-agent` stayed alive
/// (re-parented to launchd), but the menu-bar `NSStatusItem` — owned
/// by SwiftUI's `MenuBarExtra` scene inside the main process —
/// disappeared with the process. Root cause:
/// `NSApplication.applicationShouldTerminateAfterLastWindowClosed`
/// returns `true` by default; even with `LSUIElement=true`, the main
/// process has window-creating surfaces (the "Download AI Model"
/// `Window` scene, `NSAlert.runModal()` panels in `StatusMenuView`,
/// the `KeyWrapAuditView` sheet) whose close path satisfies the
/// "last window closed" predicate.
final class MenuBarLifecycleTests: XCTestCase {

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

    private var infoPlistPath: String? {
        let candidate = repoRoot
            .appendingPathComponent(
                "apps/hippocampus/Resources/Info.plist"
            )
        return FileManager.default.fileExists(atPath: candidate.path)
            ? candidate.path : nil
    }

    // MARK: - applicationShouldTerminateAfterLastWindowClosed

    /// `AppDelegate` MUST declare the override.
    ///
    /// AppKit's default is `true` — that is the bug. Removing the
    /// override re-introduces the cycle 8.22 main-GUI-death failure
    /// mode.
    func test_AppDelegate_overrides_terminate_after_last_window_closed() throws {
        guard let path = appDelegateSourcePath else {
            throw XCTSkip("HippocampusApp.swift not found at expected repo location")
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(
            content.contains("applicationShouldTerminateAfterLastWindowClosed"),
            """
            AppDelegate MUST override `applicationShouldTerminateAfterLastWindowClosed`.
            The AppKit default is `true`, which kills the menu-bar app whenever the
            user closes any transient window — see cycle 8.22 main-GUI-death PR.
            """
        )
    }

    /// The override MUST return `false`.
    ///
    /// Returning `true` (or removing the body) is the regression we
    /// are pinning shut. We tolerate both the multi-line and
    /// one-liner forms, but reject anything that returns `true`.
    func test_AppDelegate_override_returns_false() throws {
        guard let path = appDelegateSourcePath else {
            throw XCTSkip("HippocampusApp.swift not found at expected repo location")
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)

        // Anchor on `func applicationShouldTerminateAfterLastWindowClosed`
        // — the `func` prefix uniquely picks the function declaration
        // and skips any doc-comment mentions of the same selector.
        guard let sigRange = content.range(
            of: "func applicationShouldTerminateAfterLastWindowClosed"
        ) else {
            XCTFail("override declaration not found — earlier test should have caught this")
            return
        }

        // Scan the next ~400 chars of source for the return statement.
        // 400 is generous enough to cover a multi-line signature +
        // body but tight enough not to drift into the next method.
        let tail = String(content[sigRange.upperBound...].prefix(400))

        let returnsFalse = tail.contains("return false")
            || tail.contains("{ false }")
            || tail.contains("-> Bool { false")
        XCTAssertTrue(
            returnsFalse,
            """
            `applicationShouldTerminateAfterLastWindowClosed` MUST return `false`.
            Returning `true` (the AppKit default) is the cycle 8.22 main-GUI-death bug.
            Source tail under the override marker:
            \(tail)
            """
        )

        XCTAssertFalse(
            tail.contains("return true"),
            """
            `applicationShouldTerminateAfterLastWindowClosed` MUST NOT return `true`.
            Source tail under the override marker:
            \(tail)
            """
        )
    }

    // MARK: - LSUIElement

    /// `LSUIElement` MUST be `true` in Info.plist so the app launches
    /// as a menu-bar-only accessory (no Dock icon). Without it, the
    /// app is a regular GUI app whose lifecycle is even more
    /// terminate-on-last-window-close-prone.
    ///
    /// Combined with the `applicationShouldTerminateAfterLastWindowClosed`
    /// override above, this gives the main GUI process two independent
    /// guards against vanishing while the helper + agent keep
    /// recording.
    func test_InfoPlist_LSUIElement_is_true() throws {
        guard let path = infoPlistPath else {
            throw XCTSkip("Info.plist not found at expected repo location")
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)

        XCTAssertTrue(
            content.contains("<key>LSUIElement</key>"),
            "Info.plist MUST declare LSUIElement"
        )

        // The key + the next <true/> value, tolerating any whitespace
        // / newlines between them. Catches an accidental `<false/>`
        // flip or removal of the value entirely.
        let pattern = #"<key>LSUIElement</key>\s*<true/>"#
        XCTAssertNotNil(
            content.range(of: pattern, options: .regularExpression),
            "LSUIElement MUST be <true/>"
        )
    }
}

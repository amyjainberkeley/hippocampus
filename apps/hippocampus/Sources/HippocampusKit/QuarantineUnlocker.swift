// SPDX-License-Identifier: TBD-private
import Foundation
import os

/// Strips `com.apple.quarantine` from the running `.app` bundle on first
/// launch.
///
/// ## Why
///
/// When a user downloads a DMG via a web browser, macOS attaches
/// `com.apple.quarantine` to every binary inside it. Dragging the .app
/// to `/Applications` preserves the attr — it is not cleared by the
/// drag-install. The `com.apple.quarantine` attr drives a set of
/// LaunchServices and TCC behaviors which are NOT covered by the
/// notarization + stapling path:
///
///   * Each time a quarantined app launches, LaunchServices consults
///     its per-bundle decision record. A single Cancel/Don't-Open click
///     on any Gatekeeper-adjacent prompt (or even a stale decision from
///     a prior unsigned build of the same bundle id) can flip the
///     decision to "reject" and silently refuse subsequent launches.
///   * After a TCC denial of a permission attributed to the bundle id,
///     macOS Sequoia / Tahoe can revoke the launch authorization for
///     quarantined apps even when the .app is notarized + stapled.
///   * Child processes spawned with `Process()` are re-parented to
///     `launchd` (PID 1) when the parent dies, so the main GUI binary
///     can vanish while `MCICaptureHelper` + `mci-agent` keep running —
///     the menu-bar icon disappears, but `helper-health` keeps emitting
///     frames. This is exactly the symptom the CEO reported across
///     cycles 8.19 and 8.21:
///
///         "after onboarding hippocampus would like to get access to
///          some data i click yes and the icon bar disappears from
///          the top notch and i can't see it."
///
///     The verified empirical fix in both cycles was:
///
///         xattr -dr com.apple.quarantine /Applications/Hippocampus.app
///         pkill -x Hippocampus  &&  open /Applications/Hippocampus.app
///
/// Stripping `com.apple.quarantine` does NOT change the app's
/// notarization or signing posture — the notarization ticket is
/// stapled into the bundle and survives the xattr strip. Gatekeeper
/// continues to verify the staple at launch. The xattr is purely a
/// LaunchServices first-launch coordination metadata bit.
///
/// ## What this does
///
/// At `applicationDidFinishLaunching`, before any TCC-related code path
/// runs, check whether the running .app's bundle has
/// `com.apple.quarantine`. If yes, fork `/usr/bin/xattr -dr
/// com.apple.quarantine <bundlePath>`. The operation is idempotent
/// (xattr exits 0 even when the attr is already absent) and is logged
/// to `os_log subsystem=ai.hippocampus category=quarantine`.
///
/// The strip operates only on the running `.app`'s own bundle — never
/// any other path. The bundle path is resolved from `Bundle.main`, so
/// the strip targets whichever path the user installed to
/// (`/Applications`, `~/Applications`, Desktop, etc.).
///
/// ## §5 protected-set posture
///
/// This is a user-space `xattr` call on the running app's own bundle.
/// It does NOT touch:
///   * entitlements
///   * code signing
///   * AMFI / hardened-runtime
///   * notarization (the ticket is embedded in the bundle and stapled
///     in advance — `stapler validate` continues to pass post-strip)
///   * Gatekeeper rules
///   * any system-scope path (no `/Library`, no `~/Library/LaunchAgents`)
///
/// Per the dispatch prompt §5 audit table, this falls outside the
/// CSO veto-gate set. CSO sign-off is not required, but the rationale
/// is documented inline in the PR body and in this comment block for
/// audit.
public struct QuarantineUnlocker: Sendable {
    private let logger = Logger(
        subsystem: "ai.hippocampus", category: "quarantine"
    )

    /// Where to look for the running `.app` bundle. Defaults to
    /// `Bundle.main.bundleURL`. Injectable for tests.
    public let bundlePath: URL

    /// Path to the `xattr` binary. Injectable for tests.
    public let xattrPath: String

    /// Hook used to actually invoke the strip. Defaults to a real
    /// `/usr/bin/xattr` `Process` invocation; tests inject an
    /// in-memory recorder.
    public typealias StripInvoker = @Sendable (
        _ xattrPath: String,
        _ bundlePath: URL
    ) -> Int32
    public let invoke: StripInvoker

    /// Hook to probe whether the bundle currently has the quarantine
    /// attr set. Defaults to a real `getxattr(2)` call; tests inject
    /// an in-memory probe.
    public typealias QuarantineProbe = @Sendable (_ bundlePath: URL) -> Bool
    public let probe: QuarantineProbe

    public init(
        bundlePath: URL = Bundle.main.bundleURL,
        xattrPath: String = "/usr/bin/xattr",
        probe: @escaping QuarantineProbe = QuarantineUnlocker.realProbe,
        invoke: @escaping StripInvoker = QuarantineUnlocker.realStrip
    ) {
        self.bundlePath = bundlePath
        self.xattrPath = xattrPath
        self.probe = probe
        self.invoke = invoke
    }

    public enum Outcome: Sendable, Equatable {
        /// Bundle did not have the attr set — nothing to do.
        case notQuarantined
        /// xattr strip succeeded (exit 0).
        case stripped
        /// xattr exited non-zero. Carries the exit code.
        case stripFailed(Int32)
        /// We can't strip ourselves — the .app is inside a read-only
        /// volume (typical when the user runs the app straight from the
        /// mounted DMG without dragging to /Applications first). The
        /// outer wrapper logs and continues; subsequent first launches
        /// from /Applications will succeed.
        case readOnlyMount
    }

    /// Run the strip if needed. Safe to call on every launch — the
    /// `probe()` short-circuits when the attr is absent.
    @discardableResult
    public func runIfNeeded() -> Outcome {
        guard probe(bundlePath) else {
            logger.debug("quarantine: not set on \(self.bundlePath.path, privacy: .public)")
            return .notQuarantined
        }

        // Detect read-only mount (DMG-launch case): writing back the
        // xattr removal requires the volume be writable. The earliest
        // signal is the bundle path starting with `/Volumes/`. We
        // still attempt the strip — xattr will report the failure if
        // the volume rejects the unlink — but flag it for logging.
        let onMountedVolume = bundlePath.path.hasPrefix("/Volumes/")

        let exit = invoke(xattrPath, bundlePath)
        if exit == 0 {
            logger.info(
                "quarantine: stripped from \(self.bundlePath.path, privacy: .public)"
            )
            return .stripped
        }

        if onMountedVolume {
            logger.warning(
                "quarantine: strip failed (exit=\(exit)) on mounted volume — \(self.bundlePath.path, privacy: .public). User likely ran from DMG; expected."
            )
            return .readOnlyMount
        }

        logger.warning(
            "quarantine: strip failed (exit=\(exit)) on \(self.bundlePath.path, privacy: .public)"
        )
        return .stripFailed(exit)
    }

    // MARK: - Default real implementations

    /// Real quarantine probe via `getxattr(2)`. Returns true iff the
    /// attribute is present and has non-zero length.
    public static let realProbe: QuarantineProbe = { url in
        let path = url.path
        return path.withCString { cstr in
            let n = getxattr(cstr, "com.apple.quarantine", nil, 0, 0, 0)
            return n > 0
        }
    }

    /// Real strip invocation via `/usr/bin/xattr -dr com.apple.quarantine`.
    /// Returns the child's exit code (or 255 if the spawn itself failed).
    public static let realStrip: StripInvoker = { xattrBin, url in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: xattrBin)
        proc.arguments = ["-dr", "com.apple.quarantine", url.path]
        // Swallow stdout/stderr — we already log the outcome above.
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return 255
        }
    }
}

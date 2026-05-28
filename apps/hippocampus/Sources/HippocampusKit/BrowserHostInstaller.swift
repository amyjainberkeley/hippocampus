// SPDX-License-Identifier: TBD-private
import Foundation
import os

/// Writes Chromium native-messaging host manifests to each installed
/// Chromium-family browser's `NativeMessagingHosts/` directory.
///
/// The shipped extension cannot connect to its native host unless a
/// per-browser JSON manifest exists at
/// `~/Library/Application Support/<Browser>/NativeMessagingHosts/
/// ai.hippocampus.native_messaging.json` with:
///
///   - `path`         → absolute path of the bundled
///                      `hippocampus-native-host` binary inside the
///                      currently-running `.app` (resolved at
///                      runtime from `Bundle.main.bundleURL`).
///   - `allowed_origins` → `chrome-extension://<ID>/` where `<ID>` is
///                      the deterministic extension ID derived from the
///                      RSA public key embedded in
///                      `extensions/chromium/manifest.json` as the
///                      `key` field. The private key lives outside the
///                      repo at `~/.config/hippocampus/
///                      extension-signing.pem`.
///
/// The installer runs at every `applicationDidFinishLaunching`. It is
/// idempotent and ~milliseconds — the rewrite guarantees the `path`
/// tracks where the user dragged the `.app` (`/Applications/`,
/// `~/Applications/`, Desktop, etc.).
public final class BrowserHostInstaller: Sendable {
    /// Deterministic Chromium extension ID derived from the `key` field
    /// in `extensions/chromium/manifest.json`. To regenerate (only if
    /// the keypair is rotated):
    ///
    ///   openssl rsa -in ~/.config/hippocampus/extension-signing.pem \
    ///     -pubout -outform DER \
    ///     | openssl dgst -sha256 -binary | head -c 16 \
    ///     | xxd -p -c 32 | tr '0-9a-f' 'a-p'
    public static let chromiumExtensionID = "edcdeplngcpiiphcenbkjjlnjmpllljf"

    /// Native-messaging host name. Must match `NATIVE_HOST_NAME` in
    /// `extensions/chromium/background.js` AND the `name` field of the
    /// JSON we write.
    public static let hostName = "ai.hippocampus.native_messaging"

    /// One row per supported Chromium-family browser.
    public struct Browser: Sendable {
        public let displayName: String
        /// Path under `~/Library/Application Support/`.
        public let supportRelativePath: String

        public init(displayName: String, supportRelativePath: String) {
            self.displayName = displayName
            self.supportRelativePath = supportRelativePath
        }
    }

    /// The four Chromium-family browsers MCI targets per
    /// `docs/research/browser-extension-audit.md` §K.
    public static let knownBrowsers: [Browser] = [
        Browser(displayName: "Chrome",
                supportRelativePath: "Google/Chrome"),
        Browser(displayName: "Arc",
                supportRelativePath: "Arc/User Data"),
        Browser(displayName: "Brave",
                supportRelativePath: "BraveSoftware/Brave-Browser"),
        Browser(displayName: "Edge",
                supportRelativePath: "Microsoft Edge"),
    ]

    public struct Outcome: Sendable, Equatable {
        public let browser: String
        public let path: String
        public let action: Action

        public enum Action: String, Sendable, Equatable {
            case wrote
            case unchanged
            case skipped       // browser dir absent → browser not installed
            case failed
        }
    }

    private let supportRoot: URL
    private let binaryURL: URL?
    private let logger: Logger

    /// - Parameters:
    ///   - bundle: the `.app` bundle whose
    ///     `Contents/MacOS/hippocampus-native-host` is the install
    ///     target. Defaults to `.main`. In tests pass a fake URL via
    ///     `binaryOverride`.
    ///   - supportRoot: parent of each browser's
    ///     `NativeMessagingHosts/` dir. Defaults to
    ///     `~/Library/Application Support/`.
    ///   - binaryOverride: test seam.
    public init(
        bundle: Bundle = .main,
        supportRoot: URL? = nil,
        binaryOverride: URL? = nil
    ) {
        self.supportRoot = supportRoot ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support",
                                    isDirectory: true)
        self.binaryURL = binaryOverride ?? Self.resolveBinary(in: bundle)
        self.logger = Logger(
            subsystem: "ai.hippocampus", category: "browser-host-installer"
        )
    }

    /// Install the manifest into every browser whose support dir is
    /// present. Browsers that aren't installed are silently skipped.
    @discardableResult
    public func install(
        browsers: [Browser] = BrowserHostInstaller.knownBrowsers
    ) -> [Outcome] {
        guard let binaryURL else {
            logger.error("install: hippocampus-native-host not bundled — skipping all browsers")
            return browsers.map {
                Outcome(browser: $0.displayName,
                        path: "",
                        action: .failed)
            }
        }
        let payload = Self.renderManifest(binaryPath: binaryURL.path)
        guard let data = payload.data(using: .utf8) else {
            logger.error("install: failed to UTF-8 encode manifest JSON")
            return browsers.map {
                Outcome(browser: $0.displayName,
                        path: "",
                        action: .failed)
            }
        }
        return browsers.map { install(browser: $0, payload: data) }
    }

    private func install(browser: Browser, payload: Data) -> Outcome {
        let browserSupport = supportRoot
            .appendingPathComponent(browser.supportRelativePath,
                                    isDirectory: true)
        let nmDir = browserSupport
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        let manifest = nmDir.appendingPathComponent(
            "\(Self.hostName).json"
        )

        // If the browser support dir does not exist, the browser is not
        // installed. Do NOT create it — that would leave orphan dirs
        // and confuse the browser's own first-launch checks.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: browserSupport.path,
            isDirectory: &isDir
        ), isDir.boolValue else {
            return Outcome(
                browser: browser.displayName,
                path: manifest.path,
                action: .skipped
            )
        }

        do {
            try FileManager.default.createDirectory(
                at: nmDir,
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("install \(browser.displayName, privacy: .public): mkdir failed: \(error.localizedDescription, privacy: .public)")
            return Outcome(
                browser: browser.displayName,
                path: manifest.path,
                action: .failed
            )
        }

        if let existing = try? Data(contentsOf: manifest), existing == payload {
            return Outcome(
                browser: browser.displayName,
                path: manifest.path,
                action: .unchanged
            )
        }

        do {
            try payload.write(to: manifest, options: .atomic)
            logger.info("install \(browser.displayName, privacy: .public): wrote \(manifest.path, privacy: .public)")
            return Outcome(
                browser: browser.displayName,
                path: manifest.path,
                action: .wrote
            )
        } catch {
            logger.error("install \(browser.displayName, privacy: .public): write failed: \(error.localizedDescription, privacy: .public)")
            return Outcome(
                browser: browser.displayName,
                path: manifest.path,
                action: .failed
            )
        }
    }

    /// JSON shape required by the Chromium native-messaging spec
    /// (<https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging>).
    /// Public for tests; safe to call without an installer instance.
    public static func renderManifest(binaryPath: String) -> String {
        // Hand-rolled rather than JSONSerialization so the on-disk file
        // is deterministic (key order, two-space indent) — easier for a
        // CEO/CSO triaging "what got installed".
        let origin = "chrome-extension://\(chromiumExtensionID)/"
        let lines = [
            "{",
            "  \"name\": \"\(hostName)\",",
            "  \"description\": \"Hippocampus native messaging host — forwards page content to the MCI agent\",",
            "  \"path\": \(jsonString(binaryPath)),",
            "  \"type\": \"stdio\",",
            "  \"allowed_origins\": [",
            "    \"\(origin)\"",
            "  ]",
            "}",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// Minimal JSON string escaper — paths can contain `"` or `\`
    /// (rare but legal on macOS). Avoids pulling in JSONEncoder for a
    /// single string.
    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if c.value < 0x20 {
                    out.append(String(format: "\\u%04x", c.value))
                } else {
                    out.append(Character(c))
                }
            }
        }
        out.append("\"")
        return out
    }

    /// Locate `hippocampus-native-host` next to the running app.
    /// Mirrors `BundleBinaryLocator.resolve(_:)` but standalone — the
    /// existing locator's protocol is heavy for a single one-shot
    /// install, and adding the method there would force every caller
    /// to know about a binary it doesn't supervise.
    private static func resolveBinary(in bundle: Bundle) -> URL? {
        let bundleURL = bundle.bundleURL
        let inBundle = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent("hippocampus-native-host")
        if FileManager.default.fileExists(atPath: inBundle.path) {
            return inBundle
        }

        // Dev fallback: `swift run` from the workspace root.
        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let devRoot = execURL
            .deletingLastPathComponent()  // .build/debug/
            .deletingLastPathComponent()  // .build/
            .deletingLastPathComponent()  // apps/hippocampus/
            .deletingLastPathComponent()  // apps/
            .deletingLastPathComponent()  // repo root
        for relative in [
            "target/release/hippocampus-native-host",
            "target/debug/hippocampus-native-host",
        ] {
            let candidate = devRoot.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

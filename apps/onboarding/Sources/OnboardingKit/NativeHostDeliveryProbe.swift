import Foundation

/// Empirical "is content actually reaching the brain from `source`?" probe.
///
/// Cycle 8.29 P0 #3 surface: replaces the pre-cycle-8.29
/// `RealBrowserDetector` probe that checked for the *presence* of a
/// per-browser host manifest on disk. Manifest presence is a necessary
/// condition for Chromium content delivery, but not sufficient — the user
/// may not have toggled Developer mode + Load Unpacked, may have rejected
/// the extension, or may not have navigated any page since install.
///
/// The probe runs `mci-agent stats --source <X> --since-seconds N`
/// against the running agent's SQLCipher brain, which counts how many
/// `PageContentEvent`s have been ingested from that source in the last
/// window. Non-zero count = the brain is empirically receiving content.
///
/// Source values:
///   - `safari` — events whose `app_bundle_id == com.apple.Safari`
///   - `chromium-native-host` — events from any Chromium-family bundle
///     (Chrome, Arc, Brave, Edge, Firefox)
///
/// Returns `nil` when the probe failed (subprocess error, brain key
/// unavailable, `mci-agent` binary not bundled). The detector maps `nil`
/// to `.unknown` so the slide does not show a misleading badge.
public protocol NativeHostDeliveryProbe: Sendable {
    func recentEventCount(source: String, withinSeconds: Int) -> Int?
}

public struct DefaultNativeHostDeliveryProbe: NativeHostDeliveryProbe {
    private let mciAgentResolver: @Sendable () -> URL?
    private let timeoutSeconds: Double

    public init(
        mciAgentResolver: @escaping @Sendable () -> URL? =
            { DefaultNativeHostDeliveryProbe.resolveMciAgent() },
        timeoutSeconds: Double = 2.0
    ) {
        self.mciAgentResolver = mciAgentResolver
        self.timeoutSeconds = timeoutSeconds
    }

    public func recentEventCount(source: String, withinSeconds: Int) -> Int? {
        guard let bin = mciAgentResolver() else { return nil }
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = [
            "stats",
            "--source", source,
            "--since-seconds", "\(withinSeconds)",
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            return nil
        }

        // Bounded wait so a wedged agent cannot freeze the slide.
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            return nil
        }

        guard proc.terminationStatus == 0 else { return nil }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.flatMap(Int.init)
    }

    /// Resolve the bundled `mci-agent` binary the same way
    /// `DefaultNativeHostManifestWriter.resolveBundledNativeHost`
    /// resolves the host binary: look in the running binary's
    /// directory first, fall back to `target/{release,debug}/`.
    public static func resolveMciAgent() -> URL? {
        let argv0 = ProcessInfo.processInfo.arguments.first ?? ""
        let execURL = URL(fileURLWithPath: argv0).resolvingSymlinksInPath()
        let execDir = execURL.deletingLastPathComponent()
        let bundled = execDir.appendingPathComponent("mci-agent")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let devRoot = execDir
            .deletingLastPathComponent()  // .build/<profile> → .build
            .deletingLastPathComponent()  // .build → onboarding
            .deletingLastPathComponent()  // onboarding → apps
            .deletingLastPathComponent()  // apps → repo root
        for profile in ["release", "debug"] {
            let candidate = devRoot
                .appendingPathComponent("target/\(profile)/mci-agent")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

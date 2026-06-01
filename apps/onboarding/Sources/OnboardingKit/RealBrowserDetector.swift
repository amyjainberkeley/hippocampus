#if canImport(AppKit)
import Foundation
import AppKit

/// Per-browser truth source for "is the Hippocampus extension installed?"
///
/// Evolution of the probe — three generations:
///
/// 1. **Pre-PR #206 (the lie).** Both Safari + Chromium rows probed
///    `fileExists("/usr/local/bin/hippocampus-native-host")`. Nothing
///    in the build pipeline ever populates that path. The badge had
///    zero causal relationship with reality.
///
/// 2. **Post-PR #206 (the manifest-presence probe).** Safari probed for
///    the bundled `.appex`; Chromium probed for the per-browser
///    `NativeMessagingHosts/ai.hippocampus.native_messaging.json`. A
///    real improvement — both check for an artifact this codebase
///    actually writes — but the probe is still structural. The manifest
///    can be present while the user has never Loaded-Unpacked the
///    extension, has rejected it, or has not navigated any page.
///
/// 3. **Cycle 8.29 P0 #3 (this implementation, the empirical probe).**
///    The detector runs `mci-agent stats --source <X> --since-seconds N`
///    against the brain and reports `.installed` iff the count is
///    positive. That is the only signal that empirically proves content
///    is reaching the brain — exactly what the user sees as "the
///    extension is working." Source: `docs/research/browser-extension-
///    audit.md` §Q8.
///
/// Coarse aggregation: every Chromium-family browser shares one probe
/// (`source=chromium-native-host`). The pre-cycle-8.29 per-browser
/// independence semantic (installing Chrome did not flip Arc's badge)
/// is intentionally dropped here — the audit memo recommends 2-source
/// aggregation, and a single empirical signal is more honest than four
/// independent file-existence proxies. When ANY Chromium browser
/// delivers content, every Chromium row in the slide turns green; the
/// slide CTA continues to show per-browser install instructions until
/// the user accepts.
@MainActor
public final class RealBrowserDetector: BrowserDetector, @unchecked Sendable {
    private let deliveryProbe: any NativeHostDeliveryProbe
    private let probeWindowSeconds: Int

    public init(
        deliveryProbe: any NativeHostDeliveryProbe = DefaultNativeHostDeliveryProbe(),
        probeWindowSeconds: Int = 30
    ) {
        self.deliveryProbe = deliveryProbe
        self.probeWindowSeconds = probeWindowSeconds
    }

    public func installedBrowsers() -> [DetectedBrowser] {
        knownBrowsers.compactMap { entry in
            if NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: entry.bundleId
            ) != nil {
                return DetectedBrowser(
                    id: entry.bundleId,
                    name: entry.name,
                    kind: entry.kind
                )
            }
            return nil
        }
    }

    public func checkExtensionInstalled(for browser: DetectedBrowser) -> ExtensionStatus {
        let source = Self.probeSource(for: browser.kind)
        guard let count = deliveryProbe.recentEventCount(
            source: source,
            withinSeconds: probeWindowSeconds
        ) else {
            return .unknown
        }
        return count > 0 ? .installed : .notInstalled
    }

    /// `--source` value for each browser kind:
    ///
    ///   - `.safari`   → `"safari"`
    ///   - `.chromium` → `"chromium-native-host"`
    public static func probeSource(for kind: BrowserKind) -> String {
        switch kind {
        case .safari:   return "safari"
        case .chromium: return "chromium-native-host"
        }
    }
}
#endif

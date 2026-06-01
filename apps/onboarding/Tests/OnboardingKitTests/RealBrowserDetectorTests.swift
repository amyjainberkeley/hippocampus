#if canImport(AppKit)
import XCTest
@testable import OnboardingKit

/// Empirical delivery-probe semantics for `RealBrowserDetector` per
/// cycle 8.29 P0 #3. Drives the probe via a stub so no live subprocess
/// or brain access is touched.
@MainActor
final class RealBrowserDetectorTests: XCTestCase {

    private let safari   = DetectedBrowser(id: "com.apple.Safari", name: "Safari", kind: .safari)
    private let chrome   = DetectedBrowser(id: "com.google.Chrome", name: "Chrome", kind: .chromium)
    private let arc      = DetectedBrowser(id: "company.thebrowser.Browser", name: "Arc", kind: .chromium)
    private let brave    = DetectedBrowser(id: "com.brave.Browser", name: "Brave", kind: .chromium)
    private let edge     = DetectedBrowser(id: "com.microsoft.edgemac", name: "Edge", kind: .chromium)

    private func makeDetector(probe: StubNativeHostDeliveryProbe) -> RealBrowserDetector {
        RealBrowserDetector(deliveryProbe: probe, probeWindowSeconds: 30)
    }

    // MARK: - source mapping

    func testProbeSourceForSafariIsSafari() {
        XCTAssertEqual(RealBrowserDetector.probeSource(for: .safari), "safari")
    }

    func testProbeSourceForChromiumIsChromiumNativeHost() {
        XCTAssertEqual(RealBrowserDetector.probeSource(for: .chromium), "chromium-native-host")
    }

    // MARK: - Safari

    func testSafariEventsPresentReportsInstalled() {
        let probe = StubNativeHostDeliveryProbe(counts: ["safari": 1])
        XCTAssertEqual(makeDetector(probe: probe).checkExtensionInstalled(for: safari), .installed)
    }

    func testSafariZeroEventsReportsNotInstalled() {
        let probe = StubNativeHostDeliveryProbe(counts: ["safari": 0])
        XCTAssertEqual(makeDetector(probe: probe).checkExtensionInstalled(for: safari), .notInstalled)
    }

    func testSafariProbeFailureReportsUnknown() {
        let probe = StubNativeHostDeliveryProbe(counts: [:])  // any source → nil
        XCTAssertEqual(makeDetector(probe: probe).checkExtensionInstalled(for: safari), .unknown)
    }

    /// Pin the source separation: the Safari row must NOT consult the
    /// chromium-native-host bucket. Pre-cycle-8.29 (post-PR #206) the
    /// detector used file-existence under per-browser dirs, so this
    /// regression is structurally impossible; we keep the test so
    /// future surface changes cannot quietly merge the buckets.
    func testSafariRowIgnoresChromiumNativeHostBucket() {
        let probe = StubNativeHostDeliveryProbe(counts: [
            "chromium-native-host": 1000,
            "safari": 0,
        ])
        XCTAssertEqual(makeDetector(probe: probe).checkExtensionInstalled(for: safari), .notInstalled)
    }

    // MARK: - Chromium (coarse aggregation, audit memo §Q8)

    /// Any Chromium-family event flips every Chromium row to
    /// `.installed`. The audit memo recommends the 2-source aggregation
    /// (safari, chromium-native-host) rather than per-bundle granularity.
    func testChromiumEventsFromAnyBrowserFlipEveryChromiumRow() {
        let probe = StubNativeHostDeliveryProbe(counts: [
            "chromium-native-host": 1,  // could be from Chrome, Arc, Brave, Edge
        ])
        let detector = makeDetector(probe: probe)
        XCTAssertEqual(detector.checkExtensionInstalled(for: chrome), .installed)
        XCTAssertEqual(detector.checkExtensionInstalled(for: arc), .installed)
        XCTAssertEqual(detector.checkExtensionInstalled(for: brave), .installed)
        XCTAssertEqual(detector.checkExtensionInstalled(for: edge), .installed)
    }

    func testChromiumZeroEventsReportsNotInstalled() {
        let probe = StubNativeHostDeliveryProbe(counts: ["chromium-native-host": 0])
        XCTAssertEqual(makeDetector(probe: probe).checkExtensionInstalled(for: chrome), .notInstalled)
        XCTAssertEqual(makeDetector(probe: probe).checkExtensionInstalled(for: arc), .notInstalled)
        XCTAssertEqual(makeDetector(probe: probe).checkExtensionInstalled(for: brave), .notInstalled)
        XCTAssertEqual(makeDetector(probe: probe).checkExtensionInstalled(for: edge), .notInstalled)
    }

    func testChromiumProbeFailureReportsUnknown() {
        let probe = StubNativeHostDeliveryProbe(counts: [:])
        XCTAssertEqual(makeDetector(probe: probe).checkExtensionInstalled(for: chrome), .unknown)
    }

    func testChromiumRowIgnoresSafariBucket() {
        let probe = StubNativeHostDeliveryProbe(counts: [
            "safari": 100,
            "chromium-native-host": 0,
        ])
        XCTAssertEqual(makeDetector(probe: probe).checkExtensionInstalled(for: chrome), .notInstalled)
    }

    // MARK: - Probe call shape

    func testDetectorPassesProbeWindowSecondsToProbe() {
        let probe = StubNativeHostDeliveryProbe(counts: ["safari": 1])
        let detector = RealBrowserDetector(
            deliveryProbe: probe,
            probeWindowSeconds: 90
        )
        _ = detector.checkExtensionInstalled(for: safari)
        XCTAssertEqual(probe.calls.last?.source, "safari")
        XCTAssertEqual(probe.calls.last?.withinSeconds, 90)
    }
}

/// Test seam — records each `recentEventCount` call and returns
/// pre-canned counts keyed by source. A missing key returns `nil` to
/// exercise the detector's `.unknown` fallback.
final class StubNativeHostDeliveryProbe: NativeHostDeliveryProbe, @unchecked Sendable {
    struct Call: Equatable {
        let source: String
        let withinSeconds: Int
    }

    let counts: [String: Int]
    private(set) var calls: [Call] = []

    init(counts: [String: Int]) {
        self.counts = counts
    }

    func recentEventCount(source: String, withinSeconds: Int) -> Int? {
        calls.append(Call(source: source, withinSeconds: withinSeconds))
        return counts[source]
    }
}
#endif

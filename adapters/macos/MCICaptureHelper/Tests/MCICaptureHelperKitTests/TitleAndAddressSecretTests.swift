// SPDX-License-Identifier: Apache-2.0
//
// The OCR-time checks look past the window's text: its title and its
// address are checked too, the address as the agent stores it (without
// sign-in parameters), and the event that leaves the helper carries that
// address. The end-to-end run found both gaps (E2E-REPORT finding 2,
// `c8.url`): a token in the address of a window whose text showed only the
// site's name, and a key on a line of its own. All values are made up.

import CoreGraphics
import CoreVideo
import Foundation
import XCTest

@testable import MCICaptureHelperKit

final class TitleAndAddressSecretTests: XCTestCase {
    private static let jwt = "eyJhbGciOiJIUzI1NiJ9" + ".eyJzdWIiOiJsYXJjaCJ9" + ".TGFyY2hTZWNyZXRTaWduYXR1cmU"
    private static let tokenURL = "https://app.larch.example/auth/callback?access_token=" + jwt + "&lang=en"
    private static let anthropicKey = "sk-" + "ant-" + "api03-" + "Qm7Zp2Lr9Xw4Tn8Vb6Hc3Jk5Df1Gs0Ya8Ue4Wi2R"

    private static func cascade() -> SuppressionCascade {
        SuppressionCascade(
            secureEventInput: NoSecureInputForAddressTests(),
            axSecureSubrole: NonSecureAXForAddressTests(),
            denylist: EmptyDenylistForAddressTests(),
            blackedRegion: NoBlackRegionForAddressTests(),
            knownSafeAppBundles: ["com.example.notes"]
        )
    }

    // MARK: - The shared address corpus

    /// `core/brain/fixtures/url-secret-params-corpus.json`, which the Rust
    /// agent's test reads too: both store every address the same way.
    func testEveryAddressInTheSharedCorpusIsStoredAsItSays() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("core/brain/fixtures/url-secret-params-corpus.json")
        struct Corpus: Decodable {
            let cases: [Case]
            struct Case: Decodable {
                let url: String
                let stored: String
                let why: String
            }
        }
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 30)
        for item in corpus.cases {
            XCTAssertEqual(SuppressionCascade.urlWithoutSecretParams(item.url), item.stored, item.why)
            XCTAssertEqual(SuppressionCascade.urlWithoutSecretParams(item.stored), item.stored, "idempotent: \(item.why)")
        }
    }

    // MARK: - decideOcr reads the title and the address

    func testASecretInTheTitleStopsTheFrame() {
        let context = WorkflowContext(appBundleId: "com.example.notes", windowTitle: "Keys — " + Self.anthropicKey)
        XCTAssertEqual(Self.cascade().decideOcr(text: "Bramble agent setup", context: context),
                       .suppress(reason: .ocrTimeSecret))
    }

    func testASecretInTheAddressOutsideItsSignInParametersStopsTheFrame() {
        let context = WorkflowContext(appBundleId: "com.example.notes", windowTitle: "Reset",
                                      url: "https://app.larch.example/reset/" + Self.jwt)
        XCTAssertEqual(Self.cascade().decideOcr(text: "Choose a new password", context: context),
                       .suppress(reason: .ocrTimeSecret))
    }

    func testAnAddressWhoseOnlySecretIsASignInParameterIsKept() {
        XCTAssertTrue(SuppressionCascade.containsSecretOrPII(Self.tokenURL), "the raw address holds a secret")
        let context = WorkflowContext(appBundleId: "com.example.notes", windowTitle: "Larch Workspace",
                                      url: Self.tokenURL)
        XCTAssertEqual(Self.cascade().decideOcr(text: "Welcome back to app.larch.example", context: context), .allow)
    }

    func testABareVendorKeyOnScreenStopsTheFrame() {
        let context = WorkflowContext(appBundleId: "com.example.notes", windowTitle: "Terminal")
        XCTAssertEqual(Self.cascade().decideOcr(text: "Bramble agent setup\n" + Self.anthropicKey, context: context),
                       .suppress(reason: .ocrTimeSecret))
    }

    // MARK: - What leaves the helper

    func testTheEventCarriesTheAddressWithoutItsSignInParameters() async {
        let sink = AddressRecordingSink()
        await CascadeTwiceOCREmitter.handleOCRResult(
            tsUs: 1,
            context: WorkflowContext(appBundleId: "com.example.notes", windowTitle: "Larch Workspace", url: Self.tokenURL),
            result: OCRResult(
                recognizedLines: [OCRLine(text: "Welcome back to app.larch.example",
                                          boundingBox: CGRect(x: 0.2, y: 0.8, width: 0.4, height: 0.02),
                                          confidence: 0.95)],
                durationMs: 1, timedOut: false
            ),
            cascade: Self.cascade(),
            sink: sink,
            sequence: FrameSequence(),
            counters: HelperHealthCounters(),
            pixelBuffer: Self.pixelBuffer()
        )
        let frames = await sink.frames()
        XCTAssertEqual(frames.count, 1)
        guard let frame = frames.first else { return }
        XCTAssertFalse(frame.count >= 4 && frame[2] == 0x11, "kept, not a tombstone")
        XCTAssertNotNil(frame.range(of: Data("https://app.larch.example/auth/callback?lang=en".utf8)))
        XCTAssertNil(frame.range(of: Data("access_token".utf8)))
        XCTAssertNil(frame.range(of: Data("TGFyY2hTZWNyZXRTaWduYXR1cmU".utf8)))
    }

    private static func pixelBuffer() -> CVPixelBuffer {
        var output: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 1440, 900, kCVPixelFormatType_32BGRA, nil,
                                         &output) == kCVReturnSuccess)
        return output!
    }
}

private actor AddressRecordingSink: FrameSink {
    private var recorded: [Data] = []
    func write(_ bytes: Data) throws { recorded.append(bytes) }
    func frames() -> [Data] { recorded }
}

private struct NoSecureInputForAddressTests: SecureEventInputProbe {
    func isSecureEventInputEnabled() -> Bool { false }
}

private struct NonSecureAXForAddressTests: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { false }
}

private struct EmptyDenylistForAddressTests: DenylistProbe {
    func appIsDenied(bundleId _: String) -> Bool { false }
    func urlIsDenied(_: String) -> Bool { false }
    func windowTitleIsDenied(_: String) -> Bool { false }
}

private struct NoBlackRegionForAddressTests: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}

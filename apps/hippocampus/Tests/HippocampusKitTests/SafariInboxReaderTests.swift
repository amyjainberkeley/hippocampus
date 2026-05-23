// SPDX-License-Identifier: TBD-private
import XCTest
@testable import HippocampusKit

final class SafariInboxReaderTests: XCTestCase {

    // MARK: - URL Denylist

    func testDeniedURLsBlocked() {
        XCTAssertTrue(SafariInboxReader.isDeniedURL("https://example.com/login"))
        XCTAssertTrue(SafariInboxReader.isDeniedURL("https://accounts.google.com/signin"))
        XCTAssertTrue(SafariInboxReader.isDeniedURL("https://example.com/sign-in"))
        XCTAssertTrue(SafariInboxReader.isDeniedURL("https://example.com/Password/reset"))
        XCTAssertTrue(SafariInboxReader.isDeniedURL("chrome://settings"))
        XCTAssertTrue(SafariInboxReader.isDeniedURL("chrome-extension://abc"))
        XCTAssertTrue(SafariInboxReader.isDeniedURL("about:blank"))
        XCTAssertTrue(SafariInboxReader.isDeniedURL("data:text/html,<h1>hi</h1>"))
        XCTAssertTrue(SafariInboxReader.isDeniedURL("file:///etc/passwd"))
    }

    func testAllowedURLsPass() {
        XCTAssertFalse(SafariInboxReader.isDeniedURL("https://example.com/pricing"))
        XCTAssertFalse(SafariInboxReader.isDeniedURL("https://docs.rust-lang.org/book/"))
        XCTAssertFalse(SafariInboxReader.isDeniedURL("https://github.com/pulls"))
    }

    // MARK: - Secret Filter

    func testCleanTextPasses() {
        XCTAssertFalse(SafariInboxReader.containsSecret("Hello world, no secrets here."))
        XCTAssertFalse(SafariInboxReader.containsSecret(""))
        XCTAssertFalse(SafariInboxReader.containsSecret("Plans start at $10/mo."))
    }

    func testPasswordPatternBlocked() {
        XCTAssertTrue(SafariInboxReader.containsSecret("password=hunter2"))
        XCTAssertTrue(SafariInboxReader.containsSecret("Password: SuperSecret!"))
        XCTAssertTrue(SafariInboxReader.containsSecret("api_key = sk-deadbeefcafe"))
    }

    func testGitHubPATBlocked() {
        XCTAssertTrue(SafariInboxReader.containsSecret(
            "Stale ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 token"
        ))
    }

    func testAWSKeyBlocked() {
        XCTAssertTrue(SafariInboxReader.containsSecret("AWS AKIAIOSFODNN7EXAMPLE"))
    }

    func testJWTBlocked() {
        XCTAssertTrue(SafariInboxReader.containsSecret(
            "Set-Cookie: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123; HttpOnly"
        ))
    }

    // MARK: - Text Truncation

    func testShortTextUnchanged() {
        let text = "short"
        XCTAssertEqual(
            SafariInboxReader.truncateAtSentenceBoundary(text, maxBytes: 1000),
            "short"
        )
    }

    func testTruncateAtSentenceBoundary() {
        let text = "First sentence. Second sentence. Third sentence."
        let result = SafariInboxReader.truncateAtSentenceBoundary(text, maxBytes: 30)
        XCTAssertEqual(result, "First sentence.")
    }

    func testTruncateAtNewline() {
        let text = "no sentence boundary here\nbut there is a newline"
        let result = SafariInboxReader.truncateAtSentenceBoundary(text, maxBytes: 35)
        XCTAssertEqual(result, "no sentence boundary here")
    }

    func testTruncateRawCutoff() {
        let text = "no sentence boundary here at all"
        let result = SafariInboxReader.truncateAtSentenceBoundary(text, maxBytes: 15)
        XCTAssertEqual(result, "no sentence bou")
    }

    // MARK: - Wire encoding

    func testWireEncodingCrossSideFixture() {
        // Must match core/src/ipc/wire.rs page_content_event_cross_side_fixture
        let data = SafariInboxReader.encodePageContentEvent(
            seq: 7,
            tsUs: 0x0102_0304_0506_0708,
            url: "U",
            title: "T",
            fullText: "Hi",
            sourceBrowser: "chrome",
            tabId: 99
        )

        // Frame total = 16 (header) + 29 (fixed payload) + 10 (variable) = 55
        XCTAssertEqual(data.count, 55)

        let bytes = Array(data)

        // Header: magic(M), version(0x06), msg_type(0x0050 LE), seq(7 LE), payload_len(39 LE)
        XCTAssertEqual(bytes[0], 0x4D)
        XCTAssertEqual(bytes[1], 0x06)
        XCTAssertEqual(bytes[2], 0x50)
        XCTAssertEqual(bytes[3], 0x00)

        // Frame seq
        var expected = UInt64(7).littleEndian
        XCTAssertEqual(
            Data(bytes: &expected, count: 8),
            data[4..<12]
        )

        // Payload len
        var payloadLen = UInt32(39).littleEndian
        XCTAssertEqual(
            Data(bytes: &payloadLen, count: 4),
            data[12..<16]
        )

        // Payload seq
        XCTAssertEqual(
            Data(bytes: &expected, count: 8),
            data[16..<24]
        )

        // url_len = 1
        XCTAssertEqual(bytes[32], 1)
        XCTAssertEqual(bytes[33], 0)

        // title_len = 1
        XCTAssertEqual(bytes[34], 1)
        XCTAssertEqual(bytes[35], 0)

        // full_text_len = 2
        XCTAssertEqual(bytes[36], 2)
        XCTAssertEqual(bytes[37], 0)
        XCTAssertEqual(bytes[38], 0)
        XCTAssertEqual(bytes[39], 0)

        // source_browser_len = 6
        XCTAssertEqual(bytes[40], 6)

        // tab_id = 99
        XCTAssertEqual(bytes[41], 99)
        XCTAssertEqual(bytes[42], 0)
        XCTAssertEqual(bytes[43], 0)
        XCTAssertEqual(bytes[44], 0)

        // Variable: U, T, Hi, chrome
        XCTAssertEqual(bytes[45], UInt8(ascii: "U"))
        XCTAssertEqual(bytes[46], UInt8(ascii: "T"))
        XCTAssertEqual(bytes[47], UInt8(ascii: "H"))
        XCTAssertEqual(bytes[48], UInt8(ascii: "i"))
        XCTAssertEqual(Array(bytes[49..<55]), Array("chrome".utf8))
    }

    func testWireEncodingMinimal() {
        let data = SafariInboxReader.encodePageContentEvent(
            seq: 0,
            tsUs: 0,
            url: "",
            title: "",
            fullText: "",
            sourceBrowser: "",
            tabId: 0
        )
        // 16 (header) + 29 (fixed payload) + 0 (variable) = 45
        XCTAssertEqual(data.count, 45)

        let bytes = Array(data)
        XCTAssertEqual(bytes[0], 0x4D)
        XCTAssertEqual(bytes[1], 0x06)
    }
}

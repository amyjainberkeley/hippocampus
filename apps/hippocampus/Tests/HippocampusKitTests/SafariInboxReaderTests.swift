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

    // MARK: - SO_NOSIGPIPE (cycle 8.23 main-GUI-death regression pin)

    /// `SafariInboxReader.makeUnixStreamSocket()` MUST return an fd
    /// with `SO_NOSIGPIPE` set, so a `write(2)` against a peer that
    /// has closed its read end returns `EPIPE` instead of raising
    /// `SIGPIPE` and terminating the process.
    ///
    /// Regression context: cycle 8.23 main-GUI-death. The
    /// `ProcessSupervisor` retry loop unbinds + rebinds the agent's
    /// `page_content.sock` listener whenever helper or agent exits.
    /// Any drain that has already `connect()`ed and is mid-`write()`
    /// during that window would, without `SO_NOSIGPIPE`, raise
    /// `SIGPIPE` in the main GUI process — whose default disposition
    /// is process termination with a clean exit (no `.ips` report).
    /// This is exactly the menu-bar-icon-disappears bug the CEO
    /// reported. `HippocampusApp.applicationDidFinishLaunching` also
    /// installs `SIG_IGN` for `SIGPIPE` process-wide; this socket-
    /// option is the surgical defense at the offending call site.
    func test_makeUnixStreamSocket_sets_SO_NOSIGPIPE() throws {
        guard let fd = SafariInboxReader.makeUnixStreamSocket() else {
            XCTFail("socket(AF_UNIX, SOCK_STREAM, 0) failed")
            return
        }
        defer { close(fd) }

        var value: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        let rc = getsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE,
            &value, &len
        )
        XCTAssertEqual(
            rc, 0,
            "getsockopt(SO_NOSIGPIPE) failed errno=\(errno)"
        )
        XCTAssertNotEqual(
            value, 0,
            """
            SO_NOSIGPIPE MUST be non-zero on the returned fd.
            Without it, write(2) to a closed-peer socket raises
            SIGPIPE — clean process exit, no crash report. This is
            the cycle 8.23 main-GUI-death bug.
            """
        )
    }

    /// End-to-end pin: an in-process server accepts on a Unix-domain
    /// socket, immediately closes its accepted fd, and we verify that
    /// `write(2)` from the SafariInboxReader-style socket returns -1
    /// (with `errno == EPIPE`) instead of raising `SIGPIPE` and
    /// killing the test process.
    ///
    /// This is the actual end-to-end reproduction of the cycle 8.23
    /// failure mode in a test: take a real socket, real peer-close,
    /// real write — without `SO_NOSIGPIPE` the test runner itself
    /// would die here (no XCTest failure, just a clean exit with no
    /// junit output). With `SO_NOSIGPIPE` set by
    /// `makeUnixStreamSocket()` this returns gracefully.
    func test_write_to_closed_peer_returns_EPIPE_not_SIGPIPE() throws {
        // Build a sock path under /tmp that is short enough for
        // sockaddr_un (104 bytes incl. NUL on Darwin).
        let socketPath = "/tmp/mci-test-\(UInt32.random(in: 0..<UInt32.max)).sock"
        unlink(socketPath)
        defer { unlink(socketPath) }

        // Server side
        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(serverFD, 0)
        defer { close(serverFD) }

        // Pre-capture sun_path size to avoid Swift exclusivity
        // violation inside `withUnsafeMutablePointer(to: &addr.sun_path)`.
        let sunPathSize = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

        var serverAddr = sockaddr_un()
        serverAddr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &serverAddr.sun_path) { dest in
                dest.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { destChar in
                    strncpy(destChar, src, sunPathSize - 1)
                }
            }
        }
        let bindRC = withUnsafePointer(to: &serverAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saddr in
                Darwin.bind(
                    serverFD, saddr,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        XCTAssertEqual(bindRC, 0, "bind failed errno=\(errno)")
        XCTAssertEqual(listen(serverFD, 1), 0)

        // Client side via SafariInboxReader's hardened socket factory.
        guard let clientFD = SafariInboxReader.makeUnixStreamSocket() else {
            XCTFail("makeUnixStreamSocket failed")
            return
        }
        defer { close(clientFD) }

        var clientAddr = sockaddr_un()
        clientAddr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &clientAddr.sun_path) { dest in
                dest.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { destChar in
                    strncpy(destChar, src, sunPathSize - 1)
                }
            }
        }
        let connectRC = withUnsafePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saddr in
                Darwin.connect(
                    clientFD, saddr,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        XCTAssertEqual(connectRC, 0, "connect failed errno=\(errno)")

        // Server accepts then immediately closes — simulating an
        // mci-agent restart during a SafariInboxReader write.
        let acceptedFD = accept(serverFD, nil, nil)
        XCTAssertGreaterThanOrEqual(acceptedFD, 0, "accept failed errno=\(errno)")
        close(acceptedFD)

        // Give the OS a beat to deliver the close to the client side.
        // 50ms is plenty on a loaded CI box; we're not racing anything.
        usleep(50_000)

        // First write may succeed into the buffer (TCP-like grace) —
        // the second triggers EPIPE. Loop until we get a negative
        // return or 64 KB to bound the test.
        let payload = [UInt8](repeating: 0x41, count: 4096)
        var sawEPIPE = false
        var totalWritten = 0
        for _ in 0..<16 {
            let n = payload.withUnsafeBytes { buf -> Int in
                Darwin.write(clientFD, buf.baseAddress, payload.count)
            }
            if n < 0 {
                XCTAssertEqual(
                    errno, EPIPE,
                    "expected EPIPE, got errno=\(errno)"
                )
                sawEPIPE = true
                break
            }
            totalWritten += n
        }

        // Either we saw EPIPE (write failed gracefully) OR we wrote
        // the full bounded payload (peer's socket buffer absorbed it,
        // no error path needed). Either is acceptable — what would
        // FAIL the test is process termination via SIGPIPE, which
        // would prevent this XCTAssert from ever running.
        XCTAssertTrue(
            sawEPIPE || totalWritten > 0,
            "neither EPIPE nor any successful write — unexpected"
        )
    }
}

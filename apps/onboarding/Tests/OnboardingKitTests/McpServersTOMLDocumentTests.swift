import XCTest
@testable import OnboardingKit

final class McpServersTOMLDocumentTests: XCTestCase {
    func testEmitRoundTrips() throws {
        let entries = [
            McpServerEntry(name: "gchat", url: "http://127.0.0.1:7890/mcp"),
            McpServerEntry(
                name: "slack",
                url: "http://localhost:9000/sse",
                authHeader: "Bearer abc123",
                enabled: false
            ),
        ]
        let s = McpServersTOMLDocument.emit(entries)
        let parsed = try McpServersTOMLDocument.parse(s)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].name, "gchat")
        XCTAssertEqual(parsed[0].url, "http://127.0.0.1:7890/mcp")
        XCTAssertNil(parsed[0].authHeader)
        XCTAssertTrue(parsed[0].enabled)
        XCTAssertEqual(parsed[1].authHeader, "Bearer abc123")
        XCTAssertFalse(parsed[1].enabled)
    }

    func testEmptyEmitParsesToEmpty() throws {
        let s = McpServersTOMLDocument.emit([])
        let parsed = try McpServersTOMLDocument.parse(s)
        XCTAssertEqual(parsed.count, 0)
    }

    func testIncompleteRowIsDropped() throws {
        // Missing required `url` — the OnboardingKit reader is
        // forgiving; the agent's strict loader is the source of truth.
        let body = """
        [[server]]
        name = "broken"
        """
        let parsed = try McpServersTOMLDocument.parse(body)
        XCTAssertEqual(parsed.count, 0)
    }

    func testUnknownKeysAreSkipped() throws {
        let body = """
        [[server]]
        name = "x"
        url = "http://127.0.0.1/m"
        future_field = "ignore me"
        """
        let parsed = try McpServersTOMLDocument.parse(body)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].name, "x")
    }

    func testQuotesAndBackslashesAreStripped() throws {
        // Hostile rationale-like input gets sanitized on emit so the
        // file cannot break out of the strict subset.
        let entry = McpServerEntry(
            name: "x",
            url: "http://127.0.0.1/m",
            authHeader: "evil\\\"injection",
            enabled: true
        )
        let s = McpServersTOMLDocument.emit([entry])
        let parsed = try McpServersTOMLDocument.parse(s)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertFalse(parsed[0].authHeader?.contains("\"") ?? false)
    }
}

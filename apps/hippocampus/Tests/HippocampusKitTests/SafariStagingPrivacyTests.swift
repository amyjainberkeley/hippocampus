// SPDX-License-Identifier: Apache-2.0
//
// Storage-security review S10: a page the Safari extension stages is never
// kept on disk for more than about a minute, and the capture helper's full
// secret check (the four shapes, a card number, a one-time code) runs on
// its text, title and address before it is forwarded. Every page here is
// made up, in a throwaway folder.

import XCTest
@testable import HippocampusKit

final class SafariStagingPrivacyTests: XCTestCase {
    private var inbox: URL!

    override func setUpWithError() throws {
        inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("safari-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: inbox)
    }

    private func stage(_ name: String, url: String = "https://example.com/page", title: String = "Page",
                       text: String = "Plain words about the project.", age: TimeInterval = 0) throws -> URL {
        let file = inbox.appendingPathComponent(name)
        let payload: [String: Any] = [
            "url": url, "title": title, "text": text, "ts_us": UInt64(1), "tab_id": UInt32(7),
            "source_browser": "safari", "capture_generation": "generation-1",
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        let stamp = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        return file
    }

    func testAPageStagedOverAMinuteAgoIsDeletedUnread() throws {
        let stale = try stage("stale.json", age: 90)
        let half = try stage(".half-written.json.tmp", age: 120)
        let fresh = try stage("fresh.json", age: 5)
        XCTAssertEqual(SafariInboxReader.removeStalePages(in: inbox), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: half.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "a page still on its way is kept")
        XCTAssertEqual(SafariInboxReader.maxStagedAge, 60)
    }

    @MainActor
    func testEverySecretShapeIsDroppedFromTextTitleAndAddress() throws {
        let reader = SafariInboxReader(expectedGenerationID: "generation-1")
        var frames: [Data] = []
        let writer: (Data) -> Bool = { frames.append($0); return true }
        // The public test card number, a code beside its keyword, a token
        // in the address, a secret in the title: none reaches the agent.
        let pages = [
            try stage("card.json", text: "Pay with card 4111 1111 1111 1111 exp 12/29"),
            try stage("code.json", text: "Your verification code is 482913."),
            try stage("address.json", url: "https://app.example.com/cb?access_token=SYNTHTOKEN0000"),
            try stage("title.json", title: "password: SYNTHhunter2"),
        ]
        for page in pages {
            reader.processPayloadFile(page, writeFrame: writer)
            XCTAssertFalse(FileManager.default.fileExists(atPath: page.path), "\(page.lastPathComponent) is gone")
        }
        XCTAssertEqual(reader.droppedSecret, 4)
        XCTAssertEqual(reader.forwarded, 0)
        XCTAssertTrue(frames.isEmpty)

        let clean = try stage("clean.json")
        reader.processPayloadFile(clean, writeFrame: writer)
        XCTAssertEqual(reader.forwarded, 1, "a page with nothing secret still goes through")
    }

    /// The vendor keys the helper learned (sec/secrets) are dropped from a
    /// staged page too, and a number inside a file name is not a card. Each
    /// key is put together here from parts, so no whole key-shaped string
    /// sits in the repository; none is, or ever was, a real key.
    @MainActor
    func testVendorKeysAreDroppedAndANumberInsideANameIsNot() throws {
        let reader = SafariInboxReader(expectedGenerationID: "generation-1")
        var frames: [Data] = []
        let writer: (Data) -> Bool = { frames.append($0); return true }
        let body = "Qm7Zp2Lr9Xw4Tn8Vb6Hc3Jk5Df1Gs0Ya8Ue4Wi2R"
        let short20 = String(body.prefix(20)), short22 = String(body.prefix(22)), short24 = String(body.prefix(24))
        let google = String((body + body).prefix(35))
        let parts: [[String]] = [
            ["sk-", "ant-", "api03-", body],
            ["sk-", "proj-", body],
            ["xox", "b-", "1234567890", "-", "9876543210", "-", short24],
            ["github", "_pat_", short22, "_", body],
            ["glpat-", short20],
            ["AIza", google],
            ["sk", "_live_", short24],
            ["-----BEGIN ", "OPENSSH PRIVATE KEY-----"],
            ["Authorization: ", "Bearer ", body],
        ]
        let keys: [String] = parts.map { $0.joined() }
        for (index, key) in keys.enumerated() {
            XCTAssertTrue(PageSecretCheck.containsSecret("Copy it now: \(key) (shown once)"), key)
            let page = try stage("vendor-\(index).json", text: "Copy it now: \(key) (shown once)")
            reader.processPayloadFile(page, writeFrame: writer)
            XCTAssertFalse(FileManager.default.fileExists(atPath: page.path))
        }
        XCTAssertEqual(reader.droppedSecret, UInt64(keys.count))
        XCTAssertTrue(frames.isEmpty)

        // A timestamp in a name passes Luhn (4111111111111111 does too), yet
        // it is an id, not a card; on its own the same digits are a card.
        XCTAssertFalse(PageSecretCheck.containsCreditCard("handoff-4111111111111111.md"))
        XCTAssertFalse(PageSecretCheck.containsCreditCard("export_4111111111111111.json"))
        XCTAssertTrue(PageSecretCheck.containsCreditCard("card 4111111111111111 exp 12/29"))
        let named = try stage("named.json", title: "handoff-4111111111111111.md",
                              text: "The handoff-4111111111111111.md packet is ready.")
        reader.processPayloadFile(named, writeFrame: writer)
        XCTAssertEqual(reader.forwarded, 1, "a number inside a name is not a secret")
    }

    /// The shared corpus every secret check answers alike: the helper's,
    /// the Rust reader's and this one.
    func testTheFullCheckAgreesWithTheSharedCorpus() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let corpusURL = root.appendingPathComponent("core/brain/fixtures/ocr-secret-corpus.json")
        let corpus = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL)) as? [String: Any]
        )
        let cases = try XCTUnwrap(corpus["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 20)
        // A case gives its `text`, or `parts` to join: key-shaped cases are
        // kept in parts so no whole key sits in the repository. Every one of
        // them counts here, the vendor keys among them.
        XCTAssertGreaterThan(cases.filter { $0["parts"] != nil }.count, 20)
        for entry in cases {
            let text = try XCTUnwrap(
                (entry["text"] as? String) ?? (entry["parts"] as? [String])?.joined(),
                "\(entry["why"] ?? "a case with neither text nor parts")"
            )
            let secret = try XCTUnwrap(entry["secret"] as? Bool)
            XCTAssertEqual(PageSecretCheck.containsSecret(text), secret, "\(entry["why"] ?? ""): \(text)")
            XCTAssertEqual(SafariInboxReader.containsSecret(text) || !secret, true, text)
        }
    }
}

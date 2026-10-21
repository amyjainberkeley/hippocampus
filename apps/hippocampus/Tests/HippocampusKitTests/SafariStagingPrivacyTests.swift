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
        for entry in cases {
            // The case's text, or its `parts` joined: key-shaped cases are
            // kept in parts so no whole key sits in the repository.
            let text = try XCTUnwrap((entry["text"] as? String) ?? (entry["parts"] as? [String])?.joined(),
                                     "\(entry["why"] ?? "")")
            let secret = try XCTUnwrap(entry["secret"] as? Bool)
            XCTAssertEqual(PageSecretCheck.containsSecret(text), secret, "\(entry["why"] ?? ""): \(text)")
            XCTAssertEqual(SafariInboxReader.containsSecret(text) || !secret, true, text)
        }
    }
}

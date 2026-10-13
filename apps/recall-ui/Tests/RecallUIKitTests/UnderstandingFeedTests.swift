import XCTest
@testable import RecallUIKit

@MainActor
final class UnderstandingFeedTests: XCTestCase {
    func testANewKeyLoadsAndShowsItsRead() async {
        let source = FeedSource()
        let feed = UnderstandingFeed<String, String>(deletions: MemoryDeletionSignal()) { key in
            try await source.read(key)
        }
        XCTAssertEqual(feed.phase, .idle)
        await source.answer("monday", with: "Monday's day")
        await feed.load("monday")
        XCTAssertEqual(feed.phase, .ready)
        XCTAssertEqual(feed.value, "Monday's day")
        XCTAssertFalse(feed.isRefreshing)
    }

    func testARefreshKeepsTheLastGoodReadOnScreen() async throws {
        let source = FeedSource()
        let feed = UnderstandingFeed<String, String>(deletions: MemoryDeletionSignal()) { key in
            try await source.read(key)
        }
        await source.answer("monday", with: "first")
        await feed.load("monday")
        await source.hold()
        let refresh = Task { await feed.refresh() }
        await assertEventually { await source.waiting }
        XCTAssertEqual(feed.value, "first")
        XCTAssertEqual(feed.phase, .ready)
        XCTAssertTrue(feed.isRefreshing)
        await source.release(with: .success("second"))
        await refresh.value
        XCTAssertEqual(feed.value, "second")
        XCTAssertFalse(feed.isRefreshing)
    }

    func testAFailedRefreshKeepsTheLastGoodRead() async {
        let source = FeedSource()
        let feed = UnderstandingFeed<String, String>(deletions: MemoryDeletionSignal()) { key in
            try await source.read(key)
        }
        await source.answer("monday", with: "first")
        await feed.load("monday")
        await source.fail("monday", with: UnderstandingError.unavailable)
        await feed.refresh()
        XCTAssertEqual(feed.value, "first")
        XCTAssertEqual(feed.phase, .ready)
        XCTAssertFalse(feed.isRefreshing)
    }

    func testAFailedFirstReadIsUnavailable() async {
        let source = FeedSource()
        let feed = UnderstandingFeed<String, String>(deletions: MemoryDeletionSignal()) { key in
            try await source.read(key)
        }
        await source.fail("monday", with: UnderstandingError.malformed)
        await feed.load("monday")
        XCTAssertEqual(feed.phase, .unavailable)
        XCTAssertNil(feed.value)
    }

    func testACancelledReadIsNeverUnavailable() async {
        let source = FeedSource()
        let feed = UnderstandingFeed<String, String>(deletions: MemoryDeletionSignal()) { key in
            try await source.read(key)
        }
        await source.fail("monday", with: CancellationError())
        await feed.load("monday")
        XCTAssertEqual(feed.phase, .loading)
        XCTAssertNil(feed.value)

        await source.answer("monday", with: "first")
        await feed.load("monday")
        await source.fail("monday", with: CancellationError())
        await feed.refresh()
        XCTAssertEqual(feed.phase, .ready)
        XCTAssertEqual(feed.value, "first")
        XCTAssertFalse(feed.isRefreshing)
    }

    func testAnotherKeyNeverShowsTheLastKeysRead() async {
        let source = FeedSource()
        let feed = UnderstandingFeed<String, String>(deletions: MemoryDeletionSignal()) { key in
            try await source.read(key)
        }
        await source.answer("monday", with: "Monday's day")
        await feed.load("monday")
        await source.hold()
        let tuesday = Task { await feed.load("tuesday") }
        await assertEventually { await source.waiting }
        XCTAssertEqual(feed.key, "tuesday")
        XCTAssertNil(feed.value)
        XCTAssertEqual(feed.phase, .loading)
        XCTAssertFalse(feed.isRefreshing)
        await source.release(with: .success("Tuesday's day"))
        await tuesday.value
        XCTAssertEqual(feed.value, "Tuesday's day")
    }

    func testAnOlderReadThatFinishesLastIsNotShown() async {
        let source = FeedSource()
        let feed = UnderstandingFeed<String, String>(deletions: MemoryDeletionSignal()) { key in
            try await source.read(key)
        }
        await source.hold()
        let monday = Task { await feed.load("monday") }
        await assertEventually { await source.waiting }
        await source.answer("tuesday", with: "Tuesday's day")
        await feed.load("tuesday")
        await source.release(with: .success("Monday's day"))
        await monday.value
        XCTAssertEqual(feed.key, "tuesday")
        XCTAssertEqual(feed.value, "Tuesday's day")
    }

    func testADeleteClearsWhatIsShownAtOnceAndReadsItAgain() async {
        let source = FeedSource()
        let deletions = MemoryDeletionSignal()
        let feed = UnderstandingFeed<String, String>(deletions: deletions) { key in
            try await source.read(key)
        }
        await source.answer("monday", with: "made from a moment that is about to go")
        await feed.load("monday")
        await source.answer("monday", with: "what is left")
        deletions.post()
        XCTAssertNil(feed.value, "derived text leaves the screen at once")
        XCTAssertEqual(feed.phase, .loading)
        await assertEventually { await MainActor.run { feed.value == "what is left" } }
        XCTAssertEqual(feed.phase, .ready)
    }

    func testADeleteElsewhereDoesNotClearThisFeed() async {
        let source = FeedSource()
        let feed = UnderstandingFeed<String, String>(deletions: MemoryDeletionSignal()) { key in
            try await source.read(key)
        }
        await source.answer("monday", with: "kept")
        await feed.load("monday")
        MemoryDeletionSignal().post()
        XCTAssertEqual(feed.value, "kept")
    }
}

/// Answers a feed's reads as the test says: at once, failing, or (the next
/// read after `hold()`) held until released.
private actor FeedSource {
    private var answers: [String: Result<String, any Error>] = [:]
    private var holding = false
    private var held: CheckedContinuation<String, any Error>?

    var waiting: Bool { held != nil }

    func answer(_ key: String, with value: String) { answers[key] = .success(value) }
    func fail(_ key: String, with error: any Error) { answers[key] = .failure(error) }
    func hold() { holding = true }

    func release(with result: Result<String, any Error>) {
        held?.resume(with: result)
        held = nil
    }

    func read(_ key: String) async throws -> String {
        if holding {
            holding = false
            return try await withCheckedThrowingContinuation { held = $0 }
        }
        guard let answer = answers[key] else { throw UnderstandingError.unavailable }
        return try answer.get()
    }
}

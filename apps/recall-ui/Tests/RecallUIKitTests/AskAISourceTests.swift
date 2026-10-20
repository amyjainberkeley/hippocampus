import XCTest
@testable import RecallUIKit

/// What an Ask {Tool} button hands over names moments by id and a session
/// by its time: never a moment's text (SPEC 5.3.3, 5.3.10).
final class AskAISourceTests: XCTestCase {
    func testEachSourceNamesItsMomentsOnly() {
        XCTAssertEqual(AskAISource.moments([4812, 4790]).momentIds, [4812, 4790])
        XCTAssertEqual(AskAISource.question("Why does rounding drift?", moments: [4812]).momentIds, [4812])
        XCTAssertEqual(AskAISource.session(title: "Shipping the rounding fix", range: 10...20).momentIds, [])
        XCTAssertEqual(AskAISource.item("w_9c41e2").momentIds, [])
    }

    func testSourcesAreValues() {
        XCTAssertEqual(AskAISource.item("w_1"), .item("w_1"))
        XCTAssertNotEqual(AskAISource.item("w_1"), .item("w_2"))
        XCTAssertEqual(Set([AskAISource.moments([1]), .moments([1])]).count, 1)
    }
}

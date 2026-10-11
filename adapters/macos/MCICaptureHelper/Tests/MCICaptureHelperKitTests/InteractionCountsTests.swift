import XCTest
@testable import MCICaptureHelperKit

final class InteractionCountsTests: XCTestCase {
    func testDeltasHandleWrapAndReset() {
        let before = InteractionTotals(keys: UInt32.max - 2, clicks: 10, scrolls: 500, moves: 7)
        let after = InteractionTotals(keys: 4, clicks: 13, scrolls: 2, moves: 9)
        let delta = after.since(before)
        XCTAssertEqual(delta.keys, 7, "a counter that wrapped still counts")
        XCTAssertEqual(delta.clicks, 3)
        XCTAssertEqual(delta.scrolls, 0, "a counter that reset reads as nothing")
        XCTAssertEqual(delta.moves, 2)
    }

    func testWireLayoutIsTwoTimesThenFourCounts() {
        let frame = encodeInteractionCounts(seq: 5, counts: MeasuredInteractionCounts(
            startUs: 1_000_000, endUs: 5_000_000,
            totals: InteractionTotals(keys: 12, clicks: 1, scrolls: 3, moves: 40)))
        let payload = frame.suffix(8 + 8 + 16)
        func u64(_ offset: Int) -> UInt64 { payload.dropFirst(offset).prefix(8).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) } }
        func u32(_ offset: Int) -> UInt32 { payload.dropFirst(offset).prefix(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        XCTAssertEqual(u64(0), 1_000_000)
        XCTAssertEqual(u64(8), 5_000_000)
        XCTAssertEqual([u32(16), u32(20), u32(24), u32(28)], [12, 1, 3, 40])
        XCTAssertEqual(MessageType.interactionCounts.rawValue, 0x0061)
    }
}

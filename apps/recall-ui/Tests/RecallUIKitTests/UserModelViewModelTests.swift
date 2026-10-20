import Foundation
import XCTest
@testable import RecallUIKit

/// You: the exact words an AI is given, grouped as the page shows them, with
/// "Right" and "Forget" written at once (RULINGS I7, I8, I10; contract
/// model-page.md).
@MainActor
final class UserModelViewModelTests: XCTestCase {
    private func inbox() throws -> (VerdictInbox, URL) {
        let folder = try TestFolders.make().appendingPathComponent("understanding-feedback", isDirectory: true)
        return (VerdictInbox(directory: folder, environment: [:]), folder)
    }

    private func loaded(_ verdicts: VerdictInbox, page: ModelPage? = nil,
                        deletions: MemoryDeletionSignal = MemoryDeletionSignal()) async throws -> (UserModelViewModel, ScriptedUnderstanding) {
        let understanding = ScriptedUnderstanding()
        await understanding.setPage(try page ?? UnderstandingFixture.modelPage())
        let model = UserModelViewModel(understanding: understanding, verdicts: verdicts, deletions: deletions)
        await model.reload()
        return (model, understanding)
    }

    func testGroupsFollowThePagesOrderAndKeepTheAgentsOrderInside() throws {
        let page = try UnderstandingFixture.modelPage()
        let shared = UserModelGrouping.groups(page.shared)
        XCTAssertEqual(shared.map(\.group), [.workingOn, .howYouWork, .skills])
        XCTAssertEqual(shared.map(\.title), ["Projects and goals", "How you work", "Skills"])
        XCTAssertEqual(shared[0].rows.map(\.id), [41, 37, 45])
        XCTAssertEqual(shared[2].rows.map(\.id), [22, 18])
        let keptBack = UserModelGrouping.groups(page.keptBack)
        XCTAssertEqual(keptBack.map(\.group), [.howYouWork, .people, .struggles])
        XCTAssertEqual(keptBack.map(\.title), ["How you work", "People", "Where you got stuck"])
        XCTAssertTrue(UserModelGrouping.groups([]).isEmpty)
    }

    func testAGroupTheWindowHasNoTitleForComesLastUntitled() throws {
        let page = try UnderstandingFixture.modelPage()
        let unknown = ModelItem(id: 99, text: "Sam keeps a reading list.", kind: .other, group: .other,
                                basis: .seenOnce, daysSeen: 1, reasoning: "", updatedUs: 1, evidenceSessions: [])
        let groups = UserModelGrouping.groups([unknown] + page.shared)
        XCTAssertEqual(groups.last?.group, .other)
        XCTAssertNil(groups.last?.title)
    }

    func testThePageLoadsWithItsThreeLists() async throws {
        let (verdicts, _) = try inbox()
        let (model, _) = try await loaded(verdicts)
        XCTAssertEqual(model.state, .ready)
        XCTAssertFalse(model.modelIsOff)
        XCTAssertEqual(model.groups(.shared).flatMap(\.rows).count, 7)
        XCTAssertEqual(model.groups(.keptBack).flatMap(\.rows).map(\.id), [51, 27, 31])
        XCTAssertEqual(model.groups(.notSeenLately).flatMap(\.rows).map(\.id), [12])
    }

    func testRightIsWrittenAtOnceAndSaysYouConfirmedThis() async throws {
        let (verdicts, folder) = try inbox()
        let (model, _) = try await loaded(verdicts)
        let item = try XCTUnwrap(model.page?.shared.first { $0.id == 37 })
        XCTAssertEqual(item.basis, .seenOnDays)
        model.confirm(item)
        XCTAssertFalse(model.verdictFailed)
        XCTAssertEqual(model.page?.shared.first { $0.id == 37 }?.basis, .confirmed)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.count, 1)
        let body = try String(contentsOf: folder.appendingPathComponent(files[0]), encoding: .utf8)
        XCTAssertEqual(body, #"{"id":37,"verdict":"confirm"}"#)
    }

    func testForgetIsWrittenAtOnceAndLeavesForgottenWhereTheItemStood() async throws {
        let (verdicts, folder) = try inbox()
        let (model, _) = try await loaded(verdicts)
        let item = try XCTUnwrap(model.page?.shared.first { $0.id == 37 })
        model.forget(item)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasSuffix("-37.json"))
        XCTAssertNil(model.page?.shared.first { $0.id == 37 }, "it is not listed")
        let workingOn = try XCTUnwrap(model.groups(.shared).first)
        XCTAssertEqual(workingOn.rows, [.item(try XCTUnwrap(model.page?.shared.first { $0.id == 41 })),
                                        .forgotten(item),
                                        .item(try XCTUnwrap(model.page?.shared.first { $0.id == 45 }))])
        XCTAssertTrue(model.canUndo(item))
    }

    func testSeveralForgottenItemsStayInTheirOrder() async throws {
        let (verdicts, _) = try inbox()
        let (model, _) = try await loaded(verdicts)
        let items = try XCTUnwrap(model.page?.shared.filter { $0.group == .workingOn })
        XCTAssertEqual(items.map(\.id), [41, 37, 45])
        for id in [45, 41, 37] {
            model.forget(try XCTUnwrap(items.first { $0.id == id }))
        }
        XCTAssertEqual(model.groups(.shared).first?.rows.map(\.id), [41, 37, 45])
        XCTAssertEqual(model.groups(.shared).first?.rows, items.map(ModelItemRow.forgotten))
        XCTAssertEqual(model.groups(.shared).map(\.group), [.workingOn, .howYouWork, .skills],
                       "a group whose items were all forgotten keeps its place")
    }

    func testUndoBringsTheItemBackWhileTheAgentHasNotTakenIt() async throws {
        let (verdicts, folder) = try inbox()
        let (model, understanding) = try await loaded(verdicts)
        let item = try XCTUnwrap(model.page?.shared.first { $0.id == 45 })
        model.forget(item)
        XCTAssertTrue(model.undo(item))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        XCTAssertEqual(model.page?.shared.first { $0.id == 45 }, item)
        XCTAssertEqual(model.groups(.shared).first?.rows.map(\.id), [41, 37, 45])
        await assertEventually { await understanding.pageReads == 2 }

        model.forget(item)
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: folder.path).first)
        try FileManager.default.moveItem(at: folder.appendingPathComponent(file),
                                         to: folder.appendingPathComponent(file.replacingOccurrences(of: ".json", with: ".taken")))
        XCTAssertFalse(model.canUndo(item), "the agent took it: it is being applied")
        XCTAssertFalse(model.undo(item))
        XCTAssertNil(model.page?.shared.first { $0.id == 45 })
    }

    func testAVerdictThatCannotBeSavedChangesNothingAndSaysSo() async throws {
        let blocked = try TestFolders.make().appendingPathComponent("not-a-folder")
        try Data("file".utf8).write(to: blocked)
        let verdicts = VerdictInbox(directory: blocked.appendingPathComponent("understanding-feedback"), environment: [:])
        let (model, _) = try await loaded(verdicts)
        let item = try XCTUnwrap(model.page?.shared.first)
        model.forget(item)
        XCTAssertTrue(model.verdictFailed)
        XCTAssertEqual(model.page?.shared.first, item)
        XCTAssertFalse(model.groups(.shared).flatMap(\.rows).contains(.forgotten(item)))
        model.confirm(try XCTUnwrap(model.page?.shared.first { $0.id == 37 }))
        XCTAssertTrue(model.verdictFailed)
        XCTAssertEqual(model.page?.shared.first { $0.id == 37 }?.basis, .seenOnDays)
    }

    func testThePreviewsInboxWritesNothingButVerdictsStillShow() async throws {
        let verdicts = VerdictInbox(directory: nil, environment: [:])
        let (model, _) = try await loaded(verdicts)
        let item = try XCTUnwrap(model.page?.shared.first { $0.id == 22 })
        model.forget(item)
        XCTAssertFalse(model.verdictFailed)
        XCTAssertNil(model.page?.shared.first { $0.id == 22 })
        XCTAssertTrue(model.canUndo(item))
        XCTAssertTrue(model.undo(item))
    }

    func testNothingLearnedAndModelOffAreToldApart() async throws {
        let (verdicts, _) = try inbox()
        let full = try UnderstandingFixture.modelPage()
        var empty = full
        empty.shared = []
        empty.keptBack = []
        empty.notSeenLately = []
        let (learning, _) = try await loaded(verdicts, page: empty)
        XCTAssertEqual(learning.state, .nothingLearned)

        var off = empty
        off.modelStatus = ModelStatus(state: .unavailable, reason: "apple_intelligence_off", checkedUs: 1)
        let (needsModel, _) = try await loaded(verdicts, page: off)
        XCTAssertEqual(needsModel.state, .needsModel)

        var itemsButOff = full
        itemsButOff.modelStatus = off.modelStatus
        let (footer, _) = try await loaded(verdicts, page: itemsButOff)
        XCTAssertEqual(footer.state, .ready)
        XCTAssertTrue(footer.modelIsOff)
    }

    func testAPageThatCannotBeReadIsUnavailable() async throws {
        let (verdicts, _) = try inbox()
        let understanding = ScriptedUnderstanding()
        await understanding.failPage()
        let model = UserModelViewModel(understanding: understanding, verdicts: verdicts, deletions: MemoryDeletionSignal())
        XCTAssertEqual(model.state, .loading)
        await model.reload()
        XCTAssertEqual(model.state, .unavailable)
        XCTAssertTrue(model.groups(.shared).isEmpty)
    }

    func testADeleteClearsThePageAtOnceAndReadsItAgain() async throws {
        let signal = MemoryDeletionSignal()
        let (verdicts, _) = try inbox()
        let (model, understanding) = try await loaded(verdicts, deletions: signal)
        model.forget(try XCTUnwrap(model.page?.shared.first))
        signal.post()
        XCTAssertNil(model.page, "what was learned from deleted moments goes at once")
        XCTAssertTrue(model.groups(.shared).isEmpty)
        await assertEventually { await understanding.pageReads == 2 }
        await assertEventually { await MainActor.run { model.state == .ready } }
        XCTAssertFalse(model.groups(.shared).flatMap(\.rows).contains { if case .forgotten = $0 { true } else { false } })
    }
}

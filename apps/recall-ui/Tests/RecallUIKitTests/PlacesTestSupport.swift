import Foundation
import os
import XCTest
@testable import RecallUIKit

/// An `UnderstandingReader` a test scripts: an overview per day, one You page,
/// and an answer per question. It records what it was asked, and can hold the
/// next question until released or cancelled. No agent, no memory.
actor ScriptedUnderstanding: UnderstandingReader {
    private(set) var overviewDays: [UnderstandingDay] = []
    private(set) var pageReads = 0
    private(set) var questions: [String] = []
    private(set) var cancelledQuestions: [String] = []
    private var overviews: [String: Result<DayOverview, UnderstandingError>] = [:]
    private var page: Result<ModelPage, UnderstandingError> = .failure(.unavailable)
    private var answers: [String: Result<AskAnswer, UnderstandingError>] = [:]
    private var holdNext = false
    private var gate: CheckedContinuation<Bool, Never>?
    private var cancelPending = false

    var waiting: Bool { gate != nil }

    func setOverview(_ overview: DayOverview) { overviews[overview.date] = .success(overview) }
    func failOverview(_ date: String) { overviews[date] = .failure(.unavailable) }
    func setPage(_ page: ModelPage) { self.page = .success(page) }
    func failPage() { page = .failure(.unavailable) }
    func setAnswer(_ answer: AskAnswer, for question: String) { answers[question] = .success(answer) }
    func failAnswer(for question: String) { answers[question] = .failure(.unavailable) }
    /// The next question waits until `release()`, or until its task is cancelled.
    func holdNextQuestion() { holdNext = true }

    func release() {
        gate?.resume(returning: true)
        gate = nil
    }

    private func cancelWaiting() {
        if let gate {
            gate.resume(returning: false)
            self.gate = nil
        } else {
            cancelPending = true
        }
    }

    func overview(_ day: UnderstandingDay) async throws -> DayOverview {
        overviewDays.append(day)
        guard let result = overviews[day.dateLocal] else { throw UnderstandingError.unavailable }
        return try result.get()
    }

    func modelPage() async throws -> ModelPage {
        pageReads += 1
        return try page.get()
    }

    func ask(_ question: String, app: String?, title: String?, now: String?) async throws -> AskAnswer {
        questions.append(question)
        if holdNext {
            holdNext = false
            cancelPending = false
            let released = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    if cancelPending {
                        cancelPending = false
                        continuation.resume(returning: false)
                    } else {
                        gate = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiting() }
            }
            guard released else {
                cancelledQuestions.append(question)
                throw CancellationError()
            }
        }
        guard let answer = answers[question] else { throw UnderstandingError.unavailable }
        return try answer.get()
    }

    func invalidate() async {}
    func shutdown() async {}
}

/// ICU may put a narrow no-break space before AM and PM.
func spaced(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
}

/// Keeps a query in memory, never in the test runner's defaults.
final class MemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [String: Data]())
    func data(forKey key: String) -> Data? { values.withLock { $0[key] } }
    func set(_ data: Data?, forKey key: String) { values.withLock { $0[key] = data } }
    func removeObject(forKey key: String) { values.withLock { $0[key] = nil } }
}

/// The contract samples' day and clock (persona Sam, Monday 2026-10-12 in UTC−7).
enum SampleDay {
    static let now = PreviewUnderstandingReader.sampleNow
    static let calendar = PreviewUnderstandingReader.sampleCalendar
    static let date = "2026-10-12"
    static let locale = Locale(identifier: "en_US")
    static let timeZone = PreviewUnderstandingReader.sampleTimeZone

    /// A saved status written `age` seconds before the samples' clock.
    static func receipt(age: TimeInterval = 5, blocked: String? = nil, suppressed: String? = nil) -> CaptureHealthReceipt {
        CaptureHealthReceipt(schemaVersion: 1, updatedAt: now.addingTimeInterval(-age),
                             lastStoredFrameAt: now.addingTimeInterval(-age), storedFrameCount: 10,
                             storedScreenshotCount: 2, suppressionReason: suppressed, blockedReason: blocked)
    }
}

extension DayOverview {
    /// This overview with other blocks: the strip and the Right now card
    /// are left as they were.
    func with(blocks: [DayBlock]) -> DayOverview {
        DayOverview(version: version, date: date, isToday: isToday, nowUs: nowUs, tzOffsetSecs: tzOffsetSecs,
                    dayStartUs: dayStartUs, dayEndUs: dayEndUs, basis: basis, truncated: truncated,
                    modelStatus: modelStatus, now: now, strip: strip, blocks: blocks, gaps: gaps, kinds: kinds,
                    facts: facts, searches: searches, account: account, aiKnows: aiKnows)
    }

    func with(now: RightNow, aiKnows: AIKnows? = nil, isToday: Bool? = nil) -> DayOverview {
        DayOverview(version: version, date: date, isToday: isToday ?? self.isToday, nowUs: nowUs,
                    tzOffsetSecs: tzOffsetSecs, dayStartUs: dayStartUs, dayEndUs: dayEndUs, basis: basis,
                    truncated: truncated, modelStatus: modelStatus, now: now, strip: strip, blocks: blocks,
                    gaps: gaps, kinds: kinds, facts: facts, searches: searches, account: account,
                    aiKnows: aiKnows ?? self.aiKnows)
    }

    func with(strip: DayStrip?, truncated: Bool? = nil, isToday: Bool? = nil, nowUs: Int64? = nil) -> DayOverview {
        DayOverview(version: version, date: date, isToday: isToday ?? self.isToday, nowUs: nowUs ?? self.nowUs,
                    tzOffsetSecs: tzOffsetSecs, dayStartUs: dayStartUs, dayEndUs: dayEndUs, basis: basis,
                    truncated: truncated ?? self.truncated, modelStatus: modelStatus, now: now, strip: strip,
                    blocks: blocks, gaps: gaps, kinds: kinds, facts: facts, searches: searches, account: account,
                    aiKnows: aiKnows)
    }
}

extension DayBlock {
    /// A session with only the fields the window's own rules read.
    static func make(id: Int64, start: Int64? = nil, end: Int64, kind: WorkKind = .writing,
                     provisional: Bool = false, touchesPrevious: Bool = false, title: String = "Session",
                     openEventId: Int64? = nil) -> DayBlock {
        DayBlock(id: id, provisional: provisional, startUs: start ?? id, endUs: end, inProgress: false,
                 touchesPrevious: touchesPrevious, title: title, writtenBy: "measured", kind: kind,
                 kindLabel: kind.rawValue.capitalized, mixed: false, kinds: [], apps: [], windows: [],
                 sentences: [], searches: [], screenshotEventId: nil, openEventId: openEventId,
                 reopen: nil, noticed: nil)
    }
}

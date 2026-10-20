// SPDX-License-Identifier: Apache-2.0
//
// CalendarQuestion.swift — Ask's "When did I last meet with …?", answered
// from the calendar's titles and times (SPEC-DELTA 5).

import Foundation

/// A question Ask can answer from the calendar: "When did I last meet with
/// Mira?", "When was my last meeting about pricing?", "Last call with Teo".
/// Anything else is nil, and Ask answers it as it always has.
public struct CalendarQuestion: Equatable, Sendable {
    public enum Link: String, Equatable, Sendable {
        /// Who the meeting was with.
        case with
        /// What the meeting was about.
        case about
    }

    /// Who or what, as typed: "Mira", "the design team", "pricing".
    public let subject: String
    public let link: Link

    /// The longest subject Ask looks for, in words.
    static let mostWords = 6

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?.!")))
        // Straight apostrophes for the patterns: same length, so ranges hold.
        let plain = trimmed.replacingOccurrences(of: "\u{2019}", with: "'")
        let whole = NSRange(plain.startIndex..., in: plain)
        for (pattern, fixed) in Self.patterns {
            guard let match = pattern.firstMatch(in: plain, range: whole) else { continue }
            let subjectGroup = match.numberOfRanges - 1
            guard let subjectRange = Range(match.range(at: subjectGroup), in: trimmed) else { continue }
            var link = fixed
            if fixed == nil, let linkRange = Range(match.range(at: 1), in: plain) {
                link = Link(rawValue: plain[linkRange].lowercased())
            }
            let subject = String(trimmed[subjectRange]).trimmingCharacters(in: .whitespaces)
            let words = Self.words(subject)
            guard let link, !words.isEmpty, words.count <= Self.mostWords, subject.count <= 60 else { return nil }
            self.subject = subject
            self.link = link
            return
        }
        return nil
    }

    /// Each pattern, and its link when the question doesn't say "with" or
    /// "about". The subject is the last group.
    private static let patterns: [(NSRegularExpression, Link?)] = [
        (#"^when did i last meet(?: up)?(?: with)? (.+)$"#, .with),
        (#"^when did i meet(?: up)?(?: with)? (.+?) last$"#, .with),
        (#"^when(?: was| is|'s) the last time i met(?: up)?(?: with)? (.+)$"#, .with),
        (#"^when did i last have an? (?:meeting|call) (with|about) (.+)$"#, nil),
        (#"^when(?: was| is|'s) my (?:last|latest|most recent) (?:meeting|call) (with|about) (.+)$"#, nil),
        (#"^(?:my )?(?:last|latest|most recent) (?:meeting|call) (with|about) (.+)$"#, nil),
    ].map { pattern, link in
        // The patterns are fixed and tested, so making one can't fail.
        (try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), link)
    }

    /// The latest meeting before `now` whose title names the subject: every
    /// word of it, in any case and with or without accents. All-day events
    /// never count.
    public func lastMeeting(in meetings: [CalendarMeeting], before now: Date) -> CalendarMeeting? {
        let wanted = Self.words(subject).filter { !Self.minorWords.contains($0) }
        let needed = wanted.isEmpty ? Self.words(subject) : wanted
        return meetings
            .filter { !$0.isAllDay && $0.start <= now && $0.end > $0.start }
            .filter { meeting in
                let title = Set(Self.words(meeting.title).map(Self.stem))
                return needed.allSatisfy { title.contains(Self.stem($0)) }
            }
            .max { $0.start == $1.start ? $0.title > $1.title : $0.start < $1.start }
    }

    /// The answer, as one sentence, with the day and times as this Mac
    /// writes them; nil when no meeting matches, so Ask answers from memory
    /// as before instead of saying the calendar has nothing.
    public func answer(
        from meetings: [CalendarMeeting], now: Date, calendar: Calendar = .current, locale: Locale = .current
    ) -> String? {
        guard let meeting = lastMeeting(in: meetings, before: now) else { return nil }
        let when = Self.when(meeting, now: now, calendar: calendar, locale: locale)
        return CalendarCopy.lastMeeting("\(link.rawValue) \(spokenSubject)", when: when, title: meeting.title)
    }

    /// The subject as the answer says it back: "my manager" is "your manager".
    var spokenSubject: String {
        guard subject.lowercased().hasPrefix("my ") else { return subject }
        return "your " + subject.dropFirst(3)
    }

    /// "today, 2:00 – 2:30 PM", "on Tuesday, October 13, 2:00 – 2:30 PM".
    static func when(_ meeting: CalendarMeeting, now: Date, calendar: Calendar, locale: Locale) -> String {
        let times = DateIntervalFormatter()
        times.calendar = calendar
        times.locale = locale
        times.timeZone = calendar.timeZone
        times.dateStyle = .none
        times.timeStyle = .short
        let hours = times.string(from: meeting.start, to: meeting.end)
        if calendar.isDate(meeting.start, inSameDayAs: now) { return CalendarCopy.today(hours) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(meeting.start, inSameDayAs: yesterday) {
            return CalendarCopy.yesterday(hours)
        }
        let day = DateFormatter()
        day.calendar = calendar
        day.locale = locale
        day.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: meeting.start) == calendar.component(.year, from: now)
        day.setLocalizedDateFormatFromTemplate(sameYear ? "EEEEMMMMd" : "MMMMdyyyy")
        return CalendarCopy.onDay(day.string(from: meeting.start), hours)
    }

    /// Words, folded for matching: lowercase, without accents.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Words a subject can drop: "the design team" is about design and team.
    static let minorWords: Set<String> = ["the", "a", "an", "my", "our", "your", "and"]

    /// "investors" and "investor" match, as do "syncs" and "sync".
    static func stem(_ word: String) -> String {
        word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : word
    }
}

/// Answers Ask's calendar questions (SPEC-DELTA 5), from the titles and
/// times of the person's own calendar, read on this Mac. It reads only while
/// the person has the calendar on and macOS allows it, never while Demo
/// Memory is in use, and never asks macOS. The answer goes nowhere on its
/// own: it is shown in Ask, and reaches an AI tool only if the person sends
/// it there.
public struct CalendarAnswerer: Sendable {
    /// How far back "last" looks: a year.
    public static let lookBack: TimeInterval = 365 * 86_400

    private let store: any CalendarAccessStore
    private let setting: CalendarSetting
    private let now: @Sendable () -> Date
    private let demoMemory: @Sendable () -> Bool
    private let calendar: Calendar
    private let locale: Locale

    /// `demoMemory` says whether Demo Memory is in use: then the person's own
    /// calendar stays out of Ask, so a demo never shows a real meeting.
    public init(
        store: any CalendarAccessStore = EventKitCalendarAccess.shared,
        setting: CalendarSetting = CalendarSetting(),
        now: @escaping @Sendable () -> Date = { Date() },
        demoMemory: @escaping @Sendable () -> Bool = { DemoMemory.isActive },
        calendar: Calendar = .current,
        locale: Locale = .current
    ) {
        self.store = store
        self.setting = setting
        self.now = now
        self.demoMemory = demoMemory
        self.calendar = calendar
        self.locale = locale
    }

    /// The calendar's answer to `question`, or nil: when it isn't a calendar
    /// question, the calendar is off, macOS doesn't allow reading it, Demo
    /// Memory is in use, or no meeting matches. Ask then answers as before.
    public func answer(_ question: String) async -> String? {
        guard let asked = CalendarQuestion(question), setting.isOn, !demoMemory(),
              store.permission() == .fullAccess
        else {
            return nil
        }
        let now = now()
        let year = DateInterval(start: now.addingTimeInterval(-Self.lookBack), end: now)
        guard let meetings = try? store.meetings(in: year) else { return nil }
        return asked.answer(from: meetings, now: now, calendar: calendar, locale: locale)
    }
}

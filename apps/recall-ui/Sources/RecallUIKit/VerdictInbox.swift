import Foundation
import os

/// The person's verdicts on what Hippocampus understands about them: "Right"
/// and "Forget" (RULINGS I8, I9).
///
/// Each verdict is one file in the inbox the agent applies on its next cycle,
/// the same file the Ask panel writes: `{milliseconds}-{id}.json` holding
/// `{"id":…,"verdict":"confirm"}` or `"reject"`, in a folder only this user can
/// open. It is written at once. Undo removes the file while it is still
/// there; the agent renames a file to `.taken` before it applies it, and after
/// that Undo is no longer possible. Until the agent has applied a verdict, the
/// window lays it over every read itself (`pending()`), so a forgotten item
/// never comes back on screen, and a confirmed one already says so.
///
/// With the development key (`MCI_DEVELOPMENT_FILE_KEY=1`) nothing is written:
/// a development memory's ids name items the real inbox would apply to the
/// person's own memory. The window's own verdicts still apply on screen.
public final class VerdictInbox: Sendable {
    public enum Verdict: String, Sendable {
        /// "Right"
        case confirm
        /// "Forget"
        case reject
    }

    /// One verdict given in this window.
    public struct Given: Equatable, Sendable {
        public let id: Int64
        public let verdict: Verdict
        /// Nil when nothing was written: the development key, or a write that failed.
        public let file: URL?
    }

    public static let shared = VerdictInbox()

    /// The agent reads at most this much of a verdict file.
    static let maxFileBytes = 1_024
    /// A pending read looks at this many files at most.
    static let maxFiles = 512

    /// Where verdicts are written; nil when nothing may be written.
    public let directory: URL?
    private let now: @Sendable () -> Date
    private let given = OSAllocatedUnfairLock(initialState: [Int64: Verdict]())

    public init(
        directory: URL? = VerdictInbox.defaultDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = environment["MCI_DEVELOPMENT_FILE_KEY"] == "1" ? nil : directory
        self.now = now
    }

    /// `~/Library/Application Support/Hippocampus/understanding-feedback`, as
    /// the agent's `feedback::inbox_dir` names it.
    public static func defaultDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Library/Application Support/Hippocampus/understanding-feedback",
                                    isDirectory: true)
    }

    /// "Right" (`confirm`) or "Forget" (`reject`): written at once.
    @discardableResult
    public func give(_ verdict: Verdict, id: Int64) -> Given {
        given.withLock { $0[id] = verdict }
        guard let directory else { return Given(id: id, verdict: verdict, file: nil) }
        let file = try? Self.write(id: id, verdict: verdict, directory: directory, now: now())
        return Given(id: id, verdict: verdict, file: file)
    }

    /// Undo is offered only while the verdict's file is still there.
    public func canUndo(_ given: Given) -> Bool {
        guard let file = given.file else { return directory == nil }
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// Withdraw a verdict while its file is still there. False once the agent
    /// has taken it: it is being applied.
    @discardableResult
    public func undo(_ given: Given) -> Bool {
        if let file = given.file {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                return false
            }
        } else if directory != nil {
            return false
        }
        self.given.withLock { verdicts in
            if verdicts[given.id] == given.verdict { verdicts[given.id] = nil }
        }
        return true
    }

    /// Every verdict not yet applied: the inbox's files, given or taken, then
    /// the ones given in this window. The newest verdict on an id wins.
    public func pending() -> PendingVerdicts {
        var result = directory.map { Self.pending(directory: $0) } ?? PendingVerdicts()
        for (id, verdict) in given.withLock({ $0 }) {
            result.record(verdict, id: id)
        }
        return result
    }

    /// Write one verdict file the way the Ask panel does: a folder only this
    /// user can open, one atomic write.
    public static func write(id: Int64, verdict: Verdict, directory: URL, now: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let milliseconds = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        let file = directory.appendingPathComponent("\(milliseconds)-\(id).json", isDirectory: false)
        let body = #"{"id":\#(id),"verdict":"\#(verdict.rawValue)"}"#
        try Data(body.utf8).write(to: file, options: .atomic)
        return file
    }

    /// The verdicts in `directory` the agent has not finished applying, read
    /// in the order the agent applies them (by name, a taken file before a
    /// given one of the same name).
    public static func pending(directory: URL) -> PendingVerdicts {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return PendingVerdicts()
        }
        let files = names
            .compactMap { name -> (stem: String, given: Bool, name: String)? in
                if name.hasSuffix(".json") { return (String(name.dropLast(5)), true, name) }
                if name.hasSuffix(".taken") { return (String(name.dropLast(6)), false, name) }
                return nil
            }
            .sorted { ($0.stem, $0.given ? 1 : 0) < ($1.stem, $1.given ? 1 : 0) }
            .suffix(maxFiles)
        var result = PendingVerdicts()
        for file in files {
            let url = directory.appendingPathComponent(file.name, isDirectory: false)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: maxFileBytes), data.count < maxFileBytes,
                  let body = try? JSONDecoder().decode(VerdictFile.self, from: data),
                  let verdict = Verdict(rawValue: body.verdict)
            else { continue }
            result.record(verdict, id: body.id)
        }
        return result
    }

    private struct VerdictFile: Decodable {
        let id: Int64
        let verdict: String
    }
}

/// Verdicts the agent has not applied yet, laid over every read.
public struct PendingVerdicts: Equatable, Sendable {
    public private(set) var confirmed: Set<Int64> = []
    public private(set) var rejected: Set<Int64> = []

    public init() {}

    public var isEmpty: Bool { confirmed.isEmpty && rejected.isEmpty }

    mutating func record(_ verdict: VerdictInbox.Verdict, id: Int64) {
        switch verdict {
        case .confirm:
            rejected.remove(id)
            confirmed.insert(id)
        case .reject:
            confirmed.remove(id)
            rejected.insert(id)
        }
    }
}

public extension ModelPage {
    /// A forgotten item is hidden from every list; a confirmed one says "You confirmed this".
    func overlaying(_ verdicts: PendingVerdicts) -> ModelPage {
        guard !verdicts.isEmpty else { return self }
        var page = self
        page.shared = Self.overlay(verdicts, on: shared)
        page.keptBack = Self.overlay(verdicts, on: keptBack)
        page.notSeenLately = Self.overlay(verdicts, on: notSeenLately)
        return page
    }

    private static func overlay(_ verdicts: PendingVerdicts, on items: [ModelItem]) -> [ModelItem] {
        items.compactMap { item in
            guard !verdicts.rejected.contains(item.id) else { return nil }
            var item = item
            if verdicts.confirmed.contains(item.id) { item.basis = .confirmed }
            return item
        }
    }
}

public extension DayOverview {
    /// A forgotten item is not shown among what your AI already knows.
    func overlaying(_ verdicts: PendingVerdicts) -> DayOverview {
        guard !verdicts.rejected.isEmpty else { return self }
        var overview = self
        overview.aiKnows.aboutYou.removeAll { verdicts.rejected.contains($0.id) }
        return overview
    }
}

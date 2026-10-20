import Darwin
import Foundation

/// What a forget removes: moments by id and spans of time, never content.
public struct ForgetRequest: Equatable, Sendable, Codable {
    /// One span, in microseconds since the epoch, both ends kept.
    public struct Span: Equatable, Sendable, Codable {
        public let startUs: UInt64
        public let endUs: UInt64

        public init(startUs: UInt64, endUs: UInt64) {
            self.startUs = min(startUs, endUs)
            self.endUs = max(startUs, endUs)
        }
    }

    public var momentIds: [UInt64]
    public var spans: [Span]

    public init(momentIds: [UInt64] = [], spans: [Span] = []) {
        self.momentIds = momentIds.filter { $0 > 0 }
        self.spans = spans
    }

    /// Forget Recent: from `choice`'s start, fixed at the click, to the click.
    public static func recent(_ choice: ForgetRecentChoice, now: Date, calendar: Calendar) -> ForgetRequest {
        let start = choice.start(at: now, calendar: calendar)
        return ForgetRequest(spans: [Span(startUs: microseconds(start), endUs: microseconds(now))])
    }

    public var isEmpty: Bool { momentIds.isEmpty && spans.isEmpty }

    static func microseconds(_ date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970 * 1_000_000))
    }
}

/// The forget the window has promised and not finished: written before
/// anything is deleted, removed once it is done, and applied the next time
/// the window opens if the window ended in between (SPEC 3.11). Moment ids
/// and times only, never content. The file passes the writer lease's own
/// checks: a regular file owned by this user, mode 0600, never a symlink.
public struct PendingForgetStore: Sendable {
    /// What the file holds.
    struct Record: Codable, Equatable {
        var version = 1
        /// Which memory it is for, by a hash of its path, so a forget for one
        /// memory is never applied to another.
        var memory: String
        var request: ForgetRequest
        var createdUs: UInt64
    }

    /// The most the file may hold.
    static let maxBytes = 256 * 1_024

    /// `~/Library/Application Support/Hippocampus`, beside the verdict
    /// inbox the agent applies.
    public static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Hippocampus", isDirectory: true)
    }

    public static let fileName = "window-pending-forget.json"

    /// Nil writes nothing anywhere: the synthetic preview and renders.
    public let directory: URL?
    /// The memory this window reads, by path (hashed before it is written).
    public let memory: String

    public init(directory: URL?, memory: String) {
        self.directory = directory
        self.memory = memory
    }

    var file: URL? { directory?.appendingPathComponent(Self.fileName, isDirectory: false) }

    private var memoryKey: String { SidebarHides.memoryKey(memory) }

    /// Writes `request` atomically, mode 0600, in a folder only this user
    /// can open. Throws when it can't, and then nothing is deleted.
    public func save(_ request: ForgetRequest, now: Date = Date()) throws {
        guard let directory, let file else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let record = Record(memory: memoryKey, request: request, createdUs: ForgetRequest.microseconds(now))
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let temporary = directory.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let wrote = data.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        _ = fchmod(descriptor, 0o600)
        _ = fsync(descriptor)
        Darwin.close(descriptor)
        guard wrote == data.count, Darwin.rename(temporary.path, file.path) == 0 else {
            _ = Darwin.unlink(temporary.path)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// The pending forget for this memory, if the file is there and passes
    /// every check. A file that fails one is never read, and never applied.
    public func load() -> ForgetRequest? {
        guard let file else { return nil }
        var info = stat()
        guard lstat(file.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0,
              info.st_size <= Self.maxBytes
        else { return nil }
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var data = Data(count: Int(info.st_size))
        let read = data.withUnsafeMutableBytes { buffer in
            Darwin.read(descriptor, buffer.baseAddress, buffer.count)
        }
        guard read == Int(info.st_size),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1, record.memory == memoryKey
        else { return nil }
        return record.request
    }

    /// Removes the file once the forget is done or undone.
    public func remove() {
        guard let file else { return }
        _ = Darwin.unlink(file.path)
    }
}

/// Forgetting, from every page (SPEC 3.11): the hold while remembering, the
/// pending file, the deletes, Undo, and a forget a crash left.
///
/// While Hippocampus is remembering, the agent holds the memory's only
/// writer lease, so the window asks the app, over the private pipe, for a
/// hold: the app stops remembering the way Pause does without touching the
/// person's own pause, answers once the lease is free, and on `release`
/// starts remembering again only if it was on. Paused or off, the app has
/// nothing to stop and answers at once.
@MainActor
public final class ForgetCoordinator: ObservableObject {
    public enum Outcome: Equatable, Sendable {
        /// Deleted. `moments` is how many the deletes reported.
        case forgotten(moments: UInt64)
        /// Nothing was deleted; it's still saved.
        case failed
        /// A window opened by hand while Hippocampus runs: open it first.
        case needsApp
        /// Nothing here can delete (the synthetic preview, a memory that
        /// can't be opened).
        case unavailable
    }

    /// One forget waiting out its Undo note.
    public struct Undoable: Equatable, Sendable {
        public let id: UUID
        public let request: ForgetRequest
        public let count: Int
    }

    /// What the footer says while a forget runs.
    @Published public private(set) var phase: ForgetPhase?
    /// The forget whose Undo note is up, if any.
    @Published public private(set) var undoable: Undoable?

    /// How long the Undo note waits before the delete goes ahead.
    public static let undoWindow: Duration = .seconds(5)
    /// How long the app has to free the writer lease.
    public static let holdWait: Duration = .seconds(12)

    private let mutator: (any PrivacyMutator)?
    private let channel: (any WindowChannelSending)?
    private let store: PendingForgetStore
    private let appRunning: @Sendable () -> Bool
    private let deletions: MemoryDeletionSignal
    private let now: @Sendable () -> Date
    private var undoTask: Task<Void, Never>?

    /// `channel` is the private pipe; nil for a window opened by hand,
    /// which deletes directly only while Hippocampus isn't running.
    public init(
        mutator: (any PrivacyMutator)?,
        channel: (any WindowChannelSending)?,
        store: PendingForgetStore,
        appRunning: @escaping @Sendable () -> Bool,
        deletions: MemoryDeletionSignal = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.mutator = mutator
        self.channel = channel
        self.store = store
        self.appRunning = appRunning
        self.deletions = deletions
        self.now = now
    }

    // MARK: Forgetting now

    /// Forgets `request` now: written down, held, deleted, released. For
    /// anything a confirmation asked about first (a session, an hour, a
    /// page, recent time).
    @discardableResult
    public func forget(_ request: ForgetRequest) async -> Outcome {
        guard !request.isEmpty else { return .forgotten(moments: 0) }
        await finishUndoable()
        guard mutator != nil else { return .unavailable }
        if channel == nil, appRunning() { return .needsApp }
        do {
            try store.save(request, now: now())
        } catch {
            return .failed
        }
        return await apply(request, phase: .forgetting)
    }

    // MARK: Forgetting after the Undo note

    /// Forgets `request` once its Undo note has closed: the note says
    /// "Forgot 1 moment." with Undo, and ⌘Z undoes it while it shows. The
    /// promise is written at once, so a window that ends in those seconds
    /// still forgets on its next open. A newer forget, or the window
    /// closing, finishes this one first.
    @discardableResult
    public func forgetAfterUndo(_ request: ForgetRequest, count: Int) async -> Outcome? {
        guard !request.isEmpty else { return nil }
        await finishUndoable()
        guard mutator != nil else { return .unavailable }
        if channel == nil, appRunning() { return .needsApp }
        do {
            try store.save(request, now: now())
        } catch {
            return .failed
        }
        let pending = Undoable(id: UUID(), request: request, count: count)
        undoable = pending
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            await self?.finish(pending.id)
        }
        return nil
    }

    /// Undo: the note's button, or ⌘Z while it shows. Nothing was deleted.
    @discardableResult
    public func undo() -> Bool {
        guard undoable != nil else { return false }
        undoTask?.cancel()
        undoTask = nil
        undoable = nil
        store.remove()
        return true
    }

    /// The forget waiting out its note goes ahead now: a newer forget, or
    /// the window closing.
    public func finishUndoable() async {
        guard let pending = undoable else { return }
        await finish(pending.id)
    }

    @discardableResult
    private func finish(_ id: UUID) async -> Outcome? {
        guard let pending = undoable, pending.id == id else { return nil }
        undoTask?.cancel()
        undoTask = nil
        undoable = nil
        return await apply(pending.request, phase: .forgetting)
    }

    // MARK: A forget a crash left

    /// The window opened and found a forget it promised and didn't finish:
    /// "Finishing a forget…" until it's done. True when one was applied.
    @discardableResult
    public func finishLeftover() async -> Outcome? {
        guard mutator != nil, let request = store.load() else { return nil }
        if channel == nil, appRunning() { return .needsApp }
        return await apply(request, phase: .finishing)
    }

    // MARK: The hold, the deletes and the release

    private func apply(_ request: ForgetRequest, phase: ForgetPhase) async -> Outcome {
        guard let mutator else { return .unavailable }
        self.phase = phase
        defer { self.phase = nil }
        var held = false
        if let channel {
            held = await channel.send(WindowChannelRequest(op: .hold), timeout: Self.holdWait)
            guard held else {
                // The app didn't answer, or the lease stayed busy: nothing
                // is deleted, and the promise goes, so the rows come back.
                store.remove()
                return .failed
            }
        }
        var deleted: UInt64 = 0
        var failed = false
        for id in request.momentIds {
            do {
                deleted += try await mutator.deleteEvent(id: id).eventsDeleted
            } catch {
                failed = true
            }
        }
        for span in request.spans {
            do {
                deleted += try await mutator.deleteEventsInRange(startTsUs: span.startUs, endTsUs: span.endUs)
                    .eventsDeleted
            } catch {
                failed = true
            }
        }
        store.remove()
        if held, let channel {
            _ = await channel.send(WindowChannelRequest(op: .release), timeout: .seconds(5))
        }
        if deleted > 0 || !failed {
            deletions.post()
        }
        return failed && deleted == 0 ? .failed : .forgotten(moments: deleted)
    }
}

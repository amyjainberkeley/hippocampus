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

/// The forgets the window has promised and not finished: each written
/// before anything is deleted, removed once it is done, and applied the next
/// time the window opens if the window ended in between (SPEC 3.11). Moment
/// ids and times only, never content. The file passes the writer lease's own
/// checks: a regular file owned by this user, mode 0600, never a symlink.
///
/// It is a list, so two forgets close together each keep their own promise:
/// one finishing removes only its own entry, never the other's.
public struct PendingForgetStore: Sendable {
    /// One promised forget.
    public struct Entry: Codable, Equatable, Sendable {
        public let id: UUID
        /// Which memory it is for, by a hash of its path, so a forget for
        /// one memory is never applied to another.
        let memory: String
        public var request: ForgetRequest
        public let createdUs: UInt64
    }

    /// What the file holds: every forget promised on this Mac and not yet
    /// finished, for any memory, oldest first.
    struct List: Codable, Equatable {
        var version = 2
        var forgets: [Entry]
    }

    /// The one forget the first build wrote. Still read, so a forget it left
    /// behind is finished, not lost.
    struct Single: Codable, Equatable {
        var version = 1
        var memory: String
        var request: ForgetRequest
        var createdUs: UInt64
    }

    /// The id a forget in the first form goes by.
    static let singleID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

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

    /// This memory's promised forgets, oldest first. A file that fails a
    /// check is never read, and none of it is applied.
    public func entries() -> [Entry] {
        (readAll() ?? []).filter { $0.memory == memoryKey }
    }

    /// Promises `request`: added to the file before anything is deleted.
    /// Throws when it can't be written, and then nothing is deleted.
    @discardableResult
    public func save(_ request: ForgetRequest, now: Date = Date()) throws -> UUID {
        let entry = Entry(id: UUID(), memory: memoryKey, request: request, createdUs: ForgetRequest.microseconds(now))
        guard directory != nil else { return entry.id }
        try write((readAll() ?? []) + [entry])
        return entry.id
    }

    /// What is still promised of `id` once part of it is done; when nothing
    /// is left, its entry goes. Every other entry stays as it is.
    public func update(_ id: UUID, to remaining: ForgetRequest) {
        guard var all = readAll(),
              let index = all.firstIndex(where: { $0.id == id && $0.memory == memoryKey })
        else { return }
        if remaining.isEmpty {
            all.remove(at: index)
        } else {
            all[index].request = remaining
        }
        try? write(all)
    }

    /// `id` is done or undone: its own entry goes, and only its own.
    public func remove(_ id: UUID) {
        update(id, to: ForgetRequest())
    }

    /// Everything promised for this memory, as one request: every entry's
    /// moments and spans. Nil when nothing is.
    public func load() -> ForgetRequest? {
        let mine = entries()
        guard !mine.isEmpty else { return nil }
        var ids: [UInt64] = []
        var seen = Set<UInt64>()
        for id in mine.flatMap(\.request.momentIds) where seen.insert(id).inserted {
            ids.append(id)
        }
        return ForgetRequest(momentIds: ids, spans: mine.flatMap(\.request.spans))
    }

    /// Every forget promised for this memory goes; other memories' stay.
    public func remove() {
        guard let all = readAll() else { return }
        try? write(all.filter { $0.memory != memoryKey })
    }

    // MARK: The file

    /// Every entry, for any memory; nil when there is no file or it fails a
    /// check: not a regular file of this user's, readable by others, too
    /// large, or not one of the two forms.
    func readAll() -> [Entry]? {
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
        guard read == Int(info.st_size) else { return nil }
        let decoder = JSONDecoder()
        if let list = try? decoder.decode(List.self, from: data), list.version == 2 {
            return list.forgets
        }
        if let single = try? decoder.decode(Single.self, from: data), single.version == 1 {
            return [Entry(id: Self.singleID, memory: single.memory, request: single.request,
                          createdUs: single.createdUs)]
        }
        return nil
    }

    /// Writes `entries` atomically, mode 0600, in a folder only this user
    /// can open; with none left, the file goes.
    func write(_ entries: [Entry]) throws {
        guard let directory, let file else { return }
        guard !entries.isEmpty else {
            _ = Darwin.unlink(file.path)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(List(forgets: entries))
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
///
/// Forgets go one after another through one queue: a forget that comes
/// while another is under way waits for it, inside the same hold, instead of
/// asking the app for a second one (the app allows one at a time).
@MainActor
public final class ForgetCoordinator: ObservableObject {
    public enum Outcome: Equatable, Sendable {
        /// Deleted. `moments` is how many the deletes reported.
        case forgotten(moments: UInt64)
        /// Some of it was deleted (`moments`) and the rest is still saved:
        /// its promise stays for the rest, so Try Again, or the next time
        /// the window opens, finishes it.
        case partlyForgotten(moments: UInt64)
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
    /// While the deletes run, how often the window asks the app to keep its
    /// hold, which otherwise ends on its own (SPEC 3.11).
    public static let renewEvery: Duration = .seconds(10)
    /// How long a renewal waits for its answer; it is never awaited by the
    /// forget, and a refusal changes nothing.
    public static let renewWait: Duration = .seconds(2)
    /// The most moments one delete call takes (the FFI's
    /// `MAX_DELETE_EVENT_IDS`): a forget of more goes in a few calls.
    public static let idsPerDelete = 10_000

    /// One forget on its way to the store: its promise's id in the pending
    /// file, what it removes, and what the footer says while it runs.
    private struct Job {
        let id: UUID
        let request: ForgetRequest
        let phase: ForgetPhase
    }

    private let mutator: (any PrivacyMutator)?
    private let channel: (any WindowChannelSending)?
    private let store: PendingForgetStore
    private let appRunning: @Sendable () -> Bool
    private let deletions: MemoryDeletionSignal
    private let now: @Sendable () -> Date
    private let renewal: Duration
    private var undoTask: Task<Void, Never>?
    /// Forgets waiting for the store, oldest first.
    private var queue: [Job] = []
    /// Every forget queued and not yet answered, by its promise's id.
    private var inFlight: [UUID: ForgetRequest] = [:]
    private var worker: Task<Void, Never>?
    /// Who waits for each forget's outcome, by its promise's id.
    private var waiting: [UUID: [CheckedContinuation<Outcome, Never>]] = [:]

    /// `channel` is the private pipe; nil for a window opened by hand,
    /// which deletes directly only while Hippocampus isn't running.
    public init(
        mutator: (any PrivacyMutator)?,
        channel: (any WindowChannelSending)?,
        store: PendingForgetStore,
        appRunning: @escaping @Sendable () -> Bool,
        deletions: MemoryDeletionSignal = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
        renewEvery: Duration = ForgetCoordinator.renewEvery
    ) {
        self.mutator = mutator
        self.channel = channel
        self.store = store
        self.appRunning = appRunning
        self.deletions = deletions
        self.now = now
        renewal = renewEvery
    }

    // MARK: Forgetting now

    /// Forgets `request` now: written down, held, deleted, released. For
    /// anything a confirmation asked about first (a session, an hour, a
    /// page, recent time). A forget waiting out its Undo note goes first.
    @discardableResult
    public func forget(_ request: ForgetRequest) async -> Outcome {
        guard !request.isEmpty else { return .forgotten(moments: 0) }
        finishUndoableNow()
        guard mutator != nil else { return .unavailable }
        if channel == nil, appRunning() { return .needsApp }
        let id: UUID
        do {
            id = try store.save(request, now: now())
        } catch {
            return .failed
        }
        return await run(Job(id: id, request: request, phase: .forgetting))
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
        let earlier = finishUndoableNow()
        guard mutator != nil else { return await settle(earlier, then: .unavailable) }
        if channel == nil, appRunning() { return await settle(earlier, then: .needsApp) }
        let id: UUID
        do {
            id = try store.save(request, now: now())
        } catch {
            return await settle(earlier, then: .failed)
        }
        let pending = Undoable(id: id, request: request, count: count)
        undoable = pending
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            await self?.finish(pending.id)
        }
        return await settle(earlier, then: nil)
    }

    /// Undo: the note's button, or ⌘Z while it shows. Nothing was deleted.
    @discardableResult
    public func undo() -> Bool {
        guard let pending = undoable else { return false }
        undoTask?.cancel()
        undoTask = nil
        undoable = nil
        store.remove(pending.id)
        return true
    }

    /// The forget waiting out its note goes ahead now, and this returns once
    /// it is done: a newer forget, or the window closing.
    public func finishUndoable() async {
        guard let id = finishUndoableNow() else { return }
        _ = await outcome(of: id)
    }

    /// The note's time is up: the forget goes ahead, if it is still the one
    /// waiting (Undo, or a newer forget, may have come first).
    private func finish(_ id: UUID) async {
        guard undoable?.id == id else { return }
        finishUndoableNow()
        _ = await outcome(of: id)
    }

    /// Moves the forget waiting out its note into the queue; its id.
    @discardableResult
    private func finishUndoableNow() -> UUID? {
        guard let pending = undoable else { return nil }
        undoTask?.cancel()
        undoTask = nil
        undoable = nil
        enqueue(Job(id: pending.id, request: pending.request, phase: .forgetting))
        return pending.id
    }

    /// Waits for the earlier forget a newer one moved ahead, then answers
    /// `outcome`: the newer one's note shows at once, and its caller hears
    /// back once the earlier one is done.
    private func settle(_ earlier: UUID?, then outcome: Outcome?) async -> Outcome? {
        if let earlier { _ = await self.outcome(of: earlier) }
        return outcome
    }

    // MARK: A forget a crash left

    /// The window opened and found forgets it promised and didn't finish:
    /// "Finishing a forget…" until they're done. Nil when there were none.
    @discardableResult
    public func finishLeftover() async -> Outcome? {
        guard mutator != nil else { return nil }
        let known = Set(inFlight.keys).union([undoable?.id].compactMap { $0 })
        let leftovers = store.entries().filter { !known.contains($0.id) && !$0.request.isEmpty }
        guard !leftovers.isEmpty else { return nil }
        if channel == nil, appRunning() { return .needsApp }
        var outcomes: [Outcome] = []
        for entry in leftovers {
            outcomes.append(await run(Job(id: entry.id, request: entry.request, phase: .finishing)))
        }
        return Self.together(outcomes)
    }

    /// Several forgets' outcomes as one: every moment they deleted; partly
    /// when one didn't all go, `failed` when none of them deleted anything.
    private static func together(_ outcomes: [Outcome]) -> Outcome {
        var moments: UInt64 = 0
        var progressed = false
        var failed = false
        for outcome in outcomes {
            switch outcome {
            case let .forgotten(count):
                moments += count
                progressed = true
            case let .partlyForgotten(count):
                moments += count
                progressed = true
                failed = true
            case .failed, .needsApp, .unavailable:
                failed = true
            }
        }
        guard failed else { return .forgotten(moments: moments) }
        return progressed ? .partlyForgotten(moments: moments) : .failed
    }

    // MARK: The queue, the hold, the deletes and the release

    /// Runs `job` through the queue and answers its outcome.
    private func run(_ job: Job) async -> Outcome {
        await withCheckedContinuation { continuation in
            waiting[job.id, default: []].append(continuation)
            enqueue(job)
        }
    }

    /// The outcome of a forget already in the queue. Asked for at once
    /// after it is queued, before anything can finish it.
    private func outcome(of id: UUID) async -> Outcome {
        guard inFlight[id] != nil else { return .failed }
        return await withCheckedContinuation { continuation in
            waiting[id, default: []].append(continuation)
        }
    }

    private func enqueue(_ job: Job) {
        queue.append(job)
        inFlight[job.id] = job.request
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    private func complete(_ job: Job, _ outcome: Outcome) {
        inFlight[job.id] = nil
        for continuation in waiting.removeValue(forKey: job.id) ?? [] {
            continuation.resume(returning: outcome)
        }
    }

    /// One hold for everything queued, and for what comes while it lasts:
    /// each forget's deletes and its promise, then the release. Each forget
    /// is answered once the hold it ran in is released.
    private func drain() async {
        while let first = queue.first {
            guard let mutator else {
                let jobs = queue
                queue.removeAll()
                for job in jobs { complete(job, .unavailable) }
                break
            }
            phase = first.phase
            var held = false
            if let channel {
                held = await channel.send(WindowChannelRequest(op: .hold), timeout: Self.holdWait)
                guard held else {
                    // The app didn't answer, or the lease stayed busy:
                    // nothing is deleted, and the promises go, so the rows
                    // come back.
                    let jobs = queue
                    queue.removeAll()
                    if queue.isEmpty { phase = nil }
                    for job in jobs {
                        store.remove(job.id)
                        complete(job, .failed)
                    }
                    continue
                }
            }
            // The hold ends on its own unless the window asks for more while
            // its deletes run.
            let renewing = held ? renewals() : nil
            var done: [(Job, Outcome)] = []
            while !queue.isEmpty {
                let job = queue.removeFirst()
                phase = job.phase
                let deletion = await delete(job.request, with: mutator)
                done.append((job, conclude(job, deletion)))
            }
            renewing?.cancel()
            if held, let channel {
                _ = await channel.send(WindowChannelRequest(op: .release), timeout: .seconds(5))
            }
            if queue.isEmpty { phase = nil }
            for (job, outcome) in done { complete(job, outcome) }
        }
        phase = nil
        worker = nil
    }

    /// What a forget's deletes did: how many moments went, what is still
    /// saved of it, and whether any part went at all.
    private struct Deletion {
        var deleted: UInt64 = 0
        var remaining: ForgetRequest
        var progressed = false
    }

    /// The picked moments in one call (one transaction, one writer lease,
    /// one integrity check and one cleanup for the whole forget), then each
    /// span. What failed is kept in `remaining`, never dropped.
    private func delete(_ request: ForgetRequest, with mutator: any PrivacyMutator) async -> Deletion {
        var result = Deletion(remaining: request)
        var gone = Set<UInt64>()
        for ids in Self.chunks(of: request.momentIds) {
            do {
                result.deleted += try await mutator.deleteEvents(ids: ids).eventsDeleted
                gone.formUnion(ids)
                result.progressed = true
            } catch let partial as PartialDeletion {
                result.deleted += partial.result.eventsDeleted
                gone.formUnion(partial.deleted)
                result.progressed = true
            } catch {
                // Still saved: kept in `remaining`.
            }
        }
        var spansLeft: [ForgetRequest.Span] = []
        for span in request.spans {
            do {
                result.deleted += try await mutator.deleteEventsInRange(startTsUs: span.startUs, endTsUs: span.endUs)
                    .eventsDeleted
                result.progressed = true
            } catch {
                spansLeft.append(span)
            }
        }
        result.remaining = ForgetRequest(momentIds: request.momentIds.filter { !gone.contains($0) }, spans: spansLeft)
        if result.progressed {
            deletions.post()
        }
        return result
    }

    /// What becomes of a forget's promise once its deletes ran: done, it
    /// goes; partly done, it stays for what is still saved, never for what
    /// went; not done at all, it goes, and the rows come back with the
    /// note's Try Again.
    private func conclude(_ job: Job, _ deletion: Deletion) -> Outcome {
        if deletion.remaining.isEmpty {
            store.remove(job.id)
            return .forgotten(moments: deletion.deleted)
        }
        if deletion.progressed {
            store.update(job.id, to: deletion.remaining)
            return .partlyForgotten(moments: deletion.deleted)
        }
        store.remove(job.id)
        return .failed
    }

    /// `renew` every `renewal` until cancelled, fire-and-forget: an app that
    /// doesn't answer, or doesn't know the op, never fails the forget.
    private func renewals() -> Task<Void, Never>? {
        guard let channel else { return nil }
        let every = renewal
        return Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled else { return }
                _ = await channel.send(WindowChannelRequest(op: .renew), timeout: Self.renewWait)
            }
        }
    }

    /// The ids in calls of at most `idsPerDelete`, in order.
    static func chunks(of ids: [UInt64]) -> [[UInt64]] {
        stride(from: 0, to: ids.count, by: idsPerDelete).map { start in
            Array(ids[start..<min(start + idsPerDelete, ids.count)])
        }
    }
}

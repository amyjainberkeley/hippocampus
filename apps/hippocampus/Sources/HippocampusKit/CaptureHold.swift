// SPDX-License-Identifier: Apache-2.0
//
// CaptureHold.swift — remembering held still for a forget (SPEC 3.11).
//
// While Hippocampus remembers, the agent holds the memory's only writer
// lease, and every delete from the window fails. For a forget the window
// asks, over its private pipe, for a hold: the app notes whether remembering
// was on, stops the capture helper and the agent the way Pause does,
// **without** touching the person's saved pause, and answers once the
// writer lease is free (at most 10 s). On `release` it starts remembering
// again only if it was on before the hold and the person hasn't paused or
// turned it off in the meantime. A hold also ends when the window's process
// does, and on its own 30 seconds after the lease was free, or after the
// window last said it is still deleting (`renew`), and never lasts more than
// 10 minutes.

import Foundation

/// What the hold stops and starts again: the supervisor in the app.
@MainActor
public protocol CaptureHolding: AnyObject {
    /// Remembering runs now: the agent holds the writer lease.
    var isRememberingForHold: Bool { get }
    /// Stops the helper and the agent as Pause does, without the person's
    /// pause. Returns once the writer lease is free.
    func stopForHold() async throws
    /// Remembering again after a hold, if the person hasn't paused or turned
    /// it off since.
    func restartAfterHold() async throws
    /// The hold is on: the status reads "Forgetting…".
    func holdChanged(_ holding: Bool)
}

@MainActor
public final class CaptureHold {
    /// How long the window may wait for the writer lease.
    public nonisolated static let stopWait: Duration = .seconds(10)
    /// A hold ends on its own this long after the writer lease is free, or
    /// after the window last renewed it. The stop before it has its own
    /// bound, `stopWait`, so a slow stop never eats into the window's time.
    public nonisolated static let limit: Duration = .seconds(30)
    /// The longest a hold lasts, however often it is renewed: a window that
    /// hangs while it still renews never keeps remembering still for long.
    public nonisolated static let longest: Duration = .seconds(10 * 60)

    private let target: any CaptureHolding
    private let sleep: @Sendable (Duration) async throws -> Void
    /// The hold now, with whether remembering was on when it began.
    public private(set) var active: (wasOn: Bool, id: UUID)?
    private var expiry: Task<Void, Never>?
    private var cap: Task<Void, Never>?

    public init(target: any CaptureHolding,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.target = target
        self.sleep = sleep
    }

    public var isHolding: Bool { active != nil }

    /// Begins a hold. True once nothing holds the writer lease: at once when
    /// remembering wasn't on, after the stop when it was. False when it
    /// couldn't be had in time; then nothing is held.
    public func hold() async -> Bool {
        guard active == nil else { return false }
        let wasOn = target.isRememberingForHold
        let id = UUID()
        active = (wasOn, id)
        target.holdChanged(true)
        cap = Task { [weak self, sleep] in
            try? await sleep(Self.longest)
            guard !Task.isCancelled else { return }
            await self?.end(id)
        }
        if wasOn {
            let stopped = await stop(within: Self.stopWait)
            guard stopped else {
                await end(id)
                return false
            }
        }
        guard active?.id == id else { return false }
        // The window's 30 seconds start now, with the lease free.
        armExpiry(id)
        return true
    }

    /// The window is still deleting: the hold now ends `limit` from now,
    /// unless it is released first, and never after `longest`. False when
    /// nothing is held.
    @discardableResult
    public func renew() -> Bool {
        guard let id = active?.id else { return false }
        armExpiry(id)
        return true
    }

    /// The window is done: remembering comes back if it was on.
    public func release() async {
        guard let id = active?.id else { return }
        await end(id)
    }

    /// The window's process ended mid-hold: the same as a release.
    public func windowEnded() async {
        await release()
    }

    private func armExpiry(_ id: UUID) {
        expiry?.cancel()
        expiry = Task { [weak self, sleep] in
            try? await sleep(Self.limit)
            guard !Task.isCancelled else { return }
            await self?.end(id)
        }
    }

    private func end(_ id: UUID) async {
        guard let current = active, current.id == id else { return }
        active = nil
        expiry?.cancel()
        expiry = nil
        cap?.cancel()
        cap = nil
        target.holdChanged(false)
        if current.wasOn {
            try? await target.restartAfterHold()
        }
    }

    /// The stop, or false once `limit` has passed: whichever comes first.
    /// A stop still under way then goes on, and the release that follows
    /// waits for it.
    private func stop(within limit: Duration) async -> Bool {
        let target = self.target
        let sleep = self.sleep
        let once = Once()
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let stopped: Bool
                do {
                    try await target.stopForHold()
                    stopped = true
                } catch {
                    stopped = false
                }
                if once.claim() { continuation.resume(returning: stopped) }
            }
            Task {
                try? await sleep(limit)
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }
}

/// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

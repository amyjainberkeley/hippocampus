// SPDX-License-Identifier: TBD-private
//
// TCCHelperStderrTail — cycle 8.47 PR #80 follow-up.
//
// The MCICaptureHelper (a background XPC-style child spawned by
// ProcessSupervisor) emits `helper_health tcc_revoked=<surface>` and
// `helper_health tcc_restored=<surface>` breadcrumbs on stderr when
// the OS-side TCC verdict for a surface (screen recording,
// accessibility, full-disk-access, automation) flips. See
// `MCICaptureHelperKit/TCCHelperHealth.line(...)` for the emitter.
//
// PR #80 shipped the detection (TCCStatusMonitor), the notifier
// (TCCRevokedNotifier), and the menu-bar bridge signatures
// (MenuBarStatus.derive(tccRevokedSurface:)) but did NOT wire the
// helper's stderr into the app. This file closes that gap:
//
//   helper stderr → helper.stderr.log → this tail → TCCRevokedNotifier
//                                                 → ProcessSupervisor.tccRevokedSurface
//                                                 → MenuBarStatus.derive
//
// Why tail the log file rather than intercept the pipe: the supervisor
// hands the helper's stderr directly to a LogRotator FileHandle so
// helper output never blocks on backpressure from the app's own reader
// (a mid-run stall in the reader would wedge the helper on a full
// stderr buffer). Tailing the log file is decoupled from the write
// path — the OS handles it — and matches the sentinel-watcher pattern
// already used elsewhere in AppDelegate. It also survives helper
// crash+respawn: the file persists, the log-rotator appends, we keep
// reading.
//
// Protected-set / privacy audit:
//   (a) Reads only `helper_health tcc_<state>=<surface>` breadcrumbs
//       the helper already emits; adds no new capability, no new
//       polling, no new probe. The TCC probe cadence in the helper
//       (0.5 Hz) is unchanged.
//   (b) The lines carry only the surface name (an enum rawValue) — no
//       file path, no bundle id, no window title, no captured pixel.
//       Privacy invariant unchanged.
//   (c) All work is app-local; nothing leaves the process.

import Foundation
import os

// MARK: - Event

/// One parsed helper-health TCC breadcrumb.
public enum TCCHelperHealthEvent: Sendable, Equatable {
    case revoked(TCCRevokedReason)
    case restored(TCCRevokedReason)
}

// MARK: - Pure parser

/// Pure string parser for the helper's stderr breadcrumbs. Unit-tested
/// without any I/O. The tail actor (below) is the OS-touching layer
/// that feeds byte chunks through this function.
public enum TCCHelperStderrParser {

    /// Prefix the helper writes on every breadcrumb line. Pinned by
    /// `TCCHelperHealthTests.testHealthLineForRevoked_hasFrozenFormat`
    /// on the helper side.
    static let helperPrefix = "mci-capture-helper: helper_health "

    /// Parse one line of helper stderr into a `TCCHelperHealthEvent`,
    /// or nil if the line is not a TCC breadcrumb we recognise.
    ///
    /// Robust against:
    ///   - Non-helper log lines (returns nil silently — the log file
    ///     also carries `os_log` noise from the helper's other
    ///     subsystems; we ignore everything that doesn't match the
    ///     `helper_health tcc_<state>=<surface>` schema).
    ///   - Unknown surface identifiers (returns nil — a future helper
    ///     that adds a new surface without a corresponding app update
    ///     is silently ignored; the helper's own pause still holds).
    ///   - Whitespace / trailing newline (trimmed).
    ///   - Leading log-timestamp prefixes some rotators add. We scan
    ///     for the `helper_health ` marker anywhere in the line, so
    ///     `[2026-07-13T...] mci-capture-helper: helper_health tcc_revoked=accessibility`
    ///     also parses.
    public static func parseLine(_ raw: String) -> TCCHelperHealthEvent? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        // Find the `helper_health ` marker. Anchoring on this rather
        // than the full prefix lets us tolerate log-line decoration
        // (timestamps, PID tags) that upstream tools might inject.
        guard let markerRange = line.range(of: "helper_health ") else {
            return nil
        }

        let payload = line[markerRange.upperBound...]
        // Payload shape: `tcc_revoked=<surface>` or
        // `tcc_restored=<surface>`. Split on the first `=`.
        guard let eqIndex = payload.firstIndex(of: "=") else { return nil }
        let key = String(payload[..<eqIndex])
        let value = String(payload[payload.index(after: eqIndex)...])

        // Payload might have trailing tokens (future extension); take
        // the first whitespace-terminated word as the surface.
        let surfaceRaw = value.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard let surface = TCCRevokedReason.fromHealthLogSurface(surfaceRaw) else {
            return nil
        }

        switch key {
        case "tcc_revoked":
            return .revoked(surface)
        case "tcc_restored":
            return .restored(surface)
        default:
            return nil
        }
    }

    /// Parse a multi-line chunk (as returned by a partial file read).
    /// The tail actor accumulates bytes between newlines; complete
    /// lines are handed to this function in order.
    public static func parseChunk(_ chunk: String) -> [TCCHelperHealthEvent] {
        return chunk
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { parseLine(String($0)) }
    }
}

// MARK: - Sink protocol

/// Sink that the tail invokes for every parsed event. `TCCRevokedNotifier`
/// + `ProcessSupervisor` conform via a small adapter in AppDelegate; tests
/// substitute a recording fake.
///
/// Marked `@MainActor` so mutations to `ProcessSupervisor.tccRevokedSurface`
/// (which is `@Published`) happen on the main thread — SwiftUI requires
/// this to avoid AtomicReference races on the ObservableObject signal.
@MainActor
public protocol TCCRevokedEventSink: AnyObject {
    func handleRevoked(_ reason: TCCRevokedReason) async
    func handleRestored(_ reason: TCCRevokedReason) async
}

// MARK: - Default sink (production wiring)

/// The production sink: dispatches revoked/restored events to a
/// `TCCRevokedNotifier` and mirrors the current revoked surface onto
/// a `ProcessSupervisor.tccRevokedSurface` @Published property so
/// SwiftUI (MenuBarIcon + StatusMenuView) picks up the change.
///
/// Held weakly by AppDelegate — the sink itself carries strong refs
/// to the notifier + supervisor because those are the app's canonical
/// singletons.
@MainActor
public final class TCCNotifierAndSupervisorSink: TCCRevokedEventSink {
    private let notifier: TCCRevokedNotifier
    private weak var supervisor: ProcessSupervisor?
    private var revoked: Set<TCCRevokedReason> = []

    public init(notifier: TCCRevokedNotifier, supervisor: ProcessSupervisor) {
        self.notifier = notifier
        self.supervisor = supervisor
        if let existing = supervisor.tccRevokedSurface { revoked.insert(existing) }
    }

    public func handleRevoked(_ reason: TCCRevokedReason) async {
        revoked.insert(reason)
        updateVisibleReason()
        await notifier.notifyRevoked(reason)
    }

    public func handleRestored(_ reason: TCCRevokedReason) async {
        revoked.remove(reason)
        updateVisibleReason()
        await notifier.notifyRestored(reason)
    }

    private func updateVisibleReason() {
        // Screen capture has priority; restoring another permission must not
        // hide a permission that is still revoked.
        supervisor?.tccRevokedSurface = TCCRevokedReason.allCases.first { revoked.contains($0) }
    }
}

// MARK: - File tail

/// Tails the helper's stderr log file, parses TCC-breadcrumb lines,
/// and dispatches parsed events to a `TCCRevokedEventSink`.
///
/// Poll content-free log metadata once a second. Read at most 64 KiB per tick;
/// rotation is detected by file identity as well as truncation. Only complete
/// permission lines reach the sink, and stopped generations cannot deliver.
///
/// Runs on the main actor because it drives `TCCRevokedEventSink`,
/// which touches `@Published` state that SwiftUI reads.
@MainActor
public final class TCCHelperStderrTail {

    /// Default log path — matches `ProcessSupervisor.spawnChildren`'s
    /// LogRotator path for the helper's stderr sink.
    public static var defaultLogPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MCI/helper.stderr.log")
    }

    private let logPath: URL
    private let sink: TCCRevokedEventSink
    private let logger = Logger(subsystem: "ai.hippocampus", category: "tcc-stderr-tail")

    private var source: DispatchSourceTimer?
    private var generation: UInt64 = 0
    private var fileIdentity: UInt64?
    private var cursor: UInt64 = 0
    private var pendingBuffer = ""
    private var pendingEvents: [[TCCHelperHealthEvent]] = []
    private var deliveryTask: Task<Void, Never>?

    public init(sink: TCCRevokedEventSink, logPath: URL = TCCHelperStderrTail.defaultLogPath) {
        self.logPath = logPath
        self.sink = sink
    }

    /// Begin watching. Idempotent — a second `start()` cancels the
    /// prior watch and re-arms. Positions the cursor at end-of-file
    /// on start so we don't replay historical breadcrumbs from prior
    /// runs; the notifier is meant to be actionable in the moment.
    public func start() {
        stop()

        let dir = logPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )

        // Seed cursor at current EOF so we surface only NEW events.
        cursor = currentFileSize()

        fileIdentity = currentFileIdentity()
        let activeGeneration = generation
        // A directory vnode does not report appends to an existing child file.
        // Poll metadata once a second so rotation and ordinary appends both work.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == activeGeneration else { return }
                self.drainNewBytes()
            }
        }
        source = timer
        timer.resume()
    }

    /// Cancel pending observation and discard partial lines from the old run.
    public func stop() {
        generation &+= 1
        source?.cancel()
        source = nil
        pendingBuffer = ""
        pendingEvents.removeAll()
        deliveryTask?.cancel()
        deliveryTask = nil
    }

    /// TEST HOOK — feed a synthetic chunk as if the file had been
    /// appended. Bypasses the file watch so `swift test` can exercise
    /// the parse → sink dispatch path deterministically.
    public func injectForTest(_ chunk: String) async {
        await dispatch(chunk: chunk)
    }

    // MARK: - Private

    private func currentFileSize() -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath.path),
              let size = attrs[.size] as? UInt64
        else { return 0 }
        return size
    }

    private func currentFileIdentity() -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: logPath.path))?[.systemFileNumber] as? UInt64
    }

    /// Read a bounded chunk, feed complete lines to the parser, dispatch events.
    /// Handles rotation: if the file shrank (rotator moved the old
    /// file to `.1`), reset cursor to 0 and start over.
    private func drainNewBytes() {
        let size = currentFileSize()
        let identity = currentFileIdentity()
        if identity != fileIdentity || size < cursor {
            fileIdentity = identity
            // Rotation happened, or file was recreated fresh.
            cursor = 0
            pendingBuffer = ""
        }
        guard size > cursor else { return }

        guard let handle = try? FileHandle(forReadingFrom: logPath) else {
            return
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: cursor)
        } catch {
            return
        }

        let data = (try? handle.read(upToCount: 65_536)) ?? Data()
        cursor += UInt64(data.count)
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)

        // Fold in any partial trailing line from last drain.
        let combined = pendingBuffer + text
        // Split on newlines; keep trailing partial for next drain.
        if let lastNewline = combined.lastIndex(of: "\n") {
            let complete = String(combined[..<lastNewline])
            pendingBuffer = String(combined[combined.index(after: lastNewline)...].suffix(4096))
            enqueue(complete)
        } else {
            pendingBuffer = String(combined.suffix(4096))
        }
    }

    private func enqueue(_ chunk: String) {
        let events = TCCHelperStderrParser.parseChunk(chunk)
        guard !events.isEmpty else { return }
        // Retain only parsed permission enums while notification consent waits.
        pendingEvents.append(events)
        guard deliveryTask == nil else { return }
        let activeGeneration = generation
        deliveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == activeGeneration { self.deliveryTask = nil } }
            while self.generation == activeGeneration, !Task.isCancelled, !self.pendingEvents.isEmpty {
                let next = self.pendingEvents.removeFirst()
                await self.dispatch(events: next, generation: activeGeneration)
            }
        }
    }

    private func dispatch(chunk: String, generation expectedGeneration: UInt64? = nil) async {
        await dispatch(events: TCCHelperStderrParser.parseChunk(chunk), generation: expectedGeneration)
    }

    private func dispatch(events: [TCCHelperHealthEvent], generation expectedGeneration: UInt64? = nil) async {
        for event in events {
            if let expectedGeneration, generation != expectedGeneration { return }
            switch event {
            case .revoked(let reason):
                logger.info("tcc-stderr-tail: revoked \(reason.rawValue, privacy: .public)")
                await sink.handleRevoked(reason)
            case .restored(let reason):
                logger.info("tcc-stderr-tail: restored \(reason.rawValue, privacy: .public)")
                await sink.handleRestored(reason)
            }
        }
    }
}

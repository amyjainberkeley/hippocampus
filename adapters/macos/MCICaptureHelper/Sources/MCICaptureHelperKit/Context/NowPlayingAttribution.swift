// SPDX-License-Identifier: TBD-private
//
// NowPlayingAttribution — `MPNowPlayingInfoCenter`-backed
// "what is currently playing on this Mac" attribution source for
// `WorkflowContext`.
//
// Phase 6 PR 5 — SH Fork D1 (EventKit + Contacts +
// MPNowPlayingInfoCenter cascade attribution; ratified at
// AGENT_QUESTIONS.md F-RATIFICATION-2026-05-31).
//
// PROTECTED-SET per AGENT_PROTOCOL §5 (this PR adds the
// `NSAppleMusicUsageDescription` TCC surface; driver-CSO sign-off
// authored inline in the PR body, not via the `cso` sub-agent —
// CEO-INFRA-001).
//
// # API choice — MPNowPlayingInfoCenter (system-wide reader)
//
// `MPNowPlayingInfoCenter.default().nowPlayingInfo` is the system-
// wide "currently playing" dictionary populated by whichever app
// has the audio focus (Music, Podcasts, Spotify, browser players
// that announce themselves via the framework, etc.). Reading the
// dictionary does NOT require a music-library entitlement on macOS
// 14+; the `NSAppleMusicUsageDescription` string is required for
// the prompt to render cleanly when the system surfaces a privacy
// dialog. Steady-state behaviour: no prompt at all on most Macs —
// the framework returns either a populated dict or an empty one.
// We surface only `title` + `artist` and NEVER read library
// contents / play history / album art bytes.
//
// # Scope binding
//
// PER-EVENT attribution enricher, NOT a deep-hook plugin. Returns
// title + artist only (NowPlayingTrackRef in
// `Suppression/SuppressionInputs.swift`). Caches aggressively — the
// reader is cheap (one dictionary lookup) but we still cache to a
// 1 s TTL so the 1 Hz capture-poll fans into one read.
//
// # TCC denial / unavailability path
//
// On Macs where the framework is unavailable (CI / headless), the
// `#if canImport(MediaPlayer)` block compiles out and the source
// always returns `nil` — graceful absence. No crash. No state-
// change warn (this is not a TCC denial; it is platform absence).

import Dispatch
import Foundation
import os
#if canImport(MediaPlayer)
import MediaPlayer
#endif

/// Protocol surface — production reads
/// `MPNowPlayingInfoCenter.default().nowPlayingInfo`; tests inject a
/// deterministic stub.
public protocol NowPlayingTrackSource: Sendable {
    /// Currently-playing track on this Mac, or `nil` if nothing is
    /// playing / framework unavailable / dict missing required keys.
    func currentTrack() -> NowPlayingTrackRef?
}

/// Production `NowPlayingTrackSource` over `MPNowPlayingInfoCenter`.
/// Holds a per-read cache with a 1 s TTL so the 1 Hz capture-poll
/// burns one dictionary read per second in the steady state.
///
/// Lifetime discipline (SCSTREAM-LIVE-001 lesson): construct at
/// process top level in `MCICaptureHelper/main.swift`; never let a
/// detached `Task` be the sole owner.
public final class NowPlayingAttribution: NowPlayingTrackSource, @unchecked Sendable {
    /// Cache TTL. 1 s by default — matches the 1 Hz cascade-floor
    /// (ADR-0015 §3) so a per-frame read deduplicates to one
    /// framework call per second under load.
    private let cacheTtl: TimeInterval

    private let stateLock = NSLock()
    /// Last observed track. `nil` when nothing was playing on the
    /// last read.
    private var cached: NowPlayingTrackRef?
    /// Wall clock of the last read.
    private var cachedAt: Date?

    public init(cacheTtl: TimeInterval = 1.0) {
        self.cacheTtl = cacheTtl
        self.cached = nil
        self.cachedAt = nil
    }

    /// `MPNowPlayingInfoCenter` requires no explicit start / TCC
    /// prompt on macOS 14+ for read-only consumption. The method
    /// exists to mirror the `CalendarAttribution.start()` shape so
    /// the construction site at `main.swift` looks uniform across
    /// the three providers.
    public func start() {
        // No-op on production; placeholder for symmetry with
        // CalendarAttribution.start() / ContactsAttribution.start().
    }

    public func currentTrack() -> NowPlayingTrackRef? {
        // Cache-hit fast path: a recent observation within TTL.
        stateLock.lock()
        let ttl = cacheTtl
        let cachedSnapshot = cached
        let cachedAtSnapshot = cachedAt
        stateLock.unlock()

        if let at = cachedAtSnapshot, Date().timeIntervalSince(at) < ttl {
            return cachedSnapshot
        }

        let observed = readNowPlaying()

        stateLock.lock()
        cached = observed
        cachedAt = Date()
        stateLock.unlock()

        return observed
    }

    /// Read the `nowPlayingInfo` dict and project to
    /// `NowPlayingTrackRef`. Returns `nil` if the dict is missing OR
    /// both title and artist are missing (we only emit a track ref
    /// when there is something to attribute).
    private func readNowPlaying() -> NowPlayingTrackRef? {
        #if canImport(MediaPlayer)
        guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            return nil
        }
        // Project ONLY the two keys we attribute. `MPMediaItem
        // PropertyTitle` and `MPMediaItemPropertyArtist` are the
        // documented standard keys. NO album art bytes
        // (`artwork` is intentionally not read).
        let titleAny = info[MPMediaItemPropertyTitle]
        let artistAny = info[MPMediaItemPropertyArtist]
        let title = (titleAny as? String) ?? ""
        let artist = (artistAny as? String) ?? ""
        // Both empty → nothing meaningful to attribute.
        if title.isEmpty && artist.isEmpty {
            return nil
        }
        return NowPlayingTrackRef(title: title, artist: artist)
        #else
        return nil
        #endif
    }
}

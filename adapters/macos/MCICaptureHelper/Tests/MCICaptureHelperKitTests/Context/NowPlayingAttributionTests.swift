// SPDX-License-Identifier: TBD-private
//
// NowPlayingAttributionTests — Phase 6 PR 5 (SH Fork D1).

import XCTest
@testable import MCICaptureHelperKit

final class StubNowPlayingTrackSource: NowPlayingTrackSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _track: NowPlayingTrackRef?
    private var _calls: Int = 0

    init(initial: NowPlayingTrackRef? = nil) {
        self._track = initial
    }

    func set(_ track: NowPlayingTrackRef?) {
        lock.lock(); defer { lock.unlock() }
        _track = track
    }

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func currentTrack() -> NowPlayingTrackRef? {
        lock.lock(); defer { lock.unlock() }
        _calls += 1
        return _track
    }
}

final class NowPlayingAttributionTests: XCTestCase {

    func testStubReturnsConfiguredTrack() {
        let track = NowPlayingTrackRef(title: "Bohemian Rhapsody", artist: "Queen")
        let stub = StubNowPlayingTrackSource(initial: track)
        XCTAssertEqual(stub.currentTrack(), track)
        XCTAssertEqual(stub.calls, 1)
    }

    func testStubReturnsNilWhenNothingPlaying() {
        let stub = StubNowPlayingTrackSource(initial: nil)
        XCTAssertNil(stub.currentTrack())
    }

    func testTickFoldsTrackIntoSnapshot() async {
        let track = NowPlayingTrackRef(title: "Episode 42", artist: "Daily Podcast")
        let frontmost = StubFrontmostAppSource(initial: "com.spotify.client")
        let nowPlaying = StubNowPlayingTrackSource(initial: track)
        let store = WorkflowContextSnapshot()
        await NSWorkspaceContextProvider.tickOnce(
            source: frontmost,
            titleProvider: nil,
            calendarSource: nil,
            nowPlayingSource: nowPlaying,
            contactsSource: nil,
            store: store
        )
        let ctx = store.currentSync()
        XCTAssertEqual(ctx.currentListeningTrack, track)
        XCTAssertNil(ctx.currentCalendarEvent)
        XCTAssertNil(ctx.currentContact)
    }

    func testTickWithNoSourceLeavesFieldNil() async {
        let frontmost = StubFrontmostAppSource(initial: "com.spotify.client")
        let store = WorkflowContextSnapshot()
        await NSWorkspaceContextProvider.tickOnce(
            source: frontmost,
            titleProvider: nil,
            calendarSource: nil,
            nowPlayingSource: nil,
            contactsSource: nil,
            store: store
        )
        XCTAssertNil(store.currentSync().currentListeningTrack)
    }

    func testTccDeniedSourceReturnsNilGracefully() async {
        // Source returns nil (mirrors production's
        // framework-unavailable / empty-dict path). Event capture
        // proceeds; the track field stays nil.
        let frontmost = StubFrontmostAppSource(initial: "com.apple.Music")
        let nowPlaying = StubNowPlayingTrackSource(initial: nil)
        let store = WorkflowContextSnapshot()
        await NSWorkspaceContextProvider.tickOnce(
            source: frontmost,
            titleProvider: nil,
            calendarSource: nil,
            nowPlayingSource: nowPlaying,
            contactsSource: nil,
            store: store
        )
        let ctx = store.currentSync()
        XCTAssertEqual(ctx.appBundleId, "com.apple.Music")
        XCTAssertNil(ctx.currentListeningTrack)
    }

    func testProductionConstructorBindsCleanly() {
        // Production `NowPlayingAttribution` constructs without
        // exception in headless CI; reading before start() is a
        // graceful nil (the implementation reads the system info
        // dict directly — empty on a headless host).
        let attribution = NowPlayingAttribution()
        attribution.start()
        // Result depends on what is playing on the host (CI: nil,
        // dev: maybe a track). Only assert no-crash here.
        _ = attribution.currentTrack()
    }
}

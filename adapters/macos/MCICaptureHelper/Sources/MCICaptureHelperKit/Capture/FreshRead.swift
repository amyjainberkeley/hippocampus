import Foundation

/// Ask opened: read the window in front once now, so "What's on this
/// screen?" is answered from what is on screen, not from the last read
/// before the reader's rest.
///
/// The app asks by writing `byte` to the helper's parent-lifetime lease
/// (its standard input), which only the app that started the helper holds.
/// The helper is started without `--capture` when remembering is off and
/// is not running while paused, so then nothing is read.
public enum FreshReadRequest {
    /// "r". The app's `HelperLeaseCommand.freshRead` must stay equal.
    public static let byte: UInt8 = 0x72
}

/// One fresh read of one window, bypassing the reader's rest once.
///
/// A request names the window in front when Ask opened (its focus
/// generation). The window's stream is started again for a new frame,
/// since a still window sends none, and that frame is read without waiting
/// for the reader's rest or the window's read interval. The request lapses
/// once used, when focus moves to another window, or after `lifetimeUs`.
/// Requests closer together than `minimumSpacingUs` (Ask toggled quickly)
/// ask for nothing more. Pure, so the timing is tested without a screen.
struct FreshReadToken: Sendable, Equatable {
    /// Long enough for a stream to start and its first frame to arrive.
    static let lifetimeUs: UInt64 = 5_000_000
    static let minimumSpacingUs: UInt64 = 2_000_000

    private var generation: UInt64?
    private var issuedAtUs: UInt64 = 0
    private var frameRequested = false
    private var lastIssuedAtUs: UInt64?

    /// Asks for a fresh read of the window with focus `generation`. False
    /// when a request was issued less than `minimumSpacingUs` ago.
    mutating func issue(generation: UInt64, nowUs: UInt64) -> Bool {
        if let last = lastIssuedAtUs, nowUs >= last, nowUs - last < Self.minimumSpacingUs {
            return false
        }
        self.generation = generation
        issuedAtUs = nowUs
        frameRequested = true
        lastIssuedAtUs = nowUs
        return true
    }

    /// Whether a read of `generation` is still owed.
    func isPending(generation: UInt64, nowUs: UInt64) -> Bool {
        guard self.generation == generation, nowUs >= issuedAtUs else { return false }
        return nowUs - issuedAtUs < Self.lifetimeUs
    }

    /// True once per request: the caller starts the window's stream again so
    /// a frame of it arrives.
    mutating func takeFrameRequest(generation: UInt64, nowUs: UInt64) -> Bool {
        guard frameRequested, isPending(generation: generation, nowUs: nowUs) else { return false }
        frameRequested = false
        return true
    }

    /// True once per request, for a frame of the requested window: read it
    /// now. Using the request ends it.
    mutating func consume(generation: UInt64, nowUs: UInt64) -> Bool {
        guard isPending(generation: generation, nowUs: nowUs) else { return false }
        self.generation = nil
        frameRequested = false
        return true
    }
}

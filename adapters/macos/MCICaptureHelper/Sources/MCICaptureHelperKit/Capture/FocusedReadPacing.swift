import Foundation

/// Paces OCR of the focused window when its picture never stops changing.
///
/// A playing video or an animation changes every frame, and every changed
/// frame used to be read: the OCR worker ran without pause. Text catch-up
/// reads (typing, new messages) keep their own three-second floor. Frames
/// that changed visually are read at most every three seconds. Once changes
/// of either kind have kept arriving back to back for four reads (a video, a
/// streamed answer, a scrolling log), the window is read at most every
/// fifteen seconds until it settles. A new focused window is always read.
public struct FocusedReadPacing: Sendable, Equatable {
    public static let minimumIntervalUs: UInt64 = 3_000_000
    public static let motionIntervalUs: UInt64 = 15_000_000
    /// Reads that keep landing as soon as the interval allows, this many in
    /// a row, mean the picture never settles (video, animation).
    public static let motionAfterDenseReads = 4
    /// A read within this much of the interval counts as back to back.
    public static let denseSlackUs: UInt64 = 2_000_000

    private var generation: UInt64?
    private var lastReadUs: UInt64 = 0
    private var denseReads = 0
    private var waitedSinceRead = false

    public init() {}

    /// Whether to read a frame the change gate admitted.
    /// `scale` stretches every interval (2 on battery, 4 in Low Power Mode).
    public mutating func admit(generation: UInt64, nowUs: UInt64, textCatchUp: Bool, scale: UInt64 = 1) -> Bool {
        if generation != self.generation {
            self.generation = generation
            lastReadUs = nowUs
            denseReads = 0
            waitedSinceRead = false
            return true
        }
        let interval = (isInMotion ? Self.motionIntervalUs : Self.minimumIntervalUs) * max(scale, 1)
        let sinceRead = nowUs >= lastReadUs ? nowUs - lastReadUs : 0
        // Typing has its own three-second floor upstream; on battery it waits
        // the scaled interval too.
        let catchUpFloor = scale > 1 ? Self.minimumIntervalUs * scale : 0
        if textCatchUp && !isInMotion && sinceRead >= catchUpFloor {
            // Text that changes again as soon as it may be read is still being
            // written: a streamed answer, a build log, steady typing. Four
            // such reads in a row and it is read at the motion interval,
            // then normally again once it has settled.
            let dense = sinceRead <= max(catchUpFloor, Self.minimumIntervalUs) + Self.denseSlackUs
            denseReads = dense ? denseReads + 1 : 0
            waitedSinceRead = false
            lastReadUs = nowUs
            return true
        }
        guard sinceRead >= interval else {
            waitedSinceRead = true
            return false
        }
        // Changes that were already waiting when the interval ran out, read
        // right away, mean the picture is still moving.
        if waitedSinceRead && sinceRead <= interval + Self.denseSlackUs {
            denseReads += 1
        } else {
            denseReads = 0
        }
        waitedSinceRead = false
        lastReadUs = nowUs
        return true
    }

    public var isInMotion: Bool { denseReads >= Self.motionAfterDenseReads }

    /// Whether `generation` is a window this pacing has not read yet.
    public func isNewWindow(generation: UInt64) -> Bool { generation != self.generation }
}

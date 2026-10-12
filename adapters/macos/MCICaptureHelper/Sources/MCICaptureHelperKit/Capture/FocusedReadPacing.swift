import Foundation

/// Paces OCR of the focused window when its picture never stops changing.
///
/// A playing video or an animation changes every frame, and every changed
/// frame used to be read: the OCR worker ran without pause. Text catch-up
/// reads (typing, new messages) keep their own three-second floor. Frames
/// that changed visually are read at most every two seconds, and once
/// changes have kept arriving for ten seconds (motion), at most every fifteen
/// seconds until the picture settles. A new focused window is always read.
public struct FocusedReadPacing: Sendable, Equatable {
    public static let minimumIntervalUs: UInt64 = 2_000_000
    public static let motionIntervalUs: UInt64 = 15_000_000
    public static let motionAfterUs: UInt64 = 10_000_000
    /// Changes closer together than this count as one continuous stretch.
    public static let continuityUs: UInt64 = 1_500_000

    private var generation: UInt64?
    private var lastReadUs: UInt64 = 0
    private var lastCandidateUs: UInt64 = 0
    private var continuousSinceUs: UInt64 = 0

    public init() {}

    /// Whether to read a frame the change gate admitted.
    public mutating func admit(generation: UInt64, nowUs: UInt64, textCatchUp: Bool) -> Bool {
        defer { lastCandidateUs = nowUs }
        if generation != self.generation {
            self.generation = generation
            lastReadUs = nowUs
            continuousSinceUs = nowUs
            return true
        }
        if nowUs.saturatingSub(lastCandidateUs) > Self.continuityUs {
            continuousSinceUs = nowUs
        }
        let sinceRead = nowUs.saturatingSub(lastReadUs)
        let inMotion = nowUs.saturatingSub(continuousSinceUs) >= Self.motionAfterUs
        let interval = textCatchUp ? 0 : (inMotion ? Self.motionIntervalUs : Self.minimumIntervalUs)
        guard sinceRead >= interval else { return false }
        lastReadUs = nowUs
        return true
    }

    public var isInMotion: Bool { lastCandidateUs.saturatingSub(continuousSinceUs) >= Self.motionAfterUs }
}

private extension UInt64 {
    func saturatingSub(_ other: UInt64) -> UInt64 { self >= other ? self - other : 0 }
}

import Foundation

/// Bounds how much of the time the text reader may be busy off mains power.
///
/// A read costs seconds of processor time, and on battery one could start
/// every few seconds for as long as the screen kept changing. After each read
/// the reader now rests for a multiple of the time that read took: eight
/// times on battery, sixteen in Low Power Mode, not at all when plugged in.
/// Whatever is on screen, it is busy at most a ninth of the time on battery.
public struct ReadBudget: Sendable, Equatable {
    /// A read that timed out must not silence the reader for minutes.
    public static let longestRestUs: UInt64 = 120_000_000

    /// Rest owed after a read, as a multiple of how long the read took.
    /// `scale` is `CapturePowerMode.intervalScale`.
    public static func restFactor(scale: UInt64) -> UInt64 {
        switch scale {
        case 0, 1: 0
        case 2: 8
        default: 16
        }
    }

    private var restUntilUs: UInt64 = 0

    public init() {}

    public mutating func record(endedUs: UInt64, tookUs: UInt64, scale: UInt64) {
        let rest = min(tookUs.multipliedReportingOverflow(by: Self.restFactor(scale: scale)).partialValue,
                       Self.longestRestUs)
        restUntilUs = max(restUntilUs, endedUs &+ rest)
    }

    /// Whether a read may start now. Plugging in ends any rest at once.
    public func admits(nowUs: UInt64, scale: UInt64) -> Bool {
        Self.restFactor(scale: scale) == 0 || nowUs >= restUntilUs
    }
}

/// The one budget every reader in the helper shares: the focused window and
/// the whole-screen reads use the same OCR worker.
public final class CaptureReadBudget: @unchecked Sendable {
    public static let shared = CaptureReadBudget()

    private let lock = NSLock()
    private var budget = ReadBudget()

    private static func uptimeUs() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000 }

    /// Call when a read ends, with how long it took.
    public func recordRead(tookUs: UInt64) {
        let scale = CapturePower.current().intervalScale
        lock.withLock { budget.record(endedUs: Self.uptimeUs(), tookUs: tookUs, scale: scale) }
    }

    public func admitsRead() -> Bool {
        let scale = CapturePower.current().intervalScale
        return lock.withLock { budget.admits(nowUs: Self.uptimeUs(), scale: scale) }
    }
}

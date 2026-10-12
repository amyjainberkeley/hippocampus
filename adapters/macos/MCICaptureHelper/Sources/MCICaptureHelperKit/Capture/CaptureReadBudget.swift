import Foundation

/// Bounds how much of the time the text reader may be busy.
///
/// A read costs seconds of processor time, and one could start every few
/// seconds for as long as the screen kept changing: most of a core through a
/// video call, plugged in or not. After each read the reader now rests for a
/// multiple of the time that read took: three times plugged in, eight on
/// battery, sixteen in Low Power Mode. So it is busy at most a quarter of the
/// time plugged in and a ninth on battery, whatever is on screen. A quick
/// read of a window that barely changed rests for less than the reader waits
/// between reads anyway.
public struct ReadBudget: Sendable, Equatable {
    /// A read that timed out must not silence the reader for minutes.
    public static let longestRestUs: UInt64 = 120_000_000

    /// Rest owed after a read, as a multiple of how long the read took.
    /// `scale` is `CapturePowerMode.intervalScale`.
    public static func restFactor(scale: UInt64) -> UInt64 {
        switch scale {
        case 0, 1: 3
        case 2: 8
        default: 16
        }
    }

    private var endedUs: UInt64 = 0
    private var tookUs: UInt64 = 0

    public init() {}

    public mutating func record(endedUs: UInt64, tookUs: UInt64) {
        self.endedUs = endedUs
        self.tookUs = tookUs
    }

    /// Whether a read may start now. The power mode is the one in force now,
    /// so plugging in shortens a rest that began on battery.
    public func admits(nowUs: UInt64, scale: UInt64) -> Bool {
        let rest = min(tookUs.multipliedReportingOverflow(by: Self.restFactor(scale: scale)).partialValue,
                       Self.longestRestUs)
        return nowUs >= endedUs &+ rest
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
        lock.withLock { budget.record(endedUs: Self.uptimeUs(), tookUs: tookUs) }
    }

    public func admitsRead() -> Bool {
        let scale = CapturePower.current().intervalScale
        return lock.withLock { budget.admits(nowUs: Self.uptimeUs(), scale: scale) }
    }
}

import Foundation

/// Input inactivity lowers processing frequency; it does not establish absence.
/// Keep a bounded quiet-period sample and the first sample of each new window.
final class CaptureActivitySchedule: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSampleTime: UInt64?
    private var lastGeneration: UInt64?
    private static let quietInterval: UInt64 = 10_000_000_000

    func shouldProcess(inputQuiet: Bool, focusGeneration: UInt64?, now: UInt64) -> Bool {
        lock.withLock {
            if inputQuiet, let previous = lastSampleTime,
               focusGeneration == lastGeneration, now >= previous,
               now - previous < Self.quietInterval {
                return false
            }
            lastSampleTime = now
            lastGeneration = focusGeneration
            return true
        }
    }
}

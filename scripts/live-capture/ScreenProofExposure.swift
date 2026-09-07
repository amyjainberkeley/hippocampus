import Foundation

struct ScreenProofExposure {
    private(set) var seconds: TimeInterval = 0
    private var previous: TimeInterval?

    mutating func sample(at time: TimeInterval, eligible: Bool) {
        guard eligible, time.isFinite else {
            seconds = 0
            previous = nil
            return
        }
        defer { previous = time }
        guard let previous, time >= previous, time - previous <= 2 else {
            seconds = 0
            return
        }
        seconds += time - previous
    }
}

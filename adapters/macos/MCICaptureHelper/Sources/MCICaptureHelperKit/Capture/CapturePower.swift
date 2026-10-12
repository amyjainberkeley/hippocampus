import Foundation
import IOKit.ps

/// How hard capture may work right now. Reading the screen is the biggest
/// energy cost Hippocampus has, so it slows on battery and slows further in
/// Low Power Mode.
public enum CapturePowerMode: Sendable, Equatable {
    case pluggedIn
    case battery
    case lowPower

    /// Multiplier on every read interval.
    public var intervalScale: UInt64 {
        switch self {
        case .pluggedIn: 1
        case .battery: 2
        case .lowPower: 4
        }
    }

    /// Seconds between whole-screen reads of a display; nil means none.
    public var displayReadInterval: TimeInterval? {
        switch self {
        case .pluggedIn: 30
        case .battery: 60
        case .lowPower: nil
        }
    }
}

public enum CapturePower {
    private static let cache = NSLock()
    nonisolated(unsafe) private static var cached: (mode: CapturePowerMode, at: Date)?

    /// The current mode, re-read at most every 20 seconds.
    public static func current(now: Date = Date()) -> CapturePowerMode {
        cache.lock(); defer { cache.unlock() }
        if let cached, now.timeIntervalSince(cached.at) < 20 { return cached.mode }
        let mode = read()
        cached = (mode, now)
        return mode
    }

    private static func read() -> CapturePowerMode {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPower }
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else { return .pluggedIn }
        return source == kIOPSBatteryPowerValue ? .battery : .pluggedIn
    }
}

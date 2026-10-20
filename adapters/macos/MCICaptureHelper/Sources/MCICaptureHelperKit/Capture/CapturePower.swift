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
    nonisolated(unsafe) private static var cachedBattery: (percent: Int?, at: Date)?

    /// Below this charge on battery, no picture of a window beside the one in
    /// front is kept (SPEC 6.2.8). The window in front is unaffected.
    public static let sidePicturesMinimumBatteryPercent = 20

    /// The current mode, re-read at most every 20 seconds.
    public static func current(now: Date = Date()) -> CapturePowerMode {
        cache.lock(); defer { cache.unlock() }
        if let cached, now.timeIntervalSince(cached.at) < 20 { return cached.mode }
        let mode = read()
        cached = (mode, now)
        return mode
    }

    /// The internal battery's charge, 0 to 100, re-read at most every 20
    /// seconds; nil on a Mac without one.
    public static func batteryPercent(now: Date = Date()) -> Int? {
        cache.lock(); defer { cache.unlock() }
        if let cachedBattery, now.timeIntervalSince(cachedBattery.at) < 20 { return cachedBattery.percent }
        let percent = readBatteryPercent()
        cachedBattery = (percent, now)
        return percent
    }

    /// Whether pictures of side windows may be kept now: never in Low Power
    /// Mode, and not on battery below 20%. Plugged in, the charge is no
    /// matter.
    public static func allowsSidePictures(mode: CapturePowerMode, batteryPercent: Int?) -> Bool {
        switch mode {
        case .lowPower: false
        case .pluggedIn: true
        case .battery: (batteryPercent ?? 100) >= sidePicturesMinimumBatteryPercent
        }
    }

    private static func read() -> CapturePowerMode {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPower }
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else { return .pluggedIn }
        return source == kIOPSBatteryPowerValue ? .battery : .pluggedIn
    }

    private static func readBatteryPercent() -> Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            return max(0, min(100, current * 100 / maximum))
        }
        return nil
    }
}

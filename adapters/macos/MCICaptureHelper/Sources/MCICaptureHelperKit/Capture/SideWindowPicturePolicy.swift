// SPDX-License-Identifier: Apache-2.0
//
// SideWindowPicturePolicy — when a picture of a window beside the one in
// front is kept (SPEC 6.2). Every rule must hold:
//
//   1. A whole-screen read happened, under today's rules (the caller:
//      BackgroundCaptureSession reads only then).
//   2. The window's text changed meaningfully since its last picture: three
//      or more lines added or changed, at least 15% of its text, or a new
//      title.
//   3. Its text passed every check (the caller: a picture is retained only
//      for an event that cleared both privacy passes).
//   4. Enough of it can be seen (WindowPictureCrop.Plan.isVisibleEnough).
//   5. It isn't a call or a video (isCallOrVideo).
//   6. Not too often: one per window every 2 minutes (sooner when its title
//      changes), 30 an hour and 300 a day, and only when the picture changed
//      visibly (a dHash distance of 12 or more) or its last one is 30
//      minutes old.
//   7. There is room: the budget isn't full and the disk has 10 GB free.
//   8. Not on low battery: none on battery below 20%, none in Low Power Mode.
//
// PRIVACY: the ledger is content-free. It keeps a hash of each line and of
// the title, never text, only in memory, and only to compare with the next
// read of the same window.

import CoreGraphics
import Darwin
import Foundation

public struct SideWindowPicturePolicy: Sendable, Equatable {
    public static let `default` = SideWindowPicturePolicy()

    public var minimumChangedLines = 3
    public var minimumChangedTextFraction = 0.15
    public var minimumIntervalUs: UInt64 = 120_000_000
    public var maximumPerHour = 30
    public var maximumPerDay = 300
    public var materialDistance = 12
    public var maximumSilenceUs: UInt64 = 30 * 60 * 1_000_000

    public init() {}

    // MARK: Rule 5 — calls and video

    /// Call apps (their text is still read; their windows are never pictured).
    static let callApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.apple.FaceTime",
        "com.cisco.webexmeetingsapp", "com.webex.meetingmanager", "Cisco-Systems.Spark", "com.skype.skype",
        "app.tuple.app", "com.apple.PhotoBooth",
    ]

    /// Video players.
    static let videoApps: Set<String> = [
        "com.apple.TV", "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.colliderli.iina",
        "com.firecore.infuse", "tv.plex.desktop", "com.netflix.Netflix",
    ]

    /// Call pages and video sites, by the words their windows' titles carry.
    static let callOrVideoTitles: [String] = [
        "google meet", "zoom meeting", "zoom webinar", "microsoft teams", "webex", "whereby", "huddle",
        "youtube", "netflix", "twitch", "vimeo", "prime video", "disney+", "hulu", "apple tv",
    ]

    /// Rule 5: a call app or video player, or a window whose title names a
    /// call page, a huddle or a video site. A Google Meet room's title is
    /// "Meet – " or "Meet - " and its name.
    public static func isCallOrVideo(bundleId: String?, title: String?) -> Bool {
        if let bundleId, callApps.contains(bundleId) || videoApps.contains(bundleId) { return true }
        guard let title = title?.lowercased(), !title.isEmpty else { return false }
        if title.hasPrefix("meet - ") || title.hasPrefix("meet \u{2013} ") || title == "meet" { return true }
        return callOrVideoTitles.contains { title.contains($0) }
    }
}

/// A side window's text as the keep rule compares it: one key per line,
/// never the text itself.
public struct SideWindowText: Sendable, Equatable {
    public let lineKeys: [Int]
    public let lineLengths: [Int]

    public init(lines: [String]) {
        var keys: [Int] = [], lengths: [Int] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            keys.append(trimmed.hashValue)
            lengths.append(trimmed.count)
        }
        lineKeys = keys
        lineLengths = lengths
    }

    var totalLength: Int { lineLengths.reduce(0, +) }
}

/// Why no picture was kept: content-free, for the trace only.
public enum SidePictureSkip: String, Sendable, Equatable {
    case off
    case lowPower = "low_power"
    case lowBattery = "low_battery"
    case lowDisk = "low_disk"
    case budgetFull = "budget_full"
    case textUnchanged = "text_unchanged"
    case tooSoon = "too_soon"
    case hourlyLimit = "hourly_limit"
    case dailyLimit = "daily_limit"
    case nearlyOneColour = "one_colour"
    case pictureUnchanged = "picture_unchanged"
}

/// What has been kept: each window's last picture and when pictures were
/// kept, for rules 2 and 6. Pure and content-free.
public struct SidePictureLedger: Sendable, Equatable {
    struct Memory: Sendable, Equatable {
        let keptAtUs: UInt64
        let titleKey: Int
        let dhash: DHash
        let lines: Set<Int>
    }

    public let policy: SideWindowPicturePolicy
    private(set) var memory: [CGWindowID: Memory] = [:]
    private(set) var keptAtUs: [UInt64] = []

    public init(policy: SideWindowPicturePolicy = .default) {
        self.policy = policy
    }

    /// Rules 2 and 6 before the picture is made: nil when it may be kept.
    public func admits(windowId: CGWindowID, titleKey: Int, text: SideWindowText, nowUs: UInt64) -> SidePictureSkip? {
        let lastHour = keptAtUs.filter { nowUs &- $0 < 3_600_000_000 && $0 <= nowUs }.count
        if keptAtUs.filter({ nowUs &- $0 < 86_400_000_000 && $0 <= nowUs }).count >= policy.maximumPerDay {
            return .dailyLimit
        }
        if lastHour >= policy.maximumPerHour { return .hourlyLimit }
        guard let last = memory[windowId] else { return nil }
        let newTitle = last.titleKey != titleKey
        if !newTitle, nowUs >= last.keptAtUs, nowUs - last.keptAtUs < policy.minimumIntervalUs { return .tooSoon }
        if newTitle { return nil }
        var changedLines = 0, changedLength = 0
        for (key, length) in zip(text.lineKeys, text.lineLengths) where !last.lines.contains(key) {
            changedLines += 1
            changedLength += length
        }
        let fraction = text.totalLength > 0 ? Double(changedLength) / Double(text.totalLength) : 0
        if changedLines >= policy.minimumChangedLines || fraction >= policy.minimumChangedTextFraction { return nil }
        return .textUnchanged
    }

    /// Rule 6 once the picture is made: nil when it differs enough from the
    /// window's last one, or that one is 30 minutes old.
    public func admitsPicture(windowId: CGWindowID, dhash: DHash, nowUs: UInt64) -> SidePictureSkip? {
        guard let last = memory[windowId] else { return nil }
        if nowUs >= last.keptAtUs, nowUs - last.keptAtUs >= policy.maximumSilenceUs { return nil }
        return dhash.distance(to: last.dhash) >= policy.materialDistance ? nil : .pictureUnchanged
    }

    /// A picture was kept and its moment written.
    public mutating func record(windowId: CGWindowID, titleKey: Int, text: SideWindowText, dhash: DHash,
                                nowUs: UInt64) {
        memory[windowId] = Memory(keptAtUs: nowUs, titleKey: titleKey, dhash: dhash, lines: Set(text.lineKeys))
        keptAtUs.append(nowUs)
        // A day is all the caps look back; a window unseen for a day is new.
        keptAtUs.removeAll { nowUs &- $0 >= 86_400_000_000 && $0 <= nowUs }
        memory = memory.filter { nowUs &- $0.value.keptAtUs < 86_400_000_000 || $0.value.keptAtUs > nowUs }
    }
}

// MARK: Rules 7 and 8 — the person's settings, room and power

/// What `~/.config/hippocampus/runtime.toml` says about side pictures. The
/// app's Preferences write it; the agent reads the same keys
/// (`mci_brain::side_pictures`). Anything missing or damaged reads as off.
public struct SidePictureSettings: Sendable, Equatable {
    public static let budgetChoicesMB = [1_000, 2_000, 5_000]
    public static let defaultBudgetBytes: Int64 = 2_000_000_000

    public var enabled: Bool
    public var budgetMB: Int?

    public init(enabled: Bool = false, budgetMB: Int? = nil) {
        self.enabled = enabled
        self.budgetMB = budgetMB
    }

    /// The two root keys, read from a TOML document. A key given twice, or
    /// a root line that is not a comment, a key and a value, or a table
    /// header, makes the whole document read as off.
    public static func parse(_ text: String) -> SidePictureSettings {
        var enabled: Bool?
        var budget: String?
        var seen = Set<String>()
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") { break }
            guard let equals = line.firstIndex(of: "=") else { return SidePictureSettings() }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            line = String(line[line.index(after: equals)...])
            if let comment = line.firstIndex(of: "#"), !line.contains("\"") { line = String(line[..<comment]) }
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !seen.contains(key) else { return SidePictureSettings() }
            seen.insert(key)
            switch key {
            case "side_window_pictures": enabled = value == "true"
            case "side_pictures_budget_mb": budget = value
            default: continue
            }
        }
        let mb = budget.flatMap(Int.init).flatMap { budgetChoicesMB.contains($0) ? $0 : nil }
        return SidePictureSettings(enabled: enabled ?? false, budgetMB: mb)
    }

    /// The budget in bytes on a disk of `diskTotalBytes`: the person's
    /// choice, else 2 GB or 2% of the disk if that is less.
    public func budgetBytes(diskTotalBytes: Int64?) -> Int64 {
        if let budgetMB { return Int64(budgetMB) * 1_000_000 }
        guard let total = diskTotalBytes, total / 100 * 2 > 0 else { return Self.defaultBudgetBytes }
        return min(Self.defaultBudgetBytes, total / 100 * 2)
    }
}

/// Where the side-picture rules read the world from. The live one reads the
/// person's settings, the agent's usage record, the disk and the power
/// source; tests give fixed answers.
public protocol SidePictureEnvironment: Sendable {
    func settings() -> SidePictureSettings
    func power() -> (mode: CapturePowerMode, batteryPercent: Int?)
    func disk() -> (availableBytes: Int64?, totalBytes: Int64?)
    /// Side bytes in the agent's last usage record, and when it measured them.
    func recordedSideBytes() -> (bytes: Int64, measuredAt: Date)?
}

/// The real world: `runtime.toml` under the person's home folder, the
/// agent's `pictures-usage.json` beside the blob folder, the blob folder's
/// disk and the power source. Files are read again only when they change;
/// the disk is looked at once a minute.
public final class LiveSidePictureEnvironment: SidePictureEnvironment, @unchecked Sendable {
    public let settingsURL: URL
    public let usageURL: URL
    public let blobDirectory: URL

    private let lock = NSLock()
    private var settingsCache: (stamp: FileStamp, value: SidePictureSettings)?
    private var usageCache: (stamp: FileStamp, value: (bytes: Int64, measuredAt: Date)?)?
    private var diskCache: (at: Date, value: (availableBytes: Int64?, totalBytes: Int64?))?

    struct FileStamp: Equatable {
        let modified: Date
        let size: Int64
    }

    public init(settingsURL: URL, usageURL: URL, blobDirectory: URL) {
        self.settingsURL = settingsURL
        self.usageURL = usageURL
        self.blobDirectory = blobDirectory
    }

    /// The person's own: `~/.config/hippocampus/runtime.toml`, and the usage
    /// record the agent writes beside the brain, one folder up from blobs.
    public convenience init(blobDirectory: URL) {
        self.init(
            settingsURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/hippocampus/runtime.toml"),
            usageURL: blobDirectory.deletingLastPathComponent().appendingPathComponent("pictures-usage.json"),
            blobDirectory: blobDirectory)
    }

    public func settings() -> SidePictureSettings {
        // Only a regular file this user owns, that no one else may change,
        // can turn side pictures on.
        guard let stamp = Self.ownStamp(settingsURL) else { return SidePictureSettings() }
        return lock.withLock {
            if let settingsCache, settingsCache.stamp == stamp { return settingsCache.value }
            let value = (try? String(contentsOf: settingsURL, encoding: .utf8)).map(SidePictureSettings.parse)
                ?? SidePictureSettings()
            settingsCache = (stamp, value)
            return value
        }
    }

    public func power() -> (mode: CapturePowerMode, batteryPercent: Int?) {
        (CapturePower.current(), CapturePower.batteryPercent())
    }

    public func disk() -> (availableBytes: Int64?, totalBytes: Int64?) {
        let now = Date()
        if let cached = lock.withLock({ diskCache }), now.timeIntervalSince(cached.at) < 60 { return cached.value }
        let values = try? blobDirectory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey,
        ])
        let available = values?.volumeAvailableCapacityForImportantUsage
            ?? values?.volumeAvailableCapacity.map(Int64.init)
        let value = (available, values?.volumeTotalCapacity.map(Int64.init))
        lock.withLock { diskCache = (now, value) }
        return value
    }

    public func recordedSideBytes() -> (bytes: Int64, measuredAt: Date)? {
        guard let stamp = Self.ownStamp(usageURL) else { return nil }
        return lock.withLock {
            if let usageCache, usageCache.stamp == stamp { return usageCache.value }
            let value: (bytes: Int64, measuredAt: Date)? = (try? Data(contentsOf: usageURL))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { record in
                    (record["side_bytes"] as? NSNumber).map { (Int64(truncating: $0), stamp.modified) }
                }
            usageCache = (stamp, value)
            return value
        }
    }

    /// The file's change time and size when it is a regular file owned by
    /// this user that neither its group nor others may write.
    static func ownStamp(_ url: URL) -> FileStamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_mode & (S_IWGRP | S_IWOTH) == 0
        else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return FileStamp(modified: modified, size: Int64(info.st_size))
    }
}

/// The disk floor (SPEC 6.5): below 10 GB free no new side picture is kept;
/// they resume above 12 GB.
public struct SidePictureDiskFloor: Sendable, Equatable {
    public static let pauseBelowBytes: Int64 = 10_000_000_000
    public static let resumeAboveBytes: Int64 = 12_000_000_000

    public private(set) var paused = false

    public init() {}

    /// Whether side pictures pause with `availableBytes` free. Unknown free
    /// space keeps the last state.
    public mutating func update(availableBytes: Int64?) -> Bool {
        guard let availableBytes else { return paused }
        if paused {
            if availableBytes > Self.resumeAboveBytes { paused = false }
        } else if availableBytes < Self.pauseBelowBytes {
            paused = true
        }
        return paused
    }
}

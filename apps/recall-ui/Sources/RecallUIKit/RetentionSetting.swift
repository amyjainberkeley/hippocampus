import Foundation

/// How long moments are kept, as setup and Preferences › Privacy save it in
/// `retention.json` and the agent's retention worker reads it
/// (`apps/agent/src/retention_worker.rs`). History's last line and Privacy
/// say it: "Older moments are deleted after 90 days." It is read the way the
/// worker reads it, so the window never claims a limit the worker doesn't
/// keep.
public enum RetentionSetting: Equatable, Sendable {
    /// Moments older than this many days are deleted.
    case days(Int)
    /// Kept until the person deletes them.
    case forever

    /// The worker's default when nothing was saved.
    public static let standard = RetentionSetting.days(90)

    /// `retention.json` in the memory's folder, where setup and Preferences
    /// write it and the agent reads it.
    public static var defaultURL: URL? {
        MemoryFolder.url().appendingPathComponent("retention.json")
    }

    /// The setting saved at `url`. A missing file is the 90-day default. Nil
    /// when the file can't be read or isn't one the worker accepts (a
    /// limit saved before it was reviewed, an unknown mode): the worker
    /// deletes nothing then, so nothing is said.
    public static func read(from url: URL?) -> RetentionSetting? {
        guard let url else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .standard
        } catch {
            return nil
        }
        return decode(data)
    }

    /// The setting in a `retention.json`'s bytes, by the worker's rules.
    public static func decode(_ data: Data) -> RetentionSetting? {
        struct Saved: Decodable {
            var schema_version: UInt64?
            var mode: String
            var days: UInt64?
        }
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        if let version = saved.schema_version, version != 1, version != 2 { return nil }
        let setting: RetentionSetting
        switch saved.mode {
        case "forever": setting = .forever
        case "ninetyDays": setting = .days(90)
        case "thirtyDays": setting = .days(30)
        case "sevenDays": setting = .days(7)
        case "custom":
            guard let days = saved.days, (1...365).contains(days) else { return nil }
            setting = .days(Int(days))
        default: return nil
        }
        if case .days = setting, saved.schema_version != 2 { return nil }
        return setting
    }

    /// The days moments are kept, or nil when they are kept until deleted.
    public var days: Int? {
        if case let .days(days) = self { return days }
        return nil
    }
}

/// The folder the memory's own small files sit in, beside the capture
/// status: a development database's folder when one is set, so it never
/// borrows the person's, else Application Support's.
public enum MemoryFolder {
    public static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let database = environment["MCI_DB_PATH"] {
            return URL(fileURLWithPath: database).deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MCI", isDirectory: true)
    }
}

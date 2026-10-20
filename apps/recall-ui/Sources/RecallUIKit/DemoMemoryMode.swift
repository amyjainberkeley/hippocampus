import Foundation

/// Whether the window reads Demo Memory, the made-up week for the launch
/// video and screenshots (SPEC-DELTA 6), instead of the person's own. The app
/// says so when it opens the window (`DemoMemory` in HippocampusKit sets the
/// variable, with the demo store's path); the window then shows a small Demo
/// tag by its title, and its calendar is the week's made-up one. The
/// person's own memory and calendar are never touched.
public enum DemoMemoryMode {
    /// Set to "1" by the app in the window's environment while Demo Memory is
    /// in use; never set otherwise.
    public static let environmentKey = "MCI_DEMO_MEMORY"

    /// The made-up calendar's file, beside the demo store.
    public static let calendarFileName = "demo-calendar.json"

    /// Whether `environment` says the window reads Demo Memory.
    public static func isOn(environment: [String: String]) -> Bool {
        environment[environmentKey] == "1"
    }

    /// Demo Memory's folder, the one its store is in, while the window reads
    /// it; nil otherwise.
    public static func folder(environment: [String: String]) -> URL? {
        guard isOn(environment: environment), let path = environment["MCI_DB_PATH"], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }

    /// The calendar the window reads: the made-up week's while it reads Demo
    /// Memory, and `fallback`, the person's own, otherwise. Never both: on
    /// Demo Memory nothing asks macOS for the person's calendar.
    public static func calendarReader(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallback: @autoclosure () -> any CalendarReader
    ) -> any CalendarReader {
        guard let folder = folder(environment: environment) else { return fallback() }
        return DemoCalendar(url: folder.appendingPathComponent(calendarFileName))
    }
}

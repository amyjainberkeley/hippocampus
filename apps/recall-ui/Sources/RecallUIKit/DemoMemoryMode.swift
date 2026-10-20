import Foundation

/// Whether the window reads Demo Memory, the made-up week for the launch
/// video and screenshots (SPEC-DELTA 6), instead of the person's own. The app
/// says so when it opens the window (`DemoMemory` in HippocampusKit sets the
/// variable, with the demo store's path); the window then shows a small Demo
/// tag by its title. The person's own memory is never touched.
public enum DemoMemoryMode {
    /// Set to "1" by the app in the window's environment while Demo Memory is
    /// in use; never set otherwise.
    public static let environmentKey = "MCI_DEMO_MEMORY"

    /// Whether `environment` says the window reads Demo Memory.
    public static func isOn(environment: [String: String]) -> Bool {
        environment[environmentKey] == "1"
    }
}

import Foundation

public enum ChildProcessEnvironment {
    public static let forbiddenInheritedNames = [
        "MCI_DB_KEY_HEX",
        "MCI_DB_KEY_FILE",
        "MCI_DEVELOPMENT_FILE_KEY",
        "HIPPOCAMPUS_ENABLE_V2P1",
    ]

    public static func scrubbingReusableKeys(
        from baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = baseEnvironment
        for name in forbiddenInheritedNames {
            environment.removeValue(forKey: name)
        }
        return environment
    }

    public static func makeProcess(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Process {
        let process = Process()
        process.environment = scrubbingReusableKeys(from: baseEnvironment)
        return process
    }
}

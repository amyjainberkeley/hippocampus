import Foundation

@main
struct ChildProcessEnvironmentBehavior {
    static func main() throws {
        let process = ChildProcessEnvironment.makeProcess(baseEnvironment: [
            "SAFE_VALUE": "preserved",
            "MCI_DB_KEY_HEX": String(repeating: "cd", count: 32),
            "MCI_DB_KEY_FILE": "/tmp/dev.key",
            "MCI_DEVELOPMENT_FILE_KEY": "1",
            "HIPPOCAMPUS_ENABLE_V2P1": "1",
        ])
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let received = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        precondition(process.terminationStatus == 0)
        precondition(received.contains("SAFE_VALUE=preserved"))
        for forbidden in ChildProcessEnvironment.forbiddenInheritedNames {
            precondition(!received.contains("\(forbidden)="), "child inherited \(forbidden)")
        }
    }
}

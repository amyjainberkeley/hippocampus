import Foundation
import HippocampusKit

@main
struct ChildProcessEnvironmentBehavior {
    static func main() throws {
        try proveAmbientEnvironmentIsScrubbed()
        try provePreparedEnvironmentIsPreserved()
        proveMalformedPreparedEnvironmentsAreRejected()
        proveOnboardingPreservesDevelopmentKeyAuthority()
        try proveRecallPreservesPreparedDevelopmentAuthority()
    }

    private static func proveAmbientEnvironmentIsScrubbed() throws {
        let received = try run(ChildProcessEnvironment.makeProcess(baseEnvironment: [
            "SAFE_VALUE": "preserved",
            "MCI_DB_KEY_HEX": String(repeating: "ab", count: 32),
            "MCI_DB_KEY_FILE": "/tmp/dev.key",
            "MCI_DEVELOPMENT_FILE_KEY": "1",
            "HIPPOCAMPUS_ENABLE_V2P1": "1",
        ]))

        precondition(received.contains("SAFE_VALUE=preserved"))
        for forbidden in ChildProcessEnvironment.forbiddenInheritedNames {
            precondition(!received.contains("\(forbidden)="), "child inherited \(forbidden)")
        }
    }

    private static func provePreparedEnvironmentIsPreserved() throws {
        let received = try run(try ChildProcessEnvironment.makeProcess(preparedEnvironment: [
            "SAFE_VALUE": "preserved",
            "MCI_DEVELOPMENT_FILE_KEY": "1",
            "MCI_DB_KEY_FILE": "/tmp/fixed-user-owned/dev.key",
        ]))

        precondition(received.contains("SAFE_VALUE=preserved"))
        precondition(received.contains("MCI_DEVELOPMENT_FILE_KEY=1"))
        precondition(received.contains("MCI_DB_KEY_FILE=/tmp/fixed-user-owned/dev.key"))
        precondition(!received.contains("MCI_DB_KEY_HEX="))
    }

    private static func proveMalformedPreparedEnvironmentsAreRejected() {
        expectPreparedEnvironmentError(.rawKeyMaterial, environment: [
            "MCI_DB_KEY_HEX": String(repeating: "ab", count: 32),
        ])
        expectPreparedEnvironmentError(.featureOverride, environment: [
            "HIPPOCAMPUS_ENABLE_V2P1": "1",
        ])
        expectPreparedEnvironmentError(.invalidDevelopmentKeyAuthority, environment: [
            "MCI_DEVELOPMENT_FILE_KEY": "1",
        ])
        expectPreparedEnvironmentError(.invalidDevelopmentKeyAuthority, environment: [
            "MCI_DB_KEY_FILE": "/tmp/orphaned.key",
        ])
    }

    private static func proveOnboardingPreservesDevelopmentKeyAuthority() {
        let keyURL = URL(fileURLWithPath: "/tmp/fixed-user-owned/dev.key")
        let environment = ProcessSupervisorLaunchPlan.onboardingEnvironment(
            baseEnvironment: [:],
            dbPath: URL(fileURLWithPath: "/tmp/mci.sqlite"),
            keyReference: .defaultDatabaseKey,
            developmentKeyMode: DevelopmentFileKeyMode(keyURL: keyURL),
            initialStep: "allowlist"
        )

        precondition(environment["MCI_DEVELOPMENT_FILE_KEY"] == "1")
        precondition(environment["MCI_DB_KEY_FILE"] == keyURL.path)
        precondition(environment["MCI_DB_KEYCHAIN_SERVICE"] == nil)
        precondition(environment["MCI_DB_KEYCHAIN_ACCOUNT"] == nil)
    }

    private static func proveRecallPreservesPreparedDevelopmentAuthority() throws {
        let keyURL = URL(fileURLWithPath: "/tmp/fixed-user-owned/dev.key")
        let agentURL = URL(fileURLWithPath: "/Applications/Hippocampus.app/Contents/MacOS/mci-agent")
        let environment = ProcessSupervisorLaunchPlan.recallEnvironment(
            baseEnvironment: ["MCI_EPHEMERAL_UI_STATE": "1"],
            dbPath: URL(fileURLWithPath: "/tmp/mci.sqlite"),
            keyReference: .defaultDatabaseKey,
            developmentKeyMode: DevelopmentFileKeyMode(keyURL: keyURL),
            initialTab: "search",
            focusEventId: 42,
            openPopup: false,
            agentURL: agentURL
        )

        let received = try run(
            try ChildProcessEnvironment.makeProcess(preparedEnvironment: environment)
        )
        precondition(received.contains("MCI_DEVELOPMENT_FILE_KEY=1"))
        precondition(received.contains("MCI_DB_KEY_FILE=\(keyURL.path)"))
        precondition(received.contains("MCI_INITIAL_TAB=search"))
        precondition(received.contains("MCI_INITIAL_FOCUS_EVENT_ID=42"))
        precondition(received.contains("MCI_EPHEMERAL_UI_STATE=1"))
        precondition(received.contains("MCI_AGENT_PATH=\(agentURL.path)"))
        precondition(!received.contains("MCI_DB_KEY_HEX="))
    }

    private static func expectPreparedEnvironmentError(
        _ expected: ChildProcessEnvironment.PreparedEnvironmentError,
        environment: [String: String]
    ) {
        do {
            _ = try ChildProcessEnvironment.makeProcess(preparedEnvironment: environment)
            preconditionFailure("accepted malformed prepared environment")
        } catch let error as ChildProcessEnvironment.PreparedEnvironmentError {
            precondition(error == expected)
        } catch {
            preconditionFailure("unexpected prepared-environment error: \(error)")
        }
    }

    private static func run(_ process: Process) throws -> String {
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
        return received
    }
}

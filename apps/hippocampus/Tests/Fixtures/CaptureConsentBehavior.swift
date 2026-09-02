import Foundation
import HippocampusKit

@main
struct CaptureConsentBehavior {
    static func main() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let stateURL = sandbox.appendingPathComponent("capture-consent.json")
        let authority = CaptureConsentAuthority(
            stateURL: stateURL,
            ownerProcessID: 4242,
            ownerStartTimeUs: 123_000_456
        )

        try authority.enable(generationID: "generation-7")
        let enabled = try CaptureConsentAuthority.readState(at: stateURL)
        precondition(enabled.enabled)
        precondition(enabled.generation == "generation-7")
        precondition(enabled.ownerProcessID == 4242)
        precondition(enabled.ownerStartTimeUs == 123_000_456)
        precondition(CaptureConsentAuthority.allowsCapture(
            state: enabled,
            ownerIdentityMatches: { $0 == 4242 && $1 == 123_000_456 }
        ))
        precondition(!CaptureConsentAuthority.allowsCapture(
            state: enabled,
            ownerIdentityMatches: { _, _ in false }
        ))

        try authority.disable()
        let disabled = try CaptureConsentAuthority.readState(at: stateURL)
        precondition(!disabled.enabled)
        precondition(disabled.generation == nil)

        precondition(SafariInboxReader.matchesCaptureGeneration(
            payload: ["capture_generation": "generation-7"],
            expected: "generation-7"
        ))
        precondition(!SafariInboxReader.matchesCaptureGeneration(
            payload: ["capture_generation": "generation-6"],
            expected: "generation-7"
        ))

        let generation = try SupervisorProcessGeneration.make(captureEnabled: false)
        let plan = ProcessSupervisorLaunchPlan.make(
            helperURL: URL(fileURLWithPath: "/bundle/MCICaptureHelper"),
            agentURL: URL(fileURLWithPath: "/bundle/mci-agent"),
            dbPath: sandbox.appendingPathComponent("mci.sqlite"),
            keyReference: .defaultDatabaseKey,
            knownSafeAppsURL: nil,
            captureEnabled: false,
            crashReportOptedIn: false,
            generation: generation,
            baseEnvironment: [:]
        )
        precondition(!plan.helperArguments.contains("--capture"))
        precondition(plan.agentEnvironment["MCI_CAPTURE_ENABLED"] == "0")
    }
}

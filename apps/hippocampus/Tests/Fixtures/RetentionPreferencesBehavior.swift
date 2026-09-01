import Foundation
import HippocampusKit

@main
struct RetentionPreferencesBehavior {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            preconditionFailure("usage: RetentionPreferencesBehavior OUTPUT_DIRECTORY")
        }
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let cases: [(String, RetentionPolicy, Int?, String, Int?)] = [
            ("forever", .forever, nil, "forever", nil),
            ("thirty-days", .thirtyDays, nil, "thirtyDays", nil),
            ("seven-days", .sevenDays, nil, "sevenDays", nil),
            ("custom", .custom, 90, "custom", 90),
        ]
        for (name, policy, customDays, expectedMode, expectedDays) in cases {
            let directory = outputDirectory.appendingPathComponent(name, isDirectory: true)
            let retentionURL = directory.appendingPathComponent("retention.json")
            let suiteName = "retention-behavior-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                preconditionFailure("ephemeral defaults")
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = PreferencesStore(
                defaults: defaults,
                retentionURL: retentionURL,
                now: { Date(timeIntervalSince1970: 1_788_220_800) }
            )

            precondition(store.setRetentionPolicy(policy, customDays: customDays))
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: retentionURL))
            guard let json = object as? [String: Any] else {
                preconditionFailure("retention payload object")
            }
            precondition(json["mode"] as? String == expectedMode)
            if let expectedDays {
                precondition(json["days"] as? Int == expectedDays)
            } else {
                precondition(json["days"] is NSNull)
            }
            precondition(json["updated_at"] as? String == "2026-09-01T00:00:00Z")
            let directoryContents = try FileManager.default.contentsOfDirectory(
                atPath: directory.path
            )
            precondition(
                directoryContents == ["retention.json"],
                "atomic writer must not leave temporary siblings"
            )

            let reloaded = PreferencesStore(defaults: defaults, retentionURL: retentionURL)
            precondition(reloaded.retentionPolicy == policy)
            precondition(reloaded.retentionCustomDays == customDays)
        }

        let replacementDirectory = outputDirectory.appendingPathComponent(
            "replacement",
            isDirectory: true
        )
        let replacementURL = replacementDirectory.appendingPathComponent("retention.json")
        let replacementSuite = "retention-replacement-\(UUID().uuidString)"
        guard let replacementDefaults = UserDefaults(suiteName: replacementSuite) else {
            preconditionFailure("replacement defaults")
        }
        defer { replacementDefaults.removePersistentDomain(forName: replacementSuite) }
        let replacementStore = PreferencesStore(
            defaults: replacementDefaults,
            retentionURL: replacementURL,
            now: { Date(timeIntervalSince1970: 1_788_220_800) }
        )
        precondition(replacementStore.setRetentionPolicy(.sevenDays))
        precondition(replacementStore.setRetentionPolicy(.custom, customDays: 90))
        let replacement = try JSONDecoder().decode(
            WorkerRetentionPayload.self,
            from: Data(contentsOf: replacementURL)
        )
        precondition(replacement.mode == "custom")
        precondition(replacement.days == 90)
        let replacementContents = try FileManager.default.contentsOfDirectory(
            at: replacementDirectory,
            includingPropertiesForKeys: nil
        )
        precondition(replacementContents.map(\.lastPathComponent) == ["retention.json"])

        let malformedDirectory = outputDirectory.appendingPathComponent(
            "malformed",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: malformedDirectory,
            withIntermediateDirectories: true
        )
        let malformedURL = malformedDirectory.appendingPathComponent("retention.json")
        try Data("not json".utf8).write(to: malformedURL)
        let malformedSuite = "retention-malformed-\(UUID().uuidString)"
        guard let malformedDefaults = UserDefaults(suiteName: malformedSuite) else {
            preconditionFailure("malformed defaults")
        }
        defer { malformedDefaults.removePersistentDomain(forName: malformedSuite) }
        malformedDefaults.set("days30", forKey: "ai.hippocampus.prefs.retentionPolicy")
        let malformedStore = PreferencesStore(
            defaults: malformedDefaults,
            retentionURL: malformedURL
        )
        precondition(malformedStore.retentionPolicy == .forever)
        precondition(malformedStore.retentionWriteError != nil)
        let malformedContents = try String(contentsOf: malformedURL, encoding: .utf8)
        precondition(malformedContents == "not json")

        let blockedParent = outputDirectory.appendingPathComponent("blocked-parent")
        try Data("not a directory".utf8).write(to: blockedParent)
        let failedSuite = "retention-failed-write-\(UUID().uuidString)"
        guard let failedDefaults = UserDefaults(suiteName: failedSuite) else {
            preconditionFailure("failed-write defaults")
        }
        defer { failedDefaults.removePersistentDomain(forName: failedSuite) }
        let failedStore = PreferencesStore(
            defaults: failedDefaults,
            retentionURL: blockedParent.appendingPathComponent("retention.json")
        )
        precondition(!failedStore.setRetentionPolicy(.sevenDays))
        precondition(failedStore.retentionPolicy == .forever)
        precondition(failedStore.retentionWriteError != nil)

        precondition(
            MenuBarStatus.derive(from: .running, captureEnabled: false) == .idle
        )
        precondition(
            RecordingControl.derive(from: .running, captureEnabled: false) == .start
        )
    }
}

private struct WorkerRetentionPayload: Decodable {
    let mode: String
    let days: Int?
}

import Foundation
import OnboardingKit

@main
struct RetentionPersistenceBehavior {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            preconditionFailure("usage: RetentionPersistenceBehavior OUTPUT_DIRECTORY")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

        let defaultStore = DiskRetentionStore(directory: root.appendingPathComponent("fresh-default"))
        let defaultPolicy = await defaultStore.currentPolicy()
        precondition(defaultPolicy == .ninetyDays)
        try await defaultStore.setPolicy(defaultPolicy, customDays: nil)

        let seed = DiskRetentionStore(directory: root)
        let freshPolicy = await seed.currentPolicy()
        precondition(freshPolicy == .ninetyDays)
        try await seed.setPolicy(.ninetyDays, customDays: nil)
        let reviewedJSON = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("retention.json"))
        ) as! [String: Any]
        precondition(reviewedJSON["schema_version"] as? Int == 2)
        precondition(reviewedJSON["mode"] as? String == "ninetyDays")
        try await seed.setPolicy(.sevenDays, customDays: nil)
        let replacement = DiskRetentionStore(directory: root)
        try await replacement.setPolicy(.custom, customDays: 365)
        let replacementReload = DiskRetentionStore(directory: root)
        let replacementPolicy = await replacementReload.currentPolicy()
        let replacementDays = await replacementReload.currentCustomDays()
        precondition(replacementPolicy == .custom)
        precondition(replacementDays == 365)
        try await replacementReload.setPolicy(.sevenDays, customDays: nil)

        let failures: [CocoaError.Code] = [
            .fileWriteUnknown,
            .fileWriteOutOfSpace,
            .fileWriteNoPermission,
        ]
        for failure in failures {
            let store = DiskRetentionStore(
                directory: root,
                writer: FailingRetentionWriter(code: failure)
            )
            let policyBeforeFailure = await store.currentPolicy()
            precondition(policyBeforeFailure == .sevenDays)
            do {
                try await store.setPolicy(.custom, customDays: 30)
                preconditionFailure("injected write failure was swallowed: \(failure)")
            } catch {
                precondition((error as NSError).code == failure.rawValue)
            }
            let policyAfterFailure = await store.currentPolicy()
            let daysAfterFailure = await store.currentCustomDays()
            precondition(policyAfterFailure == .sevenDays)
            precondition(daysAfterFailure == nil)

            let viewModel = RetentionViewModel(store: store)
            viewModel.selectedPolicy = .thirtyDays
            var advanced = false
            let saved = await viewModel.saveThen { advanced = true }
            precondition(!saved)
            precondition(!advanced)
            precondition(viewModel.saveError != nil)
        }

        for invalidDays in [0, 366] {
            let store = DiskRetentionStore(directory: root)
            do {
                try await store.setPolicy(.custom, customDays: invalidDays)
                preconditionFailure("invalid custom retention was persisted: \(invalidDays)")
            } catch {}
            let policy = await store.currentPolicy()
            precondition(policy == .sevenDays)
        }
        let missingDaysStore = DiskRetentionStore(directory: root)
        do {
            try await missingDaysStore.setPolicy(.custom, customDays: nil)
            preconditionFailure("missing custom retention was persisted")
        } catch {}
        let missingDaysPolicy = await missingDaysStore.currentPolicy()
        precondition(missingDaysPolicy == .sevenDays)

        let invalidPayloads = [
            ("zero", #"{"mode":"custom","days":0}"#),
            ("above-maximum", #"{"mode":"custom","days":366}"#),
            ("missing", #"{"mode":"custom"}"#),
            ("overflow", #"{"mode":"custom","days":18446744073709551616}"#),
        ]
        for (name, payload) in invalidPayloads {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data(payload.utf8).write(
                to: directory.appendingPathComponent("retention.json")
            )
            let store = DiskRetentionStore(directory: directory)
            let policy = await store.currentPolicy()
            let days = await store.currentCustomDays()
            precondition(policy == .forever)
            precondition(days == nil)
        }
    }
}

private struct FailingRetentionWriter: RetentionFileWriting {
    let code: CocoaError.Code

    func write(_ data: Data, to fileURL: URL) throws {
        _ = (data, fileURL)
        throw CocoaError(code)
    }
}

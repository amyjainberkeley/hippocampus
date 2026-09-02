import Foundation
import HippocampusKit

@main
struct BriefModelPresenceBehavior {
    @MainActor
    static func main() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("hippocampus-brief-presence-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        let installedRoot = root.appendingPathComponent("installed")
        let installedModelDir = installedRoot
            .appendingPathComponent(BriefModelPresence.qwen3ModelID)
        let installedModel = installedModelDir
            .appendingPathComponent(BriefModelPresence.qwen3Basename)
        try fileManager.createDirectory(at: installedModel, withIntermediateDirectories: true)

        precondition(
            !BriefModelPresence.isQwen3Installed(modelsDir: installedRoot),
            "a model without tokenizer.json must not be reported as installed"
        )
        try Data("tokenizer".utf8).write(
            to: installedModelDir.appendingPathComponent("tokenizer.json")
        )
        precondition(
            BriefModelPresence.isQwen3Installed(modelsDir: installedRoot),
            "model plus tokenizer.json must be reported as installed"
        )

        let bundleRoot = root.appendingPathComponent("Fixture.bundle")
        let contents = bundleRoot.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        let bundledDir = resources
            .appendingPathComponent("Models")
            .appendingPathComponent(BriefModelPresence.qwen3ModelID)
        let bundledModel = bundledDir.appendingPathComponent(BriefModelPresence.qwen3Basename)
        try fileManager.createDirectory(at: bundledModel, withIntermediateDirectories: true)
        try Data("tokenizer".utf8).write(to: bundledDir.appendingPathComponent("tokenizer.json"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": "ai.hippocampus.fixture",
            "CFBundleName": "Fixture",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1",
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        guard let bundle = Bundle(url: bundleRoot) else {
            preconditionFailure("fixture bundle did not load")
        }

        let seededRoot = root.appendingPathComponent("seeded")
        let outcome = BriefModelPresence.seedBundledQwen3IfNeeded(
            modelsDir: seededRoot,
            bundle: bundle,
            fileManager: fileManager
        )
        precondition(outcome == .seeded, "fixture bundle should seed")
        precondition(
            BriefModelPresence.isQwen3Installed(modelsDir: seededRoot),
            "seeding must copy both the model and tokenizer.json"
        )

        // A first launch must not run the potentially multi-gigabyte model
        // copy on AppKit's main thread. Repeated launch/menu events must join
        // the first request instead of scheduling competing copies.
        let invocation = ProvisioningInvocation()
        let provisioner = BriefModelProvisioner {
            dispatchPrecondition(condition: .notOnQueue(.main))
            await invocation.record()
            try? await Task.sleep(nanoseconds: 100_000_000)
            return .seeded
        }
        provisioner.startIfNeeded()
        provisioner.startIfNeeded()
        precondition(
            provisioner.state == .provisioning,
            "the UI must truthfully report that the bundled model is preparing"
        )
        try? await Task.sleep(nanoseconds: 250_000_000)
        precondition(
            provisioner.state == .ready,
            "a completed seed must make Daily Briefs available without a relaunch"
        )
        let calls = await invocation.calls
        precondition(calls == 1, "duplicate starts must share one provisioning job")

        // A development-lite app has no bundled Qwen model. That is an
        // expected unavailable state, not a misleading failed download.
        let unavailableProvisioner = BriefModelProvisioner {
            .noBundle
        }
        unavailableProvisioner.startIfNeeded()
        try? await Task.sleep(nanoseconds: 50_000_000)
        precondition(
            unavailableProvisioner.state == .unavailable,
            "a missing bundled model must be reported as unavailable"
        )

        // A user can remove Application Support while the app is still
        // running. The menu must detect that loss and restart provisioning
        // instead of leaving a stale enabled Daily Briefs control behind.
        let replacement = ProvisioningInvocation()
        let replacementProvisioner = BriefModelProvisioner(
            isInstalled: { false },
            provision: {
                await replacement.record()
                try? await Task.sleep(nanoseconds: 100_000_000)
                return .seeded
            }
        )
        replacementProvisioner.startIfNeeded()
        try? await Task.sleep(nanoseconds: 150_000_000)
        precondition(replacementProvisioner.state == .ready, "fixture seed should complete")
        replacementProvisioner.refreshIfMissing()
        precondition(
            replacementProvisioner.state == .provisioning,
            "a removed model must immediately leave the ready UI state"
        )
        try? await Task.sleep(nanoseconds: 150_000_000)
        let replacementCalls = await replacement.calls
        precondition(
            replacementCalls == 2,
            "recovery must schedule one replacement provisioning job"
        )
    }
}

private actor ProvisioningInvocation {
    private(set) var calls = 0

    func record() {
        calls += 1
    }
}

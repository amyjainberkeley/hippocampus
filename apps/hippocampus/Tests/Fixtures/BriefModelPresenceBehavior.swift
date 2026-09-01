import Foundation

@main
struct BriefModelPresenceBehavior {
    static func main() throws {
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
    }
}

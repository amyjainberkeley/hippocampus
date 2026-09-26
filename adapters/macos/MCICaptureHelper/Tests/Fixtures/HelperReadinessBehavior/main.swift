import Foundation
import MCICaptureHelperKit

@main
struct HelperReadinessBehavior {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helper-readiness-behavior-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("ready.json")
        let receipt = HelperReadinessReceipt(
            fileURL: file,
            generation: "generation-runtime-1",
            captureEnabled: false
        )

        try receipt.publish()
        let published = try HelperReadinessReceipt.read(from: file)
        precondition(published == receipt)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        precondition(attributes[.posixPermissions] as? Int == 0o600)

        do {
            try receipt.publish()
            preconditionFailure("readiness publication overwrote an existing receipt")
        } catch HelperReadinessError.existingReceipt {
            // Expected: startup receipts are generation-bound and add-only.
        }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(leftovers == ["ready.json"], "readiness publication leaked a temporary file")
    }
}

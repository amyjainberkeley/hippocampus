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

        try proveACaptureReceiptNamesOnlyThePermissionsOff(in: directory)
    }

    /// A capture generation that started with permissions off says which, by
    /// name only: sorted, once each, and nothing else in the file.
    private static func proveACaptureReceiptNamesOnlyThePermissionsOff(in directory: URL) throws {
        let file = directory.appendingPathComponent("capture-ready.json")
        let receipt = HelperReadinessReceipt(fileURL: file, generation: "generation-runtime-2", captureEnabled: true)
        try receipt.publish(permissionsOff: [.screenRecording, .accessibility, .screenRecording])

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        precondition(Set(json?.keys.map { $0 } ?? []) == ["generation", "capture_enabled", "permissions_off"],
                     "a readiness receipt carries its generation, its capture setting and permission names only")
        precondition(json?["generation"] as? String == "generation-runtime-2")
        precondition(json?["capture_enabled"] as? Bool == true)
        precondition(json?["permissions_off"] as? [String] == ["accessibility", "screenRecording"],
                     "permission names are sorted and listed once")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        precondition(attributes[.posixPermissions] as? Int == 0o600)
        let readBack = try HelperReadinessReceipt.read(from: file)
        precondition(readBack.permissionsOff == ["accessibility", "screenRecording"])
    }
}

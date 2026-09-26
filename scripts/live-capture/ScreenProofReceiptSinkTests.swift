import Foundation
import Darwin

@main
enum ScreenProofReceiptSinkTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("proof-sink-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("receipt.jsonl")
        let oldMask = umask(0)
        defer { umask(oldMask) }
        let sink = try ScreenProofReceiptSink(url: url)
        let bytes = Data("{\"record_type\":\"fixture_ready\"}\n".utf8)
        try sink.append(bytes)
        try sink.append(bytes)
        let appended = try Data(contentsOf: url)
        precondition(appended == bytes + bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        do {
            _ = try ScreenProofReceiptSink(url: url)
            preconditionFailure("must not overwrite an existing receipt")
        } catch {}
        let alias = directory.appendingPathComponent("alias.jsonl")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        do {
            _ = try ScreenProofReceiptSink(url: alias)
            preconditionFailure("must not follow a symlink")
        } catch {}
        let preserved = try Data(contentsOf: url)
        precondition(preserved == bytes + bytes)
        print("ScreenProofReceiptSinkTests passed")
    }
}

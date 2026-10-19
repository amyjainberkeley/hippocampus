import Foundation
import XCTest

@testable import MCICaptureHelperKit

final class HelperReadinessReceiptTests: XCTestCase {
    func test_complete_arguments_parse_generation_bound_receipt() throws {
        let receipt = try HelperReadinessReceipt.parse(arguments: [
            "mci-capture-helper",
            "--readiness-file", "/tmp/helper-ready.json",
            "--generation", "generation-17",
            "--capture",
        ])

        XCTAssertEqual(receipt?.fileURL.path, "/tmp/helper-ready.json")
        XCTAssertEqual(receipt?.generation, "generation-17")
        XCTAssertEqual(receipt?.captureEnabled, true)
    }

    func test_partial_arguments_fail_closed() {
        XCTAssertThrowsError(try HelperReadinessReceipt.parse(arguments: [
            "mci-capture-helper", "--readiness-file", "/tmp/helper-ready.json",
        ]))
    }

    func test_publish_is_add_only_mode_600_and_round_trips_exact_generation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helper-readiness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ready.json")
        let receipt = HelperReadinessReceipt(
            fileURL: file,
            generation: "generation-42",
            captureEnabled: true
        )

        try receipt.publish()

        XCTAssertEqual(try HelperReadinessReceipt.read(from: file), receipt)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        XCTAssertThrowsError(try receipt.publish(), "readiness must not overwrite an existing receipt")
    }

    /// A capture generation that started with a permission off reads
    /// nothing while it is off. Its receipt says so, so the app never takes a
    /// start for done while one is off. Only a permission's name can be
    /// written there: the list is typed, so nothing else (a window title,
    /// say) can reach the file.
    func test_publish_names_the_permissions_found_off_at_startup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helper-readiness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ready.json")
        let receipt = HelperReadinessReceipt(fileURL: file, generation: "generation-43", captureEnabled: true)

        try receipt.publish(permissionsOff: [TCCSurface.screenRecording, .accessibility, .screenRecording])

        let read = try HelperReadinessReceipt.read(from: file)
        XCTAssertEqual(read.permissionsOff, ["accessibility", "screenRecording"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["permissions_off"] as? [String], ["accessibility", "screenRecording"])
        XCTAssertEqual(Set(json.keys), ["generation", "capture_enabled", "permissions_off"], "content-free")
    }

    /// A receipt from before the field reads as no permission off.
    func test_a_receipt_without_permissions_reads_as_none_off() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helper-readiness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ready.json")
        try Data(#"{"generation":"generation-44","capture_enabled":true}"#.utf8).write(to: file)

        XCTAssertEqual(try HelperReadinessReceipt.read(from: file).permissionsOff, [])
    }
}

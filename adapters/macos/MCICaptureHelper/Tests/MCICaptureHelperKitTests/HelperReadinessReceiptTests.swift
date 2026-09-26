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
}

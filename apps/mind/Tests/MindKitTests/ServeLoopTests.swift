import Foundation
import XCTest

/// Runs the built `hippocampus-mind --serve` binary: the loop must answer
/// requests in order (it once deadlocked by blocking the main actor).
final class ServeLoopTests: XCTestCase {
    func testTheServeLoopAnswersEachRequestInOrder() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let binary = products.appendingPathComponent("hippocampus-mind")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("hippocampus-mind not built next to the tests")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--serve"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer { process.terminate() }
        // Malformed requests need no model, so this runs on any Mac.
        input.fileHandleForWriting.write(Data("not json\n{\"id\":7,\"task\":\"nope\",\"input\":{}}\n".utf8))
        let deadline = Date().addingTimeInterval(20)
        var text = ""
        while text.split(separator: "\n").count < 3, Date() < deadline {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            text += String(decoding: chunk, as: UTF8.self)
        }
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, text)
        XCTAssertTrue(lines[0].contains("\"ready\":true"))
        XCTAssertTrue(lines[1].contains("bad_request"))
        XCTAssertTrue(lines[2].contains("\"id\":7"))
    }
}

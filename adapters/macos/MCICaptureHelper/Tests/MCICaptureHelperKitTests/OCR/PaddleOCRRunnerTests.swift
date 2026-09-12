import CoreGraphics
import CoreVideo
import Foundation
import XCTest
@testable import MCICaptureHelperKit

final class PaddleOCRRunnerTests: XCTestCase {
    private func input(roi: CGRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)) throws -> OCREngineInput {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 100, 80, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<80 { for x in 0..<100 {
            let offset = y*stride+x*4
            bytes[offset] = UInt8(x); bytes[offset+1] = UInt8(y)
            bytes[offset+2] = 255; bytes[offset+3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return OCREngineInput(pixelBuffer: buffer, roi: roi)
    }

    private func fixture(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("worker")
        try ("#!/usr/bin/python3\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testOnlyCroppedPixelsCrossPipeAndBoxesMapToOriginalImage() async throws {
        let executable = try fixture("""
        import sys,struct,json,os
        data=sys.stdin.buffer.read()
        assert len(data)==54+50*40*4
        assert struct.unpack('<ii',data[18:26])==(50,-40)
        assert list(data[54:58])==[25,20,255,255]
        assert list(data[-4:])==[74,59,255,255]
        assert 'HIPPO_TEST_SECRET' not in os.environ
        print(json.dumps({'version':1,'lines':[{'text':'Synthetic chat','confidence':0.95,'box':[0.1,0.2,0.8,0.25]}]}))
        """)
        let runner = PaddleOCRRunner(executableURL: executable)
        let result = await runner.recognize(input: try input(), timeoutMs: 4000)
        XCTAssertFalse(result.timedOut)
        let line = try XCTUnwrap(result.recognizedLines.first)
        XCTAssertEqual(line.text, "Synthetic chat")
        XCTAssertEqual(line.boundingBox.minX, 0.3, accuracy: 0.00001)
        XCTAssertEqual(line.boundingBox.minY, 0.35, accuracy: 0.00001)
        XCTAssertEqual(line.boundingBox.width, 0.4, accuracy: 0.00001)
        XCTAssertEqual(line.boundingBox.height, 0.125, accuracy: 0.00001)
    }

    func testMalformedGeometryAndProcessFailurePublishNoText() async throws {
        for reply in [
            "{'version':1,'lines':[{'text':'bad','confidence':0.9,'box':[-1,0,1,1]}]}",
            "{'version':2,'lines':[]}",
            "{'version':1,'lines':[{'text':'bad','confidence':2,'box':[0,0,1,1]}]}"
        ] {
            let executable = try fixture("import sys,json\nsys.stdin.buffer.read()\nprint(json.dumps(\(reply)))\n")
            let result = await PaddleOCRRunner(executableURL: executable).recognize(input: try input(), timeoutMs: 4000)
            XCTAssertFalse(result.timedOut)
            XCTAssertTrue(result.recognizedLines.isEmpty)
        }
        let executable = try fixture("import sys\nsys.stdin.buffer.read()\nprint('{\"version\":1,\"lines\":[]}')\nsys.exit(1)")
        let result = await PaddleOCRRunner(executableURL: executable).recognize(input: try input(), timeoutMs: 4000)
        XCTAssertTrue(result.recognizedLines.isEmpty)
    }

    func testHungChildIsKilledAndLaneBecomesAvailable() async throws {
        let executable = try fixture("import time\ntime.sleep(60)\n")
        let runner = PaddleOCRRunner(executableURL: executable)
        let start = ContinuousClock.now
        let result = await runner.recognize(input: try input(), timeoutMs: 150)
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.recognizedLines.isEmpty)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let available = await runner.waitUntilAvailable(timeoutMs: 2000)
        XCTAssertTrue(available, "Timeout must kill/reap the child, not leave the lane quarantined")
    }

    func testStoppingWorkerReapsChildWithoutWaitingForLongOCRDeadline() async throws {
        let executable = try fixture("import time\ntime.sleep(60)\n")
        let runner = PaddleOCRRunner(executableURL: executable)
        let worker = VisionOCRWorker(engine: runner, timeoutMs: 12_000)
        await worker.start()
        await worker.submit(input: try input(), completion: { _ in })
        try await Task.sleep(for: .milliseconds(150))
        let start = ContinuousClock.now
        await worker.stopAndDrain()
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let available = await runner.waitUntilAvailable(timeoutMs: 1000)
        XCTAssertTrue(available)
    }

    func testMissingExecutableReturnsWithoutCrash() async throws {
        let result = await PaddleOCRRunner(executableURL: URL(fileURLWithPath: "/nonexistent/ocr-worker"))
            .recognize(input: try input(), timeoutMs: 1000)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.recognizedLines.isEmpty)
    }

    func testOversizedReplyIsRejectedAndChildReaped() async throws {
        let executable = try fixture("import sys\nsys.stdin.buffer.read()\nsys.stdout.write('x'*1100000)\n")
        let runner = PaddleOCRRunner(executableURL: executable)
        let result = await runner.recognize(input: try input(),timeoutMs: 3000)
        XCTAssertTrue(result.recognizedLines.isEmpty)
        let available = await runner.waitUntilAvailable(timeoutMs: 1000)
        XCTAssertTrue(available)
    }

    func testInvalidROIIsNeverSentToWorker() async throws {
        let executable = try fixture("raise RuntimeError('must not start')")
        let runner = PaddleOCRRunner(executableURL: executable)
        let result = await runner.recognize(input: try input(roi: CGRect(x: -0.1,y: 0,width: 1,height: 1)),timeoutMs: 2000)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.recognizedLines.isEmpty)
    }
}

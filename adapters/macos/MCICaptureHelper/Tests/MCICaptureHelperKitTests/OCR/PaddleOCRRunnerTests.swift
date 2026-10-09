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

    // MARK: - Persistent worker

    private static let serveLoop = """
    import sys,struct,json,os
    def frame():
        header=sys.stdin.buffer.read(54)
        if not header: return None
        length=struct.unpack('<I',header[34:38])[0]
        return header+sys.stdin.buffer.read(length)

    """

    func testPersistentWorkerStartsOnceAndAnswersEveryFrame() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: marker) }
        let executable = try fixture(Self.serveLoop + """
        assert sys.argv[1:]==['--serve']
        open('\(marker.path)','a').write('start\\n')
        print(json.dumps({'version':1,'ready':True}),flush=True)
        n=0
        while frame():
            n+=1
            print(json.dumps({'version':1,'lines':[{'text':'frame %d'%n,'confidence':0.9,'box':[0.1,0.2,0.8,0.25]}]}),flush=True)
        """)
        let runner = PaddleOCRRunner(executableURL: executable, persistent: true)
        addTeardownBlock { runner.stop() }
        for expected in ["frame 1", "frame 2", "frame 3"] {
            let result = await runner.recognize(input: try input(), timeoutMs: 4000)
            XCTAssertFalse(result.timedOut)
            XCTAssertEqual(result.recognizedLines.map(\.text), [expected])
            XCTAssertEqual(try XCTUnwrap(result.recognizedLines.first).boundingBox.minX, 0.3, accuracy: 0.00001)
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "start\n")
    }

    func testSlowStartTimesOutWithoutRestartingThenServes() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: marker) }
        let executable = try fixture(Self.serveLoop + """
        import time
        open('\(marker.path)','a').write('start\\n')
        time.sleep(0.6)
        print(json.dumps({'version':1,'ready':True}),flush=True)
        while frame():
            print(json.dumps({'version':1,'lines':[{'text':'warm','confidence':0.9,'box':[0,0,1,1]}]}),flush=True)
        """)
        let runner = PaddleOCRRunner(executableURL: executable, persistent: true)
        addTeardownBlock { runner.stop() }
        let first = await runner.recognize(input: try input(), timeoutMs: 150)
        XCTAssertTrue(first.timedOut, "a cold worker misses the first deadline")
        try await Task.sleep(for: .milliseconds(700))
        let second = await runner.recognize(input: try input(), timeoutMs: 4000)
        XCTAssertEqual(second.recognizedLines.map(\.text), ["warm"])
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "start\n",
                       "the warming worker must not be killed and restarted")
    }

    func testLateReplyIsDrainedNotAttributedToTheNextFrame() async throws {
        let executable = try fixture(Self.serveLoop + """
        import time
        print(json.dumps({'version':1,'ready':True}),flush=True)
        n=0
        while frame():
            n+=1
            if n==2: time.sleep(0.5)
            print(json.dumps({'version':1,'lines':[{'text':'frame %d'%n,'confidence':0.9,'box':[0,0,1,1]}]}),flush=True)
        """)
        let runner = PaddleOCRRunner(executableURL: executable, persistent: true)
        addTeardownBlock { runner.stop() }
        let warm = await runner.recognize(input: try input(), timeoutMs: 4000)
        XCTAssertEqual(warm.recognizedLines.map(\.text), ["frame 1"])
        let slow = await runner.recognize(input: try input(), timeoutMs: 200)
        XCTAssertTrue(slow.timedOut)
        let next = await runner.recognize(input: try input(), timeoutMs: 4000)
        XCTAssertEqual(next.recognizedLines.map(\.text), ["frame 3"], "frame 2's late reply is drained, not reused")
    }

    func testRefusedFrameKeepsWorkerAndCrashedWorkerIsReplaced() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: marker) }
        let executable = try fixture(Self.serveLoop + """
        open('\(marker.path)','a').write('start\\n')
        print(json.dumps({'version':1,'ready':True}),flush=True)
        n=0
        while frame():
            n+=1
            if n==1: print(json.dumps({'version':1,'failed':True}),flush=True)
            elif n==2: print(json.dumps({'version':1,'lines':[{'text':'ok','confidence':0.9,'box':[0,0,1,1]}]}),flush=True)
            else: sys.exit(3)
        """)
        let runner = PaddleOCRRunner(executableURL: executable, persistent: true)
        addTeardownBlock { runner.stop() }
        let refused = await runner.recognize(input: try input(), timeoutMs: 4000)
        XCTAssertFalse(refused.timedOut)
        XCTAssertTrue(refused.recognizedLines.isEmpty)
        let ok = await runner.recognize(input: try input(), timeoutMs: 4000)
        XCTAssertEqual(ok.recognizedLines.map(\.text), ["ok"])
        let crashed = await runner.recognize(input: try input(), timeoutMs: 4000)
        XCTAssertTrue(crashed.recognizedLines.isEmpty)
        let replaced = await runner.recognize(input: try input(), timeoutMs: 4000)
        XCTAssertTrue(replaced.recognizedLines.isEmpty, "the replacement refuses its first frame")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "start\nstart\n")
    }

    func testPersistentOversizedReplyAndMalformedReadyAreRejected() async throws {
        for body in [
            "print(json.dumps({'version':1,'ready':True}),flush=True)\nframe()\nsys.stdout.write('x'*1100000)\nsys.stdout.flush()\nframe()",
            "print('{\"version\":2}',flush=True)\nframe()",
        ] {
            let runner = PaddleOCRRunner(executableURL: try fixture(Self.serveLoop + body), persistent: true)
            let result = await runner.recognize(input: try input(), timeoutMs: 3000)
            XCTAssertTrue(result.recognizedLines.isEmpty)
            runner.stop()
        }
    }

    func testStopEndsPersistentWorker() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: marker) }
        let executable = try fixture(Self.serveLoop + """
        print(json.dumps({'version':1,'ready':True}),flush=True)
        open('\(marker.path)','w').write(str(os.getpid()))
        while frame():
            print(json.dumps({'version':1,'lines':[]}),flush=True)
        """)
        let runner = PaddleOCRRunner(executableURL: executable, persistent: true)
        _ = await runner.recognize(input: try input(), timeoutMs: 4000)
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
        runner.stop()
        let gone = ContinuousClock.now.advanced(by: .seconds(3))
        while kill(pid, 0) == 0, ContinuousClock.now < gone {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "the worker must be killed and reaped after stop")
        let after = await runner.recognize(input: try input(), timeoutMs: 1000)
        XCTAssertTrue(after.recognizedLines.isEmpty)
    }
}

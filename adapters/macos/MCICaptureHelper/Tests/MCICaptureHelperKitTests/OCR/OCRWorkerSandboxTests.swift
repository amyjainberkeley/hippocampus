import CoreGraphics
import CoreVideo
import Foundation
import XCTest
@testable import MCICaptureHelperKit

/// The sandbox the OCR worker runs in: what it closes, how it is launched,
/// and that the worker never starts without it.
final class OCRWorkerSandboxTests: XCTestCase {
    private func input() throws -> OCREngineInput {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &pixels),
                       kCVReturnSuccess)
        return OCREngineInput(pixelBuffer: try XCTUnwrap(pixels), roi: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func fixture(_ body: String) throws -> URL {
        let url = try temporaryFolder().appendingPathComponent("worker")
        try ("#!/usr/bin/python3\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// The person's ~/Library is the account's, not HOME: the worker's own
    /// environment has none, so that is where its libraries would write.
    func testTheWorkerCannotWriteOnnxRuntimesOrCFNetworksFoldersInTheAccountHome() async throws {
        let home = URL(fileURLWithPath: OCRWorkerSandbox.realPath(try temporaryFolder().path))
        for folder in ["Library/Caches", "Library/HTTPStorages", "Library/Application Support/Microsoft/DeveloperTools"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
        let executable = try fixture("""
        import json,os,sys
        sys.stdin.buffer.read()
        home = \(String(reflecting: home.path))
        made = []
        for folder in ['Library/Caches/hippocampus-ocr', 'Library/HTTPStorages/hippocampus-ocr',
                       'Library/Application Support/Microsoft/DeveloperTools/.onnxruntime', 'Library/Caches/other']:
            try:
                os.mkdir(os.path.join(home, folder))
                made.append(folder.split('/')[-1])
            except PermissionError:
                pass
        print(json.dumps({'version':1,'lines':[{'text':'made ' + ' '.join(made),'confidence':0.9,'box':[0.1,0.2,0.8,0.25]}]}))
        """)
        let runner = PaddleOCRRunner(executableURL: executable, sandbox: OCRWorkerSandbox(accountHome: home.path))
        let result = await runner.recognize(input: try input(), timeoutMs: 10_000)
        XCTAssertEqual(result.recognizedLines.map(\.text), ["made other"])
    }

    /// Fail closed: without sandbox-exec the worker never starts.
    func testWithoutItsSandboxTheWorkerNeverStarts() async throws {
        let marker = try temporaryFolder().appendingPathComponent("started")
        let executable = try fixture("""
        import json,sys
        open(\(String(reflecting: marker.path)),'w').write('started')
        print(json.dumps({'version':1,'ready':True}),flush=True)
        sys.stdin.buffer.read()
        """)
        let missing = OCRWorkerSandbox(launcherPath: "/nonexistent/sandbox-exec")
        for persistent in [true, false] {
            let runner = PaddleOCRRunner(executableURL: executable, persistent: persistent, sandbox: missing)
            let result = await runner.recognize(input: try input(), timeoutMs: 2000)
            runner.stop()
            XCTAssertTrue(result.recognizedLines.isEmpty)
            XCTAssertFalse(result.timedOut)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the worker ran without its sandbox")
    }

    func testTheLaunchIsSandboxExecWithTheProfileThenTheWorker() throws {
        let worker = try fixture("print('never run')\n")
        let process = Process()
        let sandbox = OCRWorkerSandbox(accountHome: "/Users/someone")
        XCTAssertTrue(sandbox.prepare(process, worker: worker, arguments: ["--serve"], threads: 2))
        XCTAssertEqual(process.executableURL?.path, "/usr/bin/sandbox-exec")
        XCTAssertEqual(process.arguments, ["-D", "ACCOUNT_HOME=/Users/someone", "-p", sandbox.profile,
                                           worker.path, "--serve"])
        XCTAssertEqual(process.environment, ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1",
                                             "OMP_NUM_THREADS": "2", "OPENBLAS_NUM_THREADS": "1",
                                             "ORT_DISABLE_TELEMETRY": "1"])
        for rule in ["(deny network-outbound)", "(deny network-inbound)", "(deny network-bind)",
                     "(deny mach-lookup (global-name \"com.apple.dnssd.service\"))"] {
            XCTAssertTrue(sandbox.profile.contains(rule), rule)
        }
        XCTAssertFalse(sandbox.profile.contains("/Users/someone"), "paths go in as parameters, never as profile text")
    }

    func testTheAccountHomeComesFromTheUserDatabase() throws {
        let home = try XCTUnwrap(FileManager.default.homeDirectory(forUser: NSUserName()))
        XCTAssertEqual(OCRWorkerSandbox.realAccountHome(), OCRWorkerSandbox.realPath(home.path))
        XCTAssertEqual(OCRWorkerSandbox.realPath("/var/empty"), "/private/var/empty")
    }
}

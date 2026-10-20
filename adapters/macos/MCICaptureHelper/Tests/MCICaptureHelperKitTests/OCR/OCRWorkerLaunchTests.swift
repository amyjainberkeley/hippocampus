import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import XCTest
import MCICaptureHelperKit

/// The OCR worker starts with ONNX Runtime's telemetry off and with no
/// network at all (reports/e2e, finding S1), through the public launch the
/// helper and the window use. Stand-in workers report what they can reach
/// from inside the launch; a loopback listener the test opens shows whether
/// a connection ever got through.
final class OCRWorkerLaunchTests: XCTestCase {
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

    /// A TCP listener on 127.0.0.1, and whether anything connected to it.
    private final class LoopbackListener {
        let descriptor: Int32
        let port: UInt16

        init() throws {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    Darwin.bind(fd, generic, length) == 0 && Darwin.listen(fd, 8) == 0
                        && Darwin.getsockname(fd, generic, &length) == 0
                }
            }
            guard bound else { Darwin.close(fd); throw POSIXError(.EADDRNOTAVAIL) }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            descriptor = fd
            port = UInt16(bigEndian: address.sin_port)
        }

        var somethingConnected: Bool {
            let client = Darwin.accept(descriptor, nil, nil)
            if client >= 0 { Darwin.close(client); return true }
            return false
        }

        deinit { Darwin.close(descriptor) }
    }

    /// What a stand-in worker can do from inside its launch, as one line.
    private static func probe(port: UInt16) -> String {
        """
        import json,os,socket,struct,sys
        def attempt(action):
            try:
                action()
                return 'open'
            except PermissionError:
                return 'denied'
            except OSError as error:
                return 'error-%d' % error.errno
        def connect():
            socket.create_connection(('127.0.0.1', \(port)), timeout=3).close()
        def bind():
            s = socket.socket()
            s.bind(('127.0.0.1', 0))
            s.close()
        def report():
            return 'telemetry=%s connect=%s bind=%s' % (os.environ.get('ORT_DISABLE_TELEMETRY'), attempt(connect), attempt(bind))
        def reply(text):
            print(json.dumps({'version':1,'lines':[{'text':text,'confidence':0.9,'box':[0.1,0.2,0.8,0.25]}]}),flush=True)

        """
    }

    private static let serveLoop = """
    def frame():
        header=sys.stdin.buffer.read(54)
        if not header: return None
        length=struct.unpack('<I',header[34:38])[0]
        return header+sys.stdin.buffer.read(length)
    print(json.dumps({'version':1,'ready':True}),flush=True)
    while frame():
        reply(report())

    """

    func testTheWarmWorkerRunsWithTelemetryOffAndNoNetwork() async throws {
        let listener = try LoopbackListener()
        let executable = try fixture(Self.probe(port: listener.port) + Self.serveLoop)
        let runner = PaddleOCRRunner(executableURL: executable, persistent: true)
        addTeardownBlock { runner.stop() }
        let result = await runner.recognize(input: try input(), timeoutMs: 10_000)
        XCTAssertEqual(result.recognizedLines.map(\.text), ["telemetry=1 connect=denied bind=denied"])
        XCTAssertFalse(listener.somethingConnected, "the worker reached a socket on this Mac")
    }

    func testTheOneShotWorkerRunsWithTelemetryOffAndNoNetwork() async throws {
        let listener = try LoopbackListener()
        let executable = try fixture(Self.probe(port: listener.port) + "sys.stdin.buffer.read()\nreply(report())\n")
        let result = await PaddleOCRRunner(executableURL: executable).recognize(input: try input(), timeoutMs: 10_000)
        XCTAssertEqual(result.recognizedLines.map(\.text), ["telemetry=1 connect=denied bind=denied"])
        XCTAssertFalse(listener.somethingConnected, "the worker reached a socket on this Mac")
    }

}

import CoreGraphics
import CoreVideo
import Darwin
import Foundation

/// Bundled open-source OCR, confined to the already admitted pixel ROI. A child
/// receives one BMP over anonymous pipes; neither pixels nor text touch disk.
/// The shared execution lane bounds work; its deadline also kills the child.
public struct PaddleOCRRunner: OCREngine {
    public static let timeoutMs = 30_000
    private let lane: VisionOCRExecutionLane
    private let control: PaddleOCRProcessControl

    public static var bundledExecutableURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/HippocampusOCR/hippocampus-ocr")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    public init(executableURL: URL) {
        let control = PaddleOCRProcessControl()
        self.control = control
        lane = VisionOCRExecutionLane(label: "com.hippocampus.capture.paddle-ocr") { input, _, deadline in
            Self.perform(input: input, executableURL: executableURL, deadline: deadline, control: control)
        }
    }

    public func stop() { control.stop() }

    public func recognize(input: OCREngineInput, timeoutMs: Int) async -> OCRResult {
        await lane.recognize(input: input, languages: [], timeoutMs: timeoutMs)
    }

    public func waitUntilAvailable(timeoutMs: Int) async -> Bool {
        await lane.waitUntilIdle(timeoutMs: timeoutMs)
    }

    private static func perform(input: OCREngineInput, executableURL: URL, deadline: DispatchTime, control: PaddleOCRProcessControl) -> OCRResult {
        let empty = OCRResult(recognizedLines: [], durationMs: 0, timedOut: false)
        guard let image = PaddleOCRImage(input: input), DispatchTime.now() < deadline else { return empty }
        let process = Process()
        process.executableURL = executableURL
        // Never inherit provider credentials, Python paths, or user model overrides.
        process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1",
                               "OMP_NUM_THREADS": "2", "OPENBLAS_NUM_THREADS": "2"]
        let inputPipe = Pipe(), outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        var timerResumed = false
        timer.setEventHandler {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        defer {
            if !timerResumed { timer.resume() }
            timer.cancel()
            control.finish(process)
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
        }
        do {
            guard try control.start(process) else { return empty }
            // A killed/failed worker must not deliver SIGPIPE to the capture helper.
            _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            timer.schedule(deadline: deadline)
            timer.resume()
            timerResumed = true
            try inputPipe.fileHandleForWriting.write(contentsOf: image.bitmap)
            try inputPipe.fileHandleForWriting.close()
            var reply = Data()
            let limit = 1_048_576
            while let chunk = try outputPipe.fileHandleForReading.read(upToCount: min(65536, limit + 1 - reply.count)), !chunk.isEmpty {
                reply.append(chunk)
                guard reply.count <= limit else {
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                    return empty
                }
            }
            process.waitUntilExit()
            guard DispatchTime.now() < deadline else {
                return OCRResult(recognizedLines: [], durationMs: 0, timedOut: true)
            }
            guard process.terminationStatus == 0,
                  let decoded = try? JSONDecoder().decode(Reply.self, from: reply), decoded.version == 1,
                  decoded.lines.count <= 4096 else { return empty }
            var lines: [OCRLine] = []
            for line in decoded.lines {
                guard line.box.count == 4, line.box.allSatisfy(\.isFinite), line.confidence.isFinite,
                      (0...1).contains(line.confidence) else { return empty }
                let b = CGRect(x: line.box[0], y: line.box[1], width: line.box[2], height: line.box[3])
                guard b.width > 0, b.height > 0, CGRect(x: 0,y: 0,width: 1,height: 1).contains(b) else { return empty }
                let r = image.region
                lines.append(OCRLine(text: line.text, boundingBox: CGRect(
                    x: r.minX + b.minX*r.width, y: r.minY + b.minY*r.height,
                    width: b.width*r.width, height: b.height*r.height), confidence: line.confidence))
            }
            return OCRResult(recognizedLines: lines, durationMs: 0, timedOut: false)
        } catch {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            return empty
        }
    }

    private struct Reply: Decodable {
        let version: Int
        let lines: [Line]
        struct Line: Decodable {
            let text: String
            let confidence: Float
            let box: [Double]
        }
    }
}

/// Encode only whole pixels contained in the authorized ROI. Using an inward
/// crop prevents rounding from including neighboring, unapproved pixels.
private struct PaddleOCRImage {
    let bitmap: Data
    let region: CGRect

    init?(input: OCREngineInput) {
        let roi = input.roi
        guard roi.minX.isFinite, roi.minY.isFinite, roi.width.isFinite, roi.height.isFinite,
              roi.width > 0, roi.height > 0, CGRect(x: 0,y: 0,width: 1,height: 1).contains(roi),
              CVPixelBufferGetPixelFormatType(input.pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        let fullW = CVPixelBufferGetWidth(input.pixelBuffer), fullH = CVPixelBufferGetHeight(input.pixelBuffer)
        guard fullW > 0, fullH > 0, fullW <= 3840, fullH <= 3840 else { return nil }
        let x0 = Int(ceil(roi.minX*CGFloat(fullW))), x1 = Int(floor(roi.maxX*CGFloat(fullW)))
        let y0 = Int(ceil((1-roi.maxY)*CGFloat(fullH))), y1 = Int(floor((1-roi.minY)*CGFloat(fullH)))
        let w = x1-x0, h = y1-y0
        guard w > 0, h > 0,
              CVPixelBufferLockBaseAddress(input.pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(input.pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(input.pixelBuffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(input.pixelBuffer)
        guard stride >= fullW*4 else { return nil }
        var data = Data([0x42, 0x4D])
        func append<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        append(UInt32(54+w*h*4)); append(UInt32(0)); append(UInt32(54))
        append(UInt32(40)); append(Int32(w)); append(Int32(-h))
        append(UInt16(1)); append(UInt16(32)); append(UInt32(0)); append(UInt32(w*h*4))
        for _ in 0..<4 { append(UInt32(0)) }
        data.reserveCapacity(54+w*h*4)
        for row in y0..<y1 {
            data.append(base.advanced(by: row*stride+x0*4).assumingMemoryBound(to: UInt8.self), count: w*4)
        }
        bitmap = data
        region = CGRect(x: CGFloat(x0)/CGFloat(fullW), y: CGFloat(fullH-y1)/CGFloat(fullH),
                        width: CGFloat(w)/CGFloat(fullW), height: CGFloat(h)/CGFloat(fullH))
    }
}

/// Stop is permanent, matching VisionOCRWorker's lifetime. Installing the
/// process and checking stop share a lock, so shutdown cannot miss a child
/// that is about to launch. No future start is allowed after stop.
private final class PaddleOCRProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    func start(_ candidate: Process) throws -> Bool {
        try lock.withLock {
            guard !stopped else { return false }
            try candidate.run()
            process = candidate
            return true
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            if let process, process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    func finish(_ candidate: Process) {
        lock.withLock {
            if process === candidate { process = nil }
        }
    }
}

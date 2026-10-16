import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import ImageIO
import MCICaptureHelperKit

/// Reads images with the capture helper's own OCR engines and says what each
/// read cost. Development only: `tools/ocr/screens/bakeoff.py` drives it on
/// synthetic screens.
///
///     OCRQualityProbe IMAGE [WORKER]
///     OCRQualityProbe --serve [--worker WORKER] [--deadline-ms MS] [--pixels-per-point P]
///                             [--plan grid|panes]
///
/// Without a worker the engine is `VisionOCRRunner`, as an unbundled helper
/// reads, with the region plan `--plan` names (the helper's own by default);
/// with one it is `PaddleOCRRunner`, kept warm in `--serve` as the helper
/// keeps it. The region is the whole frame, as for the first read of a
/// focused window. The deadline is the helper's for that engine unless
/// `--deadline-ms` says otherwise.
///
/// `--serve` answers each image path read from stdin with one JSON line: the
/// frame's size, the lines with normalized bottom-left boxes, the separators,
/// wall seconds, the regions Vision read, and the CPU seconds, CPU energy and
/// peak memory of this process and of its worker child for that read.
@main struct OCRQualityProbe {
    static func main() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "--serve" else {
            guard arguments.count == 1 || arguments.count == 2 else { throw ProbeError.arguments }
            try await once(image: URL(fileURLWithPath: arguments[0]),
                           worker: arguments.count == 2 ? URL(fileURLWithPath: arguments[1]) : nil)
            return
        }
        arguments.removeFirst()
        var worker: URL?
        var deadlineMs: Int?
        var pixelsPerPoint: CGFloat = 2
        var plan = VisionOCRRunner.RegionPlan.grid
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            guard let value = arguments.first else { throw ProbeError.arguments }
            arguments.removeFirst()
            switch flag {
            case "--worker": worker = URL(fileURLWithPath: value)
            case "--deadline-ms": deadlineMs = Int(value)
            case "--pixels-per-point": pixelsPerPoint = CGFloat(Double(value) ?? 2)
            case "--plan":
                guard value == "grid" || value == "panes" else { throw ProbeError.arguments }
                plan = value == "panes" ? .panes : .grid
            default: throw ProbeError.arguments
            }
        }
        try await serve(worker: worker, deadlineMs: deadlineMs, pixelsPerPoint: pixelsPerPoint, plan: plan)
    }

    /// The original one-shot form: text and confidence only.
    static func once(image url: URL, worker: URL?) async throws {
        let buffer = try pixelBuffer(url)
        let engine: any OCREngine = worker.map { PaddleOCRRunner(executableURL: $0) } ?? VisionOCRRunner()
        let budget = worker == nil ? VisionOCRWorker.defaultTimeoutMs : PaddleOCRRunner.timeoutMs
        let result = await engine.recognize(
            input: OCREngineInput(pixelBuffer: buffer, roi: CGRect(x: 0, y: 0, width: 1, height: 1)),
            timeoutMs: budget)
        _ = await engine.waitUntilAvailable(timeoutMs: 2000)
        let output: [String: Any] = ["seconds": Double(result.durationMs) / 1000, "timed_out": result.timedOut,
                                     "lines": result.recognizedLines.map { ["text": $0.text, "confidence": $0.confidence] }]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
    }

    static func serve(worker: URL?, deadlineMs: Int?, pixelsPerPoint: CGFloat,
                      plan: VisionOCRRunner.RegionPlan) async throws {
        let regions = RegionLog()
        let engine: any OCREngine
        if let worker {
            let paddle = PaddleOCRRunner(executableURL: worker, persistent: true)
            paddle.prewarm()
            engine = paddle
        } else {
            engine = VisionOCRRunner(plan: plan, regionDidFinish: { region, nanoseconds in
                regions.append(region: region, nanoseconds: nanoseconds)
            })
        }
        defer { engine.stop() }
        let deadline = deadlineMs ?? (worker == nil ? VisionOCRWorker.defaultTimeoutMs : PaddleOCRRunner.timeoutMs)
        while let line = readLine(strippingNewline: true) {
            let path = line.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            let buffer = try pixelBuffer(URL(fileURLWithPath: path))
            regions.reset()
            let before = Usage.now()
            let started = DispatchTime.now()
            let result = await engine.recognize(
                input: OCREngineInput(pixelBuffer: buffer, roi: CGRect(x: 0, y: 0, width: 1, height: 1),
                                      pixelsPerPoint: pixelsPerPoint),
                timeoutMs: deadline)
            let wall = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
            // A timed-out read still owns the lane until Vision returns; its
            // cost belongs to this read.
            _ = await engine.waitUntilAvailable(timeoutMs: 60_000)
            let after = Usage.now()
            let reply: [String: Any] = [
                "image": path,
                "width": CVPixelBufferGetWidth(buffer), "height": CVPixelBufferGetHeight(buffer),
                "seconds": wall, "timed_out": result.timedOut, "deadline_ms": deadline,
                "regions": regions.snapshot(),
                "lines": result.recognizedLines.map { line in
                    ["text": line.text, "confidence": Double(line.confidence),
                     "box": [line.boundingBox.minX, line.boundingBox.minY,
                             line.boundingBox.width, line.boundingBox.height].map { Double($0) }] as [String: Any]
                },
                "separators": result.separators.map { [$0.minX, $0.minY, $0.width, $0.height].map { Double($0) } },
                "helper": after.helper.minus(before.helper),
                "worker": after.worker.minus(before.worker),
            ]
            var data = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        }
    }

    static func pixelBuffer(_ url: URL) throws -> CVPixelBuffer {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width <= 3840, image.height <= 3840 else { throw ProbeError.image }
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferCGImageCompatibilityKey: true,
                                   kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                                  &pixels) == kCVReturnSuccess, let buffer = pixels else { throw ProbeError.image }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width,
                                      height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw ProbeError.image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    enum ProbeError: Error { case arguments, image }
}

/// The regions one Vision read performed, with how long each took.
final class RegionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[String: Double]] = []

    func append(region: CGRect, nanoseconds: UInt64) {
        let entry: [String: Double] = [
            "x": Double(region.minX), "y": Double(region.minY), "w": Double(region.width),
            "h": Double(region.height), "seconds": Double(nanoseconds) / 1e9,
        ]
        lock.withLock { entries.append(entry) }
    }

    func reset() { lock.withLock { entries.removeAll() } }

    func snapshot() -> [[String: Double]] { lock.withLock { entries } }
}

/// CPU time, CPU energy and memory from `proc_pid_rusage`, for this process
/// and for its children (the OCR worker), summed.
struct Usage {
    struct Totals {
        var cpuSeconds = 0.0
        var energyJoules = 0.0
        var footprintMB = 0.0
        var peakFootprintMB = 0.0
        var processes = 0

        func minus(_ earlier: Totals) -> [String: Double] {
            ["cpu_seconds": cpuSeconds - earlier.cpuSeconds,
             "energy_joules": energyJoules - earlier.energyJoules,
             "footprint_mb": footprintMB, "peak_footprint_mb": peakFootprintMB,
             "processes": Double(processes)]
        }
    }

    var helper = Totals()
    var worker = Totals()

    static let ticksToNanoseconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    static func now() -> Usage {
        var usage = Usage()
        add(getpid(), to: &usage.helper)
        for child in children() { add(child, to: &usage.worker) }
        return usage
    }

    static func add(_ pid: pid_t, to totals: inout Totals) {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard status == 0 else { return }
        totals.cpuSeconds += Double(info.ri_user_time + info.ri_system_time) * ticksToNanoseconds / 1e9
        totals.energyJoules += Double(info.ri_energy_nj) / 1e9
        totals.footprintMB += Double(info.ri_phys_footprint) / 1_048_576
        totals.peakFootprintMB += Double(info.ri_lifetime_max_phys_footprint) / 1_048_576
        totals.processes += 1
    }

    /// Child pids, read from a zeroed buffer: libproc has returned both a
    /// count and a byte length here.
    static func children() -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 64)
        let found = buffer.withUnsafeMutableBytes { bytes in
            proc_listchildpids(getpid(), bytes.baseAddress, Int32(bytes.count))
        }
        guard found > 0 else { return [] }
        return buffer.filter { $0 > 0 }
    }
}

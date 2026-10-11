import Foundation

/// Whether Hippocampus can understand (answers, the day's account, the user
/// model) on this Mac: the bundled `hippocampus-mind` reports Apple
/// Intelligence availability on its first line.
public enum UnderstandingAvailability: Equatable, Sendable {
    case available
    /// Apple Intelligence is off in System Settings.
    case turnedOff
    /// Still downloading or preparing.
    case preparing
    /// This Mac or macOS version cannot run it.
    case unsupported
}

public enum UnderstandingProbe {
    /// The sibling binary next to the running executable.
    public static func mindURL(near executable: URL? = Bundle.main.executableURL) -> URL? {
        guard let url = executable?.deletingLastPathComponent().appendingPathComponent("hippocampus-mind"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// Map the ready line's fields to an availability.
    public static func availability(fromReadyLine line: String) -> UnderstandingAvailability {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return .unsupported
        }
        if object["available"] as? Bool == true { return .available }
        switch object["reason"] as? String {
        case "apple_intelligence_off": return .turnedOff
        case "model_not_ready": return .preparing
        default: return .unsupported
        }
    }

    /// Start the binary, read its first line, stop it.
    public static func check(mind: URL? = mindURL(), timeout: TimeInterval = 10) async -> UnderstandingAvailability {
        guard let mind else { return .unsupported }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = mind
                process.arguments = ["--serve"]
                process.environment = ["PATH": "/usr/bin:/bin"]
                let input = Pipe(), output = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else {
                    continuation.resume(returning: .unsupported)
                    return
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                var buffer = Data()
                while !buffer.contains(0x0A) {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                }
                timer.cancel()
                try? input.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                let line = String(decoding: buffer.prefix { $0 != 0x0A }, as: UTF8.self)
                continuation.resume(returning: availability(fromReadyLine: line))
            }
        }
    }
}

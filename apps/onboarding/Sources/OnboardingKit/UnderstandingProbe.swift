import Foundation

/// Whether Hippocampus can understand (answers, the day's account, the user
/// model) on this Mac: the bundled `hippocampus-mind` picks Apple
/// Intelligence or a model served on this Mac (Ollama, LM Studio) when it
/// starts, and says on its first line whether either can answer.
public enum UnderstandingAvailability: Equatable, Sendable {
    /// Apple Intelligence or a model on this Mac answers.
    case available
    /// Neither answers: Apple Intelligence is off or missing and no model
    /// server on this Mac has a usable model. Also a reply it cannot read.
    case noModel
    /// Apple Intelligence is on but still downloading or preparing, and
    /// no model on this Mac answers.
    case preparing
    /// Set to use Apple Intelligence alone, and it is off.
    case turnedOff
    /// Set to use Apple Intelligence alone, on a Mac or macOS that cannot
    /// run it.
    case unsupported
}

public enum UnderstandingProbe {
    /// The sibling binary next to the running executable.
    public static func mindURL(near executable: URL? = Bundle.main.executableURL) -> URL? {
        guard let url = executable?.deletingLastPathComponent().appendingPathComponent("hippocampus-mind"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// Map the ready line's fields to an availability. With no settings
    /// the mind says `needs_apple_intelligence_or_local_model` when neither
    /// answers; the `local_…` reasons come from a model server named in its
    /// settings, and the Apple-only reasons from a setting for Apple alone
    /// (`EngineChoice` in apps/mind).
    public static func availability(fromReadyLine line: String) -> UnderstandingAvailability {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return .noModel
        }
        if object["available"] as? Bool == true { return .available }
        switch object["reason"] as? String {
        case "model_not_ready": return .preparing
        case "apple_intelligence_off": return .turnedOff
        case "needs_macos_26", "device_not_eligible", "unavailable": return .unsupported
        default: return .noModel
        }
    }

    /// The child's environment: `PATH`, and `HOME` so the mind reads the
    /// person's model settings, as the agent starts it.
    static func environment(_ parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin"]
        if let home = parent["HOME"], !home.isEmpty { environment["HOME"] = home }
        return environment
    }

    /// Start the binary, read its first line, stop it.
    public static func check(mind: URL? = mindURL(), timeout: TimeInterval = 10) async -> UnderstandingAvailability {
        guard let mind else { return .noModel }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = mind
                process.arguments = ["--serve"]
                process.environment = Self.environment()
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

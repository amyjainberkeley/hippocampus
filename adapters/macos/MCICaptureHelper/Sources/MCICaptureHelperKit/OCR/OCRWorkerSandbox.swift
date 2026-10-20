import Darwin
import Foundation
import os

/// How every OCR worker starts: with ONNX Runtime's telemetry off, inside a
/// sandbox that has no network.
///
/// The bundled worker carries Microsoft's official ONNX Runtime build. Its
/// 1DS telemetry client is on by default and posts usage events and a device
/// ID from native code, where the worker's Python network guard can't see it
/// (reports/e2e, finding S1). So:
///
/// - `ORT_DISABLE_TELEMETRY=1`, read when ONNX Runtime starts, keeps the
///   uploader, its events and the device ID from being created. worker.py
///   sets it too.
/// - `/usr/bin/sandbox-exec` runs the worker under a profile that denies
///   every network operation and name lookups, so nothing inside it can reach
///   the network, whatever it tries. It also can't write the folders ONNX
///   Runtime and CFNetwork would keep for it in the person's ~/Library.
///   Everything else stays allowed: the worker reads its own bundle and
///   answers over its pipes.
/// - Without sandbox-exec the worker never starts: it fails closed, and the
///   process says so once, on stderr and in the unified log.
///
/// sandbox-exec applies the profile and then executes the worker in the same
/// process, so the pid the caller holds, kills and reaps is the worker's.
package struct OCRWorkerSandbox: Sendable {
    package static let launcherPath = "/usr/bin/sandbox-exec"

    /// The sandbox every product launch uses.
    package static let standard = OCRWorkerSandbox()

    package let launcherPath: String
    /// The account's home from the user database: where ONNX Runtime and
    /// CFNetwork put their folders when the worker's environment has no HOME.
    package let accountHome: String
    /// Rules appended to the profile. Only the test fixtures set them (the
    /// end-to-end harness also closes the real ~/Library to the worker); a
    /// rule added here can't reopen the network for a product launch, which
    /// never sets any.
    package let extraRules: String

    package init(
        launcherPath: String = OCRWorkerSandbox.launcherPath,
        accountHome: String = OCRWorkerSandbox.realAccountHome(),
        extraRules: String = ""
    ) {
        self.launcherPath = launcherPath
        self.accountHome = accountHome
        self.extraRules = extraRules
    }

    /// No network of any kind and no name lookups; nothing of ONNX Runtime's
    /// or CFNetwork's in the person's ~/Library. `ACCOUNT_HOME` is passed as a
    /// parameter, so no path is ever spliced into the profile's text.
    package var profile: String {
        """
        (version 1)
        (allow default)
        (deny network-outbound)
        (deny network-inbound)
        (deny network-bind)
        (deny mach-lookup (global-name "com.apple.dnssd.service"))
        (deny file-write*
            (subpath (string-append (param "ACCOUNT_HOME") "/Library/Caches/hippocampus-ocr"))
            (subpath (string-append (param "ACCOUNT_HOME") "/Library/HTTPStorages/hippocampus-ocr"))
            (subpath (string-append (param "ACCOUNT_HOME")
                "/Library/Application Support/Microsoft/DeveloperTools/.onnxruntime")))
        \(extraRules)
        """
    }

    /// The worker's whole environment. Never the caller's: no provider
    /// credentials, Python paths or model overrides are inherited.
    package static func environment(threads: Int) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1",
         "OMP_NUM_THREADS": String(threads), "OPENBLAS_NUM_THREADS": "1",
         "ORT_DISABLE_TELEMETRY": "1"]
    }

    /// Point `process` at `worker`, run inside the sandbox. False, and the
    /// process is left untouched, when the worker or sandbox-exec is missing:
    /// the worker never runs unsandboxed.
    package func prepare(_ process: Process, worker: URL, arguments: [String], threads: Int) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: worker.path) else { return false }
        guard FileManager.default.isExecutableFile(atPath: launcherPath) else {
            Self.reportMissingLauncher(launcherPath)
            return false
        }
        process.executableURL = URL(fileURLWithPath: launcherPath)
        process.arguments = ["-D", "ACCOUNT_HOME=\(accountHome)", "-p", profile, worker.path] + arguments
        process.environment = Self.environment(threads: threads)
        return true
    }

    /// The home in the user database, with symlinks resolved as the
    /// sandbox's path filters need them. HOME is not consulted: the worker's own
    /// environment has none, so that is the home its libraries fall back to.
    package static func realAccountHome() -> String {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        guard getpwuid_r(getuid(), &record, &buffer, buffer.count, &result) == 0,
              result != nil, let directory = record.pw_dir else { return "" }
        return realPath(String(cString: directory))
    }

    /// `realpath(3)`: Foundation's symlink resolution drops `/private` from
    /// `/private/var/...`, which the kernel's path filters never see.
    package static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static let missingLauncherReported = OSAllocatedUnfairLock(initialState: false)
    private static let logger = Logger(subsystem: "ai.hippocampus", category: "ocr")

    /// Once per process, however many frames ask.
    private static func reportMissingLauncher(_ path: String) {
        let first = missingLauncherReported.withLock { reported in
            defer { reported = true }
            return !reported
        }
        guard first else { return }
        let line = "hippocampus-ocr: not started: \(path) is missing, and the OCR worker never runs "
            + "with the network open. Screen text is not read until it is back.\n"
        FileHandle.standardError.write(Data(line.utf8))
        logger.error("OCR worker not started: the no-network sandbox (\(path, privacy: .public)) is missing")
    }
}

// SPDX-License-Identifier: TBD-private
//
// MCI macOS capture helper — executable entry point.
//
// Per ADR-0007 the helper is launched by the Rust core as a child
// process with an open AF_UNIX socket fd. Phase-1 cycle 3 will wire
// the SCStream lifecycle + the real socket fd ingestion; cycle 2
// (this build) lands a runnable main loop that constructs the
// production cascade with concrete probes + heartbeats `HelperHealth`
// frames to stdout or a CLI-supplied output file.

import Foundation
import MCICaptureHelperKit

// ---------------------------------------------------------------------------
// CLI parse
// ---------------------------------------------------------------------------

struct Args {
    /// Path to write IPC frames to. Defaults to `nil` = stdout.
    /// Cycle 3 replaces this with a `--socket-fd <n>` flag that takes
    /// an inherited file descriptor from the Rust parent.
    var outputPath: String?

    /// Path to the denylist TOML. Defaults to the user-config location;
    /// missing-file ⇒ empty denylist (the cascade fail-safe still fires
    /// on AX-silent / unknown apps per ADR-0013 §7).
    var denylistPath: String

    /// Heartbeat interval seconds. Default 30 per CRS telemetry-gap
    /// memo (2026-05-19).
    var heartbeatSeconds: Int

    /// `--once` — emit one HelperHealth frame and exit. Used in CI
    /// smoke tests.
    var oneShot: Bool
}

func defaultDenylistPath() -> String {
    let fm = FileManager.default
    let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    let mciDir = appSupport?.appendingPathComponent("MCI").appendingPathComponent("denylist.toml")
    return mciDir?.path ?? "/dev/null"
}

func parseArgs(_ argv: [String]) -> Args {
    var args = Args(
        outputPath: nil,
        denylistPath: defaultDenylistPath(),
        heartbeatSeconds: 30,
        oneShot: false
    )
    var i = 1
    while i < argv.count {
        let arg = argv[i]
        switch arg {
        case "--output":
            i += 1
            if i < argv.count { args.outputPath = argv[i] }
        case "--denylist":
            i += 1
            if i < argv.count { args.denylistPath = argv[i] }
        case "--heartbeat-seconds":
            i += 1
            if i < argv.count, let n = Int(argv[i]), n > 0 {
                args.heartbeatSeconds = n
            }
        case "--once":
            args.oneShot = true
        case "--version":
            print("mci-capture-helper \(helperVersion)")
            exit(0)
        case "-h", "--help":
            printUsage()
            exit(0)
        default:
            // Unknown args are accepted silently so future CLI evolution
            // doesn't break a parent that passed something new. In
            // production cycle 3+ we tighten this when the parent
            // contract is locked.
            break
        }
        i += 1
    }
    return args
}

func printUsage() {
    print("""
    mci-capture-helper \(helperVersion)

    Usage: mci-capture-helper [OPTIONS]

      --output <path>           Write IPC frames here. Default: stdout.
      --denylist <path>         Read denylist TOML here. Default:
                                ~/Library/Application Support/MCI/denylist.toml
      --heartbeat-seconds <n>   Emit HelperHealth every n seconds. Default 30.
      --once                    Emit one frame and exit (CI smoke).
      --version                 Print version and exit.
      -h, --help                Print this and exit.
    """)
}

let helperVersion = "0.0.2-phase1-cycle2-iter5"

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

let args = parseArgs(CommandLine.arguments)

// ADR-0013 Amendment 1 §4 — live capture is DEFAULT-OFF / dev-only.
// `captureEnabled` is true ONLY if the non-default `--capture` flag was
// explicitly passed. The default path never constructs an `SCStream`.
let captureOptions = CaptureLaunchOptions.parse(CommandLine.arguments)

// Output file handle.
let outputHandle: FileHandle
if let path = args.outputPath {
    // Create or truncate.
    let fm = FileManager.default
    if !fm.fileExists(atPath: path) {
        let parent = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: nil)
    }
    guard let h = FileHandle(forWritingAtPath: path) else {
        FileHandle.standardError.write(
            "mci-capture-helper: could not open --output path \(path)\n".data(using: .utf8)!
        )
        exit(2)
    }
    outputHandle = h
} else {
    outputHandle = FileHandle.standardOutput
}

// Denylist load (missing-or-empty is OK — fail-safe still fires).
let denylistEntries: [DenylistEntry]
if let toml = try? String(contentsOfFile: args.denylistPath, encoding: .utf8) {
    do {
        denylistEntries = try DenylistTOMLLoader().parse(toml)
    } catch {
        FileHandle.standardError.write(
            "mci-capture-helper: denylist parse error at \(args.denylistPath): \(error)\n"
                .data(using: .utf8)!
        )
        exit(3)
    }
} else {
    denylistEntries = []
}

// Build cascade with concrete probes. Production:
struct NoBlackedRegionYet: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}

let cascade = SuppressionCascade(
    secureEventInput: CarbonSecureEventInputProbe(),
    axSecureSubrole: AXSubroleProbe(),
    denylist: Denylist(entries: denylistEntries),
    blackedRegion: NoBlackedRegionYet(),
    knownSafeAppBundles: []
)

let loop = HelperMainLoop(
    cascade: cascade,
    sink: FileHandleFrameSink(handle: outputHandle),
    heartbeatInterval: .seconds(args.heartbeatSeconds)
)

if args.oneShot {
    // CI smoke: emit one frame, exit clean.
    do {
        try await loop.tickHealth()
        try? outputHandle.close()
        exit(0)
    } catch {
        FileHandle.standardError.write("mci-capture-helper: tick error: \(error)\n".data(using: .utf8)!)
        exit(4)
    }
}

// ADR-0013 Amendment 1 §4 — dev-only live-capture path. OFF unless
// `--capture` was explicitly passed. Even when ON this PR-1 path has
// NO IOSurface retain and NO encoder, so it structurally cannot store
// a frame; it exists so a human can drive the live SCStream wiring in
// a dev session. `// UNVERIFIED — needs live macOS`.
if captureOptions.captureEnabled {
    FileHandle.standardError.write("""
    mci-capture-helper: --capture is a DEV-ONLY, UNVERIFIED path \
    (ADR-0013 Amendment 1 §4). Live SCStream capture is NOT enabled in \
    default builds and stores no frame in this build (no retain, no \
    encoder). Starting live session…\n
    """.data(using: .utf8) ?? Data())

    let captureSession = SCStreamCaptureSession(
        pipeline: SCStreamPipeline(
            cascade: cascade,
            // No-op encoder — NO stored frame. PR-3 landed the real
            // `VideoToolboxHEVCEncoder` SHAPE, but wiring it here is a
            // CSO-gated default flip behind the green §7 corpus
            // (ADR-0013 Amendment 1 §4) — deliberately NOT autonomous.
            encoder: DeferredVideoToolboxEncoder(),
            sink: FileHandleFrameSink(handle: outputHandle)
        ),
        denylist: Denylist(entries: denylistEntries)
    )
    Task.detached {
        do {
            try await captureSession.start()
        } catch {
            FileHandle.standardError.write(
                "mci-capture-helper: live capture start failed (expected off a real screen): \(error)\n"
                    .data(using: .utf8) ?? Data()
            )
        }
    }
}

// Long-running mode. Cycle 3 adds SIGTERM/SIGINT handling +
// real inbound IPC. For now Ctrl-C from a shell delivers SIGINT
// which terminates the process; SIGPIPE on output close also kills.
do {
    try await loop.run()
} catch is CancellationError {
    // graceful shutdown
} catch {
    FileHandle.standardError.write("mci-capture-helper: loop error: \(error)\n".data(using: .utf8)!)
    exit(5)
}

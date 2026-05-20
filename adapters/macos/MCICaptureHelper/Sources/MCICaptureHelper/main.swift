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

    /// `--probe-debug` — dev-only. STEP-2-FINDING-001 instrumentation.
    /// When set, every call to `AXSubroleProbe.focusedHasSecureSubrole()`
    /// writes ONE stderr line: focused element's role + subrole +
    /// identifier + title + the `Bool?` returned. Default OFF; the
    /// steady-state (no-flag) cost of the flag is zero — the probe
    /// only reads role / identifier / title when a sink is wired.
    /// No wire-schema change. Pairs with `--capture` (which is what
    /// actually drives the cascade per-frame).
    var probeDebug: Bool
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
        oneShot: false,
        probeDebug: false
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
        case "--probe-debug":
            // Dev-only STEP-2-FINDING-001 instrumentation. Logs every
            // AXSubroleProbe call to stderr. No wire-schema change.
            args.probeDebug = true
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
      --probe-debug             DEV-ONLY. Log every AXSubroleProbe call to
                                stderr (role/subrole/identifier/title/Bool?).
                                For STEP-2-FINDING-001 diagnosis only. No
                                wire-schema change. Steady-state cost when
                                OFF is zero. Pair with --capture.
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

// Build cascade with concrete probes.
//
// ADR-0013 §2: `BlackedRegionProbe` is now the real
// `PixelGridBlackedRegionProbe` (production), replacing the prior
// `NoBlackedRegionYet` stub. The SAME instance is shared between
// the cascade (which reads `hasBlackedRegion()`) and the live
// `SCStreamCaptureSession` below (which pre-feeds the verdict via
// `update(grayscale:)` from the synchronously-extracted 9×8
// luminance grid the callback already computes for the dHash). One
// owner, one mutable byte, lock-guarded.
//
// Step-2 §7 corpus PARTIAL PASS (PR #34, 2026-05-19) recorded the
// §2 stub as a known gap; the human re-runs Step-2 after this PR
// merges to verify `reason=2` fires on full-screen FairPlay +
// `NSWindowSharingType=.none` windows.
let blackedRegionProbe = PixelGridBlackedRegionProbe()

// STEP-2-FINDING-001 diagnostic — `--probe-debug` only.
// `axProbeDebugSink == nil` is the steady-state production path: the
// probe makes the same two AX calls the prior implementation made; no
// extra work. When the sink is wired (dev-only), each probe call also
// reads role / identifier / title and emits ONE stderr line. Never
// writes to the wire / disk / encoded frame path.
let axProbeDebugSink: AXSubroleProbe.DebugSink?
if args.probeDebug {
    if !captureOptions.captureEnabled {
        FileHandle.standardError.write(
            ("mci-capture-helper: --probe-debug is on but --capture is "
                + "off; the cascade is never called from a live SCStream "
                + "callback in this build, so no probe lines will appear. "
                + "Pair --probe-debug with --capture on a real Mac.\n")
                .data(using: .utf8) ?? Data())
    }
    axProbeDebugSink = { observation in
        let role = observation.role ?? "nil"
        let subrole = observation.subrole ?? "nil"
        let identifier = observation.identifier ?? "nil"
        let title = observation.title ?? "nil"
        let result: String = {
            switch observation.classification {
            case .some(true): return "true"
            case .some(false): return "false"
            case .none: return "nil"
            }
        }()
        // STEP-2-FINDING-001 §4 backstop signals — render one short
        // token per signal so the next Step-2 re-run can attribute
        // `reason=4` (or its absence) at signal granularity.
        //   descendant=pos|neg|err
        //   value-hidden=pos|neg|err
        //   id-regex=pos|neg|err
        func renderOutcome(_ o: AXBackstopOutcome) -> String {
            switch o {
            case .positive: return "pos"
            case .negative: return "neg"
            case .errored: return "err"
            }
        }
        let line =
            "mci-capture-helper: probe(ax-subrole) "
            + "focus=\(observation.focusResult) "
            + "role=\(role) subrole=\(subrole) "
            + "id=\(identifier) title=\(title) "
            + "descendant=\(renderOutcome(observation.descendantSecure)) "
            + "value-hidden=\(renderOutcome(observation.valueAttributeHidden)) "
            + "id-regex=\(renderOutcome(observation.identifierRegexMatch)) "
            + "result=\(result)\n"
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
    }
} else {
    axProbeDebugSink = nil
}

let cascade = SuppressionCascade(
    secureEventInput: CarbonSecureEventInputProbe(),
    axSecureSubrole: AXSubroleProbe(debugLog: axProbeDebugSink),
    denylist: Denylist(entries: denylistEntries),
    blackedRegion: blackedRegionProbe,
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
//
// SCSTREAM-LIVE-001 fix (2026-05-19): the session MUST be retained
// for the lifetime of the helper process. `SCStream` per Apple
// convention holds its `SCStreamDelegate` and registered `SCStreamOutput`
// references WEAKLY ("maintain a strong reference"). The prior code
// constructed `captureSession` as a local inside the `if` block and
// kicked `start()` via `Task.detached`; once the detached closure
// finished, the only strong reference dropped and the session
// deallocated — `SCStream`'s weak delegate/output refs went nil and
// the OS callback had nowhere to land. Observable shape: `startCapture`
// returned without throwing, zero sample buffers ever delivered, zero
// `didStopWithError` (the delegate was also nil), helper heartbeats
// alive — exactly the Step-1 audit finding.
//
// The fix: bind `captureSession` at process top level (this file's
// top-level scope IS the executable's main entry — the binding lives
// until process exit), call `start()` synchronously inline, and let
// the heartbeat loop run while the session stays retained. Catches
// the regression class structurally — `if let` would re-introduce
// scoped lifetime — so the binding stays at top level even though it
// is optional.
// STEP-2-FINDING-004 fix — `cascadeFloorIntervalMs` lives on
// `StreamPolicy` so the cascade-floor heartbeat is reviewable in one
// place and so the live SCStream's frame-delivery interval and the
// pipeline's cascade-evaluation floor are wired together explicitly.
// The default policy carries `cascadeFloorIntervalMs = 1000` (1 Hz);
// the pipeline reads it via the `floorIntervalMs:` init parameter
// below.
let policy = StreamPolicy.default

let captureSession: SCStreamCaptureSession?
if captureOptions.captureEnabled {
    captureSession = SCStreamCaptureSession(
        pipeline: SCStreamPipeline(
            cascade: cascade,
            // No-op encoder — NO stored frame. PR-3 landed the real
            // `VideoToolboxHEVCEncoder` SHAPE, but wiring it here is a
            // CSO-gated default flip behind the green §7 corpus
            // (ADR-0013 Amendment 1 §4) — deliberately NOT autonomous.
            encoder: DeferredVideoToolboxEncoder(),
            sink: FileHandleFrameSink(handle: outputHandle),
            floorIntervalMs: policy.cascadeFloorIntervalMs
        ),
        denylist: Denylist(entries: denylistEntries),
        policy: policy,
        // Shared §2 probe instance: the session calls `update(...)`
        // in the SCStreamOutput callback; the cascade (constructed
        // above with this same probe) reads `hasBlackedRegion()`.
        blackedRegionProbe: blackedRegionProbe
    )
} else {
    captureSession = nil
}

if let captureSession {
    FileHandle.standardError.write("""
    mci-capture-helper: --capture is a DEV-ONLY, UNVERIFIED path \
    (ADR-0013 Amendment 1 §4). Live SCStream capture is NOT enabled in \
    default builds and stores no frame in this build (no retain, no \
    encoder). Starting live session…\n
    """.data(using: .utf8) ?? Data())

    // Synchronous `start()` inline — no `Task.detached`. The session
    // is retained by the top-level `captureSession` binding for the
    // process lifetime, so SCStream's weak delegate/output refs to
    // `self` stay live. A throw is logged and swallowed; the
    // heartbeat loop still runs so the helper stays observable.
    do {
        try await captureSession.start()
    } catch {
        FileHandle.standardError.write(
            "mci-capture-helper: live capture start failed (expected off a real screen): \(error)\n"
                .data(using: .utf8) ?? Data()
        )
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

// Defensive: ensure the optimizer cannot lift `captureSession` out
// of scope before `loop.run()` returns. The `if let` above already
// holds it (the top-level binding has whole-file lifetime in a Swift
// executable's main file), but read it here so the intent is explicit
// in the source: this binding is load-bearing for SCSTREAM-LIVE-001.
_ = captureSession

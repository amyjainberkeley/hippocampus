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

// Allowlist load — CSO-ratified known-safe-apps (ADR-0013 §3 + §6;
// ADR-0015 §5; ADR-0017 §3.1). Lives in the signed bundle's Resources
// (NOT user-writable v1) and is parsed at startup. Missing resource ⇒
// empty allowlist ⇒ cascade fail-closes on every app (the safe
// direction — `Allowlist.contains(_:)` returns false for everything).
// Parse error ⇒ exit: a damaged bundle MUST NOT be silently downgraded
// to "no apps ratified" without surfacing the bundle problem.
let allowlist: Allowlist
do {
    allowlist = try AllowlistTOMLLoader.loadBundled()
} catch {
    FileHandle.standardError.write(
        "mci-capture-helper: known-safe-apps.toml parse error: \(error)\n"
            .data(using: .utf8)!
    )
    exit(6)
}

// User-layer allowlist load (ADR-0017 §3.2 / V2-P10). The user-mutable
// layer at `~/Library/Application Support/MCI/user-allowlist.toml`
// adds bundle ids the user opted in to via the onboarding UI. The
// helper unions the user-layer's `captureEnabledBundleIds` with the
// CSO baseline; the cascade does not distinguish source — every user-
// layer bundle still flows through the same §2–§7 arms + cascade-twice
// OCR redaction. Per ADR-0017 §3.2 binding:
//   - Missing file ⇒ empty layer (fresh install — no opt-ins yet).
//   - Insecure perms / foreign owner / parse error ⇒ fall back to empty
//     + log to stderr. The cascade's fail-closed default per §7 is the
//     safe direction; refusing to start would be more conservative but
//     would also lock the user out of capture entirely if the file
//     ever gets corrupted.
let userAllowlist: UserAllowlist
do {
    userAllowlist = try UserAllowlistTOMLLoader.loadFromUserPath()
} catch {
    FileHandle.standardError.write(
        "mci-capture-helper: user-allowlist.toml read error (falling back to empty): \(error)\n"
            .data(using: .utf8)!
    )
    userAllowlist = .empty
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

// Cascade-eligible bundle ids — union of CSO-ratified baseline (§3.1)
// and the user-mutable layer (§3.2 / V2-P10). Both layers feed the
// SAME `knownSafeAppBundles` Set; the cascade's §2-§7 arms apply
// identically to every entry — user-layer entries STRICTLY ADD `.allow`
// decisions (still gated on AX positive + non-secure-input + non-
// blacked-region + cascade-twice OCR redaction) and cannot widen past
// any redaction signal. See `UserAllowlistTOMLLoader.swift` for the
// §3.2 trust contract.
let cascadeEligibleBundles = allowlist.bundleIdSet
    .union(userAllowlist.captureEnabledBundleIds)
let cascade = SuppressionCascade(
    secureEventInput: CarbonSecureEventInputProbe(),
    axSecureSubrole: AXSubroleProbe(debugLog: axProbeDebugSink),
    denylist: Denylist(entries: denylistEntries),
    blackedRegion: blackedRegionProbe,
    knownSafeAppBundles: cascadeEligibleBundles
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

// ADR-0015 §6 P2.5 — context join. Construct the shared
// `WorkflowContextSnapshot` actor (one per process); wire
// `NSWorkspaceContextProvider` (1 Hz poll of `NSWorkspace.frontmost
// Application.bundleIdentifier` + AX-backed focused-window-title via
// the injected `AXWindowTitleProvider`); compose the per-browser URL
// providers (Safari + Chromium-family + Firefox + Arc) behind the
// `CompositeURLProvider` walk. The SCStream callback reads the
// snapshot synchronously per-frame and invokes the URL provider
// against the snapshot's frontmost bundle id (each per-browser
// provider has its own 1 s cache TTL → ~1 AppleScript invocation/s
// in the steady-state hot path).
//
// Lifetime: the provider's `start()` is called BEFORE the SCStream
// kicks off, `stop()` is not currently triggered (the helper exits
// on SIGINT/SIGPIPE and the timer is best-effort cancelled in
// `deinit`). Idempotent on both ends. When `--capture` is off the
// context providers are still constructed but the snapshot has no
// reader — the polling cost is one NSWorkspace + one AX call per
// second, far inside §4 budget by inspection.
//
// ADR-0015 §4 invariant 1 ("context-as-content") + invariant 2
// ("cascade-before-storage"): the snapshot is the only path through
// which `appBundleId` / `windowTitle` / `url` reach the cascade.
// Nothing on this construction path writes those fields to disk,
// IPC, or any sink ahead of a `.allow` cascade decision (the
// `.suppress` path emits a `PrivacyTombstone` carrying ONLY
// `appBundleId` + reason — see `SCStreamPipeline.swift:411-441`).
let contextSnapshot = WorkflowContextSnapshot()
let urlProvider: URLProvider = CompositeURLProvider()
let nsWorkspaceContextProvider = NSWorkspaceContextProvider(
    snapshotStore: contextSnapshot,
    source: NSWorkspaceFrontmostAppSource(),
    windowTitleProvider: AXWindowTitleProvider()
)

let captureSession: SCStreamCaptureSession?
if captureOptions.captureEnabled {
    // Shared FrameSequence — monotonic seq numbers across tombstones
    // AND OCREvents on the same wire. Both SCStreamPipeline and
    // CascadeTwiceOCREmitter allocate from this single actor so the
    // Rust-side decoder sees strictly increasing seq regardless of
    // which emitter produced the frame.
    let sharedSequence = FrameSequence()
    let sharedSink = FileHandleFrameSink(handle: outputHandle)

    // ADR-0016 P3.6.7 — OCR worker + cascade-twice emitter. The
    // worker is started below (before the SCStream session) so the
    // consumer loop is ready to drain submissions on the first
    // `.allow` frame. The emitter is the ONLY call site that emits
    // `OCREvent` in the helper (ADR-0016 §4.2 invariant).
    let ocrEngine: OCREngine = VisionOCRRunner()
    let ocrWorker = VisionOCRWorker(engine: ocrEngine)

    // P3.6.5: encrypted keyframe blob writer. Reads the DbKey from
    // MCI_DB_KEY_HEX env var (set by the parent process or demo
    // recipe). When absent, blobs are not written — OCREvents carry
    // keyframeHash = [0; 32]. CSO invariant: the DbKey is the SAME
    // key that opens the SQLCipher brain store (ADR-0008 §5 — no
    // new key material, no new key custody surface).
    let blobKeyMaterial: [UInt8]
    let blobWriter: KeyframeBlobWriter?
    if let dbKeyHex = ProcessInfo.processInfo.environment["MCI_DB_KEY_HEX"],
       let keyBytes = hexStringToBytes(dbKeyHex),
       keyBytes.count == 32
    {
        blobKeyMaterial = keyBytes
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let blobDir = appSupport
            .appendingPathComponent("MCI")
            .appendingPathComponent("blobs")
        try? FileManager.default.createDirectory(
            at: blobDir, withIntermediateDirectories: true
        )
        let writer = KeyframeBlobWriter(blobDir: blobDir)
        await writer.start()
        blobWriter = writer
    } else {
        blobKeyMaterial = []
        blobWriter = nil
        FileHandle.standardError.write(
            ("mci-capture-helper: MCI_DB_KEY_HEX not set or invalid "
             + "— keyframe blobs will not be written\n")
                .data(using: .utf8) ?? Data()
        )
    }

    let ocrEmitter: any OCRPostAllowEmitter = CascadeTwiceOCREmitter(
        worker: ocrWorker,
        cascade: cascade,
        sink: sharedSink,
        sequence: sharedSequence,
        counters: loop.counters,
        blobWriter: blobWriter,
        blobKeyMaterial: blobKeyMaterial
    )
    // Start OCR worker consumer loop BEFORE the SCStream session so
    // submissions from the first `.allow` frame drain immediately.
    // Retained by emitter → session → top-level `captureSession`
    // binding (process-lifetime, SCSTREAM-LIVE-001 discipline).
    await ocrWorker.start()

    // DOGFOOD #3 — `VideoToolboxHEVCEncoder` wired ONLY inside the
    // `--capture` dev branch. The encoded `CMSampleBuffer`s flow into
    // an in-memory `InMemoryEncodedSampleQueue` (NOT persisted to
    // disk — that wiring is gated by ADR-0013 Amendment 1 §4 + the
    // §7 corpus). The next PR (DOGFOOD #4) plugs the OCR worker into
    // this same queue. Outside the `--capture` branch (the default
    // build path) `DeferredVideoToolboxEncoder` is still the wiring
    // and no `VTCompressionSession` is ever constructed.
    //
    // Amendment 1 §3 audit:
    //   (a) cascade-before-encode — encoder is reached only from
    //       `SCStreamPipeline.process(...)`'s `.allow` branch.
    //   (b) fail-closed preserved — encoder additions widen no
    //       `.allow` path.
    //   (c) no stored/emitted suppressed event — `.suppress` returns
    //       before the encode call site; the encoder is never reached.
    //   (d) no IOSurface pool-stall — the pipeline's top-level
    //       `defer { lease.release() }` releases the surface on every
    //       exit including a throwing encoder; the encoder takes its
    //       own bounded session-internal retain on the pixel buffer.
    //
    // Amendment 1 §4 — `CaptureLaunchOptions.captureEnabled` is the
    // sole gate; this code path is unreachable until the operator
    // passes `--capture` explicitly. Flipping the default-OFF gate is
    // still NOT this PR.
    let encodedSampleQueue = InMemoryEncodedSampleQueue()
    let hevcEncoder = VideoToolboxHEVCEncoder(sink: encodedSampleQueue)

    // STEP-2-FINDING-005 fix — pass `loop.counters` to the pipeline so
    // pipeline writes (`recordDelivered` / `recordSuppressed` /
    // `recordRedactedByFailsafe` / `recordCascadeForced` /
    // `recordCascadeFromFilter`) land on the SAME actor that
    // `loop.tickHealth()` snapshots. Prior to this PR the pipeline
    // defaulted its own `HelperHealthCounters = HelperHealthCounters()`
    // — a parallel actor that the wire encoder never read — so
    // `HelperHealth` wire frames carried all-zero counters even after
    // 228 demonstrable cascade evaluations on the Step-2 v6 live run.
    // ONE actor instance, written by the pipeline, read by the
    // heartbeat. No new wire field; no `.allow` widening; strictly
    // more observability.
    captureSession = SCStreamCaptureSession(
        pipeline: SCStreamPipeline(
            cascade: cascade,
            encoder: hevcEncoder,
            counters: loop.counters,
            sequence: sharedSequence,
            sink: sharedSink,
            floorIntervalMs: policy.cascadeFloorIntervalMs
        ),
        denylist: Denylist(entries: denylistEntries),
        policy: policy,
        // Shared §2 probe instance: the session calls `update(...)`
        // in the SCStreamOutput callback; the cascade (constructed
        // above with this same probe) reads `hasBlackedRegion()`.
        blackedRegionProbe: blackedRegionProbe,
        // ADR-0015 §6 P2.5 — shared snapshot + composite URL provider.
        // The SCStream callback reads `contextSnapshot.currentSync()`
        // synchronously per frame and dispatches the URL read against
        // the snapshot's frontmost bundle id.
        contextSnapshot: contextSnapshot,
        urlProvider: urlProvider,
        ocrPostAllowEmitter: ocrEmitter
    )
} else {
    captureSession = nil
}

if let captureSession {
    FileHandle.standardError.write("""
    mci-capture-helper: --capture is a DEV-ONLY path \
    (ADR-0013 Amendment 1 §4). Live SCStream capture is NOT enabled in \
    default builds. The `--capture` dev path now runs the live cascade \
    + the VideoToolbox HEVC encoder (DOGFOOD #3) and buffers encoded \
    keyframes in memory ONLY — no frame is persisted to disk in this \
    build. Starting live session…\n
    """.data(using: .utf8) ?? Data())

    // ADR-0015 §6 P2.5 — start the 1 Hz context poller BEFORE
    // SCStream so the snapshot has a chance to leave the all-nil
    // initial state on the first cascade evaluation. Idempotent.
    nsWorkspaceContextProvider.start()

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
// ADR-0015 §6 P2.5 — same load-bearing-binding discipline applies to
// the context provider + snapshot + URL composite. The session's
// callback reads the snapshot synchronously every frame, so the
// snapshot actor MUST stay alive for the SCStream's lifetime; the
// poller MUST stay alive to refresh it. Top-level bindings give us
// process-lifetime retention by construction (SCSTREAM-LIVE-001
// lesson, applied to Phase-2 state).
_ = contextSnapshot
_ = urlProvider
_ = nsWorkspaceContextProvider

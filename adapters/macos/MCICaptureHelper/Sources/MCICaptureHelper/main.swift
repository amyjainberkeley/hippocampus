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
    /// writes ONE content-free stderr line containing attribute-presence bits,
    /// backstop outcomes, and the `Bool?` returned. Default OFF; the
    /// steady-state (no-flag) cost of the flag is zero — the probe
    /// only reads role / identifier / title when a sink is wired.
    /// No wire-schema change. Pairs with `--capture` (which is what
    /// actually drives the cascade per-frame).
    var probeDebug: Bool

    /// Monitor stdin as an inherited parent-lifetime lease. Used only by the
    /// packaged supervisor; EOF means the owning UI no longer exists.
    var parentLeaseStdin: Bool
}

struct CaptureRuntime {
    let session: SCStreamCaptureSession
    let contextSnapshot: WorkflowContextSnapshot
    let urlProvider: any URLProvider
    let contextProvider: NSWorkspaceContextProvider
    let calendarAttribution: CalendarAttribution
    let nowPlayingAttribution: NowPlayingAttribution
    let contactsAttribution: ContactsAttribution
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
        probeDebug: false,
        parentLeaseStdin: false
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
        case "--parent-lease-stdin":
            args.parentLeaseStdin = true
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
      --parent-lease-stdin      Exit and drain capture when stdin reaches EOF.
      --readiness-file <path>   Write a generation-bound startup receipt.
      --generation <token>      Expected supervisor process generation.
      --once                    Emit one frame and exit (CI smoke).
      --probe-debug             DEV-ONLY. Log every AXSubroleProbe call to
                                stderr (presence/outcome/Bool? only; never raw
                                AX values).
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

// ADR-0013 Amendment 1 §4 — live capture is DEFAULT-OFF.
// `captureEnabled` is true ONLY if the non-default `--capture` flag was
// explicitly passed. The default path never constructs an `SCStream`.
let captureOptions = CaptureLaunchOptions.parse(CommandLine.arguments)
#if DEBUG
let qualificationRequested = LiveOCRQualification.isRequested(CommandLine.arguments)
let qualificationAuthorized = LiveOCRQualification.isAuthorized(
    arguments: CommandLine.arguments,
    environment: ProcessInfo.processInfo.environment
)
if qualificationRequested && !qualificationAuthorized {
    FileHandle.standardError.write(
        "mci-capture-helper: incomplete live OCR qualification capability\n"
            .data(using: .utf8) ?? Data()
    )
    exit(64)
}
if qualificationAuthorized {
    CascadeTwiceOCREmitter.activateM4Lift(enabled: true)
}
#endif

let readiness: HelperReadinessReceipt?
do {
    readiness = try HelperReadinessReceipt.parse(arguments: CommandLine.arguments)
} catch {
    FileHandle.standardError.write(
        "mci-capture-helper: invalid readiness contract: \(error.localizedDescription)\n"
            .data(using: .utf8) ?? Data()
    )
    exit(64)
}

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
// extra work. When the sink is wired (dev-only), each probe call emits
// presence and classification signals only. Raw AX values never reach stderr,
// the wire, disk, or the encoded-frame path.
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
        FileHandle.standardError.write(
            AXProbeDiagnostic.render(observation).data(using: .utf8) ?? Data()
        )
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
    knownSafeAppBundles: cascadeEligibleBundles,
    rawPixelExcludedAppBundles: BrowserPixelCapturePolicy.excludedBundleIds
)

let loop = HelperMainLoop(
    cascade: cascade,
    sink: FileHandleFrameSink(handle: outputHandle),
    heartbeatInterval: .seconds(args.heartbeatSeconds)
)

// Phase 6 PR 6 — wire-0x09 footprint sampler. The production sampler
// reads RSS via Mach `task_info(MACH_TASK_BASIC_INFO)` + CPU% via
// `getrusage(RUSAGE_SELF)` deltas. Each `loop.tickHealth()` flush
// asks the sampler for the current reading; the reading lands on the
// wire as `HelperHealth.cpu_pct_micro` + `HelperHealth.rss_bytes`.
// Pair with the MetricKit pipeline below for finer-than-daily
// observability against the G2-ratified ≤10-15% / ≤2 GB SLOs.
let footprintSampler = MachFootprintSampler()
await loop.counters.installFootprintSampler(footprintSampler)

// Phase 6 PR 6 — MetricKit non-content footprint telemetry pipeline.
// Apple aggregates daily; each payload lands at
// `~/Library/Application Support/MCI/metrickit/<uuid>.json` (mode 0600).
// Content-free by Apple construction — see MetricKitSubscriber.swift
// CSO sign-off block. Installed unconditionally (no --capture gate);
// MetricKit's per-process posture is "always on, lightweight".
let metricKitSink = MetricKitFileSink()
_ = MetricKitSubscriber.install(sink: metricKitSink)

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

// ADR-0013 Amendment 1 §4 — explicit live-capture path. OFF unless
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

let captureRuntime: CaptureRuntime?
if captureOptions.captureEnabled {
    // Context and attribution are content-bearing capture resources. They are
    // constructed only under the explicit argv authority and retained with
    // the stream for exactly the same lifetime.
    let contextSnapshot = WorkflowContextSnapshot()
    let focusedWindowStore = FocusedWindowStore()
    let focusedWindowReader = AXFocusedWindowReader()
    let urlProvider: any URLProvider = CompositeURLProvider()
    let calendarAttribution = CalendarAttribution()
    let nowPlayingAttribution = NowPlayingAttribution()
    let contactsAttribution = ContactsAttribution()
    let nsWorkspaceContextProvider = NSWorkspaceContextProvider(
        snapshotStore: contextSnapshot,
        source: NSWorkspaceFrontmostAppSource(),
        windowTitleProvider: AXWindowTitleProvider(),
        focusedWindowStore: focusedWindowStore,
        focusedWindowReader: focusedWindowReader,
        calendarSource: calendarAttribution,
        nowPlayingSource: nowPlayingAttribution,
        contactsSource: contactsAttribution
    )
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

    // Resolve the shared database key once, then keep screenshot policy,
    // encryption, and durable publication behind one serialized coordinator.
    let keyframeRetainer: KeyframeRetentionCoordinator
    do {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let keyBytes = try KeychainDatabaseKeyResolver().resolveBytes(
            environment: ProcessInfo.processInfo.environment,
            developmentKeyPath: appSupport
                .appendingPathComponent("MCI")
                .appendingPathComponent("dev.key")
        )
        let blobDir = appSupport
            .appendingPathComponent("MCI")
            .appendingPathComponent("blobs")
        try FileManager.default.createDirectory(
            at: blobDir, withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: blobDir.path
        )
        keyframeRetainer = KeyframeRetentionCoordinator(
            blobDirectory: blobDir,
            keyMaterial: Data(keyBytes)
        )
    } catch {
        FileHandle.standardError.write(
            ("mci-capture-helper: database key unavailable; "
             + "capture is disabled: \(error.localizedDescription)\n")
                .data(using: .utf8) ?? Data()
        )
        exit(78)
    }

    let ocrEmitter: any OCRPostAllowEmitter = CascadeTwiceOCREmitter(
        worker: ocrWorker,
        cascade: cascade,
        sink: sharedSink,
        sequence: sharedSequence,
        counters: loop.counters,
        keyframeRetainer: keyframeRetainer
    )
    // Start OCR worker consumer loop BEFORE the SCStream session so
    // submissions from the first `.allow` frame drain immediately.
    // Retained by emitter → session → top-level `captureSession`
    // binding (process-lifetime, SCSTREAM-LIVE-001 discipline).
    await ocrWorker.start()

    // The pre-OCR HEVC queue had no consumer and retained pixels before the
    // OCR privacy gate. Post-OCR condensed encrypted JPEG is now the only
    // visual persistence path, so the pipeline encoder is deliberately no-op.
    let noOpEncoder = NoOpFrameEncoder()

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
    //
    // ADR-0031 V2-P1 third-lift wiring uses the API-correct include-only
    // `SCContentFilter` path. This block is reachable only under explicit
    // supervisor argv; capture-off launches never construct these resources.
    let focusTracker = FocusTracker(
        store: focusedWindowStore,
        reader: focusedWindowReader
    )
    let tccStatusMonitor = TCCStatusMonitor()
    let captureSession = SCStreamCaptureSession(
        pipeline: SCStreamPipeline(
            cascade: cascade,
            encoder: noOpEncoder,
            counters: loop.counters,
            sequence: sharedSequence,
            sink: sharedSink,
            floorIntervalMs: policy.cascadeFloorIntervalMs
        ),
        denylist: Denylist(entries: denylistEntries),
        policy: policy,
        // Shared §2 classifier configuration. The session updates and reads
        // it synchronously, then freezes the result with secure-input and AX
        // state before any raw pixel buffer is retained or queued.
        blackedRegionProbe: blackedRegionProbe,
        // ADR-0015 §6 P2.5 — shared snapshot + composite URL provider.
        // The SCStream callback reads `contextSnapshot.currentSync()`
        // synchronously per frame and dispatches the URL read against
        // the snapshot's frontmost bundle id.
        contextSnapshot: contextSnapshot,
        urlProvider: urlProvider,
        ocrPostAllowEmitter: ocrEmitter,
        // ADR-0031 V2-P1 third-lift wiring — the scaffold factory
        // (`SCContentFilterFactory.makeMultiWindowFilter(...)`) is
        // reachable via `SCStreamCaptureSession.start()` iff the
        // focused-window store is non-nil. The rebind task follows
        // focus changes at 200 ms cadence; the race-consistency gate
        // covers residual buffer-delivery races.
        focusedWindowStore: focusedWindowStore,
        focusTracker: focusTracker,
        tccStatusMonitor: tccStatusMonitor
    )
    captureRuntime = CaptureRuntime(
        session: captureSession,
        contextSnapshot: contextSnapshot,
        urlProvider: urlProvider,
        contextProvider: nsWorkspaceContextProvider,
        calendarAttribution: calendarAttribution,
        nowPlayingAttribution: nowPlayingAttribution,
        contactsAttribution: contactsAttribution
    )
} else {
    captureRuntime = nil
}

var captureDrainFailed = false
if let captureRuntime {
    let captureSession = captureRuntime.session
    FileHandle.standardError.write(
        "mci-capture-helper: starting explicit capture generation.\n"
            .data(using: .utf8) ?? Data()
    )

    // ADR-0015 §6 P2.5 — start the 1 Hz context poller BEFORE
    // SCStream so the snapshot has a chance to leave the all-nil
    // initial state on the first cascade evaluation. Idempotent.
    //
    // Phase 6 PR 5 — SH Fork D1: kick off the three attribution
    // providers in parallel BEFORE the poller starts. Each provider's
    // `start()` triggers the TCC prompt (Calendar + Contacts) or
    // sets up the read path (MPNowPlayingInfoCenter — no prompt).
    // All three are idempotent + non-blocking; the auth callback
    // resolves asynchronously, until which point the providers
    // return `nil` (graceful absence). See CSO sign-off rows 1-2.
    captureRuntime.calendarAttribution.start()
    captureRuntime.nowPlayingAttribution.start()
    captureRuntime.contactsAttribution.start()
    captureRuntime.contextProvider.start()

    // Synchronous `start()` inline — no `Task.detached`. The session
    // is retained by the top-level `captureSession` binding for the
    // process lifetime, so SCStream's weak delegate/output refs to
    // `self` stay live. A throw exits nonzero before readiness.
    do {
        try await captureSession.start()
    } catch {
        FileHandle.standardError.write(
            "mci-capture-helper: live capture start failed: \(error)\n"
                .data(using: .utf8) ?? Data()
        )
        exit(79)
    }
}

do {
    try readiness?.publish()
} catch {
    FileHandle.standardError.write(
        "mci-capture-helper: readiness publication failed: \(error.localizedDescription)\n"
            .data(using: .utf8) ?? Data()
    )
    exit(80)
}

do {
    if args.parentLeaseStdin {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await loop.run() }
            group.addTask { try await ParentLifetimeLease.waitForEOF() }
            _ = try await group.next()
            group.cancelAll()
        }
    } else {
        try await loop.run()
    }
} catch is CancellationError {
    // graceful shutdown
} catch {
    FileHandle.standardError.write("mci-capture-helper: loop error: \(error)\n".data(using: .utf8)!)
    exit(5)
}

if let captureRuntime {
    do {
        try await captureRuntime.session.stop()
    } catch {
        captureDrainFailed = true
        FileHandle.standardError.write(
            "mci-capture-helper: capture drain failed during shutdown\n"
                .data(using: .utf8)!
        )
    }
    captureRuntime.contextProvider.stop()
}
if captureDrainFailed {
    exit(82)
}

// Defensive: ensure the optimizer cannot lift `captureSession` out
// of scope before `loop.run()` returns. The `if let` above already
// holds it (the top-level binding has whole-file lifetime in a Swift
// executable's main file), but read it here so the intent is explicit
// in the source: this binding is load-bearing for SCSTREAM-LIVE-001.
_ = captureRuntime

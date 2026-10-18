// SPDX-License-Identifier: Apache-2.0
//
// SuppressionCascade — ADR-0013 binding cascade orchestrator.
//
// LAUNCH-BLOCKER per AGENT_PROTOCOL §4 / R5.
// PROTECTED-SET per AGENT_PROTOCOL §5.
//
// This file IS the cascade. Every Phase-1 capture-spine PR that lands
// SCStream lifecycle must wire this orchestrator end-to-end. SCStream
// without this is rejected at security review (no "follow-up" path).
//
// The cascade is OS-API-free by design: it takes the four probe
// protocols + a `WorkflowContext` + a `BlackedRegionProbe` signal and
// returns a `Decision`. The actual OS-API plumbing (Carbon syscall, AX
// query, denylist load) lives in adapter implementations of these
// protocols. This separation is what lets the binding decision logic
// be testable without a running OS pipeline.
//
// ADR-0016 P3.6 — cascade-twice. The orchestrator gains a second
// decision method `decideOcr(text:context:)` that runs the §6 OCR-time
// secret/PII regex over OCR'd text AFTER the pixel-time cascade
// returned `.allow`. Events that fail the OCR re-cascade emit a
// `PrivacyTombstone(reason=ocrTimeSecret)` and never reach the wire
// as an `OCREvent`.

import CoreGraphics
import Foundation

/// What the cascade decided about a candidate event.
///
/// `.allow` means "this event survived; the helper may encode and
/// forward to the core." `.suppress(reason)` means "this event MUST be
/// dropped before any pixel/text/metadata crosses IPC; emit a privacy
/// tombstone with this reason."
public enum SuppressionDecision: Sendable, Equatable {
    case allow
    case suppress(reason: RedactionReason)

    /// Short label for the MCI_OCR_TRACE stderr surface
    /// (`SuppressionCascade.decide` → `OCRTrace.emit`). Content-free —
    /// fixed enum-name strings only.
    public var traceLabel: String {
        switch self {
        case .allow: return "allow"
        case .suppress(let r): return "suppress.\(r.dbString)"
        }
    }
}

/// Immutable result of the first privacy gate for one captured frame.
///
/// The live callback creates this value before retaining or queuing the
/// frame's pixel buffer. Secure-input and AX probes are sampled exactly once;
/// queued work consumes `decision` instead of re-reading mutable process state.
public struct PixelPrivacySnapshot: Sendable, Equatable {
    public let hasBlackedRegion: Bool
    public let secureEventInputEnabled: Bool
    public let axSecureSubrole: Bool?
    public let decision: SuppressionDecision

    public var permitsRawPixels: Bool {
        decision == .allow
    }

    init(
        hasBlackedRegion: Bool,
        secureEventInputEnabled: Bool,
        axSecureSubrole: Bool?,
        decision: SuppressionDecision
    ) {
        self.hasBlackedRegion = hasBlackedRegion
        self.secureEventInputEnabled = secureEventInputEnabled
        self.axSecureSubrole = axSecureSubrole
        self.decision = decision
    }
}

/// Cascade orchestrator.
///
/// Initialize once per helper-process lifetime with the four probes +
/// the denylist matcher. Call `decide(context:)` on every state
/// transition. The orchestrator is `Sendable` and re-entrant; tests
/// exercise it from multiple synthetic call sites in parallel.
public struct SuppressionCascade: Sendable {
    private let secureEventInput: any SecureEventInputProbe
    private let axSecureSubrole: any AXSecureSubroleProbe
    private let denylist: any DenylistProbe
    private let blackedRegion: any BlackedRegionProbe
    private let denylistDrift: any DenylistDriftProbe
    private let knownSafeAppBundles: Set<String>
    private let browserAppBundles: Set<String>
    private let admissionPolicy: CaptureAdmissionPolicy
    private let browserWindowPrivacy: (any BrowserWindowPrivacyChecking)?
    /// Browser windows seen private, so they stay skipped once their marker
    /// is hidden or gone (a new tab's title, a covered top bar).
    let privateWindows: PrivateBrowserWindows

    /// Construct a cascade orchestrator.
    ///
    /// `knownSafeAppBundles` is the curated allowlist from ADR-0013 §3
    /// — bundle IDs whose AX coverage has been positively characterized
    /// by Phase-1 integration tests. Initially empty (no app is
    /// "known-safe" until earned). Additions are review-gated.
    ///
    /// `denylistDrift` is the ADR-0013 §5 source-filter↔live-policy
    /// drift detector. It defaults to `NoDenylistDrift()` (a strict
    /// no-op) so constructions that have not yet wired live-`SCStream`
    /// filter-generation tracking keep their exact prior cascade
    /// behavior; the live adapter supplies a real implementation on a
    /// real machine (Track B). The §5 *decision* is locked + tested
    /// here regardless (Track A).
    ///
    /// `browserAppBundles` are read like every other app (RULINGS G8);
    /// `browserWindowPrivacy` can only add a skip, for a window the
    /// browser itself reports as private.
    public init(
        secureEventInput: any SecureEventInputProbe,
        axSecureSubrole: any AXSecureSubroleProbe,
        denylist: any DenylistProbe,
        blackedRegion: any BlackedRegionProbe,
        denylistDrift: any DenylistDriftProbe = NoDenylistDrift(),
        knownSafeAppBundles: Set<String> = [],
        browserAppBundles: Set<String> = [],
        admissionPolicy: CaptureAdmissionPolicy = .approvedApplications,
        browserWindowPrivacy: (any BrowserWindowPrivacyChecking)? = nil,
        privateWindows: PrivateBrowserWindows = .shared
    ) {
        self.secureEventInput = secureEventInput
        self.axSecureSubrole = axSecureSubrole
        self.denylist = denylist
        self.blackedRegion = blackedRegion
        self.denylistDrift = denylistDrift
        self.knownSafeAppBundles = knownSafeAppBundles
        self.browserAppBundles = browserAppBundles
        self.admissionPolicy = admissionPolicy
        self.browserWindowPrivacy = browserWindowPrivacy
        self.privateWindows = privateWindows
    }

    /// Apply the ADR-0013 cascade in binding order. First match wins.
    ///
    /// Order:
    ///   §1 — source-level denylist (app / URL / window title).
    ///   §2 — OS-blacked-out region present.
    ///   §3 — `IsSecureEventInputEnabled()` true.
    ///   §4 — focused AX element has `kAXSecureTextFieldSubrole`.
    ///   §5 — post-capture denylist (belt-and-suspenders; should have
    ///        been caught by §1's `SCContentFilter` exclusion, but if
    ///        the source-level config drifted from the policy table
    ///        we catch it here).
    ///   (§6 OCR-time regex runs in `core/`, NOT here.)
    ///   §7 — fail-safe default: unknown classification ⇒ redact.
    public func decide(context: WorkflowContext) -> SuppressionDecision {
        snapshotPixelPrivacy(context: context).decision
    }

    /// Sample every mutable first-gate signal into a frame-bound value.
    ///
    /// `hasBlackedRegion` is supplied by the callback's current luminance
    /// grid. Legacy callers may omit it, in which case the configured probe is
    /// read immediately here and still frozen before asynchronous dispatch.
    public func snapshotPixelPrivacy(
        context: WorkflowContext,
        hasBlackedRegion: Bool? = nil,
        capturedWindow: FocusedWindow? = nil
    ) -> PixelPrivacySnapshot {
        let blacked = hasBlackedRegion ?? blackedRegion.hasBlackedRegion()
        let secureInput = secureEventInput.isSecureEventInputEnabled()
        let axResult = axSecureSubrole.focusedHasSecureSubrole()
        let decision = decideInternal(
            context: context,
            hasBlackedRegion: blacked,
            secureEventInputEnabled: secureInput,
            axSecureSubrole: axResult,
            capturedWindow: capturedWindow
        )
        // PR #226 §5.1 (2) — MCI_OCR_TRACE=1 env-gated trace.
        // Content-free: decision enum only. No bundle ID, window title, URL,
        // or OCR text. Zero steady-state cost when off (single static-let
        // load via `OCRTrace.isEnabled`; the autoclosure prevents
        // line-construction overhead).
        OCRTrace.emit(
            "cascade-decide",
            "decision=\(decision.traceLabel)"
        )
        return PixelPrivacySnapshot(
            hasBlackedRegion: blacked,
            secureEventInputEnabled: secureInput,
            axSecureSubrole: axResult,
            decision: decision
        )
    }

    /// Inner cascade — pulled out of `decide(context:)` so the
    /// MCI_OCR_TRACE emit can wrap exactly one decision per call
    /// without duplicating the trace at every early-return arm.
    private func decideInternal(
        context: WorkflowContext,
        hasBlackedRegion: Bool,
        secureEventInputEnabled: Bool,
        axSecureSubrole: Bool?,
        capturedWindow: FocusedWindow?
    ) -> SuppressionDecision {
        // §1 — source-level denylist (the load-bearing primitive).
        if let bundle = context.appBundleId, denylist.appIsDenied(bundleId: bundle) {
            return .suppress(reason: .denylistSource)
        }
        if let url = context.url, denylist.urlIsDenied(url) {
            return .suppress(reason: .denylistSource)
        }
        if let title = context.windowTitle, denylist.windowTitleIsDenied(title) {
            if let window = capturedWindow, browserAppBundles.contains(window.bundleId),
               BrowserPixelCapturePolicy.titleMarksPrivateWindow(title) {
                privateWindows.remember(window.windowId)
            }
            return .suppress(reason: .denylistSource)
        }
        // A page without a title is titled with its address: the sign-in and
        // bank sites and the person's URL rules apply to it as to a URL.
        if let title = context.windowTitle, let bundle = context.appBundleId, browserAppBundles.contains(bundle),
           BrowserPixelCapturePolicy.namesDeniedSite(title, denylist: denylist) {
            return .suppress(reason: .denylistSource)
        }

        // Browsers are read like every other app (RULINGS G8). A window the
        // browser reports as private is never read; the probe asks only when
        // the person already allowed it, and no answer is not a yes.
        if let bundle = context.appBundleId, browserAppBundles.contains(bundle) {
            if let window = capturedWindow, window.bundleId == bundle, privateWindows.contains(window.windowId) {
                return .suppress(reason: .denylistSource)
            }
            if browserWindowPrivacy?.isPrivate(for: context, capturedWindow: capturedWindow) == true {
                if let window = capturedWindow { privateWindows.remember(window.windowId) }
                return .suppress(reason: .denylistSource)
            }
        }

        // §2 — OS-already-blacked-out region.
        if hasBlackedRegion {
            return .suppress(reason: .osBlackedRegion)
        }

        // §3 — process-wide secure-input bit.
        if secureEventInputEnabled {
            return .suppress(reason: .secureEventInput)
        }

        // §4 — focused AX secure subrole.
        // `nil` from the probe means "AX could not answer with reasonable
        // confidence" — that falls through to §7 (fail-safe) below, NOT
        // to allow.
        if axSecureSubrole == true {
            return .suppress(reason: .axSecureSubrole)
        }

        // §5 — post-capture denylist drift backstop.
        //
        // §1 enforces the denylist at the earliest layer: the
        // `SCContentFilter` installed on the live `SCStream`, built
        // from a SNAPSHOT of the policy at stream-construction time.
        // When the user edits the denylist the running stream's filter
        // is NOT rebuilt instantly — a drift window opens in which a
        // newly-denied source's pixels still flow because the
        // source-level exclusion predates the policy change.
        //
        // §5 closes that window: if the installed filter's policy
        // generation lags the CURRENT policy generation AND the live
        // context matches the CURRENT policy, suppress here with
        // `.denylistPostCapture` — a reason distinct from §1's
        // `.denylistSource`, so the privacy tombstone records that the
        // post-capture backstop fired (the ADR-0013 §5 §1↔§5
        // divergence observability surface for research Telemetry-Gap
        // analyst). Under the default `NoDenylistDrift` sentinel this
        // is a strict no-op (generation parity), so §1–§4/§7 behavior
        // is unchanged.
        if denylistDrift.installedFilterGeneration()
            != denylistDrift.currentPolicyGeneration(),
            denylistDrift.currentPolicyDenies(context)
        {
            return .suppress(reason: .denylistPostCapture)
        }

        // Admission scopes which apps the owner captures; it never substitutes
        // for an affirmative non-secure Accessibility result.
        let appIsAdmitted = admissionPolicy.admits(
            bundleID: context.appBundleId, approved: knownSafeAppBundles
        )

        switch (axSecureSubrole, appIsAdmitted) {
        case (false, true):
            return .allow
        default:
            return .suppress(reason: .failsafeUnknown)
        }
    }

    // MARK: - Browser top bar, after recognition (RULINGS G8)

    /// After recognition and before anything is stored: whether a browser
    /// window's top bar shows that it is private ("Incognito", "InPrivate",
    /// "Private Browsing", a "Private" badge) or shows the address of a site
    /// that is never read (the built-in sign-in and bank sites and the
    /// person's URL rules, which otherwise need the URL). Either one is
    /// suppressed like a denied source. `window` is the window in the lines'
    /// normalized frame space; only lines in its top bar count, so page text
    /// never decides it. Nil for any other app.
    public func browserTopBarFinding(
        lines: [OCRLine], context: WorkflowContext,
        window: CGRect, pixelSize: CGSize, pixelsPerPoint: CGFloat
    ) -> BrowserPixelCapturePolicy.TopBarFinding? {
        guard let bundle = context.appBundleId, browserAppBundles.contains(bundle) else { return nil }
        return BrowserPixelCapturePolicy.topBarFinding(
            lines, window: window, pixelSize: pixelSize, pixelsPerPoint: pixelsPerPoint, denylist: denylist
        )
    }

    // MARK: - ADR-0016 P3.6 — §6 OCR-time cascade (cascade-twice)

    /// Run the §6 OCR-time secret/PII regex over `text` AFTER the
    /// pixel-time cascade has returned `.allow`. Returns `.allow` iff
    /// no regex in the SecretBench-tuned set matches; otherwise
    /// `.suppress(reason: .ocrTimeSecret)`.
    ///
    /// LOAD-BEARING (ADR-0016 §4.2): this is the second cascade pass.
    /// `OCREvent`s that reach the IPC wire MUST have passed BOTH
    /// `decide(context:)` on pixels AND `decideOcr(text:context:)` on
    /// OCR'd text. ADR-0013 §6 defense-in-depth — SecretBench shows
    /// best detectors at ~52–88% recall, so §6 is a backstop, never a
    /// primary guarantee.
    ///
    /// `context` is currently unused; carried so a future per-app
    /// regex policy (e.g. relax patterns inside `1Password` if it ever
    /// lands on the known-safe allowlist) can land without re-shaping
    /// the call signature.
    public func decideOcr(text: String, context _: WorkflowContext) -> SuppressionDecision {
        if Self.containsSecretOrPII(text) {
            return .suppress(reason: .ocrTimeSecret)
        }
        return .allow
    }

    /// Returns true iff `text` contains any pattern in the §6 OCR-time
    /// regex set, a Luhn-valid credit-card number, or a one-time code next
    /// to an OTP keyword. The set is intentionally small + high-precision
    /// per ADR-0013 §6 (Basak et al. arXiv:2307.00714 — best-tool recall
    /// 52–88%, so we lean toward precision and add shapes under Security
    /// review only).
    ///
    /// Shapes covered:
    ///   1. `password|passwd|secret|api[_-]?key|token|bearer
    ///       |access[_-]?token` followed by `:` or `=` and a non-empty
    ///       value (covers `password: hunter2` shape).
    ///   2. GitHub PAT (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_` prefix
    ///       + 36 hex/alphanumeric chars).
    ///   3. AWS access key id (20-char `AKIA` / `ASIA` prefix).
    ///   4. JWT shape `eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+`.
    ///   5. Credit-card number — 13–19 digits (single space/hyphen groups)
    ///       that pass the Luhn checksum (`containsCreditCard`).
    ///   6. One-time code — a 4–8 digit run within ~40 bytes of an OTP
    ///       keyword (`containsOTP`).
    ///
    /// Shapes 1–4 are static regex (compiled once per process); 5 and 6 are
    /// hand-rolled byte scans kept identical to the Rust reader
    /// (`core/brain/src/redaction/ocr_secrets.rs`), proven by the shared
    /// corpus. Credit card needs a checksum and OTP needs keyword context,
    /// so neither is a pure regex: a bare `RegexSet` would over-redact.
    static func containsSecretOrPII(_ text: String) -> Bool {
        for pattern in ocrSecretPatterns {
            if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return true
            }
        }
        if containsCreditCard(text) { return true }
        if containsOTP(text) { return true }
        return false
    }

    // MARK: - Credit card (Luhn) and one-time code (OTP), ADR-0013 §6

    /// Phrases that mark a nearby 4–8 digit run as a one-time code, lower-cased.
    /// MUST stay identical to Rust `ocr_secrets::OTP_KEYWORDS`; the shared
    /// corpus is the cross-engine check. Matched case-insensitively and only on
    /// a word boundary. `confirm(ation) code` is spelled out as both forms.
    static let otpKeywords: [[UInt8]] = [
        "one-time",
        "one time",
        "verification code",
        "security code",
        "passcode",
        "otp",
        "2fa",
        "two-factor",
        "authentication code",
        "login code",
        "confirmation code",
        "confirm code",
        "your code is",
    ].map { Array($0.utf8) }

    /// How near (in UTF-8 bytes) a 4–8 digit run must sit to an OTP keyword.
    /// MUST equal Rust `ocr_secrets::OTP_WINDOW_BYTES`.
    static let otpWindowBytes = 40

    /// Whether `text` holds a credit-card number: a maximal run of 13–19 digits,
    /// with single spaces or hyphens allowed between digits, that passes the
    /// Luhn checksum. Precision-first — the run is maximal, so a 20-digit blob is
    /// one over-long candidate, never a 16-digit card hidden inside it. Mirrors
    /// Rust `ocr_secrets::contains_credit_card`.
    static func containsCreditCard(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            if !isDigit(bytes[i]) {
                i += 1
                continue
            }
            let start = i
            var digits = 0
            while true {
                while i < bytes.count, isDigit(bytes[i]) {
                    digits += 1
                    i += 1
                }
                if i + 1 < bytes.count,
                   bytes[i] == 0x20 || bytes[i] == 0x2D,
                   isDigit(bytes[i + 1]) {
                    i += 1 // a single separator between two digits stays in the run
                } else {
                    break
                }
            }
            if (13...19).contains(digits), luhnValid(bytes[start..<i]) {
                return true
            }
            // `i` already sits past this run; the maximal run is never re-entered.
        }
        return false
    }

    /// The Luhn checksum over the ASCII digits in `run`; any other byte (a space
    /// or hyphen separator) is skipped. Mirrors Rust `ocr_secrets::luhn_valid`.
    static func luhnValid(_ run: ArraySlice<UInt8>) -> Bool {
        var sum = 0
        var position = 0 // 0 for the rightmost digit, then 1, 2, …
        for byte in run.reversed() {
            guard isDigit(byte) else { continue }
            var digit = Int(byte - 0x30)
            if position % 2 == 1 {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
            position += 1
        }
        return sum % 10 == 0
    }

    /// Whether `text` holds a one-time code: a maximal run of 4–8 digits within
    /// `otpWindowBytes` of an OTP keyword (case-insensitive, on a word
    /// boundary). A bare number with no such keyword never matches. Mirrors Rust
    /// `ocr_secrets::contains_otp`.
    static func containsOTP(_ text: String) -> Bool {
        let bytes = Array(text.utf8)

        // Maximal runs of 4–8 ASCII digits. A longer run (a card, a long id) is
        // not an OTP, so runs of 9+ digits are left out.
        var runs: [(Int, Int)] = []
        var i = 0
        while i < bytes.count {
            if isDigit(bytes[i]) {
                let start = i
                while i < bytes.count, isDigit(bytes[i]) { i += 1 }
                let length = i - start
                if (4...8).contains(length) { runs.append((start, i)) }
            } else {
                i += 1
            }
        }
        if runs.isEmpty { return false }

        // Lower-case the ASCII so the keyword search is case-insensitive without
        // moving any byte offset (OTP keywords and digits are all ASCII).
        let lower = bytes.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
        for keyword in otpKeywords {
            if keyword.count > lower.count { continue }
            var start = 0
            while start <= lower.count - keyword.count {
                if !lower[start..<start + keyword.count].elementsEqual(keyword) {
                    start += 1
                    continue
                }
                let end = start + keyword.count
                let bounded = (start == 0 || !isWordByte(lower[start - 1]))
                    && (end == lower.count || !isWordByte(lower[end]))
                if bounded {
                    for (runStart, runEnd) in runs {
                        let gap: Int
                        if runStart >= end {
                            gap = runStart - end
                        } else if start >= runEnd {
                            gap = start - runEnd
                        } else {
                            gap = 0
                        }
                        if gap <= otpWindowBytes { return true }
                    }
                }
                start += 1
            }
        }
        return false
    }

    /// An ASCII digit byte, `0`–`9`.
    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    /// A byte that can be part of a word, for the OTP keyword boundary test:
    /// an ASCII letter or digit.
    private static func isWordByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    /// Compiled regex set used by `containsSecretOrPII`. ADR-0013 §6.
    /// Process-static: compile cost is paid once, not per OCR call.
    static let ocrSecretPatterns: [NSRegularExpression] = {
        // Patterns are case-insensitive where it matters; the GitHub
        // PAT / AWS / JWT shapes are case-sensitive by spec.
        let specs: [(String, NSRegularExpression.Options)] = [
            // (1) key-value secrets.
            (#"(?i)(password|passwd|secret|api[_-]?key|token|bearer|access[_-]?token)\s*[:=]\s*\S+"#,
             []),
            // (2) GitHub Personal Access Token / OAuth / refresh.
            (#"\bgh[poursAS]_[A-Za-z0-9_]{20,}\b"#, []),
            // (3) AWS Access Key ID — `AKIA` / `ASIA` + 16 uppercase /
            //     digit chars (20-char total).
            (#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, []),
            // (4) JWT three-segment shape.
            (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, []),
        ]
        return specs.compactMap { try? NSRegularExpression(pattern: $0.0, options: $0.1) }
    }()
}

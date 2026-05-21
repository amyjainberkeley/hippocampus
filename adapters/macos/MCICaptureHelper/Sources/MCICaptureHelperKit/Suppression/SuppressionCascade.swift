// SPDX-License-Identifier: TBD-private
//
// SuppressionCascade — ADR-0013 binding cascade orchestrator.
//
// LAUNCH-BLOCKER per AGENT_PROTOCOL §4 / R5.
// PROTECTED-SET per AGENT_PROTOCOL §5.
//
// This file IS the cascade. Every Phase-1 capture-spine PR that lands
// SCStream lifecycle must wire this orchestrator end-to-end. SCStream
// without this is rejected at CSO review (no "follow-up" path).
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

    /// Construct a cascade orchestrator.
    ///
    /// `knownSafeAppBundles` is the curated allowlist from ADR-0013 §3
    /// — bundle IDs whose AX coverage has been positively characterized
    /// by Phase-1 integration tests. Initially empty (no app is
    /// "known-safe" until earned). Additions are CSO-gated.
    ///
    /// `denylistDrift` is the ADR-0013 §5 source-filter↔live-policy
    /// drift detector. It defaults to `NoDenylistDrift()` (a strict
    /// no-op) so constructions that have not yet wired live-`SCStream`
    /// filter-generation tracking keep their exact prior cascade
    /// behavior; the live adapter supplies a real implementation on a
    /// real machine (Track B). The §5 *decision* is locked + tested
    /// here regardless (Track A).
    public init(
        secureEventInput: any SecureEventInputProbe,
        axSecureSubrole: any AXSecureSubroleProbe,
        denylist: any DenylistProbe,
        blackedRegion: any BlackedRegionProbe,
        denylistDrift: any DenylistDriftProbe = NoDenylistDrift(),
        knownSafeAppBundles: Set<String> = []
    ) {
        self.secureEventInput = secureEventInput
        self.axSecureSubrole = axSecureSubrole
        self.denylist = denylist
        self.blackedRegion = blackedRegion
        self.denylistDrift = denylistDrift
        self.knownSafeAppBundles = knownSafeAppBundles
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
        // §1 — source-level denylist (the load-bearing primitive).
        if let bundle = context.appBundleId, denylist.appIsDenied(bundleId: bundle) {
            return .suppress(reason: .denylistSource)
        }
        if let url = context.url, denylist.urlIsDenied(url) {
            return .suppress(reason: .denylistSource)
        }
        if let title = context.windowTitle, denylist.windowTitleIsDenied(title) {
            return .suppress(reason: .denylistSource)
        }

        // §2 — OS-already-blacked-out region.
        if blackedRegion.hasBlackedRegion() {
            return .suppress(reason: .osBlackedRegion)
        }

        // §3 — process-wide secure-input bit.
        if secureEventInput.isSecureEventInputEnabled() {
            return .suppress(reason: .secureEventInput)
        }

        // §4 — focused AX secure subrole.
        // `nil` from the probe means "AX could not answer with reasonable
        // confidence" — that falls through to §7 (fail-safe) below, NOT
        // to allow.
        let axResult = axSecureSubrole.focusedHasSecureSubrole()
        if axResult == true {
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
        // divergence observability surface for the CRS Telemetry-Gap
        // analyst). Under the default `NoDenylistDrift` sentinel this
        // is a strict no-op (generation parity), so §1–§4/§7 behavior
        // is unchanged.
        if denylistDrift.installedFilterGeneration()
            != denylistDrift.currentPolicyGeneration(),
            denylistDrift.currentPolicyDenies(context)
        {
            return .suppress(reason: .denylistPostCapture)
        }

        // §7 — fail-safe default: unknown ⇒ redact.
        // The cascade treats a positive classification ("AX returned a
        // non-secure subrole" + "no secure-event-input" + "app is on
        // the known-safe list OR the focused element has a recognizable
        // non-secure AX role") as the ONLY path to `.allow`. Everything
        // else redacts.
        let isKnownSafeApp = context.appBundleId.map(knownSafeAppBundles.contains) ?? false

        switch (axResult, isKnownSafeApp) {
        case (false, true):
            // AX positively identified the focused element as non-secure,
            // AND the foreground app is on the curated known-safe list.
            // This is the only `.allow` path.
            return .allow
        default:
            return .suppress(reason: .failsafeUnknown)
        }
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
    /// regex set. The set is intentionally small + high-precision per
    /// ADR-0013 §6 (Basak et al. arXiv:2307.00714 — best-tool recall
    /// 52–88%, so we lean toward precision and add patterns under
    /// CSO review only).
    ///
    /// Patterns covered:
    ///   1. `password|passwd|secret|api[_-]?key|token|bearer
    ///       |access[_-]?token` followed by `:` or `=` and a non-empty
    ///       value (covers `password: hunter2` shape).
    ///   2. GitHub PAT (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_` prefix
    ///       + 36 hex/alphanumeric chars).
    ///   3. AWS access key id (20-char `AKIA` / `ASIA` prefix).
    ///   4. JWT shape `eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+`.
    ///
    /// Static / immutable so the regex compile cost is paid once per
    /// process, not per OCR'd frame.
    static func containsSecretOrPII(_ text: String) -> Bool {
        for pattern in ocrSecretPatterns {
            if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return true
            }
        }
        return false
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

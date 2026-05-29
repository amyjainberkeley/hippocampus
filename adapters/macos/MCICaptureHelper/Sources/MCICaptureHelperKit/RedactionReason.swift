// SPDX-License-Identifier: TBD-private
//
// RedactionReason — Swift mirror of `core::ipc::RedactionReason`.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. The wire-byte discriminants must
// stay in lock-step with `core/src/ipc/mod.rs` — any change here without
// an equivalent change there breaks the helper-to-core contract silently.
//
// The numbering matches ADR-0013's cascade rule numbers. §6 (OCR-time
// regex) was a `core/`-side concern under wire 0x03, so it did NOT have
// a helper-side discriminant. Wire 0x04 (ADR-0016 P3.6) moves OCR into
// the helper, so §6 now emits a tombstone from the helper and gets its
// own discriminant: `ocrTimeSecret = 6`.

public enum RedactionReason: UInt8, Sendable, Equatable, CaseIterable {
    /// Cascade §1 — `SCContentFilter` denylist excluded the source.
    case denylistSource = 1
    /// Cascade §2 — captured frame contained a known-black region.
    case osBlackedRegion = 2
    /// Cascade §3 — `IsSecureEventInputEnabled()` returned true.
    case secureEventInput = 3
    /// Cascade §4 — focused AX element had `kAXSecureTextFieldSubrole`.
    case axSecureSubrole = 4
    /// Cascade §5 — post-capture denylist match on `WorkflowContext`.
    case denylistPostCapture = 5
    /// Cascade §6 — OCR-time secret/PII regex matched on OCR'd text.
    /// ADR-0016 P3.6 cascade-twice fire: frame cleared the pixel-time
    /// cascade (§1–§5 + §7), then §6 fired against the OCR'd text.
    /// No OCR text bytes cross the IPC seam on this path; only the
    /// tombstone does.
    case ocrTimeSecret = 6
    /// Cascade §7 — fail-safe: unknown classification ⇒ redact.
    case failsafeUnknown = 7
    /// ADR-0031 §5.3 race-consistency gate — focus changed between
    /// SCStream filter install and frame callback. The captured pixel
    /// buffer may correspond to a different focused window than the
    /// frame's attribution metadata; fail closed by emitting this
    /// tombstone instead of an OCREvent. The pipeline never reaches
    /// the encoder or the cascade-twice OCR emitter on this path.
    /// PROTECTED-SET — wire-byte discriminant lock-stepped with
    /// `core::ipc::RedactionReason::FocusRaceDropped` (= 8).
    case focusRaceDropped = 8

    /// String written to `events.redaction_reason` by the core's store
    /// layer. Must match `RedactionReason::as_db_str()` in
    /// `core/src/ipc/mod.rs`.
    public var dbString: String {
        switch self {
        case .denylistSource: return "denylist-source"
        case .osBlackedRegion: return "os-blacked-region"
        case .secureEventInput: return "secure-event-input"
        case .axSecureSubrole: return "ax-secure-subrole"
        case .denylistPostCapture: return "denylist-postcapture"
        case .ocrTimeSecret: return "ocr-time-secret"
        case .failsafeUnknown: return "failsafe-unknown"
        case .focusRaceDropped: return "focus-race-dropped"
        }
    }
}

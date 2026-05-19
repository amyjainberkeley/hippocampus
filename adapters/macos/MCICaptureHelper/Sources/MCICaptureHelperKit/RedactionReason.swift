// SPDX-License-Identifier: TBD-private
//
// RedactionReason — Swift mirror of `core::ipc::RedactionReason`.
//
// PROTECTED-SET per AGENT_PROTOCOL §5. The wire-byte discriminants must
// stay in lock-step with `core/src/ipc/mod.rs` — any change here without
// an equivalent change there breaks the helper-to-core contract silently.
//
// The numbering matches ADR-0013's cascade rule numbers. §6 (OCR-time
// regex) runs in `core/`, never in the helper, so it does NOT have a
// discriminant here — the cascade `decide()` function cannot return it.

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
    /// Cascade §7 — fail-safe: unknown classification ⇒ redact.
    case failsafeUnknown = 7

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
        case .failsafeUnknown: return "failsafe-unknown"
        }
    }
}

# ADR-0001 — Privacy posture: local-first + end-to-end encrypted sync

- Status: Accepted (2026-05-18; ratified by human CEO via /night-run cycle 2)
- Owner: CTO
- Reviewers: CSO; CEO
- Phase: 0

## Context

MCI captures the most sensitive possible desktop data stream: full screen contents, every focused window, every active browser URL, and the text of every page rendered. Trust is the product. DESIGN.md §1, §2 (G3, NG1), §9, and §11 already commit MCI to a specific privacy posture; this ADR pins it as an architectural invariant binding on every future component.

DESIGN.md §1 states: "*This document specifies a local-first, end-to-end-encrypted implementation that a person downloads and runs on their own machine. Capture, storage, OCR, embeddings, and recall all run on-device. An optional encrypted cloud layer provides cross-device sync and backup — the cloud never sees plaintext.*"

DESIGN.md §9.1 threat model: "*The cloud sync server must never be able to read user content (zero-knowledge).*"

AGENT_PROTOCOL §4 lists the zero-knowledge invariant as non-negotiable: "*the cloud sync server must never be able to read user content. Client-side E2E encryption before upload, always.*"

## Decision

MCI is **local-first and end-to-end encrypted**. Concretely:

1. **Capture, storage, OCR, embeddings, retrieval, and the recall UI all run on the user's own device.** No cloud round-trip is part of any hot path.
2. **The optional cloud sync layer is zero-knowledge.** The server stores opaque ciphertext blobs and a delta log; it cannot decrypt anything. Client-side encryption happens before any byte is uploaded. End-to-end across the user's own devices only.
3. **Single-user, user-owned.** No employer/admin visibility, no team mode, no surveillance affordances (NG1).
4. **No cloud LLM inference on raw capture** (NG3). On-device summarization/classification only. If the user later opts into sending a redacted slice to a cloud model, that is an explicit, content-typed per-action choice — never a default and never the hot path.
5. **The denylist + on-device redaction + incognito-exclusion + one-click pause ship with the capture path**, not as a later phase. Privacy is a launch blocker (AGENT_PROTOCOL §4, R5).

This ADR is the apex policy. ADR-0008 implements at-rest encryption; ADR-0012 specifies the zero-knowledge cryptographic model and process-hardening; both inherit from this ADR.

## Consequences

- Positive: every architectural fork below this one is constrained — there is no design space where the server reads plaintext, no design space where a cloud LLM sees raw capture, no design space where another human user can see this user's memory.
- Positive: the privacy posture *is* the product narrative. The CRS Privacy stream (RESEARCH_DIGEST §E) shows Microsoft Recall failed publicly twice in the same product space; MCI inherits Recall as its risk register. A loud, defensible local-first posture is differentiating.
- Negative / tradeoffs: cross-device convergence is harder than a server-mediated model. Recovery from total device loss requires explicit recovery-vault design (ADR-0012). Sync must be delta-based + crypto-shredded for deletion (ADR-0012).
- Forces: AGENT_PROTOCOL §5 protected-set scope (crypto, key-management, sync) is enforced by CSO veto on every PR touching `core/**` crypto/sync.

## Alternatives considered

- **Cloud-mediated capture with server-side encryption.** Rejected — the user's most sensitive data stream lives on a third party's machines under a key the third party holds. This is the Recall 2024 failure shape; MCI cannot adopt it.
- **Local-first without any sync.** Rejected — multi-device users (G5) are the target population. The product has to converge across the user's devices; the question is *how*, not *whether*.

## References

- DESIGN.md §1, §2 (G3, NG1, NG3), §9, §11
- docs/AGENT_PROTOCOL.md §4 (invariants), §5 (CSO protected-set)
- docs/RESEARCH_DIGEST.md Stream E + Verification pass — Recall as MCI's risk register
- ADR-0008 (at-rest encryption), ADR-0012 (zero-knowledge spec)

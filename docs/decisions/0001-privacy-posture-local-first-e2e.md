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

## Amendment 2026-05-31 — V2-MCP-2 HTTP+SSE network surface exception (loopback-only)

- Status: Accepted (2026-05-31; ratified Fork F7 = A in `docs/research/orchestrator-ratification-state-2026-05-31.md` §FORK 7, captured on main in `docs/AGENT_QUESTIONS.md` F-RATIFICATION-2026-05-31)
- Owner: Director of Sync & Platform Core
- Reviewers: CSO; CEO
- Phase: 5.5 (V2-MCP-2 PR landing this amendment inline)

### Context

V2-MCP-1 (PR #245) landed a pure-Rust MCP client + stdio transport. Stdio is process-local IPC and does not cross the network boundary — the V2-MCP-1 lib-crate docstring's "ADR-0001 NG3 compliance" note records that the zero-network invariant was intact through V2-MCP-1.

V2-MCP-2 adds the second MCP transport — HTTP + SSE — so the Hippocampus aggregator (V2-MCP-3, cycle 8.30, Director-Brain) can talk to **locally-running** MCP server processes that speak HTTP/SSE rather than stdio. The CRS source-hierarchy memo (`docs/research/crs-source-hierarchy-2026-05-31.md` §5.2) identifies this transport as covering ~16% of knowledge-worker app-minutes via the gchat / Slack-official / Linear / Notion / Asana / Todoist / Granola / Otter / Figma / Apple-stock-via-MCP-bridge cohort of locally-runnable MCP servers (as of 2026-05).

The original ADR-0001 §4 prohibits cloud LLM inference on raw capture and ADR-0001 §1 prohibits cloud round-trips in any hot path. The original ADR did not contemplate HTTP traffic to a *loopback* address — at the time the only network-shaped paths under discussion were the zero-knowledge sync server (ADR-0012) and the explicit per-action redacted-slice cloud LLM choice. The V2-MCP-aggregation scoping memo (`docs/research/v2-mcp-aggregation-scoping-2026-05-29.md` §5.2) formalized the need for this amendment.

### Decision

A narrow exception is admitted, with three guard rails: (a) the HTTP+SSE client may connect ONLY to addresses on the loopback set defined below; (b) loopback enforcement runs at both registration time AND at per-call connect time (defense-in-depth); (c) no other surface in MCI gains the right to open a network socket as a consequence of this amendment.

Loopback set (binding):

- IPv4: any address in `127.0.0.0/8`.
- IPv6: `::1` exactly.
- DNS hostname: accepted ONLY if every A/AAAA resolution at validation time resolves to an address in the loopback set above. `localhost` is the canonical case; an attacker-controlled hostname that points at a non-loopback address is rejected.
- All other forms — `0.0.0.0`, any non-loopback IPv4, any non-loopback IPv6, any non-`http`/`https` scheme, any URL carrying `userinfo` (a `user:password@` prefix) — are rejected with a typed error and never reach the transport's connect path.

Operational rules:

1. **F-STRAT-001a "MCI never phones home" remains binding.** This amendment does not relax that strategic commitment; loopback-only by construction means no traffic leaves the device.
2. **No automatic discovery of MCP servers.** A server is reachable only if the user explicitly registered it (via the onboarding slide V2-MCP-2 ships or by hand-editing `~/Library/Application Support/MCI/mcp-servers.toml`). No port scan, no Bonjour, no service discovery.
3. **No cloud HTTP traffic from any other code path.** The HTTP client introduced by V2-MCP-2 is scoped to `core/mcp-client` and is constructed only inside the registry's per-server connect lifecycle. Other crates remain forbidden from opening sockets; the §5 CSO protected-set continues to gate every PR that adds one.
4. **Content trust posture** (per CRS Fork-6 = A ratified the same day): bytes returned by a user-registered MCP server ingest as-is into the brain. The user installed and configured the server; trust ownership is on the user. This is distinct from the Messages/Mail deep-hook surfaces (ADR-0030 §3(c)(ii) + §3(f)) where MCI reads a local data store the user did not explicitly opt into per-tool; those continue to run through cascade-equivalent redaction at ingest. Downstream prompt-injection mitigation at the chat-UI boundary (V2-P12, Phase 7) is the future hardening lane.
5. **TLS is optional for loopback.** Plain HTTP over loopback is acceptable because no network packet ever leaves the device's loopback interface; HTTPS to `127.0.0.1` is also accepted (for servers that insist on TLS). No remote certificate pinning is needed since no remote endpoint is allowed.

### Consequences

- Positive: V2-MCP-3 aggregation unlocks roughly 16% of knowledge-worker app-minutes (CRS §5.2) without any cloud round-trip and without weakening F-STRAT-001a. Defense-in-depth (registration-time + per-call-connect-time loopback gates) means a bug in either gate alone cannot leak a non-loopback connect.
- Positive: the on-device trust boundary stays clear — the user enumerated every server, the loopback gate is the cryptographic perimeter, the registry is the audit surface.
- Negative / tradeoffs: a malicious user-supplied URL that bypasses BOTH gates would constitute a §5 protected-set incident. The driver-CSO audit table accompanying the V2-MCP-2 PR enumerates each guard and its evidence; future PRs that touch loopback enforcement must re-establish those rows. Cure53 audit scope (Fork F4 deferred ~Aug 2026) will include this surface.
- Forces: any future expansion of the network surface — mobile-companion bridge, Tailscale-mediated multi-device, remote MCP brokers — is OUT OF SCOPE for v1.0 and requires a new ADR-0001 amendment, a fresh §5 CSO review, and a Cure53 scope addition. Loopback-only is not a stepping stone; non-loopback is a separate decision.

### Alternatives considered

- **Reject HTTP+SSE entirely; stdio-only.** Rejected — eliminates the locally-installed MCP-server cohort (Slack-official, Linear, Notion, Asana, Todoist, gchat, Granola, Otter, Figma, Apple-stock-bridge as of 2026-05) and forecloses V2-MCP-3 aggregation against that ~16% of app-minutes. The trust posture cost of loopback-only is acceptable; the product cost of stdio-only is not.
- **Allow LAN-scoped HTTP (e.g., RFC 1918 ranges) for a future multi-device bridge.** Rejected — defers a much larger threat-model decision into a transport-level allowlist, and the multi-device-bridge use case has not been spec'd. Future amendment lane only.
- **Loopback-only with no defense-in-depth gate (registration-time check only).** Rejected — a registration-time-only check is a single point of failure; per-call connect-time re-check is cheap (a parsed URL on a hot path) and turns the guarantee from policy-only into transport-level. The two gates together are the binding shape.

### References

- `docs/research/v2-mcp-aggregation-scoping-2026-05-29.md` §5.2 (canonical V2-MCP scope; specified this amendment landing inline with V2-MCP-2)
- `docs/research/crs-source-hierarchy-2026-05-31.md` §5.2 (V2-MCP-2 as cycle 8.29 P1; ~16% app-minutes target)
- `docs/research/orchestrator-ratification-state-2026-05-31.md` §FORK 7 (loopback-only ratification) + CRS Fork-6 (content-trust posture) + SH Fork F1 (immediate-queue priority)
- `docs/AGENT_QUESTIONS.md` F-RATIFICATION-2026-05-31 (canonical ratification log on main)
- PR #245 (V2-MCP-1) — stdio transport precedent + the lib-crate docstring's ADR-0001 NG3 compliance note
- AGENT_PROTOCOL.md §4 (zero-knowledge invariant) + §5 (CSO protected-set; first network surface in MCI history is in scope)

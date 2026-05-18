# ADR-0004 — Product scope: capture + brain (recording + workflow context + searchable encrypted memory)

- Status: Accepted (2026-05-18; ratified by human CEO via /night-run cycle 2)
- Owner: CTO
- Reviewers: COO; CEO
- Phase: 0

## Context

MCI is, by easy analogy, "the thing Rewind / Limitless / Microsoft Recall are." It is decidedly **not** a meeting-transcription product, a note-taker, an LLM chat app, or a team-collaboration tool. DESIGN.md §1, §2 already pin the goals (G1–G6) and non-goals (NG1–NG5); this ADR re-states scope as a binding architectural decision so future feature pressure is rejected at the design level rather than re-litigated in PRs.

## Decision

MCI's scope is **capture + brain**:

1. **Capture.** Continuous, on-device screen recording at meaningful state transitions (not every frame), plus the parallel workflow-context signal (frontmost app, focused window title, active browser tab URL, full page text). This is one product, not two.
2. **Brain.** The captured stream becomes a searchable, end-to-end-encrypted long-term memory. The user (or an agent acting for them) issues natural-language and structured queries; hybrid retrieval (FTS5 + sqlite-vec) returns relevant past moments with thumbnail + extracted text + context.
3. **Recall surfaces.** A local UI (timeline + natural-language search) and an authenticated loopback API for the user's own agents.

**Out of scope for v1** (NG1–NG5):
- Team/admin/employer dashboards. MCI is single-user, user-owned (NG1).
- Real-time screen-share or collaboration (NG2). Memory, not streaming.
- Cloud-LLM inference on raw capture (NG3). On-device summarization/classification only.
- Linux (NG4).
- Mobile (NG5).

**Not the product:** meeting bot, transcription product, generic note-taker, calendar/task manager, browser extension that captures only web pages, or chat front-end. Each of these is a different product; one of them is what most "AI memory" startups actually ship.

## Consequences

- Positive: a sharp scope keeps the footprint SLO (AGENT_PROTOCOL §4) reachable — every feature that doesn't earn its way into the capture+brain hot path is rejected at design time, not at performance-tuning time.
- Positive: scope clarity is also positioning. The COO's narrative — "Rewind, but local-first; Recall, but the privacy story is real" — only holds if MCI does not drift into adjacent product spaces.
- Negative / tradeoffs: legitimate adjacent features (e.g., meeting capture, automated agent action) are tempting and explicitly deferred. ADRs proposing scope changes must amend this ADR first, not slip in via a feature PR.
- Forces: the COO's positioning work and the CRS competitor scans are gated on this scope; product/feature drift is a CEO-level decision, not a Director-level one.

## Alternatives considered

- **Capture + brain + meeting transcription.** Rejected — meetings are a different capture modality (microphone + speaker diarization), a different privacy contract (consent of other participants), and a different recall pattern (verbatim transcript vs visual moment). A separate product later, perhaps.
- **Brain only (consume capture from another tool).** Rejected — capture quality is the binding constraint on retrieval quality (DESIGN.md §5, §7; RESEARCH_DIGEST Stream A and B). Outsourcing capture forfeits the lever that matters most.

## References

- DESIGN.md §1, §2 (G1–G6, NG1–NG5), §3 (day-in-the-life)
- docs/AGENT_PROTOCOL.md §4 (footprint SLO)
- ADR-0001 (privacy posture), ADR-0010 (brain retrieval shape)

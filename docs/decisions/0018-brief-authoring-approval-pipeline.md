# ADR-0018 — Brief Authoring + Approval Pipeline (Phase 4.x — Tier-2 surface for F-STRAT-002 dual-market)

- Status: Proposed (2026-05-20 afternoon; CEO+CTO draft pending human CEO ratification). Protected-set authoring (AGENT_PROTOCOL §5) because the brief-authoring path is the FIRST mechanism by which user content can leave the Tier-1 local-only zone — a load-bearing trust boundary.
- Owners: **Director-Brain** (brief-generator + authoring UI + redaction UI; lands in `apps/recall-ui/` + a new `core/brief/` Rust crate) + **Director-Context** (per-app content classification + brief-relevant signal extraction for the generator) + **CSO** (binding — every protected-set PR carries a sign-off block asserting the §4 invariants)
- Reviewers: **CSO** (veto-gate); CEO (ratification); **Director-Sync-Core** (only at ADR-0019 wiring time — this ADR specs LOCAL brief lifecycle only; uploads + workspace sync are ADR-0019); CRS (Telemetry-Gap analyst — brief-generation cost + adoption signal)
- Phase: 4.x (between ADR-0017 onboarding/privacy-controls and ADR-0019 workspace-server). Lands AFTER Phase 3 recall UI (P3.9) ships, because the brief generator reads the same brain that recall queries.
- **Protected-set: yes** (AGENT_PROTOCOL §5). Justification: brief content is user-authored + user-redacted, but the LIFECYCLE (generation → draft → edit → redact → approve → ready-for-upload) is the trust contract for everything ADR-0019 then ships to a workspace server. Every PR below MUST carry a CSO sign-off block.
- Relationship: F-STRAT-002 ratified the dual-market (B2C + B2B). This ADR specs the Tier-2 authoring surface that produces the only artifacts which cross from Tier-1 (private) to Tier-2 (workspace-shareable). ADR-0019 (workspace server) consumes the output of this ADR but does not re-define its lifecycle.

## Context

F-STRAT-002 (2026-05-20 afternoon, ratified by CEO) committed MCI to a dual-market product:

- **Tier 1 (private):** raw screen + cascade + brain. Strictly local, zero-knowledge, single-user-owned. Unchanged from ADR-0001..0017.
- **Tier 2 (shareable):** **approved daily briefs only**. User-authored, user-redacted, user-approved per-brief. Uploaded to a vendor-blind / team-readable workspace server (ADR-0019).

This ADR specs the **brief authoring pipeline** — everything that happens between "Phase 3 recall UI surfaces today's events" and "user has clicked Approve on a daily brief ready for upload." It does NOT spec the upload, the workspace server, or the cross-team read path — those are ADR-0019.

The CEO's pitch frames it: *"It captures your work through OS APIs during work hours and produces a private daily brief — what changed, what shipped, what's blocked, what's owed. You review it. You redact what's sensitive. You approve what gets shared."* This ADR makes that one sentence implementable.

The trust contract: the user is the **sole authority** over what becomes a Tier-2 artifact. The generator drafts; the user authors. No brief reaches the upload queue without explicit per-brief approval. Cascade-of-suppression (ADR-0013) protected pixels at capture time; this ADR adds a **cascade-of-trust** at brief time — a second user-mediated gate where the user reviews content the brain already decided was safe to STORE, and decides whether it's safe to SHARE.

## Decision

### 1. Brief generator — what produces the draft

The brief generator runs at user-configurable intervals (default: end-of-workday, configurable to hourly / on-demand) and produces a markdown draft from the user's Tier-1 brain.

#### 1.1 Generator design

- **Inputs (all from Tier-1 brain, read-only):**
  - Events stored over the brief's time-window (default: last 8 hours, configurable).
  - Episodes (per ADR-0010, contiguous app/task runs) over the same window.
  - `app_bundle_id` + `window_title` + `url` per event (the Phase 2 context fields).
  - OCR'd text per event (Phase 3 P3.5 output).
- **Output:** one `BriefDraft` struct containing:
  - `ts_generated_us: u64`
  - `time_window: TimeRange`
  - `sections: Vec<BriefSection>` where each `BriefSection` has a heading (`"What shipped"` / `"What changed"` / `"What's blocked"` / `"What needs follow-up"`) and a `Vec<BriefBullet>`.
  - `BriefBullet { text: String, source_event_ids: Vec<EventId>, source_excerpts: Vec<String> }` — every bullet **carries source references** to the events that justified it (the "source-backed memory layer" promise from the CEO's pitch is structural, not aspirational).
  - `draft_state: DraftState::Generated` (initial state; transitions via UX below).

#### 1.2 Generator implementation — on-device small LLM, NOT a remote API

Per the F-STRAT-002 + ADR-0016 §4.4 zero-network invariant, the generator runs **entirely on-device**. Two options framed:

- **A) Bundle a small on-device LLM** (recommended): `Llama-3.2-1B-Instruct` int4 or smaller (~700 MB) — same family ADR-0016 §1.4 already proposed for the idle-batch summary worker. Loads via Core ML on macOS (ANE-eligible per the verified-source-conservative framing in ADR-0016 §1.1). Bundled in the signed app at release time; not downloaded at runtime. ~5-10 s per brief generation on M-series hardware in practice.
- B) Pure heuristic generator (regex + event-clustering + template-fill). Cheap, deterministic, no model bundle. But quality bar is "shippable brief" — heuristics won't clear it.
- C) Use the cloud-LLM API (OpenAI, Anthropic, etc.). **Rejected** — violates §4.4 zero-network invariant per ADR-0016. Non-negotiable.

**Recommendation:** A. The bundle-size cost (~700 MB installer) is offset by the value-prop ("your brief writes itself, locally, never seen by us"). If at v1.0 the size hurts adoption, fall back to a smaller distilled model (Phi-3-mini at int4 ≈ 1.4 GB, or Gemma-2B int4 ≈ 1.5 GB — both also Apache-2.0). Pick the smallest model that produces shippable briefs on the eval set.

#### 1.3 Generator prompt discipline (LOAD-BEARING per ADR-0016 §4)

The prompt fed to the on-device LLM:

1. **NEVER includes raw OCR'd text from `.suppress`-decided events.** Cascade-twice already prevented those from reaching the brain. Structural; not a prompt-level discipline.
2. **Includes ONLY events from the configured time window.** No drift to other days.
3. **Includes the source-event-id alongside each excerpt** so the generator's output can carry source references (structural source-binding, not a hallucination opportunity).
4. **Instructs the model to refuse to invent bullets without a source event.** A bullet with no source ID is a hallucination tripwire — the post-generation validator drops it.
5. **The model's output is post-processed** to verify every bullet carries ≥1 source event ID; bullets without one are dropped with a counter increment (`brief_bullet_hallucinated_count`, content-free).

This is the brief generator's contract: every output bullet is justified by a stored event the user can click through to. The "source-backed memory layer" pitch is structural.

#### 1.4 Per-section heuristics

The generator runs the LLM with section-specific prompts:

- **"What shipped"** — events where `app_bundle_id ∈ {git/GitHub/Linear/Jira/Slack/...} ∧ ocr_text matches commit/PR/ticket-close patterns`.
- **"What changed"** — events that produced significant content shifts (per the dHash + embedding-drift episode segmentation from ADR-0010 §1.2 NEMORI-style heuristic).
- **"What's blocked"** — events containing block / waiting-on / TODO patterns in OCR'd text or window titles.
- **"What needs follow-up"** — events near the end of the window without a closure event in the window.

These are heuristic shortcuts; the LLM does the prose. Eval set at P4.x ratify gate determines whether the heuristics shift.

### 2. Brief lifecycle states (binding state machine)

```
Generated ── user opens draft ──▶ Editing ──┬── user approves ──▶ Approved ──▶ ReadyForUpload (ADR-0019)
                                            │
                                            └── user discards ──▶ Discarded (purged from disk)
                                                                       │
                                                                       └── 30-day TTL ──▶ AutoPurged
```

- **Generated:** the LLM produced a draft. Lives in `~/Library/Application Support/MCI/briefs/<ts>.draft` (encrypted at rest with the same SE-gated DB key per ADR-0008; NOT in the main `mci.sqlite` — separate file so brief drafts can be wiped without touching the brain).
- **Editing:** user opened the draft in the recall UI's brief-author view. Edits + redactions accumulate. State persists across UI close + reopen.
- **Approved:** user explicitly clicked Approve. Brief is locked (no further edits). Ready for upload by ADR-0019.
- **ReadyForUpload:** ADR-0019 territory; the brief gets workspace-key wrapped + queued for upload.
- **Discarded:** user explicitly chose Discard. File deleted; crypto-shred per ADR-0012 deletion semantics.
- **AutoPurged:** if a draft stays in `Generated` or `Editing` state for >30 days, it auto-purges. User-configurable; default 30 days.

State transitions are user-mediated only. No background process moves a brief from `Editing` to `Approved`. **Auto-approve is structurally banned** — implementing it would be a §4 protected-set violation.

### 3. Edit UX (LOAD-BEARING — the user-as-sole-authority moment)

The recall UI gains a new top-level surface: **Today's Brief**. UX:

```
┌─────────────────────────────────────────────────────────┐
│  Today's Brief — 2026-05-20, 9:14 AM – 5:30 PM          │
│  Status: Editing                                        │
│  ───────────────────────────────────────────────────────│
│                                                         │
│  What shipped                                           │
│    • Merged P2.5 cascade wiring (PR #72)               │
│      [source: 3 events · view]                          │
│    • Cure53 RFQ kicked off                              │
│      [source: 1 event · view]                           │
│                                                         │
│  What changed                                           │
│    • Switched Phase 3 OCR pipeline from ONNX to        │
│      Core ML                                            │
│      [source: 2 events · view]                          │
│                                                         │
│  What's blocked                                         │
│    • (none)                                             │
│                                                         │
│  What needs follow-up                                   │
│    • Email Trail of Bits about v1.1 audit timing       │
│      [source: 1 event · view]                           │
│                                                         │
│  ───────────────────────────────────────────────────────│
│  [Approve & Mark Ready for Upload]    [Save Draft]      │
│  [Redact Section…]   [Discard Brief]                    │
└─────────────────────────────────────────────────────────┘
```

Every bullet has an inline `[source: N events · view]` link that opens the recall-UI hit detail for those events. The user can:

- **Edit** bullet text inline (markdown).
- **Add** a bullet manually (no source required for manual bullets; they're tagged `<user-added>`).
- **Delete** a bullet (counts as redaction).
- **Redact section** — drops the entire section from the brief.
- **Approve** — locks the brief; transitions to `ReadyForUpload` (or `Approved` if no workspace configured).
- **Discard** — purges with crypto-shred.

**Approve gate (LOAD-BEARING):** clicking Approve shows a confirmation modal:
```
You're about to make this brief readable by everyone in your workspace.
This will be visible to: <workspace name>, <N team members>.
The brief contains: <bullet count> bullets, <total word count> words.
[Cancel]   [Approve & Upload]
```

The modal carries the workspace name + team-member count so the user has explicit awareness of who can read. The Approve button is the **only** path from Tier 1 to Tier 2. No keyboard shortcut for Approve (deliberately friction-ful — accidental shares are the failure mode this UX is designed against). User can disable the confirmation modal via a per-workspace setting (off by default).

### 4. Privacy invariants — LOAD-BEARING (CSO veto-gate)

These invariants are why this ADR is protected-set.

1. **User-as-sole-authority.** No brief reaches `Approved` state without an explicit user click. Auto-approve is structurally banned. CSO veto on any code path that transitions to Approved without user action.
2. **Tier-1 store is read-only for the brief generator.** The generator never writes to the brain; it only reads via the existing `BrainStore::get_event` / `fts5_search` / `vec_search` APIs (P3.2). Generator-induced brain writes are a §4 protected-set violation.
3. **Brief drafts are encrypted at rest** with the same SE-gated DB key (ADR-0008). Drafts live in `~/Library/Application Support/MCI/briefs/<ts>.draft` (separate file from `mci.sqlite` so brief wipes don't touch the brain). The file is encrypted via the same `mci-core::store` wrapper; no plaintext path.
4. **Discard = crypto-shred** per ADR-0012 deletion semantics. A discarded brief's per-file key is destroyed; the encrypted bytes are unreadable even if they leak to Time Machine.
5. **Source-event references in approved briefs are ABSTRACT references, not embedded content.** When ADR-0019 uploads an approved brief, it uploads ONLY the user-authored text + source-event-IDs (which are just integers, content-free). The team-side recall doesn't get the raw events — only the brief. The user's full Tier-1 memory stays on their machine. CSO veto on any change that uploads raw event content alongside the brief.
6. **The LLM generator runs on-device.** Zero-network thesis per ADR-0016 §4.4. No remote API call to draft a brief. CSO veto on any network call from the brief-generator path.
7. **The LLM generator reads only `.allow`-stored events.** Same structural invariant as ADR-0016 §4.6 idle-batch worker. Brief generator's input query is `SELECT * FROM events WHERE deleted_at IS NULL` — suppressed events have no row in `events`.
8. **Hallucination tripwire is structural.** Every output bullet carries ≥1 source-event-ID; bullets without one are dropped. Counter (`brief_bullet_hallucinated_count`) is content-free per ADR-0016 §4.7.
9. **No telemetry payload may include brief content.** Telemetry is bullet-count + section-count + word-count + hallucination-drop-count — all integers, no strings. Mirrors §4.7.
10. **Approve UX shows the workspace name + member count BEFORE the click.** User awareness is structural; CSO veto on any "approve silently" path (e.g., bulk-approve, auto-approve, keyboard-shortcut without confirmation).

### 5. How this unlocks F-STRAT-002 + Phase 5

- ADR-0019 (workspace server) becomes designable — its input contract is the `Approved` brief produced here.
- The pricing model (free Personal, per-seat Teams per F-STRAT-002) becomes structural: Personal users never produce approved briefs unless they opt into a workspace; the B2B revenue surface is exactly the set of approved briefs uploaded to workspaces.
- The trust narrative becomes specific: "your full memory stays local; only briefs you author + approve cross to your team; vendor never sees content." Every clause is provable from this ADR + ADR-0019.

### 6. PR sequence — Phase 4.x

Five PRs across Director-Brain + Director-Context. Each protected-set; CSO sign-off blocks.

- **P4.x.1 — `core/brief/` new Cargo workspace member.** Director-Brain. Pure Rust trait surface: `BriefGenerator` / `BriefDraft` / `BriefSection` / `BriefBullet` / `DraftState` / `BriefStore` (encrypted draft persistence). Stubs + scaffold tests. Mirrors `core/brain/` Phase-3-P3.1 pattern. 1 cycle.
- **P4.x.2 — `LlamaBriefGenerator` production impl** (Director-Brain). Bundles `Llama-3.2-1B-Instruct` int4 via Core ML; loads via the same `mci-embed-coreml` adapter pattern from P3.3 (likely extracts a shared `CoreMLModelLoader` to a sibling crate). Implements §1.3 prompt discipline + §1.4 per-section heuristics + the hallucination tripwire. Tests against stub events + canned model output. 1 cycle. **Largest single PR in the Phase 4.x sequence** — model bundling + Core ML wiring + post-process validator.
- **P4.x.3 — `EncryptedBriefStore` production impl** (Director-Brain). Per-draft file under `~/Library/Application Support/MCI/briefs/`. Reuses `mci-core::store` encryption primitives; per-file key derivation via HKDF over master key + brief-id. Crypto-shred on discard. 1 cycle.
- **P4.x.4 — Recall UI brief-author view** (Director-Brain). Extends `apps/recall-ui/` (the P3.9 app) with the Today's Brief surface. SwiftUI markdown editor + source-link clickthroughs + Approve modal + redact controls. 1 cycle.
- **P4.x.5 — Live-Mac authoring audit** (HUMAN-IN-THE-LOOP). User runs the full pipeline: generator produces a draft, user edits + redacts + approves, draft moves to `ReadyForUpload` state (sits there until ADR-0019 lands the actual upload). Audit doc captures the lifecycle + UX latency + LLM generation cost (RAM/CPU/wall-time) on a real workday. 1 cycle.

### 7. Out of scope (deferred)

- **Brief upload to workspace server** — ADR-0019.
- **Cross-team read of briefs** — ADR-0019 + Phase 5.
- **Workspace identity / SSO / enterprise admin** — Phase 5.
- **Brief versioning / edit history** — Phase 9 (retention). v1 ships single-version-per-brief.
- **Multi-author briefs** (one brief authored by multiple users) — out of scope; one author per brief.
- **Cross-day briefs / weekly summaries** — Phase 5+. v1 ships daily.
- **Templated briefs / custom sections** — Phase 4.x.2+. v1 ships the four canonical sections.

## Consequences

- Positive: F-STRAT-002 dual-market becomes engineering-implementable. Tier-2 surface is bounded, gated, and user-mediated.
- Positive: the "source-backed memory layer" pitch becomes structural — every bullet has source-event IDs by construction.
- Positive: the trust narrative ("we never see it") is provable end-to-end after this ADR + ADR-0019 land.
- Negative / tradeoff: bundle size increases by ~700 MB (the small LLM). Mitigated by lazy-download from a signed update channel at first-brief-generation if installer-size becomes a v1 adoption blocker — CSO + COO decide at Phase 4.x.2 entry.
- Negative / tradeoff: LLM generation is the most expensive thing MCI does. 5-10 s per brief on M-series hardware. Acceptable for daily briefs; would be unacceptable for on-demand. Default to scheduled-only generation; on-demand is an opt-in.
- Negative / tradeoff: 5-PR Phase 4.x sequence adds ~1-2 weeks to the v1.0 launch target. COO GTM doc target (2026-09) holds if Phase 5 runs in parallel.
- Forces (binding):
  - Auto-approve is structurally banned (§4.1).
  - No raw-event-content alongside approved briefs (§4.5).
  - Generator never writes to brain (§4.2).
  - Discard = crypto-shred (§4.4).

## CSO sign-off (placeholder — owed at first protected-set PR)

§4 invariants binding. CSO sign-off blocks on every PR in §6 asserting (by reading the diff) that the invariants hold. CSO veto final unless human CEO overrides.

— CSO, pending (owed at PR P4.x.1)

## References

- **F-STRAT-002** (this same `docs/AGENT_QUESTIONS.md` 2026-05-20 afternoon entry) — the dual-market commit this ADR operationalizes.
- **ADR-0001** (privacy posture), **ADR-0008** (encrypted store — brief drafts use the same primitives), **ADR-0012** (zero-knowledge spec — crypto-shred discipline + per-segment-key destruction), **ADR-0013** + Amendment 1 (cascade-of-suppression — runs at capture; this ADR adds cascade-of-trust at brief-time), **ADR-0015** (Phase 2 context join — provides `app_bundle_id` + `window_title` + `url` that the generator reads), **ADR-0016** (Phase 3 OCR + brain — provides OCR'd text the generator reads), **ADR-0017** (Phase 4 privacy controls — gives the user-facing pause/denylist/retention controls this ADR layers on top of), **ADR-0019** (incoming, workspace server — consumes this ADR's output).
- `docs/business/2026-05-20-gtm-positioning.md` — the COO GTM doc that needs revision for F-STRAT-002 + this ADR.
- DESIGN.md §15 Phase 4 (privacy controls + onboarding UX) — Phase 4.x extends scope to brief authoring.

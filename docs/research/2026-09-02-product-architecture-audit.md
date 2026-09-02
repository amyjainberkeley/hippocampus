# Hippocampus Product And Architecture Audit

Date: 2026-09-02

This is the product and architecture decision record. `docs/STATUS.md` remains
the sole source of truth for what the current build actually proves. This
document explains what Hippocampus should become, why, and in what dependency
order. It does not turn roadmap intent into a shipped claim.

## Executive Verdict

Hippocampus should be a local evidence compiler for a person's work, not a
generic second brain, another chat application, a team ETL platform, or a
screen-recording archive.

Its first promise is:

> Hippocampus turns what happened on your Mac into small, cited, current
> context that you and any agent can trust.

The first customer should be a technical prosumer who already uses Claude
Code, Codex, Cursor, a terminal, GitHub, and meeting or note tools. The initial
buyer and user are the same person. Team memory is a later projection over
explicitly shared evidence, not the first ingestion boundary.

The core moat is not capture alone, local storage alone, embeddings, a graph,
or an MCP server. Each is reproducible. The moat is the measured loop:

1. Capture the right evidence without capturing protected or irrelevant data.
2. Preserve its source, time, scope, and revision history.
3. Compile it into current state without erasing contradictions.
4. Refuse to answer when evidence is insufficient.
5. Deliver a bounded, cited packet at the moment a human or agent needs it.
6. Let the person inspect, correct, delete, and improve that loop locally.

That is meaningfully different from Turnstone's broad "one brain shared by
every agent" positioning. Hippocampus should win on evidence quality and
control for technical work: what changed, why it matters to me, what I am
committed to, and what my agents need to know now.

## Repository Truth

There have been three products using overlapping names:

| Location | Actual identity | Decision |
|---|---|---|
| `/Users/amy/hippocampus` | A hosted Next.js ETL demo with mocked AI and unwired production integrations | Historical prototype; do not build the memory product here |
| `/Users/amy/mci` | Earlier personal local-memory implementation and handoff material | Historical evidence; mine deliberately, do not revive as a second source of truth |
| `/Users/amy/hippo-work/hippocampus` | Native macOS app, helper, encrypted Rust brain, Recall UI, onboarding, MCP, release controls | Canonical product |

The current sprint runs in the `hippocampus-v1` worktree on the
`codex/hippocampus-v1` branch. `docs/STATUS.md` is canonical release truth.

## What Is Good

### The foundation is substantially real

- The brain is an encrypted SQLCipher event ledger, not a browser mock.
- The app supervises a real ScreenCaptureKit helper and Rust agent.
- Capture can be turned off at every ingest boundary, not merely hidden in UI.
- Ambient OCR excludes browsers; browser extensions must establish a
  non-private context before structured content can cross the boundary.
- Search, timelines, episodes, briefs, deletion, retention, export, and MCP
  tools have executable implementations.
- `mci_context` already compiles bounded evidence with canonical event
  citations and typed outcomes.
- Claude Code and Codex can be connected together from onboarding or the menu
  without writing the database key into either client configuration.
- The semantic index stays inside the encrypted database. Hippocampus does not
  need a separate vector-database service.
- Release scripts fail when model, signing, identity, launch, or notarization
  requirements are missing instead of quietly publishing a partial artifact.

### Several architectural choices are unusually mature

- Raw events remain the source of truth while episodes, entities, embeddings,
  briefs, and future claims are rebuildable projections.
- Capture refusal happens before memory ingestion where possible. Post-hoc
  redaction is not treated as the only privacy control.
- Retrieval outcomes distinguish matched, insufficient evidence, and degraded
  execution. That distinction is essential for agent trust.
- Sparse encrypted keyframes can remain available as evidence without making
  every query carry raw screenshots.
- The clean-home E2E exercises the same binaries and wire formats the product
  uses instead of substituting an in-memory demo stack.

## What Is Bad

### 1. Product identity has been fractured

The old web product says ETL, the historical local product says personal
memory, and some repository language says project or team memory. A user
cannot tell whether Hippocampus is a database, a screen recorder, a chat app,
or an agent. The canonical promise above must govern the app, website, docs,
benchmarks, and launch copy.

### 2. Live proof trails the code

Synthetic wire tests are strong, but they do not prove focused-window OCR on
an unlocked Mac, cross-window exclusion, TCC revocation, all-day resource use,
or signed-update Keychain continuity. The product is much closer to a working
development build than the old web demo suggests, but it is not yet a public
Apple release.

### 3. Retrieval ranking is ahead of retrieval judgment

The accepted 24-case work-memory corpus shows that hybrid candidate generation
finds the answerable evidence and, as every nearest-neighbor system will, also
finds nearby material for deliberately unanswerable queries. The production
decision path abstains on all three unanswerable cases, but still labels every
answerable ranking as verifier-unavailable rather than a trusted match. General
semantic support and contradiction judgment remains a launch gate, not polish.

### 4. The visual system hides the quality of the engine

Dark, saturated, gradient-heavy surfaces and generic card treatments make the
app look generated. The product needs a restrained native shell: system
materials, clear source and time hierarchy, lightweight transitions, and one
obvious action per state. Evidence thumbnails must show useful evidence rather
than decorative branding.

### 5. Some security and lifecycle controls were development-shaped

The sprint found temporary key custody, readiness publication, private-browser
handling, and runtime error paths that were weaker than the claims around
them. Those are being replaced with explicit development capabilities,
atomic readiness, fail-closed browser context, and supervised terminal failure.
Destructive mutation now takes the same OS-held writer lease as ingestion.
Remaining release risk is live capture and signed-install verification, not a
PID-only deletion guard.

### 6. The code carries process archaeology

Long cycle-number comments, stale historical claims, duplicated client
registration wrappers, and surfaces that exist because a past milestone asked
for them make the system harder to reason about. This is not a reason for a
broad rewrite. Delete or shorten archaeology only when a touched module gains
a clearer invariant and equal or better tests.

### 7. "Connect everything" still asks too much of a normal person

The product can connect Claude Code and Codex in one click, but the flow still
talks in MCP nouns and exposes optional server registration. V1 should require
no knowledge of MCP, embeddings, models, or database paths. Advanced local
connectors can remain available after the first useful memory is visible.

## What Is Vibe-Coded Slop

This label should be reserved for code or product behavior that looks complete
without carrying its operational truth:

- The old Next.js shell returning mock AI output while presenting a production
  product.
- A capture counter that can rise while a downstream kill switch writes zero
  memory, with no visible failure state.
- A sophisticated graph walk without a one-seed completion test.
- Taking the maximum of unrelated lexical, vector, and deterministic scores as
  if they shared a calibrated scale.
- UI that explains internal machinery rather than giving the person an outcome.
- Tests that prove a fixture can emit pixels but not that the installed app
  includes the focused window and excludes the overlapping background window.
- Privacy copy that says "local" without saying when selected context leaves
  the Mac for a model provider.

The current canonical repository also contains the opposite of slop: strict
release gates, encrypted storage, fail-closed policy parsing, typed outcomes,
and clean-home execution. The cleanup strategy is to remove false confidence,
not flatten the parts that are genuinely rigorous.

## Runlog Verdict

Do not merge Runlog into Hippocampus. The detailed code audit is in
`docs/research/2026-09-01-runlog-verdict.md`.

### The useful parts

1. Source-backed claims retain who or what asserted a fact.
2. Contradictions coexist until evidence resolves them.
3. Stable content identity allows incremental projection and retraction.
4. An identity ladder tries exact and cheap matches before semantics.
5. Watermarks make compact operating memory reproducible from evidence.
6. Typed outcomes preserve "nothing matched" and "degraded" at the boundary.

### Why the current Runlog retrieval does not work as Hippocampus's core

1. It is not vectorless. It stores Gemini embeddings and calls Firestore
   nearest-neighbor search. The honest distinction is no separate vector DB.
2. Its required Firestore vector index was recorded as undeployed.
3. Its graph pathfinder has no demonstrated useful completion from one source.
4. Max fusion compares incompatible score scales and can let one arm dominate.
5. Model extraction and embeddings can fail before dependable lexical recall.
6. Map iteration and first-oversize packing make output unstable or sparse.
7. Typed internal truth is not consistently preserved at public boundaries.
8. Tenant and index correctness depend too heavily on deployment operations.

### Adaptation boundary

Bring claims, evidence links, retractions, scopes, projector versions, and
watermarks into a shadow local projection. Do not import Go, Firestore, GCS,
Pub/Sub, hosted inference, cloud auth, Cells/Factions product language, or the
existing fusion algorithm. Promote the projection only after it improves
temporal updates, contradictions, provenance, and abstention in a benchmark.

## Why Not Dump Everything Into RAG

"Put every screenshot in a vector index" fails for five reasons:

1. Near-duplicate frames dominate candidates and cost.
2. Embeddings blur source authority, revision order, and contradiction.
3. A visually or semantically similar old state can outrank the current state.
4. Raw retrieval gives an agent too much private material for the task.
5. Similarity always produces a nearest item even when no item is sufficient.

The local pipeline should instead be:

```text
capture envelope
  -> source/privacy gate
  -> OCR or structured extraction
  -> content digest + deduplication
  -> immutable event ledger
  -> episode/entity/claim projections
  -> lexical + semantic candidate generation
  -> temporal and provenance expansion
  -> explicit answer-shape relation guard
  -> local support / refute / insufficient verifier
  -> calibrated set-level evidence decision
  -> bounded cited context packet
  -> human or agent
```

Raw visuals are evidence on demand, not the default index payload. The index
stores compact textual and structural representations; a cited keyframe is
loaded only when a visual question needs it.

## Consumer Or B2B

### Decision: prosumer first, B2B pull-through

Pure consumer is a large vision but a weak first wedge: the privacy explanation
is harder, the value is diffuse, and support burden is high. Enterprise-first
creates procurement, admin, compliance, and multi-tenant requirements before
individual usefulness has been proven.

Technical prosumers are the useful middle:

- They lose context across terminals, repositories, browsers, chats, and AI
  sessions every day.
- They understand the value of local custody and inspectable evidence.
- They already use MCP-capable agents.
- They can tolerate a macOS permission walkthrough if value appears quickly.
- They can become internal champions after the individual loop works.

The first paid outcome is not "store my life." It is:

> Start a Claude or Codex session and immediately recover the relevant changes,
> decisions, commands, promises, and open loops, each linked to evidence.

The B2B product should later add policy, shared scopes, audit, explicit publish,
and team projections. It must not silently turn private personal capture into a
company surveillance feed.

## What Technical Builders Actually Want

1. **Zero re-explaining:** the current repo, issue, recent commands, decisions,
   and failures are available without maintaining another note.
2. **Small context:** a cited packet that spends hundreds of tokens, not a dump
   of thousands of events.
3. **Current truth:** superseded choices are visibly superseded.
4. **Trust:** the agent can say why it believes something and can abstain.
5. **Local control:** pause, app exclusions, retention, delete, export, and no
   hidden cloud copy.
6. **Interoperability:** Claude, Codex, Cursor, terminals, and future agents use
   one local memory through an open protocol.
7. **Automation discovery:** repeated commands and work transitions become
   suggestions only after enough evidence exists, never fabricated habits.

Builders can assemble a vector store or an Obsidian vault. The difficult part
they should not have to rebuild is trustworthy capture, temporal consolidation,
privacy governance, calibration, and cross-agent delivery.

## Lessons From Desktop Products

### HeyClicky: copy interaction, not architecture

The strongest ideas to adapt are:

1. A menu-bar presence with one global shortcut.
2. Context at invocation without a setup prompt.
3. Plain-language and later voice input.
4. Visible guidance anchored to the current work surface.
5. Long work handed to background agents with clear status and return points.

Do not copy its data architecture. HeyClicky's trust page says it only reads the
screen on hotkey, stores generated analysis and prompts in the cloud, performs
nothing locally, and collects no screen or files in the background. Its landing
page simultaneously describes passive real-time screen reading. Hippocampus
should avoid that ambiguity by making capture state and custody mechanically
visible.

### Granola: immediate utility before configuration

Granola centers the first screen on the next meeting and the person's notes,
uses a short demo to teach the product, keeps notes private by default, and
makes the artifact useful before asking users to organize a knowledge system.
Hippocampus should open on "Now" and show a truthful first captured memory
within minutes, then offer a daily brief after evidence accumulates.

### Raycast and Wispr Flow: ambient entry, deep home

Raycast makes commands predictable through one invocation point and an
installable ecosystem. Wispr Flow works across apps through one hotkey while a
separate hub owns history and personalization. Hippocampus should mirror that
shape: global recall for the common path, a full evidence workspace for review,
and a narrow extension contract rather than a plugin maze.

### Rewind/Limitless: a timeline is not a durable product outcome

Limitless's official site says Rewind screen and audio capture was disabled in
December 2025 and the desktop/web recording path was sunset after the Meta
acquisition. This does not prove capture is useless. It demonstrates that a
large searchable archive is not enough by itself. Hippocampus must make memory
act: update the current work state, prepare the next session, surface promises,
and improve agent decisions.

### Obsidian and Mem0: manual memory creates maintenance work

Obsidian's local files and extension ecosystem are powerful, but users choose a
vault, author notes, select sync, and configure plugins. Mem0/OpenMemory exposes
portable memory tools, but its core interaction remains an agent or person
deciding what to add, search, update, or delete. Hippocampus's opportunity is
evidence acquired from work with source and time already attached, followed by
reviewable consolidation.

## Eight-Part Build Order

The order is based on dependency and falsifiability, not calendar estimates.

| Order | Gate | Why it gates later work | Current sprint state |
|---:|---|---|---|
| 1 | Canonical repository and release truth | No benchmark or release matters if it targets the wrong product | Established |
| 2 | Reliable supervised runtime and key custody | Capture, deletion, and agent handoff require one healthy local authority | Development path and owner-death shutdown verified; public signing remains external |
| 3 | Capture privacy and terminal failure | Bad input poisons every later memory layer | Browser authorization, private-context exclusion, pause, lock, and TCC behavior are executable; a real ScreenCaptureKit sample reached the helper, but denied Accessibility kept OCR out of the brain and exact overlap proof remains open |
| 4 | Retention, deletion, and writer quiescence | A user must be able to withdraw evidence safely | Complete, including process-held writer lease and orphan reconciliation |
| 5 | Live focused-window corpus and soak | Synthetic wire tests cannot qualify real capture | Deterministic overlap app built; the helper receives live frames and the isolated encrypted brain opens, but denied Accessibility produced zero OCR events, so focused-token/background-token proof and soak remain pending |
| 6 | Evidence sufficiency benchmark | Useful memory must know when not to answer | Retrieval ranking and explicit relation veto pass; the host provenance contract and fail-closed Core ML adapter exist, but no task-trained artifact or manifest has passed blind qualification |
| 7 | Native product experience | A correct engine users cannot understand will not be trusted | Light native UI and release assets implemented; the disposable product capture visibly proves three authenticated keyframes, 20 events, and one brief |
| 8 | Signed distribution and update proof | Public use requires identity, notarization, models, and continuity | Ad-hoc bundle passes launch/owner-death checks; Developer ID and notarization remain external |

## V1, V2, And V3 Product Boundary

These are capability boundaries, not promises that unverified work ships.

### V1: trusted personal work memory

- macOS menu-bar app and global recall shortcut.
- Explicit opt-in capture with focused-window privacy controls.
- Structured browser capture only in proven non-private contexts.
- Encrypted local events and sparse encrypted visual evidence.
- Search, timeline, episodes, "Now," and a daily work brief.
- Source/time citations and calibrated insufficient-evidence responses.
- One-click Claude Code and Codex connection.
- Bounded `mci_context` packets; no full-history prompt injection.
- Inspect, pause, exclude, retain, export, delete, and wipe.
- Reproducible synthetic benchmark plus live capture qualification.

### V2: current-state and workflow memory

- Evidence-backed claims with supersession, contradiction, and retraction.
- Project and person scopes inferred locally, then editable by the person.
- Commitments, decisions, open loops, and changed assumptions in briefs.
- Habit and workflow suggestions only after minimum support thresholds.
- On-demand raw visual grounding for questions that require pixels.
- Vendor-neutral memory operations and a stable local extension SDK.
- More agent clients, with per-client disclosure and context budgets.
- Optional encrypted device sync where the user controls keys and scope.

### V3: personal computer control plane

- Agents consume current work state and propose actions across applications.
- Every action is separated from memory and passes an explicit capability,
  preview, approval, and audit boundary.
- Personal memory stays private; team knowledge receives explicit publication
  with source and revocation semantics.
- Repeated workflows can become local automations with measured success,
  rollback, and human override.
- The UI becomes an inspectable activity and intent layer while agents do more
  routine computer work in the background.

V3 should not be implemented by giving one model unrestricted access to the
screen, memory, network, and input devices. Memory, planning, and action need
separate authorities so a corrupted observation cannot silently become an
irreversible action.

## Memory Architecture Decisions

### Preserve evidence before interpretation

An immutable event should carry timestamp, source kind, app/window identity,
capture policy decision, content digest, redaction version, and optional blob
reference. Summaries and claims cite event IDs. Updating a claim never rewrites
the evidence that produced its older state.

### Use hierarchical projections, not one flat index

- Short horizon: recent events and active episode.
- Work horizon: episodes, entities, decisions, commitments, and project state.
- Long horizon: stable preferences, procedures, relationships, and habits.

Each promotion requires support, recency, scope, and contradiction checks.
Long-lived memory should be harder to write than an event.

### Retrieve in stages

1. Parse deterministic time, source, app, project, and identifier constraints.
2. Run lexical retrieval even if models are absent.
3. Add semantic candidates within a budget.
4. Expand through typed episode/entity/claim edges.
5. Prefer current supported state while retaining superseded evidence.
6. Veto explicit person, count, duration, and date questions when no retrieved
   sentence relates a correctly shaped value to the requested fact.
7. Run a separately calibrated local verifier over the question and compact
   evidence set. Its internal evidence budget is independent of the number of
   results the caller wants displayed. Retrieval similarity is an input, never
   proof of support.
8. Pack the smallest useful evidence set with deterministic tie breaks.

### Make abstention a product surface

An empty answer is not an error. The response should state one of:

- `matched`: sufficient evidence and citations.
- `insufficient_evidence`: the brain is healthy but cannot support the claim.
- `degraded`: a required retrieval arm or model was unavailable.

The UI should offer a narrower time/source query or show what evidence is
missing. Agents must receive the same typed outcome.

### Keep action downstream of memory

Capture observes. Memory preserves and compiles. Agents plan. An action service
executes only within explicit capabilities and approval policy. This separation
is the answer to the Meta MCI failure mode: information is governed for the
person, and merely remembering something does not grant authority to act on it.

## Evidence Behind The Major Decisions

The user's three-source rule is applied to major irreversible decisions. It is
not used as fake precision for every button or implementation detail.

### Decision A: structured, temporal memory instead of flat RAG

- LifeBench reports only 55.2% for leading systems on long-horizon,
  multi-source declarative and procedural memory:
  https://arxiv.org/abs/2603.03781
- HorizonBench identifies updated-state tracking as the main bottleneck; more
  than a third of preference errors select stale original state:
  https://arxiv.org/abs/2604.17283
- MemoryOS reports gains from short-, mid-, and long-term storage with explicit
  update, retrieval, and generation modules:
  https://arxiv.org/abs/2506.06326

### Decision B: compact indexes with raw visuals on demand

- M3Exam reports cross-modal and context-cost gaps; its on-demand raw-visual
  method improves accuracy 13% while cutting index time and retrieved tokens by
  more than 70%: https://arxiv.org/abs/2606.07402
- Screenpipe's own architecture combines accessibility text, OCR fallback, and
  local search rather than treating every frame as the same artifact:
  https://github.com/screenpipe/screenpipe/blob/main/README.md
- Hippocampus's local overlap corpus and sparse encrypted keyframe design give
  this choice a product-specific executable gate, recorded in `STATUS.md`.

### Decision C: governed consolidation and source-bound deletion

- SSGM separates memory evolution from execution and requires consistency,
  temporal decay, and access control before consolidation:
  https://arxiv.org/abs/2603.11768
- memorywire makes provenance central to recovery from poisoned memory and
  defines reviewable remember/merge/expire/forget operations:
  https://arxiv.org/abs/2606.01138
- OpenAI's Codex safety description emphasizes explicit boundaries, approval
  for higher-risk actions, secure key storage, and agent-native auditability:
  https://openai.com/index/running-codex-safely/

### Decision D: open agent interface, product-owned context compiler

- MCP is an open protocol for connecting models to context and tools:
  https://docs.anthropic.com/en/docs/mcp
- Claude Code exposes MCP registration and persistent project instructions, but
  users must curate those instructions and keep them current:
  https://docs.anthropic.com/en/docs/claude-code/cli-usage
- OpenAI describes richer App Server semantics alongside MCP, demonstrating
  that an open tool boundary and a product-specific local runtime can coexist:
  https://openai.com/index/unlocking-the-codex-harness/

### Decision E: prosumer-first outcome, not lifelog-first archive

- Granola's product centers an immediate before/during/after meeting outcome
  and private-by-default artifacts: https://www.granola.ai/
- HeyClicky centers invocation, plain-language intent, and background handoff,
  even though its custody architecture differs: https://www.hiclicky.com/trust
- Limitless officially sunset Rewind's screen/audio capture path, warning
  against treating recording itself as durable value: https://www.limitless.ai/

### Decision F: verify answerability separately from retrieval

- SURE-RAG treats topical retrieval and evidential support as different tasks,
  then aggregates pair-level support, contradiction, disagreement, and
  uncertainty into a three-way selective decision:
  https://arxiv.org/abs/2605.03534
- UAEval4RAG evaluates answerable accuracy and unanswerable rejection together
  and finds that component and prompt choices materially change that balance:
  https://aclanthology.org/2025.acl-long.415/
- Ye et al. formulate grounded checking as constrained true/false reading
  comprehension and show that small verifier models can replace expensive open
  generation while retaining competitive factuality performance:
  https://aclanthology.org/2026.acl-long.1468/

Therefore Hippocampus does not treat Arctic Embed S similarity, rank margin, or
fusion score as entailment. The qualified explicit relation guard handles four
common high-risk answer shapes today. General `Matched` status remains blocked
until a compact local question/evidence verifier passes disjoint answerability,
counterfactual-swap, contradiction, and latency tests. A SQuAD2-style MiniLM
reader was tested as that spike and rejected: it was fast in PyTorch but reached
only `0.833` held-out positive coverage with `0.333` negative false-positive
rate, confidently extracting concrete-sounding placeholders from insufficient
evidence. A DeBERTa-v3-xsmall NLI spike was semantically promising on a few
hand-authored cases but its relative-position attention graph failed conversion
through the pinned Core ML toolchain, so it was rejected as the immediate Mac
path. ADR-0038 fixes the architecture: a verifier sees atomic claims, canonical
event slots, and host-bound provenance but no retrieval scores; trusted support
must select slots from that set; malformed output and runtime failure degrade
instead of becoming hits. The host contract now enforces bounded canonical
spans, exact scope, one brain, and revalidatable provenance. A native adapter
for the selected task-trained MobileBERT three-way classifier and citation-slot
head also exists. It requires a qualification manifest pinned into the signed
binary, exact non-flexible tensor schema, unique paired evidence markers,
complete-slot retention after truncation, explicit brain authorization, and
explicit policy abstention. It still needs a trained
redistributable artifact, a blind claim-level corpus, real Core ML parity
results, signed-runtime execution, and minimum-Mac latency proof before it
enters the release manifest or production.

## Immediate Definition Of Done

The development MVP is done only when all of these are true on the canonical
commit:

1. A freshly assembled app launches and keeps helper and agent healthy.
2. Capture-off creates no observations at any ingest boundary.
3. Locked/protected/private surfaces create no memory.
4. On an unlocked desktop, the focused corpus token is recalled and the
   overlapping background token is absent.
5. A capture soak records bounded CPU, memory, disk, OCR, and error behavior.
6. Delete, range delete, retention, and wipe cannot race the ingestion writer.
7. The work-memory benchmark passes answerable and unanswerable gates without
   tuning to literal query strings.
8. Recall, timeline, episodes, brief, privacy, and AI connection are usable in
   the rebuilt light native UI.
9. A clean home connects Claude Code and Codex and receives a cited bounded
   context packet without serializing key material.
10. `scripts/check.sh`, the clean-home E2E, focused Swift tests, Rust tests,
    strict Clippy, assembly, code-sign verification, and launch verification
    pass to the extent this host supports them.

Public release adds the external gates in `docs/STATUS.md`: complete release
models, full Xcode tests, Developer ID identity, notarization, stapling, and a
clean second-Mac update/Keychain/TCC continuity run.

## Founder Decisions Still Worth Testing

1. Is the first repeated habit "resume my work," "review my day," or "brief my
   agent"? Instrument all three, then choose the one with repeated pull.
2. How much visual evidence makes trust rise before surveillance anxiety rises?
3. Which memories are private forever, project-scoped, or explicitly published
   to a team?
4. What false-positive rate makes a proactive commitment reminder annoying or
   dangerous?
5. Will users pay for local capture and agent handoff, or is team governance the
   first durable paid layer?
6. Which actions are safe to suggest, preview, or automate, and what proof is
   required at each level?
7. Can an open-source core create trust and integrations while a paid signed
   Mac distribution, sync, and team policy fund the company?

The near-term build should answer these with observable product behavior, not
with another abstract memory framework.

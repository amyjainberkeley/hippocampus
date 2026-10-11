# Hippocampus 0.3: a Mac that understands how you work

Owner's success criteria (2026-10-10), broken into steps. Each step ends with
something verified on the owner's Mac, not only in tests.

## What exists (mapped 2026-10-10)

- Capture: focused window and whole screen (ADR-0040), on-device OCR,
  browser pages through extensions (Chromium unpacked, Safari appex).
- Activity: 5-second active/idle intervals per app (`measured_activity`). No
  input counts, no dwell or app-switch signals.
- Understanding: episodes split by app switch or 10-minute gap, with no titles
  or summaries. `memory_claims` exists with confidence, evidence and
  supersession, but nothing in production writes it. Briefs are extractive.
- Recall popup: search only (Rust FFI, read-only), no knowledge of what is on
  screen, no answers, no suggestions before typing.
- Search queries are not extracted. No day breakdown by hour, project or kind
  of work.

## Model choice

GUM (Shaikh et al., 2025, arXiv 2505.10831) runs Propose, Retrieve (BM25,
recency decay, MMR), Revise and Audit on a 70B model. On a Mac the native,
private equivalent is Apple's on-device Foundation Models framework (macOS 26,
Apple Intelligence): no download, guided generation into typed structs,
available on the owner Mac (verified: a structured proposition in 7.3 s cold).
Where it is unavailable, every feature falls back to deterministic summaries;
nothing leaves the Mac either way.

## Steps

1. **Identity.** New mark: a golden-ratio curl (the hippocampus's seahorse
   shape) with a "now" dot, blue on a graphite tile. App icon, menu bar
   template, DMG volume icon, extension icons, README, brand tests.
2. **Signals beneath the surface.** Input counts per 5-second interval (keys,
   clicks, scrolls; counts only, from system counters that need no extra
   permission), app and window switches, and dwell. Derived per moment:
   *reading* (visible, scrolling, little typing), *paused* (window held, no
   input), *searching* (search URLs and query text), *revisiting*, and
   *stuck* (back-and-forth between the same windows, repeated reformulated
   searches, long dwell on error text).
3. **Searches and tabs.** Search queries extracted from URLs (Google, Bing,
   DuckDuckGo, Kagi, Perplexity, YouTube, GitHub, Stack Overflow, Wikipedia,
   Amazon, X, Reddit, ChatGPT and Claude share links). Extension: capture tabs
   that were already open, re-read pages that change after load, name Arc and
   Brave correctly.
4. **Transcripts.** Surface: a clean, deduplicated, time-ordered record of what
   was on screen per episode. Beneath: episode titles and summaries, and what
   the signals say about the moment ("paused 4 min on the pricing table,
   searched 'team plan pricing' twice").
5. **User model (GUM on device).** Observations per episode → Propose
   (proposition, reasoning, confidence 1-10, decay 1-10) → Retrieve (FTS5 BM25
   with recency decay and MMR) → Revise (merge, strengthen, contradict) →
   stored with evidence links. Privacy audit: sensitive sources never reach
   it (they are excluded at capture), and propositions about third parties'
   private data are refused by the prompt contract and a filter.
6. **Your day and how you work.** Time per hour, app, project and kind of work
   (deep work vs. fragmented), focus blocks, switches, searches, where you
   paused or got stuck, and a written report from those facts and the user
   model. In the app, in the command bar, and over MCP (`mci_day`,
   `mci_searches`, `mci_user_model`).
7. **Command bar.** A Raycast-style panel on ⌃⇧Space that already knows what
   you are looking at: suggestions before you type (continue what you were
   doing, what you just looked up, related memories for the current screen),
   answers to questions in plain language with citations (Foundation Models
   over retrieved memory and the user model), and actions: copy context for
   any AI, open the source, today's report. Native materials, keyboard first.
8. **Onboarding that just works.** Fewer steps, permissions detected without
   restarts, login item on by default, no unannounced prompts, browser setup
   that is as close to one click as each browser allows, a final check that
   proves capture is storing.
9. **Ship.** Every step verified live on the owner Mac, notarized release.

## Progress (2026-10-11)

Steps 1–8 are built and on `claude/hippocampus-0.3`; each verified as recorded
in [STATUS](../STATUS.md). Still open: confirming or rejecting propositions in
the app (the store supports it; MCP and the command bar read it), the Safari
extension's late-page reading, a richer day view in Recall, and step 9
(publishing).

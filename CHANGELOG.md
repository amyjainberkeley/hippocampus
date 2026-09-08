# Changelog

User-facing changes to Hippocampus are recorded here. Internal implementation
commits are intentionally omitted from release notes.

## [Unreleased]

### Daily review and handoff

- Open to a day-scoped review instead of another history feed. Search, History,
  and Sessions retain distinct destinations; existing Brief links remain usable.
- Inspect the last saved context, observed returns to an app, and gaps between
  available screen samples. Every observation links to its evidence. These are
  saved observations, not measured work time or claims that a task is complete.
- Keep current capture health and the daily handoff within reach at the top.
  Preview bounded source excerpts before copying or exporting, and recheck the
  source text and identity before anything is shared.
- Simplify the website around the actual Mac app, local memory, and selected
  context sharing. Keep installation, privacy and source details one click away.

### Everyday recall

- Start human search in Text mode. Related context is a separate choice; raw
  retrieval ranks are no longer presented as confidence percentages.
- Apply app, date and URL constraints before limiting Text results or filtered
  history. Calendar date ranges no longer include the next day's midnight.
  Unsupported Related filter combinations are explained rather than silently
  returning a misleading empty result.
- Read and copy the selected memory's stored text, not just its list preview.
  Reads are bounded at 128 KiB and clearly label truncated or unavailable text.
  The screenshot inspector preserves source citations in its full-text export.
- Remove the repeated filmstrip from every destination. Evidence panes adapt
  to a smaller window, with back navigation when there is not room for both.
- Keep contextual command updates from redrawing the entire workspace. Show
  readable text without its duplicated internal header; copy preserves the
  stored content and the screenshot export preserves its citations.
- Measure managed storage on request, including screenshot files and database
  sidecars. Show partial and unavailable measurements without guessing a total.
- Explicitly release a completed command's writer lock even when a duplicated
  descriptor remains; retain the daemon's protection through process teardown.

### Memory quality

- Recover more small text with bounded on-device OCR subregions inside the
  permitted focused window. Preserve complete OCR passes for secret detection;
  timeouts still discard all text, and capture coverage does not expand.
- Treat pasted `AND`, `OR`, and `NOT` as literal search terms. Keep internally
  generated fallback alternatives separate from user query syntax.
- Restore dictionary alias matches when semantic search is unavailable, without
  letting oversized optional aliases break the original search.
- Remove repeated browser menu lines from daily drafts and omit potentially
  clipped final lines whose missing qualifier could change their meaning.
  Original memory and source citations remain available.
- Show the focused-window capture area explicitly in Preferences.

### Onboarding

- Route Safari setup through the browser launcher and keep its concurrent
  completion outside the main-actor view model. Unit tests no longer open a
  real Safari window or schedule its Settings action.

### Capture reliability

- Replenish automatic recovery after five minutes of a ready, committed capture
  run instead of exhausting ten retries across an entire day. Keep rapid-crash
  backoff bounded, preserve stop/pause/revocation guards, and report exhaustion
  explicitly in the menu-bar error state.
- Distinguish absent optional Accessibility labels from failed reads when
  checking ordinary text views. Keep real keyword-probe errors and secure-field
  detections blocking capture.
- Preserve failed and malformed Accessibility child reads through privacy
  checks. Incomplete bounded traversal remains unknown, never proof of safety.
- Diagnose unclassified Accessibility checks with rate-limited local error
  codes and outcomes, without logging screen text or fetching extra attributes.
- Bind captured frames to the focused-window stream generation so focus changes
  cannot attribute stale pixels to a newly focused app.
- Resolve public AX focus to one unique WindowServer surface twice, failing
  closed on ambiguous geometry or a same-application window switch.
- Retry static-window OCR after an empty, timed-out, or dropped recognition job
  without weakening focused-window or protected-surface privacy checks.
- Treat unexpected stream loss and failed teardown as terminal capture failures
  instead of leaving a healthy-looking helper with no live capture source.
- Keep qualification diagnostics content-free and fail the live gate when the
  capture helper cannot shut down cleanly.
- End live qualification through the packaged parent-lifetime lease and prevent
  resource samplers from holding capture pipes open during graceful shutdown.

### Product and demo truth

- Keep the Recall evidence-strip label readable beside real encrypted keyframe
  previews and verify the label in the canonical product screenshot.
- Resolve the verified repository-local Arctic model explicitly in disposable
  demos, require all 20 synthetic events to be embedded in semantic mode, and
  disclose degraded lexical-only mode when the artifact is absent.
- Strip text and EXIF metadata from canonical product captures and reject
  personal paths, email addresses, and common credential shapes during OCR
  asset verification.

## [0.1.0] - 2026-09-01

### Memory and recall

- Search local work memory with combined lexical and semantic retrieval, then inspect the source context behind each result.
- Review recent activity and open recall, privacy, and diagnostic surfaces from the native macOS app.
- Run OCR, embeddings, indexing, and retrieval on the Mac without sending captured content to a hosted inference service.

### Privacy and control

- Pause or resume capture and configure app and URL exclusions before content enters the memory pipeline.
- Manage local retention, export, and deletion controls for SQLCipher-backed memory storage.
- Retention removes expired database rows and compacts local storage; it does not claim range-key erasure.

### Integrations

- Ingest permitted browser context and explicitly allowlisted Mail or Messages content when the corresponding macOS permissions are enabled.
- Use bundled on-device models for semantic recall, entity recognition, and local brief generation when those surfaces are enabled.

### Preview limitations

- Live capture remains off by default until the user enables the persisted capture setting. Each change is accepted only after generation-bound helper readiness; physical-Mac TCC and sustained-capture verification are still pending.
- Runtime capture preferences are accepted only after whole-document TOML validation; malformed syntax, wrong types, and duplicate semantic keys fail closed.
- Quit and Quit-and-Restart now wait for verified helper and agent shutdown, escalating from TERM to KILL when needed, before the app exits or relaunches.
- Legacy `dev.key` custody migrates add-only into the macOS file Keychain and removes plaintext only after validation. Cross-version Developer ID ACL continuity for Hippocampus, the capture helper, the agent, and Recall remains an owner release gate.
- The Key Wrap Audit reports whether the item is readable without treating that read as proof of its access-control object. ACL inspection and signed cross-version continuity remain release gates.

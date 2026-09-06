# Hippocampus Status

_Audited on 2026-09-06._

Audited code baseline: `493befe`

This SHA is the immediate committed baseline before this status refresh. The
release assembler requires it to be an ancestor of `HEAD` and no more than
three commits behind. This file is the repository's canonical product and
release truth; README, design docs, release notes, and UI copy must not claim
more than this page.

## September 6 Safety And Usefulness Integration

Code baseline `493befe` adds explicit macOS user-stop handling with a parent
capture-off latch, retired-stream failure isolation, visible stop failures,
read-only quiet-input sampling, source-linked native brief rendering, bounded
extractive drafts and mandatory release advisory/model/launch gates. Details
and remaining work: `docs/audit/2026-09-06-owner-product-ledger.md`.

Optimized native suites passed: capture 674 tests, parent 307, Recall 402 XCTest
plus three handoff tests. Final focused Rust integration passed 17 agent brief,
13 extractive regression, four historic evaluator and two new quality tests.
Strict Clippy for brief/eval and Rust formatting passed. The ten-case synthetic
relevance/source-containment rubric improved from 2/10 to 10/10; this is not
semantic truth or universal prompt-injection qualification.

The broad debug Rust run initially failed two tier2 footprint timing checks
during concurrent native builds. Its result remains a failure pending a quiet
and optimized check. The changed runtime and native UI still require installed
proof from the newly assembled artifact. Until that succeeds, the current
installed and notarized app remains the September 5 `fe285ee` artifact below.
An additional ordinary-window check after about 20 hours of process uptime
increased its committed screen and screenshot counters; this is continuity
evidence for that old build only, not qualification of `493befe`.

Neither measured work time, reviewable commitments, trusted answers, normal/
private-browser and owner-controlled permission qualification, second-Mac
continuity nor public release is newly claimed. The model release manifest
remains UNPROVISIONED. No permissions, keys or user memory were reset.

## Installed Product Repair

The September 5 owner audit found that the installed e7be6f0 app had no
production screenshot blobs and drained thousands of frames with zero stored
screen events. Earlier isolated capture qualification used a special app
allowlist; it did not establish usable capture under the owner's normal
configuration. The historical component qualifications below are not an
end-to-end claim for the repaired installed product.

Current repair implementation and focused tests cover:

- Ordinary identifiable applications are admitted after global capture consent,
  with secure-input, AX uncertainty, explicit exclusions, sensitive-source
  defaults, OCR secret checks, and focused-window generation checks retained.
  Browser pixels require a positively classified normal window with matching
  identity, geometry, and URL. Unsupported/private/ambiguous browser windows
  remain excluded. Live browser qualification is still pending.
- Production binds the desktop-independent focused window at startup, rebind,
  and permission recovery. The previous first-display include filter could
  return blank pixels for a window on another display. Visual evidence now
  requires full-window OCR before the secret gate; dirty-region OCR cannot
  authorize a whole-window screenshot. System consent/security dialogs are
  excluded in addition to the memory application's own windows.
- Fresh AX focused-process queries replace cached NSWorkspace foreground reads.
  A background-timer reproduction showed the cache remaining on the prior app
  after a real foreground switch. Queries now fail closed after 50 ms, allow
  only one outstanding OS request, and never reuse a timed-out result. Focused
  screenshot canvases follow window geometry and are bounded to 1920 pixels
  on the long edge. Installed event 1629 and its native image viewer prove the
  window-sized canvas. Contending focus readers now wait for their own fresh
  query within the same deadline; they do not falsely invalidate focus merely
  because another reader is active. Installed event 1646 reached real Codex MCP
  after this correction.
- Committed capture receipts distinguish saved records/screenshots, suppression,
  disconnected helpers, and storage failures. Imports have separate acquisition
  provenance; unknown historical rows are not guessed to be screen captures.
- New installs default to 90-day retention. Unversioned finite policies require
  review before automatic deletion. The owner's existing seven-day file was
  backed up and explicitly changed to a reviewed 90-day policy.
- Recall opens a light Today workspace with real screenshot references, date
  navigation, screenshot search, visual episodes, an authenticated image viewer,
  source/time details, refresh, and bounded cited exports. Observed spans are
  not measured active time.
- Today generates a model-free cited draft after useful current-day evidence
  arrives. Checks run each minute; subsequent changed-evidence rebuilds are
  limited to once per five minutes. The morning brief owns yesterday's local
  calendar date. Neither unattended path loads Qwen. Optional Qwen NER now
  requires the exact explicit opt-in `MCI_QWEN_NER_ENABLED=1` before model load.
- The old menu process was sampled at roughly 40 GB physical footprint in a
  SwiftUI menu-update loop. Its animated periodic icon was removed and image
  construction bounded. A separate orphan agent was blocked in Core ML while
  Tokio waited for blocking workers; daemon EOF shutdown now has a bounded
  runtime teardown. A 24-minute installed sample used about 56 MB menu RSS,
  35 MB helper RSS, 16 MB agent RSS and 75 MB Recall RSS. This is a point-in-time
  sanity check, not a complete resource/lifecycle qualification.
- Claude SessionStart context and Codex instruction integration are explicit,
  ownership-safe opt-ins. They preserve bounded canonical citations and do not
  install themselves into unrelated client configuration.
- The Recall workspace now links directly to capture, privacy, and AI-context
  preferences. Parent-owned preferences dependencies exist before URL delivery.
  Sources and Settings no longer show an irrelevant screenshot filmstrip.
  A live cold-parent test exposed Launch Services routing these links back to
  Recall, whose bundle identity is shared. The new router targets the exact
  parent executable, acknowledges pane opening, and prevents duplicate parent
  processes with a lifetime lock. Release binaries are built; installed routing
  qualification initially failed because the main-bundle executable lookup
  resolved Recall itself. The named-sibling lookup correction is now verified
  in the installed app: a cold launch opens AI Context, receives its
  acknowledgement and starts one parent without an extra Recall window.
- macOS TCC logs confirmed browser Automation prompts were prohibited because
  the signed parent lacked the Apple Events entitlement. Parent and capture
  helper now receive that capability through both signing paths; other children
  do not. Four signing tests include actual disposable signature readback.
  OS consent is still required. Browser AppleScript execution now permits only
  one outstanding OS request, discards timed-out work instead of accumulating
  it, and never reuses an old answer for a newer request. A behavioral regression
  failed before this change and 34 focused tests pass afterward. Real normal
  and private browser qualification is pending the corrected installed build.

All six repaired release executables built successfully. The first repair app
and DMG were signed, notarized, stapled and installed, but the positive fixture
capture did not pass. One stored screenshot was a system consent dialog, which
exposed the new exclusion requirement; it is not useful-work capture proof.
The subsequent focused-window/full-OCR repair (`17a5fdd`) was signed,
notarized, stapled and installed. Production event 1626 contains the synthetic focused
window token and an encrypted screenshot. The installed native viewer decrypted
and displayed those pixels; native Search returned that event. A normal restart
saved event 1627, which the real Hippocampus MCP connection in Codex returned
with its `screen_ocr` citation. This is observed evidence, not a verified answer.
The native image proof is `/tmp/hippocampus-production-image-proof-20260905.jpeg`.

The automated production proof remains incomplete: its bounded negative query
hit the 100-candidate limit and it has no authenticated-image tool. Native image
verification supplements it, but does not turn that script into a passing test.
The first images revealed fixed-canvas black margins. The geometry/focus/hook
repair (`bea62b3`) was signed, notarized, stapled and installed; event 1629's
authenticated native viewer shows the corrected canvas without black margins.
Proof: `/tmp/hippocampus-focus-repair-image-proof-20260905.jpeg`.
The browser-capability build `81e0cb6` was signed, notarized, stapled and installed.
Its 79 MB DMG is `/tmp/hippocampus-release-20260905-browser-routing/Hippocampus-0.1.0.dmg`,
SHA-256 `6ca2ddff5abf47c15c3d23c25cc13be8aac057925acc4c63ce65654c3ee11c78`.
The installed app is now the final repair artifact `fe285ee`, Developer ID
signed, notarized and stapled. Installed provenance, deep/strict codesign,
stapler validation and Gatekeeper assessment passed. The durable installer is
`/Users/amy/hippo-work/releases/2026-09-05-fe285ee/Hippocampus-0.1.0.dmg`,
SHA-256 `b29eaee8058bb5671d17038fb5d2e48c333904212b98281f8ee3fe0361ed74a5`.
Its product-source digest is
`07e27a1c7abf88f92d9af58bb617550a994e68054aa9f39a08a39fd5f58c05fa`.
The preceding validation app is preserved at
`/Users/amy/hippo-work/releases/backups/Hippocampus-routing-validation-2726eaf.app`.
Pause/resume was exercised in that validation app: the receipt recorded
`capture_disabled` while off and cleared that reason after restart. Both cold
and warm Sources-to-AI-Context routing acknowledged successfully in the final
installed app, without duplicate parent or Recall processes.
Normal/private-browser live proof and permission-revocation recovery remain
unqualified. A macOS security dialog interrupted browser qualification; only
the owner may handle that consent. Subsequent ordinary-window capture resumed.
No access has been granted or reset by automation.

The latest preview correction strips the complete indexing header before the
timeline's 80-character budget. Search-derived cards normalize the same body
contract; views do not strip a second time. Stored text, search indexing,
citations and detail-hit wire semantics are unchanged. All 109 Rust bridge
tests and the full optimized Recall suite (396 XCTest plus three handoff tests)
pass. The final native Today previews show OCR rather than indexing metadata.
The final installed build captured event 1679 at `2026-09-05T12:50:07.106Z`
under the ordinary production policy. Codex's live `mci_events_since` returned
its synthetic marker, and the native authenticated viewer displayed the same
event's stored pixels, OCR, source and timestamp. The committed receipt then
reported 55 screen records and 15 screenshot references. Proof:
`/Users/amy/hippo-work/releases/2026-09-05-fe285ee/hippocampus-final-fresh-screen-proof-20260905.jpeg`.
This proves the positive installed screen-to-memory loop, not all-app coverage
or the separate negative privacy and permission-recovery gates.

A real Claude SessionStart invocation exposed an oversized-packet failure even
though direct MCP worked. The hook now requests 600 tokens/four citations and
retries only oversized output at 256 tokens/one citation, preserving the same
focus and total deadline. Regression tests pass, including full citations and
failure isolation. The repaired installed hook returned a complete 2,564-byte
packet with the fixture, its canonical citation and the untrusted-memory warning.
The native consent controls enabled the owner's Claude SessionStart hook and
Codex instruction block without replacing unrelated configuration. An actual
Claude Code process, with tools and MCP disabled, emitted a successful
SessionStart hook response containing the fixture. Its remote model request
then retried until the bounded test ended; no final model answer is claimed.
Codex's real MCP connection has independently returned the fresh screen event.

The 36-task synthetic benchmark passes retrieval/handoff gates on both arms.
Hybrid recall@3 and handoff-task success are 100%; top-one hit rate is 96.8%.
The benchmark's source seeder was corrected to preserve explicit `screen://`
acquisition metadata. Corpus, answers and thresholds are unchanged. These are
synthetic retrieval results, not live capture or generated-answer qualification.
The expanded optimized capture suite passed 654 tests with zero failures,
including the newest AppleScript change.
Eighteen focused release workspace/date/receipt tests also pass.
The earlier debug suite's 107-microsecond
timing result versus its 100-microsecond gate remains recorded, not hidden.
The remaining browser checks must pass installed verification before browser
capture can be called qualified. Final installed preview readback passed.

## Product Boundary

The launchable V1 is a local evidence-memory product. It captures permitted
work context, preserves source and time, retrieves and displays related
evidence, produces citation-preserving extractive briefs, and hands bounded
context to Claude Code and Codex. It does not generate or advertise verified
answers. Production labels unverified semantic candidates as degraded related
context, while `Matched` remains unreachable without a separately qualified
verifier.

The task-trained claim/evidence verifier is a V2 capability gate. It must pass
the blind qualification below before Hippocampus may present a generated claim
or answer as trusted. This boundary does not weaken abstention or citation
requirements; it prevents an untrained model artifact from blocking a useful,
truthfully scoped evidence product.

## What Works

- The local memory ledger works: SQLCipher storage, FTS5 search, typed recall,
  timeline reads, episode derivation, briefs storage, export, deletion/wipe,
  authenticated encrypted keyframe reads, and stdio MCP.
- `mci_context` compiles a bounded handoff with typed outcomes, abstentions,
  source priority, and canonical event citations. Claude Code and Codex
  registration is structural, idempotent, ownership-safe, and records only a
  database path plus Keychain service/account references. Daemon startup now
  repairs only existing Hippocampus registrations, migrating stale packaged
  paths and legacy plaintext-key fields without creating an unsolicited
  registration or changing unrelated and malformed client configuration.
- The app and packaged `mci-agent` now share the `0.1.0` release identity.
  The agent derives its displayed version from Cargo package metadata, and a
  regression test compares it with the shipping app's Info.plist.
- Focused `mci_context` handoffs preserve the retrieval truth state all the
  way to Claude and Codex. Packets now say whether focus retrieval matched,
  contradicted, abstained, or returned degraded related context, including the
  stable degradation reason; unqualified ranking is no longer silently
  flattened into an ordinary observation-only packet.
- The same canonical context compiler is now directly usable outside MCP.
  `mci-agent context` opens the encrypted brain read-only, uses the production
  hybrid-or-lexical retrieval path, enforces the shared token and citation
  limits, and prints prompt-ready Markdown or typed JSON. Recall exposes this
  as an explicit clipboard action beside search and on the primary Now screen.
  Production resolves only the app-bundled sibling agent; an external agent
  path is accepted only in the build-gated development key mode. The UI runner
  now has a hard 15-second deadline, requests graceful termination, and kills a
  wedged child after a bounded grace period instead of leaving the interface
  spinning forever. Exported Markdown labels observations as unverified
  reference data and retains exact canonical event citations.
- Both AI-tool connection surfaces now impose a hard 15-second deadline,
  concurrently drain child output while retaining at most 8 KiB, request
  graceful termination, and force-kill a child that ignores the grace period.
  User-visible failures are sanitized instead of exposing raw stderr or local
  filesystem details. Executable fixtures prove timeout cleanup, output
  bounding, and diagnostic redaction without XCTest.
- Temporal handoff no longer treats recency as truth. A current-state query can
  remove an older raw observation only when a newer source explicitly declares
  that it supersedes or replaces a source labeled as previous or old. Competing
  observations without that marker remain visible. Exact repeated screen OCR
  consumes one packet citation, keeping the newest canonical observation while
  leaving the lossless event ledger unchanged.
- First-run onboarding now treats Screen Recording and Accessibility as required
  capture permissions, starts the supervised capture generation after the user
  finishes onboarding, and keeps one commandable Recall process available from
  the menu app. The global Recall shortcut opens that process, and search can
  deep-link to one exact canonical event instead of silently reusing stale
  popup results.
- Recall's global refresh command now publishes one content-free local signal
  and the visible filmstrip, Now, Search, Timeline, Episodes, Briefs, Sources,
  and Privacy surfaces execute their real `BrainReader` reloads. The old timed
  simulation and false "Brain refreshed" success claim are gone. A no-XCTest
  executable behavior check verifies signal delivery, active-query rerun, and
  observed-source refresh on this host.
- The unshipped canned Chat preview, fake assistant response model, and
  `?tab=chat` route have been removed from the compiled product. V1 uses the
  agents people already have through bounded handoff instead of presenting a
  mock chat surface as future functionality.
- The supervisor preserves one database-key authority across capture, Recall,
  onboarding, and AI-tool connection children. The packaged demo gives
  Foundation an isolated `HOME` and `CFFIXED_USER_HOME`, and its seeder and
  app share the exact fixed development-key path, so demo runs cannot touch
  the user's real brain or silently exercise a different key. Recall launch
  now uses the prepared-environment validator: source and demo builds retain
  only the fixed file-key marker/path while production remains Keychain-only;
  the ambient scrubber can no longer remove the authority immediately before
  the child starts.
- The supervised capture topology now has a kernel-enforced parent-lifetime
  lease. If the visible app quits, crashes, is force-quit, or receives
  `SIGKILL`, the helper observes EOF, drains capture, exits, and closes the
  existing helper-to-agent pipe so the agent releases its clean-run marker and
  exits too. Ad-hoc app assembly runs this owner-death proof against the real
  packaged process tree in a disposable home. The launch verifier allows a
  20-second cold-start window before judging onboarding missing, covering clean
  Swift package and Rust cache starts without weakening the liveness checks.
- The read-only `mci-brain` development fallback now normalizes a
  newline-terminated `dev.key` before validating it, matching the file emitted
  by the canonical demo while leaving production Keychain resolution
  unchanged and fail-closed.
- Daily briefs work without a model download. The deterministic extractive
  author removes capture headers and duplicate OCR churn, prioritizes explicit
  changes and open loops, caps output at nine bullets, and cites the exact
  canonical event behind every bullet. Stored author provenance distinguishes
  this path from optional experimental model output.
- Event, range, retention, and full-brain deletion remove last-reference
  encrypted keyframe blobs. Every retention cycle also reconciles canonical
  crash orphans and stale managed temporary files after a one-hour grace
  period, without following symlinks or deleting unknown entries. A missing
  retention file receives the fresh-install 90-day default; an existing
  unreadable, malformed, or unknown-value file fails closed and skips both
  expiry and reconciliation instead of silently changing policy.
- A process-lifetime operating-system writer lease now covers the daemon,
  every one-shot writer command, and Recall delete/wipe. The `.running` crash
  marker is separate, private, owner-checked, and opened without following
  symlinks. Existing brains pass a read-only integrity preflight before any
  writer open or schema migration; stale shutdowns require two successful
  passes. Integrity failure blocks the mutation with a dedicated exit path.
- The persisted recording setting now reaches every production ingest
  boundary. The helper receives `--capture` only when enabled; the Rust agent
  receives an explicit `MCI_CAPTURE_ENABLED` value and keeps stdin, browser
  sockets, deep hooks, and MCP collection inert while off. Safari additionally
  requires an enabled App Group authority owned by the live container process,
  binds that authority to the container's exact process-start identity, stamps
  each payload with the committed supervisor generation, and rejects stale or
  missing generations before socket delivery. Chromium performs a content-free
  native authorization handshake before reading the page DOM. A dead agent
  socket terminates the native host so the browser cannot retain a stale port
  across pause or restart. User pause stops the helper and agent process tree;
  resume starts a fresh supervised generation. Consent revocation and topology
  shutdown are independent attempts, so a failed authority-file removal cannot
  skip helper and agent termination during quit, pause, or reconfiguration.
- The production capture session now owns a live TCC monitor. A permission
  denied before helper startup is applied as an immediate fail-closed pause and
  emits the same content-free, actionable app status as a mid-run revoke.
  Restoration remains direction-asymmetric, requires two granted samples, and
  resets its grant evidence after a failed reconstruction attempt.
- Focused-window capture now binds every callback to the immutable generation
  of the `SCStream` that produced it. Focus changes build a replacement stream;
  public AX geometry must resolve twice to one unique WindowServer identity, so
  ambiguous same-bounds surfaces and same-application focus races fail closed.
  Stale generations fail closed before pixel admission, and terminal stream
  loss or failed teardown stops the helper instead of leaving a falsely healthy
  process. The live verifier preserves that nonzero status and its diagnostics
  expose only fixed outcomes, presence bits, booleans, and counts. OCR queue
  eviction, timeout, and empty recognition explicitly reopen only that exact
  frame's visual baseline. A complete later static frame can then receive one
  full-frame retry without disabling the normal no-dirty-rectangle energy gate
  or crossing a focused-window generation. The standalone 2026-09-04 M4 third
  lift enables production OCR by default after the live qualification below;
  the emergency switch remains tested and the debug qualification capability
  remains absent from release binaries.
- Semantic recall works when the Arctic Embed S Core ML artifact is present
  and backfill has run. The macOS runtime explicitly permits CPU plus Neural
  Engine for inference and uses a Rust cosine scan over vectors stored inside
  SQLCipher; there is no separate vector service or shipped sqlite-vec
  retrieval path. The shipping FP16 graph has app-owned provenance and a
  compiled-MIL contract that traces its finite `-10000` mask into every
  softmax. All 50 pinned reference sentences produce finite, normalized
  embeddings with cosine similarity at least `0.999` under both CPU-only and
  CPU-plus-Neural-Engine policies. The measured averages on this Mac were
  26.00 ms and 10.35 ms per embedding, respectively.
- Empty or whitespace-only observations no longer enter the embedding queue.
  One-shot backfill now stops when the current batch makes no progress, and the
  long-running worker waits on its normal idle interval before retrying a
  rejected batch. A live capture audit previously drove one empty row through
  hundreds of thousands of immediate retries; the fixed packaged agent drains
  the same retained encrypted brain with zero pending batches and no retry
  storm.
- Explicit person, count, duration, and date questions now pass a
  relation-grounded negative guard before retrieval can be called a match. The
  guard strips capture headers, keeps values within sentence and topic
  boundaries, passes all 14 disjoint calibration/validation cases, and rejects
  all eight adversarial cases containing an unrelated name, number, date, or
  duration. This guard can veto evidence but cannot promote it by itself.
- Hybrid recall now separates ranking from semantic evidence verification.
  The verifier contract returns source-attributed `Supported`, `Contradicted`,
  or `Insufficient` judgments; malformed confidence, invented event IDs, model
  failure, and an absent verifier all fail closed as the typed
  `EvidenceVerifierUnavailable` degradation. Supported and contradictory
  outputs retain only the exact canonical events cited by the verifier. The
  verifier receives a bounded internal set of up to eight ranked events before
  the caller's display limit is applied to untrusted fallback context, so a
  one-result UI request cannot discard any event required by a trusted support
  or contradiction verdict. The
  retired score critic remains available to tests but is no longer installed
  by production construction.
- The claim-verifier boundary now has a host-owned v3 evidence contract. A
  proposed claim is a normalized subject/predicate/object tuple; at most eight
  bounded evidence spans are cut from canonical events with UTF-8-safe byte
  ranges, exact text, and digests binding event bytes to brain, scope, and
  source identity. One call cannot mix brains or cross the claim's exact scope.
  The model can select only host-assigned slot indices. The host rejects
  non-finite confidence, duplicate or unknown slots, stale or modified
  citations, and policy-threshold uncertainty, so model output cannot invent
  provenance or disguise abstention as model-predicted insufficiency.
- The selected task-trained MobileBERT claim-set architecture now has a native
  Core ML runtime boundary. It requires exact Int32 `[1, 384]` inputs, fixed
  floating `[1, 3]` judgment and `[1, 8]` citation outputs, paired one-token
  evidence markers, and fully retained evidence slots. Startup requires a
  manifest whose SHA-256 is compiled into the signed binary, binding model and
  tokenizer hashes, class order, tensor schema, thresholds, blind-dataset
  identity, and Core ML parity. Artifacts are checked before and after load.
  The boundary fails closed on truncation, split markers, artifact drift,
  extra or flexible tensors, schema drift, an unauthorized brain, event ID
  zero, or an unqualified manifest. No task-trained artifact or qualified
  manifest exists yet, and this verifier is not installed in production.
- The first compact native verifier candidate has a reproducible Core ML
  conversion and a memory-safe Rust inference adapter. MobileBERT SQuAD2 FP32
  matches its PyTorch logits within `0.00014687` and runs in 23.49 ms median,
  but it is intentionally not installed in production: at a calibration
  threshold preserving every validation positive, it falsely accepts 16.7%
  of validation negatives against the 5% ceiling.
- The menu app, onboarding, Recall workspace, icon, installer art, extensions,
  and documented product captures use one light native visual system. Native
  macOS material supplies the translucent top surfaces, dark system appearance
  does not turn the product black, including the native Preferences panel and
  toolbar, and the retired turquoise identity is not present in the release
  asset set. The asset contract now runs in the unified gate. The Recall product
  capture is generated from a disposable SQLCipher brain and visibly proves
  three authenticated encrypted keyframes, 20 synthetic events, and one current
  synthetic brief. Recall's recent-evidence strip now shows sharp 16:9 source
  previews, an untruncated section label, cleaned two-line evidence summaries,
  source/time context, and an
  inspectable detail popover instead of blurred passive thumbnails. It compacts
  to screenshot plus summary cards in short windows instead of expanding the
  root view behind the title bar; fresh windows default to `1024x700`. The Now
  screen exposes the bounded, citation-preserving agent handoff as its stable
  primary action, and the repository thumbnail is regenerated from that exact
  packaged surface. The demo
  opts out of saved query/filter state and its automated screenshot path treats
  denied Screen Recording as an explicit nonfatal result rather than aborting
  or accepting a stale temporary image. Demo boot now hands the packaged app to
  LaunchServices, records the resulting application PID, and verifies that it
  remains alive before reporting success, so a short-lived invoking shell
  cannot orphan onboarding or falsely claim that the menu app is running.
- Runlog remains an audited research input rather than a runtime dependency.
  It does use 768-dimensional Gemini vectors and Firestore cosine search; its
  useful hypothesis is hybrid candidate generation plus source-region
  provenance. Hippocampus will evaluate those ideas locally without adopting
  Runlog's cloud store, uncited agent-written claims, query-time general
  knowledge injection, or eventual-deletion semantics.
- The app, capture helper, Recall, and onboarding Swift packages compile on
  this host through the constrained SwiftPM wrapper. The complete Rust gate
  passes formatting, all-target workspace Clippy, every workspace test, and
  dependency audit. The shell and executable behavior lanes pass, including
  capture/privacy, release identity, model integrity, product truth, clean-home,
  app launch, and visual contracts. The current verified matrix reports 52
  passing lanes, zero failures, and one unavailable SwiftFormat skip. Full
  Xcode 26.6 is selected, so all Swift package tests and executable fixtures run
  locally through the repository's manifest-compatibility wrapper.
- Installer subprocesses run in isolated POSIX process groups with bounded
  TERM/KILL escalation. Executable fixtures prove ordinary descendants and
  descendants created by TERM handlers are gone before timeout returns. Failed
  builds remove incomplete canonical DMGs and sidecars; successful cleanup
  preserves completed artifacts. The DMG stages the generated canonical terms
  as a visible `License.rtf`; the removed macOS unflatten/Rez/flatten flow is no
  longer treated as an optional success path.
- The capture stream's active-work ceiling is 2 fps and the 1 Hz privacy
  cascade floor remains independent. A Developer ID-signed current-source
  helper passed a 20-second live overlap proof with two distinct application
  identities: 38 frames, one focused OCR event, one retained authenticated
  keyframe, no background token, no foreign event, and no ingest drop or
  failure. This used an isolated qualification allowlist, not the owner's
  production configuration. The separate 1,800-second soak delivered 3,610 frames, exercised 37
  fail-closed focus-race drops (`1.0249%`), retained 38 OCR events and 37
  keyframes, and measured helper CPU p95 `3.7%`, RSS p95 `92,012,544` bytes,
  and projected storage `3,222,844` bytes/hour. The exact report and limitations
  are in `docs/audit/2026-09-04-focused-window-live-qualification.md`.
- The current-source Developer ID qualification app at
  `/tmp/hippocampus-signed-qualification/Hippocampus.app` includes Arctic Embed
  S as its only bundled model, passes signed App Group and model validation,
  survives the disposable-home first-launch gate, and carries the stable Team
  identifier `BV6KGKFKP4`. It is a debug qualification artifact, not the
  distributable release. It does not qualify the September 5 repair.
- A throwaway-home E2E installs the engine, starts with capture disabled,
  imports 20 synthetic events, injects one shared-encoder `OCREvent` through
  production `--drain-stdin --strict`, derives episodes, persists and reads
  back a brief, verifies MCP recall/timeline/episodes/cited context, registers
  both supported clients without key material, deletes the injected event,
  and uninstalls without isolated product residue.
- The disposable visual demo now runs the production enrichment pipeline over
  its 20 synthetic events before launch, producing 13 entity mentions, 20
  embeddings, and 20 inspectable work episodes on the audited Mac. An isolated
  `HOME` no longer hides the verified repository-local Arctic artifact: the demo
  resolves and exports its explicit path before enrichment when no caller
  override is present. Semantic mode now fails unless the production pipeline
  reports all 20 synthetic events embedded; an absent artifact is disclosed as
  degraded lexical-only mode. Canonical captures are stripped of EXIF and text
  metadata, and their OCR contract rejects personal home paths, email addresses,
  and common credential shapes. Its MCP
  trace exercises recall, cited context, stats, and episodes. MCP copy says
  capture begins only after opt-in and distinguishes the absence of a
  Hippocampus cloud copy from the policy of whichever AI client receives a
  user-requested handoff.

## What Is Not Yet Proven

- The production-wired TCC revocation monitor is not yet proven by a live
  grant/revoke/restore run. macOS exposes no qualified public signal that a
  different app has started sharing or recording the screen, so Hippocampus
  does not claim or simulate one; explicit pause, screen lock, TCC loss,
  denylisting, secure input, and browser-private-mode exclusion are the enforced
  controls. Delete and wipe operations
  separate committed SQL deletion from post-commit storage-cleanup warnings and
  now quiesce against every other writer through the shared operating-system
  lease.
- Production key custody targets the non-synchronizable macOS file-Keychain
  item `ai.hippocampus.brain` / `database-key-v1`. Migration is fail-closed and
  removes a legacy plaintext key only after Keychain reread plus read-only
  database validation. Ad-hoc development bundles carry a build-injected
  capability that permits the fixed user-owned `dev.key` path, and pass child
  processes only that path plus an explicit development marker, never raw key
  bytes. Developer ID bundles omit the capability and remain Keychain-only.
  A Developer ID release has completed signing and notarization on this Mac;
  second-Mac clean-install and cross-version ACL continuity remain unqualified.
- Full Xcode 26.6 is installed and selected. The Developer ID Application
  identity and its private key are installed, `notarytool-profile` authenticates
  successfully, and the Sparkle private/public key pair matches the public key
  in the shipping Info.plist. The pre-lift app and DMG completed Developer ID
  signing, Apple notarization, stapling, and verification. The production
  focused-window repair also completed that pipeline and is installed. The
  final focus/canvas/preferences/hook repair is also notarized and installed;
  its positive capture, stored-image and MCP readbacks are recorded above.
- A verified local Arctic Embed S Core ML bundle is present in the gitignored
  development model directory and is included by debug ad-hoc assembly, so that
  artifact supports semantic recall. It is the sole required release model.
  Tier-1 entity extraction remains active. This owner's custom local model
  directory contains Qwen3; that presence no longer starts unattended Qwen
  inference. Evidence-cited extractive briefs remain active. Qwen is an
  optional custom-build experiment, not a shipped download or release gate.
  A local archive containing only that compiled Arctic bundle was created and
  reconstructed through `scripts/prepare-release-models.sh`; its SHA-256 is
  `31da35fffb853a9442cef582f3319206496a00808da1ab3cbeca711b11a766f3`.
  It is not hosted, and `release-models.json` deliberately remains
  `UNPROVISIONED`, so a public updater release cannot yet be reconstructed or
  published from immutable model inputs.
- Multi-device sync and Windows are outside the verified v1 path.

## Benchmark Status

The accepted `agent-handoff-v1` evaluation runs 36 tasks through both the
production hybrid and lexical-only `LiveBrainReader::recall` plus
`LiveBrainReader::context` paths, for 72 arm-task combinations over disposable
SQLCipher brains. Both fixed quality gates pass. Hybrid scores 96.8% Hit@1,
100% Hit@3/5, 98.4% MRR, semantic relevance, temporal currency, superseded exclusion,
contradiction visibility, duplicate suppression, exact provenance,
abstention, handoff utility, fact coverage, bounded packets, and capability
pass rate; its recall is 69.4% at rank one and 100% at ranks three and five.
Lexical-only scores 100% Hit@3/5, temporal currency, superseded
exclusion, contradiction visibility, duplicate suppression, exact provenance,
abstention, and bounded packets; its capability pass rate is 35/36, handoff
task success is 75%, and fact coverage is 43/44. This qualifies retrieval and
bounded handoff only.
`trusted_answer_qualified` remains structurally false until a source-attributed
answer verifier passes its separate held-out gate. The checksummed report is
`docs/eval/agent-handoff-v1-result.json`.

The shipping extractive brief author passes all eight committed synthetic
workdays: 37/37 required facts, 69/69 valid citations, zero unresolved
citations, zero forbidden terms, and 3.20 ms total measured author time on the
audit Mac. This is a source-preservation baseline, not a human usefulness
claim; the corpus does not yet score importance, personal/work separation,
contradiction resolution, or repeated-OCR suppression. The reproducible result
and limitations are in `docs/eval/brief-extractive-baseline.md`.

The accepted, reproducible 24-case synthetic work-memory retrieval artifact is
`docs/eval/work-memory-baseline.json`. It covers 21 answerable and three
intentionally unanswerable cases across GitHub, terminal, browser, Slack,
Linear, and files. It measures retrieval and provenance, not answer generation,
and is not comparable to LoCoMo or LongMemEval.

A clean clone at `b845c59` reproduced the accepted quality exactly: hybrid
Hit@1 95.2%, Recall@1 88.1%, Recall@3 100%, MRR 0.976, exact provenance, and
zero unanswerable false positives. Two warm scenario runs measured 46.0 ms and
52.2 ms p95; one cold run measured 156.9 ms. This timer includes disposable
brain creation, seeding, document embedding, retrieval, and index measurement,
so it is a load-sensitive scenario latency rather than a pure query timer. The
same clean clone reproduced the accepted agent-handoff result and remained
`trusted_answer_qualified: false`.

| Arm | Answerable outcome | Hit rate @1 | Recall @1 / @3 | MRR | Unanswerable outcome | p95 latency |
|---|---:|---:|---:|---:|---:|---:|
| Lexical | 7/21 ranked; 14 missed | 33.3% | 33.3% / 33.3% | 0.333 | 3/3 abstained; 0 false positives | 22.15 ms |
| Hybrid | 21/21 ranked; 0 missed | 95.2% | 88.1% / 100% | 0.976 | 3/3 abstained; 0 false positives | 72.06 ms |

The artifact is complete and publishable but explicitly
`"launch_qualified": false`. Retrieval abstention passes the three
unanswerable cases, but all 21 answerable hybrid rankings are deliberately
recorded as `degradedEvidenceVerifierUnavailable`, not trusted matches. The
explicit relation guard is qualified on its narrow person/count/duration/date
corpus, leaving the missing semantic verifier as the single quality failure.
The prior score critic reached only 83.3% positive coverage with 33.3% false
positives on its tiny held-out split; a fast MiniLM SQuAD2 spike produced the
same held-out rates and was rejected. A reproducible FP32 Core ML MobileBERT
candidate improved validation positive coverage to 100% and measured 23.49 ms
median / 25.17 ms p95, but still produced 16.7% validation false positives.
Its committed evaluator exits nonzero and its artifact remains unbundled. The
fixture has only six validation scenarios and lacks contradiction, temporal,
synthesis, provenance, and order-metamorphic coverage. Evidence calibration is
a product gate, not benchmark fine print.

A DeBERTa-v3-xsmall NLI spike correctly separated several hand-authored support
and contradiction examples in PyTorch, but its relative-position attention
graph did not convert through the repository's pinned Core ML toolchain. It is
not a release dependency. The next production candidate reuses the already
convertible fixed-shape MobileBERT encoder architecture with a task-trained
three-way claim/evidence-set classifier and citation-slot head. That candidate
does not exist in the app yet and cannot qualify without blind claim-level
evaluation, Core ML parity, latency, and signed-runtime proof.

The public v2 semantic-verifier fixture is
`eval/evidence-verifier/v2-corpus.json` with SHA-256
`d612bf537fbaa8453cd0a83075722f4e7fe8ff30afab86c5a2c33e4ea42041e4`.
It has 48 cases across 24 short synthetic scenarios and usefully fails closed
on malformed or invented provenance. A fresh audit found that its answer key
is public, its partitions repeat templates, and it never scores a proposed
answer. The scorer now labels success `fixture_passed`, sets
`evaluation_scope` to `public_regression_smoke`, and always keeps
`release_qualified` false. A blind claim-level corpus executed against the
immutable signed runtime is required before a production verifier can qualify.

## Release Gates

- Run `scripts/check.sh`, `scripts/e2e-clean-home.sh`, every Swift package test,
  strict workspace Clippy, and the full workspace test suite on the release
  commit. Full Xcode is now available; the 2026-09-04 post-review matrix passed
  all 52 invoked lanes with only optional `swiftformat` absent.
- Keep the committed 30-minute capture-soak and current-source cross-app overlap
  evidence reproducible from the release commit. Prove the independent live TCC
  revocation/restoration path before calling permission recovery qualified.
- Upload the verified immutable Arctic retrieval archive, replace the explicit
  `UNPROVISIONED` manifest fields only after its stable URL exists, and repeat
  reconstruction, integrity, and completeness checks from the release commit.
- Before shipping trusted-answer or evidence-backed-claim features, train and
  qualify the claim/evidence-set verifier on a blind, scenario-disjoint corpus;
  prove citation binding, Core ML parity, calibrated abstention, and
  signed-runtime latency before adding it to the release manifest. The
  evidence-memory V1 keeps this artifact absent and semantic candidates typed
  as degraded related context.
- Rebuild the post-M4 app and DMG with the canonical installer, then inspect the
  retained signing, notarization, staple, Gatekeeper, and checksum evidence. Do
  not record secret values.
- Build, sign, notarize, staple, install, and launch on a clean second Mac;
  verify Keychain continuity across an update before publishing.
- Keep capture off by default. Keep trusted-answer presentation unavailable
  until the separate evidence-verifier gate passes.

## Owner Actions

The exact non-secret setup is in `docs/release/OWNER_SIGNING.md`. The required
protected GitHub environment secret names are:

- `APPLE_CERTIFICATE_P12`
- `APPLE_CERTIFICATE_PASSWORD`
- `NOTARYTOOL_APPLE_ID`
- `NOTARYTOOL_TEAM_ID`
- `NOTARYTOOL_PASSWORD`
- `SPARKLE_PRIVATE_KEY`

No secret value belongs in source, Markdown, shell history, app child-process
arguments, or client MCP configuration.

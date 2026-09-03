# Hippocampus Status

_Audited on 2026-09-03._

Audited code baseline: `368062d`

This SHA is the immediate committed baseline before this status refresh. The
release assembler requires it to be an ancestor of `HEAD` and no more than
three commits behind. This file is the repository's canonical product and
release truth; README, design docs, release notes, and UI copy must not claim
more than this page.

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
  retention file receives the fresh-install `forever` default; an existing
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
  stale generations fail closed before pixel admission, and terminal stream
  loss stops the helper instead of leaving a falsely healthy process. OCR queue
  eviction, timeout, and empty recognition explicitly reopen only that exact
  frame's visual baseline. A complete later static frame can then receive one
  full-frame retry without disabling the normal no-dirty-rectangle energy gate
  or crossing a focused-window generation.
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
  previews, cleaned two-line evidence summaries, source/time context, and an
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
  app launch, and visual contracts. The current verified matrix reports 43
  passing lanes, four XCTest-only failures, and one unavailable SwiftFormat
  skip. The local gate now routes package tests through the repository's
  manifest-compatibility wrapper instead of failing before test compilation.
  This host's current Command Line Tools installation does not include XCTest,
  so full Swift package test execution requires full Xcode or CI; production
  package builds and executable fixtures remain locally runnable.
- Installer subprocesses run in isolated POSIX process groups with bounded
  TERM/KILL escalation. Executable fixtures prove ordinary descendants and
  descendants created by TERM handlers are gone before timeout returns. Failed
  builds remove incomplete canonical DMGs and sidecars; successful cleanup
  preserves completed artifacts. The DMG stages the generated canonical terms
  as a visible `License.rtf`; the removed macOS unflatten/Rez/flatten flow is no
  longer treated as an optional success path.
- The capture stream's active-work ceiling is now 2 fps, matching the product
  footprint design instead of the prior 5 fps default. The 1 Hz privacy
  cascade floor remains independent, so lower frame delivery cannot suppress
  periodic protected-surface checks. Fresh 5-second and 20-second runs against
  the exact rebuilt ad-hoc app recalled the focused corpus token, excluded the
  overlapping background token, and retained one authenticated keyframe. The
  20-second run delivered 38 frames with zero backpressure or late-ack drops;
  it is a functional privacy proof, not a resource-soak qualification.
- The most recently verified `182 MB` debug ad-hoc app at
  `apps/hippocampus/dist/Hippocampus.app` includes Arctic
  Embed S as its only bundled model, passes signed App Group and model
  validation, and survives the disposable-home first-launch and owner-death
  gates. This proves a runnable development bundle, not a distributable Apple
  release.
- A throwaway-home E2E installs the engine, starts with capture disabled,
  imports 20 synthetic events, injects one shared-encoder `OCREvent` through
  production `--drain-stdin --strict`, derives episodes, persists and reads
  back a brief, verifies MCP recall/timeline/episodes/cited context, registers
  both supported clients without key material, deletes the injected event,
  and uninstalls without isolated product residue.
- The disposable visual demo now runs the production enrichment pipeline over
  its 20 synthetic events before launch, producing 13 entity mentions, 20
  embeddings, and 20 inspectable work episodes on the audited Mac. Its MCP
  trace exercises recall, cited context, stats, and episodes. MCP copy says
  capture begins only after opt-in and distinguishes the absence of a
  Hippocampus cloud copy from the policy of whichever AI client receives a
  user-requested handoff.

## What Is Not Yet Proven

- Real `ScreenCaptureKit` capture remains opt-in and is not yet release
  qualified. The executable
  `scripts/run-live-capture-overlap.sh` gate assembles an exact ad-hoc app,
  requires Screen Recording and Accessibility for that helper, foregrounds a
  synthetic overlapping-window corpus, captures through the bundled helper and
  agent, and proves focused-window recall plus background-window abstention. A
  fresh 5-second and 20-second runs on the audited Mac passed with one retained
  corpus event and one authenticated keyframe each: the exact focused token was
  recalled and the overlapped background token was absent from timeline,
  application-scoped events, and full-text retrieval. The same fail-closed gate
  aborts if another app becomes frontmost. `--soak` fixes
  the duration at 1,800 seconds, samples helper CPU/RSS every five seconds,
  retains evidence, and emits a machine-readable qualification report covering
  frame, OCR, keyframe, memory, storage, privacy, and resource-SLO evidence.
  An earlier 5 fps diagnostic soak was stopped after 91 footprint samples once
  it had already established a 39.8% helper CPU p95 against the 15% ceiling;
  that run did not qualify. The helper now builds at the documented 2 fps active-work
  ceiling. Short-window CPU percentiles are dominated by startup and do not
  qualify the 15% p95 resource target. The required uninterrupted 30-minute
  privacy and resource run remains unqualified rather than being inferred from
  source or from the short functional proofs.
- OCR is therefore not yet launch-qualified against cross-window leakage. Ambient
  ScreenCaptureKit OCR excludes browser windows entirely; Safari and Chromium
  use separate structured capture paths that reject private contexts before
  reading page content, with executable release tests. The narrow live OCR
  qualification capability exists only in debug builds and is proven absent
  from the release helper binary. Automatic OCR enablement remains blocked until
  the 30-minute live soak passes.
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
  Signed clean-install and cross-version ACL continuity cannot be accepted
  until a stable Developer ID bundle is available.
- This machine has Command Line Tools rather than full Xcode, zero valid code
  signing identities, and no `notarytool-profile`. It cannot produce or claim a
  Developer ID-signed, notarized public release. Apple Developer Program
  membership alone does not place the Developer ID certificate and its private
  key on this Mac or create notarization credentials.
- A verified local Arctic Embed S Core ML bundle is present in the gitignored
  development model directory and is included by debug ad-hoc assembly, so that
  artifact supports semantic recall. It is the sole required release model.
  BERT NER is absent and Tier-1 entity extraction remains active. Qwen3 is
  absent and evidence-cited extractive briefs remain active. Qwen is an
  optional custom-build experiment, not a shipped download or release gate.
  The immutable Arctic release archive is still unprovisioned, and the debug
  app is not distributable.
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
  commit. Full XCTest remains a full-Xcode gate on this host.
- Complete a real 30-minute capture soak with frame, OCR, retained-keyframe,
  CPU, memory, disk, pause, and protected-surface observations.
- Repeat the focused-window overlap gate from the release commit, prove live
  TCC revocation/restoration behavior, then complete the 30-minute resource and
  privacy soak.
- Provision and reconstruct the immutable Arctic retrieval archive named by
  `release-models.json`, then pass its integrity and completeness checks.
- Before shipping trusted-answer or evidence-backed-claim features, train and
  qualify the claim/evidence-set verifier on a blind, scenario-disjoint corpus;
  prove citation binding, Core ML parity, calibrated abstention, and
  signed-runtime latency before adding it to the release manifest. The
  evidence-memory V1 keeps this artifact absent and semantic candidates typed
  as degraded related context.
- Install full Xcode, a Developer ID Application identity with private key,
  and the `notarytool-profile`; verify the Sparkle private/public pair without
  recording secret values.
- Build, sign, notarize, staple, install, and launch on a clean second Mac;
  verify Keychain continuity across an update before publishing.
- Keep capture off by default and hybrid recall unqualified until their
  respective measured gates pass.

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

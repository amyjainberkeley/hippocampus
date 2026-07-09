# ADR-0034 — Fleet-authored PR merge policy (doc-only auto-merge, code needs human CEO click)

- Status: **Accepted** (2026-07-08; ratified by human CEO Amy Jain in cycle 8.33 dispatch)
- Owners: **CEO** (merge authority; policy owner)
- Reviewers: CTO (delivery-lane implications), CSO (protected-set independence)
- Phase: cross-cutting (governs every phase's PR review cadence)
- **Protected-set: no** (governs merge cadence, not code or capture surface)
- **Launch-blocker: no**
- **Relationship:** amends `AGENT_PROTOCOL.md` §1 (branching & git); tightens the "only the human CEO merges" rule with a scoped, evidence-gated exception for doc-only fleet PRs.

## Context

### The cycle 8.32 lesson

Cycle 8.32 fired 6 agent dispatches overnight and produced 7 PRs on `amyjainberkeley/newhippocampus`. Six of them were doc-only (STATE.md refresh + 3 CRS memos + 1 NIGHTLY_LOG entry + a doc-only cleanup); one was a small code fix (verify-app-launches hardening). The CEO seat reviewed each in the morning and merged all seven cleanly.

The prior AGENT_PROTOCOL.md §1 rule states: "**Never** push to `main`. Only the human CEO merges to `main`." Read strictly, this requires the human CEO to click "Squash-Merge" 7 times per cycle in the GitHub UI. That workflow does not scale as the fleet's parallel dispatch count grows: at 10+ PRs/cycle, the seat becomes a manual clicking exercise; at 30+ PRs/cycle, real review discipline breaks down as the human seat batches without reading.

Simultaneously, the raw "never let an agent merge" invariant is doing real work: it prevents fabricated-progress merges, protects the invariant chain (footprint SLO / zero-knowledge / sensitive-capture), and keeps the audit trail honest.

This ADR splits the two concerns: **doc-only merges** carry near-zero blast radius and can be automated under explicit CEO batch authorization; **code merges** retain the human CEO click.

### Why "doc-only" is a meaningful category

A doc-only PR is defined by touching **exclusively** files in the allow-list below (§2). Doc-only PRs cannot break the build, cannot regress the footprint SLO, cannot introduce a security surface, and cannot ship a runtime behavior change. Their blast radius is bounded by the file allow-list: worst case a misleading claim lands in STATE.md or a research memo and gets corrected on the next cycle's audit.

Code PRs, in contrast, ship binary artifacts to `main` that eventually ride into a public DMG. Every code merge is a potential source of runtime regression. The human CEO click on code PRs is the cheapest possible gate against a fabricated-green agent PR.

## Decision

### 1. Two merge tracks

**Track A — Doc-only auto-merge (CEO batch authorization required per cycle).**

A doc-only PR authored by a fleet agent MAY be merged by an automation acting on the human CEO's behalf, WHEN AND ONLY WHEN:

1. Every file touched by the PR is in the doc-only allow-list (§2), verified by `gh pr view <n> --json files`.
2. The human CEO has issued an explicit per-cycle merge authorization (e.g. "merge the doc-only batch for cycle N", or in-conversation confirmation "yes, merge them"). Standing/default auto-merge authorization is **explicitly forbidden**: authorization is granted per cycle, per batch, never as a persistent setting.
3. The PR body carries the standard `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` trailer.
4. The PR is not a revert of a code PR (reverts inherit the code-PR track regardless of their file surface).

**Track B — Code merge (human CEO click required).**

Any PR touching a file outside the doc-only allow-list (§2) — regardless of PR size — requires the human CEO to click "Squash-Merge" in the GitHub UI (or run `gh pr merge` themselves from a human-authenticated shell session, not through an agent). No exceptions. No batch authorization pattern.

### 2. Doc-only allow-list (binding)

A PR is doc-only if and only if every changed file matches one of:

- `docs/**/*.md` (any markdown file anywhere under `docs/`)
- `docs/**/*.png`, `docs/**/*.jpg` (diagram / screenshot assets referenced from docs)
- `*.md` at repo root (README.md, CLAUDE.md, etc.)
- `.claude/agents/*.md` (agent role definitions — technically config, but treated as doc since they only affect agent behavior, not runtime)
- `.github/*.md` (issue templates, contribution guidelines)

**Files that are NEVER doc-only** (this list is illustrative, not exhaustive — the rule is "if it's not in the allow-list above, it's code"):

- Anything under `core/`, `apps/`, `adapters/`, `server/`, `extensions/`, `tools/` (source trees).
- `Cargo.toml`, `Cargo.lock`, `package.json`, `package-lock.json`, `rust-toolchain.toml` (build config that affects binary output).
- `scripts/**` including any `.sh` file (build / verify / release tooling — a broken script can ship a broken DMG per cycle 8.24's `cp -R models .` incident).
- `.github/workflows/*.yml` (CI config; can break the build gate).
- `firebase/**`, `cloudbuild.yaml`, `docker-compose.yml` (deployment / infra config).
- `.gitignore`, `.gitattributes`, `.dockerignore` (repo hygiene with downstream impact).
- Any file with an extension in: `.rs`, `.swift`, `.ts`, `.tsx`, `.js`, `.mjs`, `.py`, `.go`, `.proto`, `.sql`, `.plist`, `.entitlements`, `.mobileprovision`.

### 3. CEO authorization mechanics

A per-cycle CEO authorization is an explicit conversational confirmation from the human CEO to the automation, of the form:

- "merge the doc-only batch" (all currently-open doc-only PRs)
- "merge PRs #N, #M, #P" (specific enumeration; can include code PRs, in which case the code PRs still require the human CEO's own click — the authorization does not lift the §1 code-track rule)
- "yes" / "go" in response to an automation's explicit ask ("I have N doc-only PRs ready to merge under Track A — confirm?")

Authorization does NOT persist across cycles. Every new `/night-run` cycle starts with no standing auto-merge grant.

Automation acting under CEO authorization commits the merge under Amy's git identity (`Amy Jain <96968067+amyjainberkeley@users.noreply.github.com>`) and MUST include the automation attribution in the merge-commit message body (via `gh pr merge --squash` picks up the PR title + body; the co-author trailer in the PR body carries forward).

### 4. Protected-set carve-out (unchanged)

A PR touching any protected-set file (per `AGENT_PROTOCOL.md` §5 — crypto, keys, sync, sensitive-capture, `mci.sqlite`, entitlements, TCC / permissions, notarization) requires **CSO sign-off** in the PR body **AND** the human CEO click. Track A does not apply. This is the hardest merge gate and it does not soften under any batch authorization.

### 5. Emergency override

The human CEO may merge any PR directly at any time (this is the seat's inherent authority). Emergency overrides on Track A boundaries (e.g. merging a code PR without waiting for own click, or merging under an expired authorization) are logged as a `## YYYY-MM-DD — override — <reason>` entry in `docs/NIGHTLY_LOG.md` under the cycle's log, so the exception is visible in the audit trail.

## Consequences

### Positive

- **Fleet scales past ~10 PRs/cycle without breaking review discipline.** Doc-only work (state audits, memos, nightly logs) flows through fast; code work retains the strict gate.
- **Audit trail preserved.** Every merge (Track A or Track B) still lands under Amy's git identity with the Claude Opus co-author trailer, so `git log` never lies about who authored.
- **Escape hatches remain honest.** Per-cycle authorization prevents drift into "well I meant standing auto-merge"; emergency overrides are logged.

### Negative

- **A malformed doc-only PR could still ship misleading claims.** Mitigation: the CEO's morning read of merged PRs (per NIGHTLY_LOG discipline) catches misleading claims in <24h and the next cycle's audit corrects.
- **The allow-list needs to stay current.** If MCI adds a new doc convention (e.g. `.mdx`, `docs/videos/*.mp4`), this ADR amends. No implicit widening.
- **Automation-side implementation subtlety.** The automation must verify the file allow-list BEFORE issuing `gh pr merge`; a bug that mistakenly classifies a code PR as doc-only would violate §1 track B. Mitigation: automation reads `gh pr view --json files` and checks every path against the allow-list programmatically; any mismatch surfaces as an explicit ask to the CEO ("PR #N touches `foo.rs` which is code — need your click").

## Amendment to AGENT_PROTOCOL.md §1

The first three bullets of `AGENT_PROTOCOL.md` §1 are amended per this ADR (see the companion patch to that file in the same PR that lands this ADR).

## References

- `docs/AGENT_PROTOCOL.md` §1 (branching & git — amended by this ADR).
- `docs/AGENT_PROTOCOL.md` §5 (CSO veto-gate — unchanged; carve-out reinforced above).
- Cycle 8.32 `docs/NIGHTLY_LOG.md` entry — the motivating cycle (6 doc-PRs + 1 code PR, all merged by human CEO in one morning session).
- Cycle 8.33 conversational ratification: human CEO Amy Jain, 2026-07-08 (in-session; recorded here as the ratifying transcript reference).

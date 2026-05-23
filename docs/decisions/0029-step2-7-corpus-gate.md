# ADR-0029 — §7 Secure-Surface Corpus Gate Criteria

- Status: **Proposed** (pending CSO validation of methodology + CEO ratification after live corpus run)
- Owners: **CSO** (binding sign-off authority) + **CRS** (corpus methodology author)
- Reviewers: CEO (ratification); Director-Recording (corpus executor); CRS Telemetry-Gap analyst (footprint regression baseline)
- Phase: 1→2 gate (this ADR formalizes the exit criteria for Phase 1's privacy verification)
- **Protected-set: yes** (AGENT_PROTOCOL §5 — the gate controls when the capture path becomes default-ON; flipping the gate is a CSO-protected change)

## Context

ADR-0013 §7 requires an integration-test corpus of secure-surface scenarios, run on a real machine, with a committed audit artifact, before any of the following may be claimed:

1. Phase 1→2 transition
2. Capture default-ON in any shipped build
3. Any footprint/G2 measurement as a satisfied gate

ADR-0013 Amendment 1 §2 sharpened the scope: the corpus is not a per-PR blocker on enabler PRs (those merge under the §3(a)–(d) structural conditions), but it IS a non-negotiable blocker on (1)/(2)/(3) above.

The prior Step-2 audit (2026-05-19, `docs/audit/2026-05-19-step2-sec-7-corpus.md`) achieved PARTIAL PASS: §3 verified live, §7 verified, §2 stubbed (now implemented by PR #36 `PixelGridBlackedRegionProbe`), §4 failed (STEP-2-FINDING-001, now closed by PR #38 + PR #40). No full corpus run has been completed since those fixes.

This ADR formalizes the gate criteria so the CSO sign-off is not a judgment call on ad-hoc evidence, but a checkable pass/fail against a defined standard.

## Decision

### 1. The corpus

The corpus is defined in `docs/audit/2026-05-23-step2-7-corpus-plan.md`. It specifies ~40 test entries across 11 categories: password managers, banking/financial, health, private messaging, secure work surfaces, incognito/private windows, FairPlay-protected video, native macOS authorization, PDF viewers, AX-silent Electron windows, and the known-safe-apps allowlist regression suite.

### 2. Gate criteria (all must hold)

The CSO signs off on flipping `CaptureLaunchOptions.swift` default-ON when ALL of the following hold, evidenced by the committed corpus artifact:

#### 2.1 Cascade layer coverage

Each testable cascade layer has been verified live on a real machine on at least the minimum number of distinct apps/surfaces:

| Layer | Minimum | Verified by |
|-------|---------|-------------|
| §2 `os-blacked-region` | ≥ 2 distinct DRM apps | Real FairPlay playback, ≥85% black pixel frames |
| §3 `secure-event-input` | ≥ 5 distinct surfaces | Real password prompts + authorization sheets |
| §4 `ax-secure-subrole` | ≥ 5 distinct surfaces | Real password fields (web + native) + ProbeHarness isolation |
| §7 `failsafe-unknown` | ≥ 5 distinct non-allowlisted apps | Normal use on non-allowlisted apps |
| `.allow` | ≥ 5 distinct allowlisted apps | Normal (non-secure) use on allowlisted apps |

#### 2.2 Zero-tolerance invariants

- **0 `.allow` frames on any known-secure surface** (password field, authorization sheet, secure text field). Any `.allow` on these surfaces is a BLOCKER finding.
- **0 `StateTransitionEvent` (0x0010) on the wire** across the entire corpus run. Pixels must never cross the IPC seam for any event.
- **0 allowlist regressions.** Every `known-safe-apps.toml` entry produces `.allow` on a non-secure surface.
- **0 helper crashes** during the corpus run.

#### 2.3 Cascade-floor heartbeat

Every corpus test entry's `frame_count > 0`. A test window with zero frames is inconclusive (cascade-floor starvation), not a pass. Re-run with the STEP-2-FINDING-004 workaround (background screen activity) if needed.

#### 2.4 Footprint soft check

The corpus run (15–30 min mixed-use session) shows:
- Helper RSS p95 ≤ 250 MB
- Helper CPU p95 ≤ 2.0%

This is informational, not a hard gate (G2.2 is the formal footprint gate). A footprint regression surfaces as a finding, not a corpus blocker.

#### 2.5 Wire schema integrity

Wire protocol version matches the current expected version (0x04 at time of writing). No unexpected message types, no decoder errors beyond end-of-file truncation from SIGINT.

### 3. What the gate does NOT cover (explicit scope limits)

- **§1 source denylist.** Requires Phase 2 context join to deliver `appBundleId` to the cascade. Deferred.
- **§5 denylist drift backstop.** Requires live policy-generation tracking. Deferred.
- **§6 OCR-time regex.** Defense-in-depth; tested headlessly by unit tests. Not a corpus item.
- **Incognito/private-window detection via §1.** Requires Phase 2 P2.3/P2.4 browser-URL providers. Current behavior (§7 catchall) is privacy-correct; §1-specific verification is a Phase 2 gate item.
- **Windows platform.** Phase 8.
- **Cross-device sync privacy.** Phase 5+.
- **Footprint SLO formal close.** G2.2 ≥4h run (ADR-0013 Amendment 1 + AGENT_PROTOCOL §9). Independent gate.

### 4. Artifact requirements

The committed corpus artifact consists of:

1. `docs/audit/2026-05-XX-step2-7-corpus-results.md` — human-readable per-entry results table.
2. `docs/audit/2026-05-XX-step2-7-corpus-results.json` — machine-readable JSON array. Schema defined in the corpus plan §3.2. This is the artifact ADR-0013 §7 references for third-party audit re-runs.

Both files are committed to `main` (via PR, not direct push). Raw wire binaries and stderr logs stay on the operator's machine.

### 5. Sign-off protocol

1. Director-Recording executes the corpus on a real Mac per the runner protocol in the corpus plan §4.
2. Director-Recording commits the artifacts and opens a PR.
3. CSO reviews the artifacts against the gate criteria in §2 above.
4. If all §2 criteria hold: CSO signs off on this ADR (status → Accepted) and authorizes the `CaptureLaunchOptions.swift` default-ON flip as a separate, CSO-reviewed PR.
5. If any §2 criterion fails: CSO rejects. Findings drive fix PRs. Re-run the corpus. Repeat.

The default-ON flip PR is a separate commit from the corpus artifact PR. It is never bundled.

## Consequences

- **Positive:** The Phase 1→2 gate becomes a checkable standard, not an ad-hoc judgment call. The CSO can verify pass/fail mechanically against the criteria.
- **Positive:** The corpus artifact gives F-STRAT-001b's third-party security audit a concrete, re-runnable test suite.
- **Positive:** The allowlist regression suite (AL-*) prevents false suppression on apps users expect to capture — a product-breaking bug that isn't a privacy issue but is equally important for trust.
- **Negative / tradeoff:** The corpus is ~40 entries run manually. A 15–30 minute operator session. Acceptable for a one-time Phase 1→2 gate; if the corpus needs to be re-run frequently (e.g., after every cascade change), automation should be considered.
- **Negative / tradeoff:** Apps the operator doesn't have installed (e.g., 1Password, Netflix native, Discord) are marked SKIPPED, not FAIL. The minimum coverage thresholds (§2.1) account for this — the runner doesn't need every app, but needs enough per layer.

## Unknowns the runner is expected to surface

The corpus plan identifies several uncertainties (marked in the inventory). The runner records what actually happens; these become findings or known gaps:

1. **Bitwarden (PM-2):** Does Electron Bitwarden call `EnableSecureEventInput()`? Does the PR #38 backstop descendant walk reach its master-password field? Or does §7 catch it?
2. **GitHub 2FA (SW-1):** Is the TOTP entry field `<input type=password>` or `<input type=text>`? If `type=text`, the cascade won't classify it as secure — is that acceptable?
3. **Preview password-protected PDF (PD-2):** Does Preview's password dialog fire the Carbon secure-input bit?
4. **Slack workspace sign-in (MS-5, AX-3):** Does the PR #38 backstop reach the password field inside Slack's Electron shell? Does §3 fire (unlikely)?
5. **Chrome password fields (BF-2):** Does Chrome expose `AXSecureTextField` subrole on `<input type=password>` on macOS 26? Or does it use a custom AX role?

## CSO sign-off (placeholder)

This ADR is proposed. CSO sign-off is owed:

1. **Now (methodology validation):** CSO validates that the corpus plan + gate criteria in this ADR are sufficient evidence for a sign-off. If not, CSO amends the criteria before the corpus is run.
2. **After the corpus run:** CSO reviews the committed artifacts against §2 and either accepts (status → Accepted) or rejects with specific findings.

— CSO, pending

## References

- `docs/audit/2026-05-23-step2-7-corpus-plan.md` — the corpus methodology this ADR gates on.
- `docs/audit/2026-05-19-step2-sec-7-corpus.md` — prior Step-2 PARTIAL PASS (superseded by this corpus).
- `docs/audit/2026-05-19-step1-live-scstream.md` — Step 1 PASS (prerequisite).
- `docs/audit/2026-05-20-step3-g2-1-footprint-preliminary.md` — G2.1 preliminary footprint PASS.
- ADR-0013 §7 + Amendment 1 §2/§4 — the binding cascade contract + enabler-PR gating boundary.
- ADR-0020 — `.mediaConsumption` cascade outcome (relevant if wired before corpus run).
- AGENT_PROTOCOL §4 (footprint SLO), §5 (CSO veto-gate), §9 (footprint-never-faked discipline).
- `adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Resources/known-safe-apps.toml` — the 10-entry allowlist.
- PR #38 (STEP-2-FINDING-001 close), PR #39 (cascade floor), PR #40 (Safari URL FP fix).

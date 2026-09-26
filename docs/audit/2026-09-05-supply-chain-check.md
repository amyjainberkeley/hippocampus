# Supply-chain and release check: 2026-09-05

## September 6 Follow-up

The original report below is retained as the failing baseline, not the current
verdict. The main integration pass repaired the following findings:

- Updated only `anyhow` from 1.0.102 to 1.0.103 in the root lockfile, including
  its registry checksum. Removed its obsolete advisory suppression. No other
  dependency was upgraded.
- Required the model and launch verifiers in app/installer assembly, including
  the installer's prebuilt-app path. A missing verifier now fails the build.
- Pinned cargo-audit to exactly 0.22.2 in CI, including the scanner cache key.
  Release and publication now audit their exact checked-out source/tag, retain
  the JSON verdict even on failure, and block on a failed or unavailable scan.
- Confirmed both tracked lockfiles pass the shared live scanner with the
  existing, visible `paste` unmaintained waiver. Advisory database revision is
  still `5a0ebedfe8bdd2e295b171f4162f8c977bcad9a5` (1,239 advisories).

Current root lockfile SHA-256:
`8be0fc18cdbf1f71cd968e5b81aed87e2931653ea6dd05ebaaae4893434fa195`.
The nested harness lockfile is unchanged. Live JSON evidence:
`/tmp/hippocampus-supply-chain-20260906.json`.

Verification: 16 scanner regression tests, seven mandatory-release-gate tests,
224 release-contract checks, eight model-archive tests, and seven model-manifest
tests passed. Fixtures cover unavailable/wrong-version tooling, incomplete
reports, empty check selection, nested lockfiles, mismatched release tags and
missing/non-executable verifiers. These are local checks, not a hosted CI run.

**Current verdict: configured Rust advisory gate passes; public release remains
blocked.** The release model manifest is still intentionally UNPROVISIONED.
The unmaintained `paste` waiver, absent broader scanners, unqualified second-Mac
behavior and unreviewed reproducibility gaps below remain open. This report is
not malware clearance, independent security certification or permission to
publish. Signing/notarization and installed behavior are recorded separately.

## Original Failing Baseline

Result: **FAIL / release readiness not established.** The installed Rust scanner
completed both tracked lockfile scans. It found no vulnerability-class advisories,
but strict unfiltered scans failed on informational advisories. The revised gate
fails on the patchable `anyhow` unsoundness warning. Release model inputs also
remain unprovisioned. These results are not malware clearance or a release approval.

Scope: `/Users/amy/hippo-work/hippocampus/.worktrees/hippocampus-v1`, baseline
`5613e3c839aa871ec0742ab06e771f174450d00b`, with concurrent uncommitted work.
Only `scripts/`, `.github/workflows/cargo-audit.yml`, and this new document were
edited. No dependency changes, lockfile changes, installations, commits, credential
changes, permission resets, or application launches were performed. Canonical
STATUS, both build scripts, runtime/core, and concurrent capture/brief edits were
left to their owners.

## Findings

Severity denotes engineering priority, not an assigned CVSS score. P2 is medium;
P3 is low. References without a baseline qualifier refer to the working tree.

| Severity | Evidence | Finding and disposition |
| --- | --- | --- |
| P2 | `Cargo.lock:27`; baseline `.github/workflows/cargo-audit.yml:86`; baseline `scripts/check.sh:30` | `anyhow 1.0.102` is affected by `RUSTSEC-2026-0190`. Both gates suppressed it under an obsolete no-fix rationale. The old policy still returned 0 on this lockfile. **Suppression removed** in the shared audit gate; the dependency remains unchanged and the gate now returns 1. |
| P2 | `.github/workflows/cargo-audit.yml:20`; `scripts/eval/agent-handoff/harness/Cargo.lock:971`; `scripts/audit-supply-chain.py:69` | Previously, only root manifests/lockfile triggered the workflow and only root `Cargo.lock` was scanned. The tracked standalone harness lockfile was omitted. **Fixed:** nested manifest/lockfile path coverage and scanning every tracked `Cargo.lock`, including paths with spaces. A fixture with a clean root and failing nested scan reproduced the old green result. |
| P2 | `scripts/check.sh:325` | `bash scripts/check.sh bash audit` previously returned 0 with zero checks. **Fixed:** an empty selection returns 1 and `{"check":"check.sh","status":"fail","reason":"no_matching_lanes"}`. Missing audit tooling and scan errors also return nonzero with JSON evidence through the shared scanner entry point. |
| P2 | `apps/hippocampus/Resources/build-app.sh:942`; `apps/hippocampus/Resources/build-app.sh:959`; `scripts/build-installer.sh:342` | Model verification in app assembly is conditional on the verifier being executable; if absent/non-executable, the block is silently omitted. Launch verification in both build scripts also skips absent/non-executable verifiers, with a warning. **Open, outside edit scope:** require these verifiers in release mode. Observed in source; full build/launch paths were not executed. |
| P2 | `.github/workflows/release.yml:5`; `.github/workflows/release.yml:94`; `.github/workflows/publish-release.yml:50` | Tag-triggered building and manually approved publication contain no explicit dependency on a successful Rust audit of that tag. A standalone audit workflow does not enforce this relationship. **Open, outside workflow scope:** bind release preparation/publication to an audit of the exact release source. Remote branch/tag rules and environment protections were not inspected. |
| P2 | `release-models.json:4`; `scripts/release_models_manifest.py:49` | The canonical model URL and digest are both `UNPROVISIONED`. The existing validator returned 1 for release `0.1.0`. **Open release prerequisite, correctly blocked:** provision the reviewed immutable archive and digest through the owning release task. No actual release model download was attempted. |
| P3 | `.github/workflows/cargo-audit.yml:77`; `.github/workflows/cargo-audit.yml:81` | Scanner installation is unversioned, while its cache uses a permanent `-v1` key. Cold caches can install different scanner versions and warm caches can retain old ones. **Open proposal:** select an approved `cargo-audit` version and include it in both installation and cache identity. The new report records the actual scanner version; this task did not change scanner dependencies. |
| P3 | `scripts/verify-models.sh:245` | The optional Hugging Face HEAD/ETag drift check warns and skips on a failed request or missing header. It is not evidence of verified remote bytes. The canonical release archive path separately requires a SHA-256 match before extraction. **Open:** classify the HEAD check explicitly as unavailable in release evidence when it cannot run. |
| P3 | `scripts/requirements-ml.txt:48`; `scripts/requirements-evidence-verifier.txt:5`; `extensions/chromium/package.json:7` | ML conversion requirements include ranges; the evidence-verifier requirements pin direct versions but do not hash-lock the complete transitive graph. Chromium has a `vitest` dev dependency and no tracked npm lockfile. **Open proposal:** review reproducible tool environments/lockfiles before changing them. No Python, npm, or Swift vulnerability scan was available/completed here. |

RustSec identifies the `anyhow` fix as `>=1.0.103`. A search of tracked Rust source
for `downcast_mut(` returned no matches; that is not proof of transitive
unreachability. Proposal, not performed: review a targeted `anyhow 1.0.102 ->
1.0.103` lockfile update, inspect the dependency diff, then rerun relevant Rust
tests and this audit. [RustSec advisory](https://rustsec.org/advisories/RUSTSEC-2026-0190.html).

`paste 1.0.15` remains unmaintained in both lockfiles. The existing
`RUSTSEC-2024-0436` waiver remains visible as `ignored_advisories` in the new report.
No replacement was made. Proposal: review upstream dependency paths and a supported
replacement separately. [RustSec advisory](https://rustsec.org/advisories/RUSTSEC-2024-0436.html).

## Measured Scans

Capability was checked before scanning with `command -v`, `cargo audit --version`,
and `cargo audit --help`. Existing scanner: `cargo-audit-audit 0.22.2`. No tool was
installed. Both scans fetched the public advisory database using default freshness
and yanked-crate checks; no `--stale`, `--no-fetch`, `--no-yanked`, or target filters
were used. Lockfiles were checked locally. Network use was limited to public
advisory/registry metadata and public RustSec reference pages.

Database: **1,239 advisories**, commit
`5a0ebedfe8bdd2e295b171f4162f8c977bcad9a5`, last updated
`2026-09-02T11:13:32+02:00`.

| Command/policy | Lockfile packages | Vulnerability advisories | Informational warnings | Exit |
| --- | ---: | ---: | --- | ---: |
| `cargo audit --json --deny warnings --file Cargo.lock` | 296 | 0 | `anyhow` unsound; `paste` unmaintained | 1 |
| `cargo audit --json --deny warnings --file scripts/eval/agent-handoff/harness/Cargo.lock` | 198 | 0 | `paste` unmaintained | 1 |
| Previous root policy, ignoring both advisory IDs | 296 | 0 | Both suppressed | 0 |
| `python3 -B scripts/audit-supply-chain.py`, root | 296 | 0 | `anyhow` unsound; existing `paste` waiver | 1 |
| Same shared gate, harness | 198 | 0 | Existing `paste` waiver | 0 |
| `CHECK_SH_QUIET=1 bash scripts/check.sh rust audit` | Both lockfiles | See above | 0 pass, 1 failed lane, 0 skipped lanes | 1 |

Counts overlap between lockfiles and must not be added as distinct dependencies.
Raw, source/lockfile-only reports are retained locally in
`/tmp/hippocampus-supply-chain.L8cQFh/`: `root-audit.json`, `harness-audit.json`,
`previous-policy-audit.json`, and `gated-audit.json`. Temporary files may be removed
by the OS; the durable measurements are recorded here.

Machine-readable summary:

```json
{
  "schema_version": 1,
  "date": "2026-09-05",
  "status": "fail",
  "scanner": {"name": "cargo-audit", "version": "0.22.2"},
  "database_commit": "5a0ebedfe8bdd2e295b171f4162f8c977bcad9a5",
  "raw_scans": [
    {"lockfile": "Cargo.lock", "status": "fail", "exit_code": 1, "packages": 296, "vulnerabilities": 0, "warnings": ["RUSTSEC-2026-0190", "RUSTSEC-2024-0436"]},
    {"lockfile": "scripts/eval/agent-handoff/harness/Cargo.lock", "status": "fail", "exit_code": 1, "packages": 198, "vulnerabilities": 0, "warnings": ["RUSTSEC-2024-0436"]}
  ],
  "release_gate": {"status": "fail", "exit_code": 1, "ignored_advisories": ["RUSTSEC-2024-0436"]},
  "release_model_manifest": {"status": "fail", "exit_code": 1, "reason": "unprovisioned_url_and_digest"},
  "source_security_scanner": {"status": "unsupported", "reason": "no_available_source_security_scanner"},
  "swift_dependency_scan": {"status": "unsupported", "reason": "no_available_compatible_scanner"},
  "python_dependency_scan": {"status": "unsupported", "reason": "pip_audit_unavailable"},
  "npm_dependency_scan": {"status": "unsupported", "reason": "no_tracked_package_lock"},
  "binary_malware_scan": {"status": "skipped", "reason": "source_and_lockfiles_only_scope"},
  "external_content_uploads": false,
  "dependency_or_lockfile_changes": false
}
```

## Integrity Review

- Root lockfile: 276 registry packages and 20 local packages. Harness: 187 registry
  and 11 local packages. All registry package entries have 64-digit hexadecimal
  checksums and the crates.io source; neither lockfile has a Git dependency.
  This verifies lock metadata, not independently downloaded crate bytes.
- `apps/hippocampus/Package.resolved:9` pins Sparkle `2.9.2` to revision
  `6276ba2b404829d139c45ff98427cf90e2efc59b`; line 18 pins TOMLKit `0.6.0` to
  `ec6198d37d495efc6acd4dffbd262cdca7ff9b3f`. Sparkle's manifest requirement is
  `from: "2.6.0"` (`apps/hippocampus/Package.swift:39`); the reviewed release build
  commands do not explicitly force resolved versions. No Swift resolution was run.
- Canonical release downloads use HTTPS with curl failure handling
  (`.github/workflows/release.yml:82`). `scripts/release_models_manifest.py:47`
  requires a release-version URL, and `scripts/prepare_release_models.py:91`
  checks the exact SHA-256 before extraction. Archive extraction rejects traversal,
  duplicate paths, links, and unsupported member types and has declared size/count
  limits (`scripts/prepare_release_models.py:101`). Only synthetic fixtures were
  extracted during this task.
- `scripts/verify_release_identity.py:163` checks the DMG checksum and filename;
  line 189 binds the appcast URL/length to the release, and line 198 invokes the
  Sparkle verifier against the exact DMG bytes. Missing signature verification is
  fatal on this path. Publication also checks codesign, notarization stapling, and
  Gatekeeper (`.github/workflows/publish-release.yml:65`). Those macOS artifact
  checks were inspected in source, not run against an application or installer.
- The audit workflow already pins actions by full commit SHA, uses read-only
  contents permission, has a 15-minute timeout, and runs weekly. Its original
  primary scan did propagate failures; the old `|| true` applied to a separate
  report command, not the primary gate. The revised workflow uses one report and
  verdict per lockfile and fails artifact upload if the report is absent.

## Verification And Limits

- New regression suite: **10 tests passed**. Two tests first reproduced the old
  zero-check and nested-lockfile false successes. Tests also cover missing scanner,
  missing subcommand, absent tracked/root lockfiles, malformed successful output,
  database errors, continuing after one failed scan, and complete successful
  coverage. Fixtures use temporary repositories and fake scanner processes;
  no real network, credentials, or application data are involved in those tests.
- Existing `test-prepare-release-models.sh`: **8 passed, 0 failed**.
  Existing `test-release-model-manifest.sh`: **7 passed, 0 failed**.
  Existing `test-no-quarantine-bypass.sh`: **passed**, a narrow source contract.
- `bash -n scripts/check.sh` and `git diff --check` passed. The workflow parsed
  using the installed Ruby YAML library; 14 representative root/nested manifest,
  lockfile, and audit-script path cases matched. This was not actionlint or a
  GitHub-hosted workflow execution. No build, full test suite, or CI run was started.
- Not found on PATH: `cargo-deny`, `osv-scanner`, `semgrep`, `trivy`, `grype`, `syft`,
  `clamscan`, `gitleaks`, `detect-secrets`, `bandit`, `pip-audit`, `shellcheck`, and
  `actionlint`. The default Python environment also lacked `pip_audit`, `bandit`,
  and `semgrep` modules. No full static security, secrets, SBOM, or malware scan
  is claimed. npm exists, but a resolved npm dependency scan was not attempted
  without a tracked lockfile. Other interpreter/virtualenv installations were not
  searched. Missing coverage is unsupported/skipped, not green.
- Personal screen/memory databases, captures, keys, developer credentials, app
  bundles, installers, and model weights were neither scanned nor uploaded.
  No permissions or protections were disabled. Runtime capture qualification and
  brief work belong to concurrent owners.

Lockfile SHA-256 values matched before and after the work:

| File | SHA-256 |
| --- | --- |
| `Cargo.lock` | `5b7b688dfb9f337dd9f8044b22d46bbfbcd9cf6d341e124610d7361b0ad5b6b4` |
| `scripts/eval/agent-handoff/harness/Cargo.lock` | `45344fb00e19b406b2fbafb90853e710b7f78dba16962303f948ce14b2f1479a` |
| `apps/hippocampus/Package.resolved` | `36eba7a3e4124b394d84e5e528511ba023f42fc14df8e2db1dd7ebe7e3e97794` |

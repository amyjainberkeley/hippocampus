# Task 2 Final Repair Report R5: Pinned Parser License Contract

Status: the repository-local R5 P1/P2 findings are repaired on
`codex/hippocampus-v1`. The R5 review accepted the behavioral and privacy work
from R4; this repair changes only third-party-license disclosure and its release
gates. Nothing was pushed, Developer-ID signed, notarized, uploaded, or
published.

R5 review base: `6fb8bab56b6ba26a0ce2af4e0eb7bd56d4c4686b`.

## Finding Disposition

| Finding | Disposition |
|---|---|
| P1-1 complete MIT terms absent from the app | Repaired locally. Complete TOMLKit 0.6.0 and bundled toml++ 3.4.0 MIT texts are committed and embedded verbatim in `NOTICE`. The build pipeline copies that file to the app's `NOTICE.txt` for the existing offline About link, then signs later. App assembly runs the content verifier before either step. |
| P2-1 release CI misses dependency-license inputs | Repaired locally. Push and pull-request filters watch `Package.swift`, `Package.resolved`, `NOTICE`, both canonical licenses, their manifest, and the verifier/test. Release CI and the unified local gate run the license contract. |

## Source Identity And Drift Boundary

- `Package.swift` exact-pins TOMLKit 0.6.0 and `Package.resolved` pins revision
  `ec6198d37d495efc6acd4dffbd262cdca7ff9b3f`.
- `third_party/licenses/toml-license-manifest.json` records that pin, each
  canonical license hash, and the reviewed upstream source path/hash.
- The committed TOMLKit license is byte-identical to `LICENSE` at the pinned
  checkout (`bccd5fe8...10abe`). The committed toml++ text is the complete MIT
  block from bundled `Sources/CTOML/Sources/toml.hpp`; that exact 3.4.0 header
  hashes to `6b5172ad...19783e`.
- `verify-toml-license-contract.py` rejects manifest drift, Swift declaration
  drift, resolved URL/version/revision drift, missing canonical files, license
  hash drift, absent permission/inclusion/warranty/liability clauses, and any
  non-verbatim or duplicate embedding in `NOTICE`.
- `test-toml-license-contract.sh` starts from the real repository and then
  mutates isolated copies. It proves rejection of a missing permission grant,
  missing warranty disclaimer, changed resolved revision, shipped-notice drift,
  and a missing canonical license.

## Release Integration

- `build-app.sh` executes the deterministic verifier before assembling the
  app, copies the verified `NOTICE` to `Contents/Resources/NOTICE.txt`, and only
  signs later. The existing About surface opens this bundled file without a
  network dependency.
- `test-release-contract.sh` checks invocation and ordering, verifies the local
  About path, asserts every license input is watched by release CI, and requires
  the license test in both CI and `scripts/check.sh`.
- The release-contract workflow runs the mutation contract on macOS and watches
  both dependency manifests, the shipped notice, canonical sources, manifest,
  verifier, and test on pushes and pull requests.

## TDD And Verification

- Red: the new license contract reported 4 missing required inputs; the release
  contract reported 11 missing assembly/CI/watch hooks (86 passed, 11 failed).
- `scripts/test-toml-license-contract.sh`: PASS, 6 passed and 0 failed.
- `scripts/test-release-contract.sh`: PASS, 99 passed and 0 failed.
- `scripts/check.sh bash lint`: PASS, 5 lanes and 0 failures, including shell
  syntax, release contract, TOML license contract, Task 2 product truth, and
  changelog sanity.
- `scripts/swift-package.sh build --package-path apps/hippocampus`: PASS.
- Exact-checkout source comparison at the resolved TOMLKit revision: PASS for
  byte-identical TOMLKit text, normalized complete toml++ header text, and both
  reviewed source hashes.
- Changed-shell `bash -n`, Python source compilation, manifest JSON parsing, and
  `git diff --check`: PASS.
- `go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7
  .github/workflows/release-contract.yml`: PASS.
- Full XCTest was not run on this Command Line Tools host and is not claimed.

## Changed Files

- `.github/workflows/release-contract.yml`
- `.superpowers/sdd/2026-09-01-hippocampus-memory-layer/task-2-report.md`
- `NOTICE`
- `apps/hippocampus/Resources/build-app.sh`
- `scripts/check.sh`
- `scripts/test-release-contract.sh`
- `scripts/test-toml-license-contract.sh`
- `scripts/verify-toml-license-contract.py`
- `third_party/licenses/TOMLKit-0.6.0-LICENSE.txt`
- `third_party/licenses/toml-license-manifest.json`
- `third_party/licenses/tomlplusplus-3.4.0-LICENSE.txt`

## Residual Owner And API Gates

- Obtain legal-owner approval of the complete third-party notice bundle and
  canonical user terms before public distribution. These repository checks
  verify content identity and packaging behavior; they are not legal advice or
  legal approval.
- Run full XCTest with full Xcode.
- Complete the existing Developer-ID continuity, Keychain access-object,
  physical-Mac TCC/lifecycle, sustained-capture, signing, notarization, and
  publication gates documented by R4/R5 before release.

Concurrent Task 5 benchmark/core edits and Task 4 keyframe/thumbnail artifacts
were preserved and are not part of this repair. `scripts/__pycache__/` also
remains untouched and untracked.

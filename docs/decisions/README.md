# docs/decisions/

The ADR (Architecture Decision Record) archive. Every locked material
decision has a numbered file here. Sequential, immutable once merged
— supersede an old ADR with a new one, do not rewrite.

## File naming

`NNNN-kebab-slug.md`, zero-padded to 4 digits, monotonically
increasing. Numbers are allocated on merge, not on draft — check
`ls docs/decisions/ | tail -1` before you claim the next number.

## Contents (as of cycle 8.44)

35 ratified ADRs from ADR-0001 (privacy posture: local-first + E2E)
through ADR-0035 (v2 P12 chat surface on AnyLanguageModel). Load-
bearing ones agents cite most often:

- `0001-privacy-posture-local-first-e2e.md` — the privacy thesis.
- `0002-stack-split-rust-core-native-adapters.md` — the trait seam.
- `0007-macos-capture-separate-signed-helper-process.md` — helper
  process boundary.
- `0008-encrypted-store-sqlcipher-sqlite-vec-keychain.md` — brain
  store layout.
- `0013-native-grade-sensitive-surface-suppression.md` — the
  cascade.
- `0016-phase-3-ocr-brain.md` — Phase-3 brain build.
- `0019-company-workspace-server-tier-2-store.md` — sync server
  model.
- `0034-fleet-authored-pr-merge-policy.md` — Track A / Track B.

## Related

- `../DESIGN.md` — the canonical architecture; ADRs are the
  provenance for each locked choice.
- `../research/` — research memos that fed the ADR debates.

## When to edit here

Only to add a NEW ADR (next sequential number) or to append a
"Superseded by ADR-NNNN" note to an existing one. Never rewrite the
body of a merged ADR — supersede it. ADRs touching crypto / sync /
sensitive-capture require CSO sign-off; commercial ADRs require CEO
ratification.

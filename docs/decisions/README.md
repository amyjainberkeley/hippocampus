# docs/decisions/

Architecture decision records. Each locked decision has a numbered file
here. Supersede an old record with a new one; do not rewrite it.

> **A note on dead links.** Some records cite working notes, design drafts
> and audit logs (`docs/business/…`, `docs/DESIGN.md`, `docs/audit/…`,
> nightly logs) that are not part of this repository. The records are
> unedited apart from their headers, so the reasoning is intact even where a
> citation does not resolve. Where a cited document was a real build input,
> such as the redaction corpora and the sensitive-domain list, it lives in
> `core/brain/fixtures/` and `core/brain/src/redaction/` instead.

## File naming

`NNNN-kebab-slug.md`, zero-padded to 4 digits, monotonically
increasing. Check `ls docs/decisions/ | tail -1` before you claim the
next number.

## Contents

Records run from ADR-0001 (privacy posture) to ADR-0040 (whole-screen
reading). Numbers 0019, 0022, 0023, 0027 and 0034 were withdrawn. They
described team and server features this app does not have. The ones cited
most often:

- `0001-privacy-posture-local-first-e2e.md`: the privacy thesis.
- `0002-stack-split-rust-core-native-adapters.md`: the trait seam.
- `0007-macos-capture-separate-signed-helper-process.md`: the helper
  process boundary.
- `0008-encrypted-store-sqlcipher-sqlite-vec-keychain.md`: the store
  layout.
- `0013-native-grade-sensitive-surface-suppression.md`: what is never
  read, and how.
- `0016-phase-3-ocr-brain.md`: the memory build.
- `0038-source-attributed-evidence-verifier.md`: the trusted recall
  boundary.
- `0039-zero-download-evidence-briefs.md`: the default brief and release
  model boundary.
- `0040-whole-screen-background-capture.md`: whole-screen reading.

## Related

- `../../ARCHITECTURE.md`: the system map.
- `../research/`: research memos that fed the decisions.

## When to edit here

Only to add a new record (the next number) or to append a "Superseded by
ADR-NNNN" note to an existing one. Never rewrite the body of a record;
supersede it.

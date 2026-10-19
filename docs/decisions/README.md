# docs/decisions/

Architecture decision records. Each locked decision has a numbered file
here. Supersede an old record with a new one; do not rewrite it.

> **A note on dead links.** Some records cite working notes, design drafts
> and audit logs (`docs/business/…`, `docs/research/…`, `docs/DESIGN.md`,
> `docs/audit/…`, nightly logs) that are not part of this repository. Where a
> cited document was a real build input, such as the redaction corpora and
> the sensitive-domain list, it lives in `core/brain/fixtures/` and
> `core/brain/src/redaction/` instead.
>
> **Edits for publication, 2026-10-15.** The records' reasoning is unchanged,
> with three exceptions. Team, enterprise and paid-tier sections are marked
> withdrawn, because Hippocampus is for individuals. Job titles from the
> project's early process are replaced by what they did ("the owner", "a
> security review"). ADR-0030's context is rewritten in plain terms.

## File naming

`NNNN-kebab-slug.md`, zero-padded to 4 digits, monotonically
increasing. Check `ls docs/decisions/ | tail -1` before you claim the
next number.

## Contents

Records run from ADR-0001 (privacy posture) to ADR-0042 (the capture
helper's readiness receipt). Numbers 0019, 0022, 0023, 0027 and 0034 were
withdrawn: they described team and server features this app does not have.
Number 0025 was withdrawn on 2026-10-15: it planned opt-in usage analytics,
and Hippocampus has none. The ones cited most often:

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
- `0041-browsers-and-reading-cadence.md`: browsers, and how often each
  window is read.
- `0042-helper-readiness-receipt.md`: how the helper says it is ready, and
  which permissions it found off.

## Related

- `../../ARCHITECTURE.md`: the system map.
- `../STATUS.md`: what works today, and how it was checked.

## When to edit here

Only to add a new record (the next number) or to append a "Superseded by
ADR-NNNN" note to an existing one. Never rewrite the body of a record;
supersede it.

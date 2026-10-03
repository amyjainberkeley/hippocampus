# Storage regression qualification

Date: October 3, 2026. Tested source:
`40e0d9a4651f2e8eddadc56f11b327651dfe237e`.

The complete `mci-brain` crate test run passes: 723 tests, zero failures and
one existing ignored performance harness. This includes library, integration
and documentation tests, using two build jobs and two test threads in an
explicit minimal environment without provider credentials. No tests were
changed, retried or newly skipped.

Relevant upgrade and deletion checks include:

- Creating earlier schema fixtures and opening them with the current writer;
  populated historical memory schemas retain their data and retraction ledger.
- Rejecting malformed or partial schemas without committing a partial upgrade;
  failed historical restoration leaves both schema and data intact.
- Preserving deletion barriers across reopening and rejecting delayed or
  replayed activity inside deleted ranges. A legacy upgrade preserves complete
  barrier history and rejects a partially missing activity schema.
- Keeping read-only opens from performing migrations or writing the handoff
  delivery ledger; repeated writer opens preserve recorded deliveries.
- Removing related memory evidence on deletion while retaining independent
  evidence, and reporting post-commit blob cleanup failures accurately.

The existing ignored test is `recall_perf_100k::run`, a separately invoked
100,000-event measurement harness. This checkpoint does not claim that
performance run passed. Workspace Rust formatting and all-target `mci-brain`
Clippy with warnings denied also pass.

## Qualification boundary

These are source-built regression fixtures, not an upgrade of the installed
owner app or a test of its private database. They do not prove Keychain access
continuity, writer shutdown, a consistent encrypted backup, a whole-bundle
installation, recovery after new deletions, live screen capture, or a
second-Mac install. The controlled installation and recovery procedure remains
necessary; restoring an old snapshot could resurrect subsequently deleted data.

No application code, owner configuration, stored memory, installed bundle or
public release changed. The private signed OCR candidate remains source
`2f4293c` and the installed app remains `f4f7bf1`. The pending owner unlock,
Screen Recording permission, notarization and visual OCR verification are
unchanged. Diagnostics remain in a private temporary directory outside Git.

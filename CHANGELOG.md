# Changelog

User-facing changes to Hippocampus are recorded here. Internal implementation
commits are intentionally omitted from release notes.

## [Unreleased]

## [0.1.0] - 2026-09-01

### Memory and recall

- Search local work memory with combined lexical and semantic retrieval, then inspect the source context behind each result.
- Review recent activity and open recall, privacy, and diagnostic surfaces from the native macOS app.
- Run OCR, embeddings, indexing, and retrieval on the Mac without sending captured content to a hosted inference service.

### Privacy and control

- Pause or resume capture and configure app and URL exclusions before content enters the memory pipeline.
- Manage local retention, export, and deletion controls for SQLCipher-backed memory storage.
- Retention removes expired database rows and compacts local storage; it does not claim range-key erasure.

### Integrations

- Ingest permitted browser context and explicitly allowlisted Mail or Messages content when the corresponding macOS permissions are enabled.
- Use bundled on-device models for semantic recall, entity recognition, and local brief generation when those surfaces are enabled.

### Preview limitations

- Live capture remains off by default until the user enables the persisted capture setting. Each change is accepted only after generation-bound helper readiness; physical-Mac TCC and sustained-capture verification are still pending.
- Runtime capture preferences are accepted only after whole-document TOML validation; malformed syntax, wrong types, and duplicate semantic keys fail closed.
- Quit and Quit-and-Restart now wait for verified helper and agent shutdown, escalating from TERM to KILL when needed, before the app exits or relaunches.
- Legacy `dev.key` custody migrates add-only into the macOS file Keychain and removes plaintext only after validation. Cross-version Developer ID ACL continuity for Hippocampus, the capture helper, the agent, and Recall remains an owner release gate.
- The Key Wrap Audit reports whether the item is readable without treating that read as proof of its access-control object. ACL inspection and signed cross-version continuity remain release gates.

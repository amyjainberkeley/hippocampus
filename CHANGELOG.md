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

### Integrations

- Ingest permitted browser context and explicitly allowlisted Mail or Messages content when the corresponding macOS permissions are enabled.
- Use bundled on-device models for semantic recall, entity recognition, and local brief generation when those surfaces are enabled.

### Preview limitations

- Live capture remains off by default and requires the `HIPPOCAMPUS_ENABLE_V2P1=1` boot-time opt-in while release verification is pending.
- The branch is migrating legacy `dev.key` custody to the macOS Keychain; end-to-end migration and release verification are still pending.

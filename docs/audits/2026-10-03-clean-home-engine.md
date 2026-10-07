# Isolated memory-engine qualification

Date: October 3, 2026. Tested source:
`a3e09ba12663bba8fbac434f5de295252c1362ec`.

The existing `scripts/e2e-clean-home.sh` completed successfully in a disposable
home. It built the current debug engine and fixture tools with two Cargo jobs,
copied them into that home and exercised the real ingest, storage, enrichment,
MCP and client-registration commands using fabricated evidence.

| Stage | Verified result |
| --- | --- |
| Initial state | Capture setting starts off; synthetic development key is mode 0600 |
| Seed import | Exactly 20 fabricated events are stored |
| Injected capture | One production wire frame passes strict ingest; count becomes 21 |
| Derived memory | Episode derivation returns sessions; a synthetic dated brief is persisted and a duplicate write is rejected |
| MCP | Initialization, tool listing, recall, timeline, episodes and context all return responses |
| Source linkage | Recall finds the injected phrase; timeline includes the fixture app; context includes event 21 in both citations and a section item |
| Client registration | Fake Claude/Codex clients receive Keychain references without the reusable development key or its file path |
| Deletion | Event 21 becomes unreadable and the count returns to 20 |
| Fixture cleanup | Isolated engine, database/key, runtime configuration and client files are removed |

The run used an explicitly constructed environment without provider credentials,
embedding disabled and fake client executables. No live screen or microphone
was recorded. The generated key and synthetic brain were confined to the
disposable home and removed by the harness. Retained diagnostic files are in
private mode-0700 temporary directories outside the repository; no memory or
key material is included in this checkpoint.

## Scope

This qualifies the source-built command-line memory path with development
custody and injected capture. Context assertions require an accepted
`evidence_backed` or `observations_only` outcome and the canonical event link;
they do not assert that the packet contains verified decisions. Embeddings,
screen OCR, native capture permission, GUI onboarding, prediction quality and
the owner's actual client sessions were outside this run.

The harness copies engine files and removes its own fixture directories.
It does not qualify the DMG/Finder installation experience, a GUI uninstall,
Keychain migration, upgrade from an older schema or recovery after deletion.
Those release gates remain open, along with the eight previously recorded
Apple Vision fallback assertions.

No application code changed in this checkpoint. The private signed candidate
still comes from `2f4293c`, the installed owner app remains `f4f7bf1`, and no
notarization, installation, public download or website state changed.

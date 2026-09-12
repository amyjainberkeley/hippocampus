# Hippocampus

Hippocampus is a local memory app for macOS. With capture enabled, it records
permitted focused-window text and selected screenshots, preserves their source
and time, and lets you search that evidence or pass cited context to an AI tool.

The implementation combines a native Swift capture and viewing layer with a
Rust storage and retrieval engine. OCR runs through Apple Vision; optional
semantic search uses a local Core ML embedder. Current daily briefs select
source excerpts with citations. They do not establish that a task was completed,
a commitment was made, or a captured statement is true.

The work-memory source update separates three jobs: **Today** shows measured
intervals and places to resume, **Search** finds matching evidence, and
**History** preserves chronological sources and sessions. Measurement is a
separate data path from screenshots: missing samples are not counted as work.
See the [work-memory checkpoint](docs/audits/2026-09-09-work-memory.md) for
verification and remaining live gates.

**Start with [current status](docs/STATUS.md).** It separates implemented code,
source-test results, installed-build evidence, and open release gates. A public
repository, a local installation, a website deployment, and a qualified public
download are separate milestones.

## Read The Repository

| Your question | Start here |
| --- | --- |
| What can I use, and how do I start? | [Overview and user path](docs/guide/overview.md) |
| How does capture become retrievable evidence? | [Architecture](docs/guide/architecture.md) |
| What changed, and why? | [Development history with commit links](docs/guide/development-history.md) |
| What consumes disk, compute, or paid usage? | [Cost and storage audit](docs/guide/cost-and-storage.md) |
| What is installed, tested, or still blocked? | [Status](docs/STATUS.md) and [publication record](docs/PUBLISHING.md) |

Newcomers can follow the overview through the synthetic demo and into the user
workflow. Contributors can then follow the architecture's code map and the
history's linked changes. Older [design documents](docs/DESIGN.md) and
[decision records](docs/decisions/) preserve intent, including work that has
since changed or remains unimplemented.

## Try Synthetic Recall

From a fresh checkout, with Rust and the `openssl` command available:

```bash
git clone --branch codex/hippocampus-v1 https://github.com/amyjainberkeley/hippocampus.git
cd hippocampus
./scripts/try-it.sh
```

The script builds the CLI, creates a disposable encrypted database under
`hippocampus-demo/`, and searches synthetic events with FTS5. It does not start
capture or open your personal memory. The first build can take several minutes
and fetch build dependencies. This demonstrates lexical recall, not live
capture or semantic-search quality. Re-running replaces the demo database.

## Privacy And Scope

Hippocampus itself has no cloud service. Capture, OCR, indexing, and the memory
store run locally. When you connect an external AI tool,
a connected AI client sends only the context it requests to its selected provider
under that provider's terms. Registration gives the local MCP process a database
path and Keychain reference; it does not give the client the database key.
Repeated authorized requests can expose more context over time.

Capture depends on consent, permissions, window attribution, and privacy checks.
Coverage is selective, OCR can miss text, and retained screenshots are condensed.
The database and screenshot blobs are encrypted separately. Age-based retention
exists; a total disk-budget cap is not implemented. The guides explain these
boundaries, including optional network paths and external-client billing.

## Contributing And Licensing

For a reproducible issue or a focused pull request, follow the
[contributor path](docs/guide/overview.md#contributor-path). Report exploitable
issues through [SECURITY.md](SECURITY.md).

The root [LICENSE](LICENSE) is Apache-2.0. Public source availability does not
mean every distribution obligation is resolved: source-header inconsistencies,
third-party notices, model packaging, and application terms need reconciliation.
See the [license and distribution audit](docs/guide/overview.md#license-and-distribution)
before treating this checkout as a complete redistributable product.

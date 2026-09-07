# Overview

Hippocampus keeps local evidence of permitted work on a Mac so you can find it
again. A memory can contain recognized text, an app, a window title, a URL, a
timestamp, and a reference to an encrypted screenshot. Missing fields and
capture gaps matter: the record is an observation, not a complete activity log.

Read [status](../STATUS.md) before installing or evaluating the app. It is the
authority for current builds and release gates; this guide explains the workflow.

## Reading Path

1. **Newcomer:** read this overview and try the [synthetic CLI demo](../../README.md#try-synthetic-recall).
2. **User:** understand capture controls, inspect a source memory, then use search,
   a daily draft, or an explicitly connected agent.
3. **Contributor:** follow the [architecture](architecture.md) into code, then
   read the relevant [development milestone](development-history.md) and tests.
4. **Evaluator:** use the [cost audit](cost-and-storage.md), [evaluation index](../eval/README.md),
   and [release checklist](../release/RELEASE_CHECKLIST.md). Fixture results and
   owner-machine observations have different scopes.

## User Path

The native app targets Apple Silicon macOS. Capture requires explicit enablement
and macOS permissions. Its boundary is the permitted focused window; it does
not promise background-window, all-app, or private-browser coverage. Uncertain
privacy or focus checks can withhold capture. Pause and app-access settings are
part of that boundary, not retrieval filters applied after recording.

In Recall, inspect a recent memory's text, source, time, and available screenshot.
Then search for distinctive words or a remembered topic. Keyword search depends
on retained text; semantic search also needs a working embedder and stored
vectors. A plausible related result is still not a verified answer. An empty
result can mean no capture, withholding, OCR failure, or no matching evidence.

The Now view and daily briefs organize selected evidence. Briefs are currently
extractive drafts: finite rules select lines, remove recognized interface noise,
and attach event citations. Their section labels do not prove completed work
or detect commitments. Day-context export is also bounded and can sample a dense
day. Review its sources before sharing.

Production CLI commands use the app's Keychain authority. With packaged tools
available on your PATH, useful entry points are:

| Command | Effect |
| --- | --- |
| `mci-brain stats`, `mci-brain recent --limit 5` | Read counts or recent evidence |
| `mci-brain search "distinctive words"` | Search with FTS5, without an embedding model |
| `mci-brain show 6` | Read one event; substitute an ID returned by your search |
| `mci-agent context --focus "project name"` | Read a bounded, cited context packet |
| `mci-agent connect --all` | Modify detected Claude Code and Codex configurations to register local MCP |
| `mci-agent embed-backfill` | Write missing vectors using a working local embedder |
| `mci-agent mcp-sync` | Import versioned resources from explicitly registered local MCP servers |

Use each tool's help for options. Manual imports and backfill are writers and can
be blocked while another process holds the writer lease. An agent connection is
optional; its provider's billing and data handling apply to received context.
The opt-in session-context hook is a separate choice from MCP registration.

For semantic setup, see the [Core ML conversion guide](../coreml-conversion-howto.md)
and [conversion script](../../scripts/convert_embedder.py). The runtime needs a
compiled `.mlmodelc`; a source `.mlpackage` alone is insufficient. Model presence
does not prove successful loading or populated vectors. Check the recall mode
reported by `mcp-serve`. The synthetic demo uses an isolated development key;
that is not the production key-custody setup.

## Contributor Path

Start with [AGENTS.md](../../AGENTS.md), the [code map](architecture.md#code-map),
and the nearest decision record. `Cargo.toml` declares package compatibility;
[rust-toolchain.toml](../../rust-toolchain.toml) pins the compiler used for builds.
Native packages require their declared Swift tools and a compatible full Xcode
installation. Use [scripts/swift-package.sh](../../scripts/swift-package.sh) for
the repository's Swift compatibility and Recall archive-staging behavior.

For a Rust brain change, typical local checks are:

```bash
cargo fmt --all --check
cargo test -p mci-brain
./scripts/check.sh rust lint
```

The [check script](../../scripts/check.sh) lists broader and native lanes.
Select checks appropriate to the changed behavior. Use synthetic fixtures and
isolated stores; do not attach personal databases, screenshots, credentials, or
exports to issues. Describe the trigger, expected behavior, source revision,
and what was actually checked. Build success, test success, installed behavior,
and publication should be reported separately.

## License And Distribution

This is an audit of tracked files at the September 7 documentation baseline,
not a new legal clearance or dependency scan.

| Footprint | What the checkout establishes |
| --- | --- |
| [LICENSE](../../LICENSE), [Cargo.toml](../../Cargo.toml) | Root Apache License 2.0 text and Apache-2.0 workspace metadata |
| Source headers, for example [SmartCaptureFilter.swift](../../adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/SmartCaptureFilter.swift) | Some still say `SPDX-License-Identifier: TBD-private`; this conflicts with a uniformly licensed-source claim and needs owner reconciliation |
| [NOTICE](../../NOTICE), [third_party/licenses](../../third_party/licenses/) | Attribution and pinned TOML license texts exist. NOTICE still describes Qwen and NER as bundled, while the current release manifest requires only Arctic; an exhaustive current dependency-license verdict is not established |
| [Application terms](../legal/terms-of-service.md) | Separate desktop terms exist and explicitly retain a legal-owner review gate; their relationship to the root license needs clarification |
| [release-models.json](../../release-models.json) | Model archive URL and hash remain `UNPROVISIONED`; full model-license packaging is an open release gate |
| [SECURITY.md](../../SECURITY.md), [.github/workflows](../../.github/workflows/) | Private vulnerability-reporting route and CI/release/advisory checks exist. SECURITY's older known-status bullets are superseded by STATUS |
| Contribution process | No standalone CONTRIBUTING.md, code of conduct, or issue/PR templates were found in tracked files; this contributor path and AGENTS.md are the available entry points |

The repository is publicly visible and includes an open-source root license.
A complete, consistently licensed and reproducible distribution still requires
resolving the footprint above, model-asset provenance, and installation/update
qualification. The [supply-chain audit](../audit/2026-09-05-supply-chain-check.md)
records its scope and waivers; the [publication record](../PUBLISHING.md) records
a scoped history secret scan. Neither is independent security certification.

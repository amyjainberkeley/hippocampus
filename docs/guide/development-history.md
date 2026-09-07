# Development History

This is a selected history of implementation and repair, audited from Git log,
diffs, and current code through
[13e7f7a](https://github.com/amyjainberkeley/hippocampus/commit/13e7f7a)
on September 7, 2026. Dates are commit dates. They do not establish continuous
development time, hours worked, or independent verification.

Early code uses the name MCI, which remains in crates, binaries, and storage
paths. The history contains initial implementations, scaffolds, tests, and later
corrections to claims that were ahead of actual behavior.

## What Changed

| Period | Change and evidence | What that milestone does not establish |
| --- | --- | --- |
| May 18-20 | [Initial design](https://github.com/amyjainberkeley/hippocampus/commit/55bec6c), [SQLCipher opening and key types](https://github.com/amyjainberkeley/hippocampus/commit/7ed0e6a), and [hybrid retrieval](https://github.com/amyjainberkeley/hippocampus/commit/7756143) established storage and retrieval contracts with tests. | A complete desktop workflow; early adapters and key-custody promises still needed implementation. |
| July 13 | [Native delete/wipe FFI](https://github.com/amyjainberkeley/hippocampus/commit/142e3f4) connected privacy actions to the store. [Calendar, Notes, and Reminders scaffolds](https://github.com/amyjainberkeley/hippocampus/commit/0ac5309) added interfaces but returned empty reads. | All integrations working merely because their directories exist. |
| August 2 | [Embedding backfill](https://github.com/amyjainberkeley/hippocampus/commit/1967d20) added the missing one-shot writer. [Compiled-model output](https://github.com/amyjainberkeley/hippocampus/commit/8011197) fixed conversion producing a package the runtime could not load. | Population-scale recall quality. The recorded end-to-end example used a small synthetic corpus. |
| August 31 | [MCP sync](https://github.com/amyjainberkeley/hippocampus/commit/56238fc) exposed connector ingestion; [query sanitization](https://github.com/amyjainberkeley/hippocampus/commit/5bc64ea) repaired natural-language FTS failures. | Qualification against every third-party connector or exact-string search semantics. |
| September 1 | [Key custody and capture gating](https://github.com/amyjainberkeley/hippocampus/commit/86c427f), [governed claims](https://github.com/amyjainberkeley/hippocampus/commit/462060a), and [bounded agent context](https://github.com/amyjainberkeley/hippocampus/commit/eddb3dc) made consent, provenance, and handoff explicit. | Automatic truth extraction from observed screens. |
| September 1-2 | [Condensed visual evidence](https://github.com/amyjainberkeley/hippocampus/commit/ee12fcc) replaced the unused pre-OCR HEVC queue with selected encrypted JPEGs after privacy approval. [Extractive briefs](https://github.com/amyjainberkeley/hippocampus/commit/4c330da) made cited drafts available without a generative model. | Continuous video, lossless screenshots, or semantic daily synthesis. |
| September 3-5 | [Two-fps ceiling](https://github.com/amyjainberkeley/hippocampus/commit/15570c1), [focused-window qualification work](https://github.com/amyjainberkeley/hippocampus/commit/e7be6f0), and [daily visual workspace](https://github.com/amyjainberkeley/hippocampus/commit/999e680) tightened capture and made evidence inspectable. | Qualification transferring automatically to a later installed build; later audits still found capture and lifecycle failures. |
| September 6 | [Capture-stop, brief, and audit hardening](https://github.com/amyjainberkeley/hippocampus/commit/493befe) and [bounded recovery/search freshness](https://github.com/amyjainberkeley/hippocampus/commit/eff26a3) addressed failures observed in use. | Complete recovery coverage, second-Mac installation, or release readiness. |
| September 7 | [Website import](https://github.com/amyjainberkeley/hippocampus/commit/86f7666) preserved its original history in this repository. [Small-text OCR and literal recall](https://github.com/amyjainberkeley/hippocampus/commit/bb02bb4) added bounded OCR passes and fixed boolean-word handling. [Onboarding isolation](https://github.com/amyjainberkeley/hippocampus/commit/13e7f7a) routed Safari tests through the injected launcher. | A source push publishing a website, installing the latest source, or proving fresh capture end to end. |

## How To Read The Evidence

**Implemented** means a code path exists and was inspected. **Source-tested**
means a recorded test or fixture exercised a specified revision and environment.
**Installed** means an artifact was placed and checked on a machine; signature
verification and successful ingestion are different checks. **Open** means
missing implementation, unresolved failure, or insufficient qualification.

At this audit checkpoint, STATUS records an installed `bb02bb4` artifact with
signing/notarization checks, but incomplete fresh fixture-to-recall-to-context
and screenshot-readback qualification. Later source includes onboarding changes
absent from that artifact. The website's recorded version 2 was owner-private.
These are historical checkpoint facts; use [STATUS](../STATUS.md) and
[PUBLISHING](../PUBLISHING.md) for the current installed, source, hosted-CI,
deployment, and public-download states.

The [September 7 quality report](../audits/2026-09-07-memory-quality.md) records
small synthetic OCR examples, failed attempts, timing limits, and a privacy
regression caught during development. The [evaluation index](../eval/README.md)
links retrieval and handoff fixtures. Neither those fixtures nor a handful of
owner-machine screenshots establish a general accuracy or storage forecast.

## Remaining Work

The current product is an evidence store and recall interface with cited drafts.
The following boundaries remain visible in code and the release ledger:

- No qualified production verifier that promotes semantic matches to trusted answers.
- No established measurement of work time, reliable commitment tracking, or
  complete semantic reconciliation of a day.
- No implemented total-byte storage cap despite the older budget ADR.
- Cross-platform adapters, several deep hooks, and sync/server plans remain
  scaffolds or unqualified paths.
- Release-model assets, license/terms reconciliation, installation/update
  continuity, and fresh live qualification remain release work.

See the [architecture](architecture.md), [storage audit](cost-and-storage.md),
and [distribution footprint](overview.md#license-and-distribution) for the code
behind these distinctions.

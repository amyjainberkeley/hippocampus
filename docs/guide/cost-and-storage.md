# Cost And Storage

Source audit: [13e7f7a](https://github.com/amyjainberkeley/hippocampus/commit/13e7f7a),
September 7, 2026. This audit inspected repository code and records, not personal
memory, installed data, or model weights. It ran no capture or application tests.
The reported **708 events / 6.1 MB** is an unverified user observation with an
unknown measurement boundary, not an independently measured benchmark.

## What Takes Space

| Component | Implemented storage and cost |
| --- | --- |
| Text and metadata | SQLCipher holds events, source/time/app/URL fields, FTS5, episodes, entities, claims, and briefs. Text and index overhead depend on content; encryption is not compression. |
| Vectors | One stored event vector is 384 float32 values: `384 * 4 = 1,536` bytes before row/index overhead. If all 708 events had one, vector payload alone would be about 1.09 MB. Do not add that again if included in the reported database size. |
| SQLite working files | `mci.sqlite-wal` and `mci.sqlite-shm` accompany the database while in use. Counting only the main file can miss current disk usage. |
| Screenshots | Separate `blobs/<digest>.bin` files contain encrypted JPEGs. These can dominate text storage and are not included in the database file's size. |
| Models | Release manifest requires Arctic Embed S FP16. Conversion documentation describes roughly 66 MB; compiled assets and caches can differ. Models are a fixed/versioned footprint, not one copy per event. Optional Qwen/NER and conversion environments add separate costs. |
| Other files | Application binaries, rotating diagnostics, exports, installers, backups, build artifacts, and downloaded model archives are separate from retained memory. A checkout's `target/` directory is not the user's brain. |

Sources: [SQLCipher open](../../core/src/store/open.rs),
[brain store](../../core/brain/src/sqlcipher_brain_store.rs),
[blob writer](../../adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/OCR/KeyframeBlobWriter.swift),
[release manifest](../../release-models.json), and
[model conversion](../../scripts/convert_embedder.py).

A useful accounting boundary is database + WAL/SHM + managed blobs. Report
model/app files and exports/backups separately. Use file sizes and aggregate
counts with a stated timestamp and logical-versus-allocated byte convention;
there is no need to decrypt event text to measure disk growth. No such
measurement was performed for this audit.

## What Bounds Growth

The [stream configuration](../../adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/StreamConfig.swift)
limits active candidate delivery to 2 fps. The
[frame filter](../../adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/SmartCaptureFilter.swift)
drops idle/incomplete/unchanged frames and low-distance visual duplicates.
Its ambiguous dHash band is forwarded; the described SSIM tie-break is not
implemented there. A fixed percentage of frames discarded is not established.

[KeyframePolicy](../../adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/KeyframePolicy.swift)
selects admitted images on first evidence, window change, dHash distance at
least 12, or five minutes since the last retained image. Five minutes is a
maximum-silence consideration for candidates that reach this policy, not a
minimum interval or a guarantee of one screenshot every five minutes.
Images are resized to at most 1280 pixels on the long edge, JPEG quality 0.7.
There is no explicit per-image byte ceiling in this encoder and no daily
screenshot-count quota in this policy.

The [codec](../../adapters/macos/MCIKeyframeCodec/Sources/MCIKeyframeCodec/KeyframeBlobCodec.swift)
adds a random 16-byte salt and an authenticated encryption envelope. Filenames
hash encrypted bytes, so independently encrypting identical images does not
deduplicate their plaintext. Frame filtering is the relevant upstream saving.

Ordinary event insertion appends rows; it does not globally deduplicate OCR
text. Context packets and briefs collapse repeats for presentation while keeping
the source events. [MCP imports](../../apps/agent/src/mcp_aggregator.rs) do have
URI/content-revision deduplication: unchanged content is skipped, changed content
creates new evidence. Bodies over 512 KiB are cataloged as metadata/pointers;
per-resource and per-pass bounds are not a total storage budget.

## Retention And Budgets

[The retention worker](../../apps/agent/src/retention_worker.rs) reads the shared
policy. A missing file gets the fresh-install 90-day default. Seven-day,
30-day, 90-day, custom 1-365-day, and forever choices exist. Finite legacy
policies need explicit review; malformed configuration stops automatic deletion.
The [daemon](../../apps/agent/src/bin/mci_agent.rs) schedules this maintenance
daily while running, so it is not an always-active disk quota.

[The purger](../../core/brain/src/retention_purger.rs) deletes expired events and
dependent records, removes orphan episodes and expired briefs, runs VACUUM, and
cleans last-reference screenshot blobs. It protects the most recent hour.
The worker also reconciles crash-orphaned blobs and stale temporary files after
a one-hour grace period, including in forever mode. Configuration/maintenance
failures can prevent a cycle from completing. Compaction adds disk I/O; deletion
is not a guarantee of erasure from backups or external copies.

**No implemented total-byte cap or budget-warning flow was found.**
[ADR-0024](../decisions/0024-storage-budget-retention-ux.md) describes a 25 GB cap,
90% warnings, and oldest-first pruning to 80%. The inspected runtime and settings
implement age-based retention, not that budget system. Its old HEIC/growth
estimates are also not measurements of today's JPEG implementation.

[Episode consolidation](../../core/brain/src/consolidator.rs) builds and
reconciles shared-identity links. It does not compress old evidence into a
summary and delete the originals. Brief generation does not reclaim source
storage. With a 90-day default, age retention alone would not remove new
evidence during an initial 60-day period.

## Conditional 60-Day Arithmetic

For decimal units, `1 MB = 1,000,000 bytes` and `1 GB = 1,000 MB`.

**Only if** the reported 6.1 MB represents seven days of incremental growth,
covers the same components, and that rate stays constant:

```text
6.1 MB / 7 days                = 0.871 MB/day
6.1 MB * 60 / 7                = 52.3 MB over 60 days
708 events * 60 / 7            = about 6,069 events
6.1 MB / 708 events            = about 8.6 kB/event, including unknown overhead
```

A current total is not necessarily a seven-day increment. Fixed schema/model
costs, imports, paused capture, missing screenshots, or sparse fixture events
invalidate that forecast. This arithmetic does not demonstrate that normal use
will remain near 52 MB, nor does it support 20 GB from the reported sample alone.

For comparison, the table below assumes **eight active hours on each of 60
days**, no deletion, a stated average size per retained encrypted image, and the
stated *retained* cadence after filtering. Sizes and cadences are hypothetical,
not measured defaults. Totals cover blobs only; add text/index/WAL and fixed
files separately. For workdays only, substitute the actual active-day count.

| Average retained image | Retained cadence | Images/day | Blobs over 60 days |
| --- | --- | ---: | ---: |
| 50 kB | One per 5 minutes | 96 | 0.288 GB |
| 100 kB | One per minute | 480 | 2.88 GB |
| 250 kB | One per 30 seconds | 960 | 14.4 GB |
| 100 kB | One per 10 seconds | 2,880 | 17.28 GB |
| 100 kB | Every 2-fps candidate retained | 57,600 | 345.6 GB |

The last row is a counterfactual ceiling scenario, not expected behavior.
The general formula is `active_days * hours/day * 3600 / interval_seconds *
bytes/image`. It shows why a capture frame rate cannot be quoted as a storage rate.

**20 GB over 60 days** means about 333 MB/day. From screenshots alone, that is
about 3,333 images/day at 100 kB, one every 8.64 seconds across eight hours; at
250 kB it is about 1,333/day, one every 21.6 seconds. Text and other files would
reduce the screenshot contribution needed. These scenarios make 20 GB
possible, but the reported 708-event sample cannot establish its likelihood.

## Compute And Paid Usage

Capture, Apple Vision OCR, lexical retrieval, Core ML embeddings, and default
extractive briefs run on the Mac. This path requires no vendor inference API
calls or Hippocampus cloud storage. It still consumes local CPU/accelerator
time, RAM, electricity, and disk I/O. The embedder's CPU+Neural Engine policy
permits scheduling on those units; it does not prove every operation runs on
the Neural Engine. Current vector search scans stored vectors, so growing
corpora also require retrieval-latency measurement.

Build/model downloads, optional updater traffic, and local connectors are
distinct from paid inference. A local connector may itself access a remote
service. A connected AI client may send requested context or an explicitly
shared screenshot to its provider and incur that provider's usage charges.

Bring-your-own subscription means authenticating a supported client with your
account, within that client's entitlements and limits. It is not arbitrary API
allowance for Hippocampus. OpenAI documents subscription versus API-key access
in [Codex authentication](https://developers.openai.com/codex/auth/) and
[separate ChatGPT/API billing](https://help.openai.com/en/articles/9039756-managing-billing-settings-on-chatgpt-web-and-platform).
Anthropic likewise distinguishes
[Claude Code plan access and API billing](https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-or-max-plan).
These official pages were checked for this September 7 audit; prices and
entitlements can change. No dollar estimate or account-specific allowance is
inferred here.

The next useful evidence is a consented, representative growth sample with
component sizes, admitted-event/screenshot counts, active duration, and retention
settings recorded. Until then, a GB/month claim would be a scenario, not a
benchmark. Current measured qualification belongs in [STATUS](../STATUS.md).

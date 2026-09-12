# Installed-Brain Capture Proof

This is a bounded, read-only **source / recall / context** check, not a capture
launcher and not full screenshot proof. Run only after the release owner has
prepared and captured the foreground fixture through the normal installed app.
Keep the focused token near the beginning of the visible fixture because MCP
returns truncated OCR snippets.

```sh
python3 -B scripts/live-capture/verify_production_memory.py --since-us <UNIX_MICROSECONDS_BEFORE_CAPTURE>
```

The required positive timestamp is an exclusive lower bound. Do not use zero or
an old all-history timestamp. Use the instant immediately before the controlled
capture. The two fixed probes are `FOCUSED_EVIDENCE_ZEPHYR_9241` and
`BACKGROUND_SECRET_NEBULA_7713`; neither cwd nor command-line input becomes a
query or shell command.

## Safety

- Starts only `/Applications/Hippocampus.app/Contents/MacOS/mci-agent mcp-serve`,
  not Hippocampus, the capture helper, or an ingestion/import command.
- Uses the invoking non-root macOS account's home from the account database,
  `Library/Application Support/MCI/mci.sqlite`, and the installed app's normal
  file-Keychain service/account references. It does not extract a key. Existing
  production Keychain access must work; it does not modify permissions or retry
  with a development key.
- Uses the existing `LiveBrainReader::open_readonly` SQLCipher path. There are no
  writes, retention changes, custom allowlists, imports, configuration changes,
  key arguments, network requests, or new dependencies in this script.
- Replaces the subprocess environment with HOME, a system PATH, and public
  Keychain references. Inherited database overrides, development keys, dynamic
  library overrides, and network credentials are not passed through.
- Holds replies only in memory. Discards native stderr and reports fixed error
  codes. No raw response files, OCR, titles, URLs, image bytes, or native errors
  are printed. Output contains only check results and focused fixture event IDs
  and timestamps.
- Stops its own probe child on timeout/interruption/size overflow. The response
  cap is 8 MiB and the wall-clock limit is 90 seconds. It does not stop the
  installed application or another agent process.

## Checks And Limits

The newline-delimited JSON-RPC protocol follows `verify_memory.py`; its isolated
corpus assumptions and all-history/stats requests are deliberately not reused.
The probe requests `mci_events_since` (1,000 rows), two fixed-token `mci_recall`
queries (100 candidates each), and focused `mci_context` (4,096 tokens / 64
evidence). No fallback query broadens the focus.

Only evidence strictly newer than `--since-us` is evaluated. Recall and context
do **not** support a server-side since filter: they may retrieve older records
internally, but this script discards those rows before inspecting text. It skips
uncited or mixed-age context items and flags them as incomplete. The timeline
must respect the since boundary. A full timeline page is marked incomplete
instead of attempting timestamp pagination that might skip tied events.

A successful bounded check requires the **same event ID and timestamp** in the
fresh focused OCR timeline, focused recall evidence, and an actual context item
with a `screen_ocr` citation. A query echo, unrelated citation, upstream frame
count, or old fixture does not qualify. Degraded recall may supply observations;
the output labels it degraded and never promotes it to a verified claim.

The background token is rejected in any returned fresh evidence, including
fresh context items and background-query candidates. Absence is limited to
returned snippets/evidence, **not** all OCR, pixels, or all historical memory.
Reads are sequential, not a transaction snapshot. A concurrent capture may need
a later bounded rerun. Retrieval caps or snippet truncation can leave a real
capture unproven; the script does not broaden scope to make it pass.

`source_recall_context_verified: true` means those bounded checks passed.
`status` remains `incomplete` and exit code **2** even then: the current MCP/CLI
does not expose the screenshot reference or an authenticated screenshot read.
Those fields explicitly report `unsupported`; full screenshot proof must come
from the release owner's authenticated Recall UI/native diagnostic. This script
never treats OCR success, a blob filename, or an upstream capture count as that
proof. Exit code **1** means a detected background token or a probe/protocol
error. There is currently no exit-zero full-proof path.

## Isolated Tests

```sh
python3 -B -m unittest discover -s scripts/live-capture -p test_verify_production_memory.py -v
```

Tests use in-memory dictionaries only. They do not launch an agent, access a
brain, consult the Keychain, start capture, or import fixture data into a store.

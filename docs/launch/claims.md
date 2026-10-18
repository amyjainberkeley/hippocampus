# Public claims and their evidence

Every factual or numeric claim Hippocampus makes in public — in the repo
`README`, the launch FAQ, and the marketing site — maps here to something in
this repository that backs it: a test, an eval document, a measurement, or a
line of source. This is the FTC's "substantiate before you publish"
discipline, written down so it can be checked by a script rather than by
memory.

`scripts/launch/claims-check.sh` reads this file and fails if any registered
claim's evidence has gone missing or drifted, if the public copy contains a
measurement (a percentage, a size, joules, CPU-seconds) that is not
registered here, or if it contains one of the ruled-out claims below.

```sh
# Repo only (README + in-repo evidence) — this is the CI gate:
scripts/launch/claims-check.sh

# Full pre-publish gate, with the marketing-site checkout:
scripts/launch/claims-check.sh ../hippocampus-site
#   or: HIPPO_SITE_DIR=/path/to/hippocampus-site scripts/launch/claims-check.sh
```

Numbers that are measured live in one place each, so this file and the public
copy never carry a second, drifting copy. The footprint and reader numbers
come from the reader bake-off (`eval/ocr-bakeoff-2026-10-15.md`); the
reading-quality shares come from the transcript bench in
`tools/ocr/screens/`, whose scenes and recorded OCR output are committed, so
`tools/ocr/screens/bakeoff.py score` reproduces them without models.

## Ruled-out claims

The owner ruled these out (decisions, 2026-10-15): absolutes that cannot be
substantiated, and a headline that echoes a competitor's. The checker fails
if any appears in public copy. This mirrors the in-repo guard in
`scripts/test-public-tree.sh`, extended to the FAQ and the site.

- "nothing leaves your Mac" (say what leaves, and when)
- "never reads passwords"
- "remembers everything"
- "perfect OCR"
- "lightweight"
- "total recall"
- "your AI already knows …" (echoes a competitor's launch line; the agreed
  line is "Your AI tools start with what you're working on.")

## Registry

`Evidence` is `kind:path`, path relative to the repo root. `Verify` is a
literal the checker must find in that file (or `-` to only require the file or
directory to exist). `Enforce = Y` means the published value is a measurement
the checker will reject if it ever appears in public copy unregistered.

<!-- REGISTRY:BEGIN -->

| ID | Published value(s) | Pages | Evidence | Verify | Enforce |
| --- | --- | --- | --- | --- | --- |
| ocr-exact-lines | 96.7% | README | eval:eval/ocr-bakeoff-2026-10-15.md | 0.967 | Y |
| vision-exact-lines | 93.9% | README | eval:eval/ocr-bakeoff-2026-10-15.md | 0.939 | Y |
| read-cpu | 3.7 to 4.8 CPU-seconds | README | eval:eval/ocr-bakeoff-2026-10-15.md | 3.69 to 4.78 | Y |
| read-energy | 4 J | README | eval:eval/ocr-bakeoff-2026-10-15.md | 3.8 to 4.2 J | Y |
| read-memory | 1.3 to 1.7 GB | README | eval:eval/ocr-bakeoff-2026-10-15.md | 1.3 to 1.7 GB | Y |
| dmg-size | 180 MB | README | eval:eval/ocr-bakeoff-2026-10-15.md | 180.3 MB | Y |
| installed-size | 370 MiB | README | eval:eval/ocr-bakeoff-2026-10-15.md | 370.2 MiB | Y |
| reader-size | 243 MiB | README | eval:eval/ocr-bakeoff-2026-10-15.md | 243.1 MiB | Y |
| interface-mixed-now | 21% | site how-it-works, site index | measure:tools/ocr/screens | - | Y |
| interface-mixed-before | 94% | site index | measure:tools/ocr/screens | - | Y |
| cpu-vs-vision | 8 to 10 times Vision's CPU | README, how-it-works | eval:eval/ocr-bakeoff-2026-10-15.md | 8 to 10 times | N |
| retention-days | 90 days by default | README, FAQ, privacy, how-it-works | code:apps/agent/src/retention_worker.rs | Days(90) | N |
| focused-read | focused window read at most every 3 seconds | README, how-it-works | code:adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/FocusedReadPacing.swift | 3_000_000 | N |
| display-read | other windows at most every 30 seconds plugged in | README, how-it-works | code:adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/CapturePower.swift | case .pluggedIn: 30 | N |
| rest-factor | rests 3x plugged in, 8x on battery, 16x in Low Power | README, FAQ, how-it-works | code:adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Capture/CaptureReadBudget.swift | case 0, 1: 3 | N |
| recent-sessions | last four sessions | FAQ, how-it-works | code:apps/agent/src/understanding/query.rs | RECENT_WORK_LINES: usize = 4 | N |
| recent-window | from the past 12 hours | FAQ, how-it-works | code:apps/agent/src/understanding/query.rs | RECENT_WORK_WINDOW_US | N |
| about-you-facts | up to six things learned about you | README, FAQ, privacy, how-it-works | code:apps/agent/src/understanding/query.rs | ABOUT_YOU_LINES: usize = 6 | N |
| encrypted-store | encrypted store (SQLCipher) | README, privacy, how-it-works | file:NOTICE | SQLCipher | N |
| keychain-key | key in the login Keychain | privacy, how-it-works | code:adapters/macos/mci-keychain/src/lib.rs | - | N |
| reader-model | on-device reader PP-OCRv6 | README, how-it-works | file:NOTICE | PP-OCRv6 | N |
| embed-model | search by meaning with Arctic Embed S | how-it-works | file:NOTICE | Arctic Embed S | N |
| embed-dims | 384 dimensions | how-it-works | doc:docs/decisions/0009-pin-sqlite-vec-dimension-384.md | 384 | N |
| readonly-mcp | tools only read; none write or delete | README, FAQ, how-it-works | test:adapters/macos/mci-brain-ffi/tests/readonly_invariant.rs | - | N |
| no-upload | uploads nothing you saw; no telemetry | README, FAQ, privacy | doc:PRIVACY.md | no telemetry | N |
| no-ffmpeg | NOTICE: does not ship FFmpeg, x264 or x265 | NOTICE | code:tools/ocr/bundle.py | NEVER_SHIPPED | N |
| license | Apache 2.0, open source | README, FAQ, site, privacy | file:LICENSE | Apache License | N |
| min-os | macOS 14 or later, Apple silicon | README, site, how-it-works | file:apps/hippocampus/Resources/Info.plist | 14.0 | N |

<!-- REGISTRY:END -->

## Notes and open items

- **Reading-quality shares (21% now, was 94%, and the per-scene table on the
  site's "How it works").** These are produced by the transcript bench in
  `tools/ocr/screens/` from committed OCR output, not frozen as a number in a
  committed file, so the checker verifies the bench is present rather than
  grepping the figure. To let a stranger (or this checker) confirm the exact
  shares, consider committing the bench's scored output as a small results
  file, or have `bakeoff.py score` write one. Until then the site's reading
  figures are "reproducible", not "pinned". **Needs a person** to decide.
- **The site is not yet safe to publish.** As of this writing
  `public/index.html` still carries the ruled-out line "Your AI already
  knows …" in four places (the `<meta name="description">`, the
  `og:description`, the hero paragraph, and the "Your AI" section heading),
  and the home-page `<meta name="description">` still reads "on your Mac
  only" plus that line. `claims-check.sh` fails on this. The README and FAQ
  already use the agreed line. **Needs a person** (the site lives in a
  separate repo): replace those four with "Your AI tools start with what
  you're working on." and refresh the two meta descriptions.
- Sample-data figures in the screenshots and alt text (a "$18" seat price, an
  invoice number, a "41 ms" latency, a clock time) are not product claims and
  are labelled "Sample data" on the page. The checker only enforces
  measurement units (%, MB/MiB/GB, J, CPU-seconds), which those sample values
  do not use, so they are out of scope by construction.

# Screen benchmarks

Two benches share these scenes.

- **Transcript bench** (`bench.py`, no arguments): does a window's text read
  the way a person reads it? It scores the assembler that shipped
  (`shipped.py`) beside the reference (`layout.py`) on every scene.
- **Engine comparison** (`bench.py OUT --paddle … --engines …`): exact lines,
  words, character error and order over every line of the eight flat scenes,
  per OCR engine. This is the measurement in
  `docs/audits/2026-10-08-ocr-transcription.md`.

## Scenes

| File | Scenes |
|---|---|
| `scenes.py` | Eight flat screens (chat, editor, article, terminal, mail, table, settings, doc). |
| `windows.py` | Six realistic windows (editor, chat, mail, article, video, notes), a two-sided bubble chat (`messages`), and four decoys whose look invites a chrome rule but whose text is content (`issue_properties`, `order_summary`, `todo_beside_notes`, `fullscreen_doc`). |

Every string carries a role: content, navigation or chrome. All text is made
up. `boxes/<scene>.json` holds what the OCR worker read from each scene,
rendered at 2x and sent at 144 dpi as the capture helper sends a Retina
window: lines with boxes, and the pane separators. Scoring needs no Chrome
and no models.

## Running

```sh
python3 tools/ocr/screens/bench.py                 # old against new, every scene
python3 tools/ocr/screens/bench.py --text mail     # one scene's text, old and new
python3 tools/ocr/screens/render.py OUT            # screenshots and truth
python3 tools/ocr/screens/bench.py --show OUT/page.html --screens-dir OUT
python3 tools/ocr/screens/bench.py --read OUT --serve "python tools/ocr/worker.py --serve"
python3 tools/ocr/screens/fixtures.py              # parity fixtures for the helper
```

Use `tools/ocr/.venv/bin/python`. `--show` writes a page with each screenshot
beside the text kept for it. `--read` reads every screenshot again and
rewrites `boxes/`. `fixtures.py` writes the cases that pin the capture
helper's port to `layout.py` (see its docstring); `--check` reports stale
ones.

When the Rust reader is built (`reading-probe`, from `core/brain`), the bench
sends each stored string through it, header included, and scores the text the
app shows. Until then it scores the assembler's own text before the chrome
separator, and says so.

## Measures

Per scene, on the text before the chrome separator: content found (whole
words), reading order of what was found, chrome and navigation found by whole
word and as whole lines, and junk tokens (in no truth string, two characters
or fewer, or no letter or digit). On the editor, the code must read as
written: every line, in order, nothing between, the same leading spaces, no
line numbers.

Hard gates: content at least the shipped value minus 0.01 on every scene, at
least the shipped value on each decoy, and the editor's code. Targets: chrome
by word at most 0.25 and by line at most 0.10, junk at most 2 per window.

## Result

Means over the windows (the six, and the bubble chat), shipped assembler
against `layout.py` with the window's geometry, assembler text only:

| | content | order | chrome, word | chrome, line | navigation, word | junk |
|---|---|---|---|---|---|---|
| shipped | 0.88 | 0.90 | 0.94 | 0.23 | 0.95 | 13.0 |
| layout.py | 0.94 | 1.00 | 0.17 | 0.08 | 0.22 | 0.4 |

No decoy loses content (mean 0.97 shipped, 0.98 now), and no flat scene
loses any either. The editor's code went from 18 problems (line numbers in
every line, sidebar and chat interleaved) to none.

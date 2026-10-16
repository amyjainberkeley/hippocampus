# Screen benchmarks

Three benches share these scenes.

- **Transcript bench** (`bench.py`, no arguments): does a window's text read
  the way a person reads it? It scores the assembler that shipped
  (`shipped.py`) beside the reference (`layout.py`) on every scene.
- **Engine comparison** (`bench.py OUT --paddle … --engines …`): exact lines,
  words, character error and order over every line of the eight flat scenes,
  per OCR engine.
- **Reader bake-off** (`bakeoff.py read OUT …`, then `bakeoff.py score OUT`):
  every scene read by the capture helper's own engines (Apple Vision as
  `VisionOCRRunner` reads, PP-OCR through `PaddleOCRRunner` and the frozen
  worker) with the cost of each read, then the launch gate: exact lines and
  words on the flat screens and the windows, and the transcript bench's hard
  gates on each engine's reading. Its docstring says how each measure is
  taken. `eval/ocr-bakeoff-2026-10-15.md` has the results.

## Scenes

| File | Scenes |
|---|---|
| `scenes.py` | Eight flat screens (chat, editor, article, terminal, mail, table, settings, doc). |
| `windows.py` | Six realistic windows (editor, chat, mail, article, video, notes), a two-sided bubble chat (`messages`), and six decoys whose look invites a chrome rule but whose text is content (`issue_properties`, `order_summary`, `todo_beside_notes`, `fullscreen_doc`, `receipt`, `invitation`). |

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
rewrites `boxes/`, and `--only` names the scenes to read. `fixtures.py` writes
the cases that pin the capture helper's port to `layout.py`, as its docstring
describes. `fixtures.py --check` reports stale ones.

When the Rust reader is built (`reading-probe`, from `core/brain`), the bench
sends each stored string through it, header included, and scores the text the
app shows. Until then it scores the assembler's own text before the chrome
separator, and says so. `--no-reader` scores the assembler's text even when
the reader is built. A line the reader cannot read stops the bench with the
scene's name.

## Measures

Per scene, on the text before the chrome separator: content found (whole
words), reading order of what was found, chrome and navigation found by whole
word and as whole lines, and junk tokens (in no content string, and two
characters or fewer or with no letter or digit, so a count left in the main
text is junk). On the editor, the code must read as written: every line, in
order, nothing between, the same leading spaces, no line numbers.

Hard gates: content at least the shipped value minus 0.01 on every scene, at
least the shipped value on each decoy, and the editor's code. Targets, as means
over the windows and decoys together: chrome by word at most 0.25 and by line
at most 0.10, junk at most 2 per window.

## Result

Means over the seven windows (the six, and the bubble chat), shipped
assembler against `layout.py` with the window's geometry, assembler text
only:

| | content | order | chrome, word | chrome, line | navigation, word | junk |
|---|---|---|---|---|---|---|
| shipped | 0.88 | 0.90 | 0.94 | 0.23 | 0.95 | 19.9 |
| layout.py | 0.94 | 1.00 | 0.21 | 0.12 | 0.23 | 1.1 |

Over the windows and the six decoys, chrome is 0.12 by word and 0.07 by line,
with 0.6 junk tokens per window. No decoy loses content, and no flat scene
does either. The editor's code went from 18 problems to none. Its line
numbers were in every line, and the sidebar and chat were interleaved.

The note's date line stays in its main text. A date is chrome only between
messages, in a chat app.

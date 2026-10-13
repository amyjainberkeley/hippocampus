"""The transcript bench: does a window's text read the way a person reads it?

    python3 tools/ocr/screens/bench.py                  old against new, every scene
    python3 tools/ocr/screens/bench.py --text mail      one scene's text, old and new
    python3 tools/ocr/screens/bench.py --show PAGE.html --screens-dir OUT
                                                        screenshot beside text, every scene
    python3 tools/ocr/screens/render.py OUT
    python3 tools/ocr/screens/bench.py --read OUT --serve "python tools/ocr/worker.py --serve"
                                                        read every screen again into boxes/

Scenes are the eight flat screens in scenes.py and the mock windows in
windows.py: six realistic windows, a bubble chat and four decoys whose look
invites a chrome rule but whose text is content. The OCR worker's lines and
pane separators for each are committed in boxes/<scene>.json, read at the
production density (a 2x frame that declares 144 dpi), so scoring needs no
Chrome and no models.

"old" is the assembler that shipped (shipped.py). "new" is layout.py given the
window's geometry, so it sorts content from chrome. Each is scored on its main
text: what comes before the chrome separator. When the Rust reader is built
(`reading-probe`, from core/brain), both stored strings go through it, header
included, and its `main` is scored, as the app shows it. Until then the
assembler's own output is scored, and the table says so.

Measures, per scene, on the main text:
  content   share of content strings present, as whole words
  order     of the content strings found, the share that come in reading order
  chrome_w  share of chrome strings present as whole words
  chrome_l  share of chrome strings that are a whole line of the text
  nav_w     the same two for navigation strings
  nav_l
  junk      tokens in no truth string that are at most two characters long or
            have no letter or digit: icon misreads and stray symbols (a list
            bullet that starts a line is formatting and does not count)
Strings shorter than three characters, and chrome or navigation strings that
also appear in the content, cannot be told apart by text and are not scored as
leaks. On an editor, the code is checked line by line: every line found, in
order, nothing between them, the same leading spaces and no line numbers.

Hard gates (RULINGS T4): content at least old minus 0.01 on every scene, at
least old on each decoy, and the editor's code check. Targets: mean chrome_w
at most 0.25 and chrome_l at most 0.10, junk at most 2 per window on average.
The exit status is 1 when a hard gate fails.
"""
import argparse
import collections
import html
import json
import re
import struct
import subprocess
import sys
import time
from difflib import SequenceMatcher
from pathlib import Path

SCREENS = Path(__file__).resolve().parent
REPO = SCREENS.parents[2]
BOXES = SCREENS / 'boxes'
sys.path.insert(0, str(SCREENS))
import layout  # noqa: E402
import scenes  # noqa: E402
import shipped  # noqa: E402
import windows  # noqa: E402

MIN_CONFIDENCE = 0.5  # OCRMemoryText.minimumConfidence
RETINA_PIXELS_PER_METER = 5669  # 144 dpi, what the helper declares for a 2x capture
SEPARATOR = '\n\n\x1e\n'  # content, then this, then chrome (RULINGS T1)
TARGETS = {'chrome_w': 0.25, 'chrome_l': 0.10, 'junk': 2.0}
STAMP = '2026-10-12T14:31:00.000Z'


# ----------------------------------------------------------------- the scenes

def all_scenes():
    """Every scene as {name, kind, items, app, title, size, code}."""
    out = []
    for name, scene in scenes.SCENES.items():
        out.append({'name': name, 'kind': 'scene', 'items': scenes.truth_items(scene), 'app': None,
                     'title': None, 'size': (1440, 900), 'code': None})
    for name, window in windows.WINDOWS.items():
        out.append({'name': name, 'kind': 'decoy' if window.get('decoy') else 'window',
                    'items': windows.truth_items(window['page']), 'app': window['app'],
                    'title': window['title'], 'size': window['size'], 'code': window.get('code')})
    return out


def load_boxes(name):
    return json.loads((BOXES / f'{name}.json').read_text(encoding='utf-8'))


def geometry(scene, boxes):
    """The window geometry the helper passes for a focused window: the whole
    frame, its density, title and app."""
    return {'rect': [0.0, 0.0, 1.0, 1.0], 'pixels_per_point': boxes['width'] / scene['size'][0],
            'title': scene['title'], 'bundle_id': scene['app']}


# ----------------------------------------------------------------- the reader

def find_reader():
    for profile in ('release', 'debug'):
        for name in ('reading-probe', 'reading_probe'):
            path = REPO / 'target' / profile / name
            if path.is_file():
                return path
    return None


class Reader:
    """The Rust reader, one JSON line in and one out (RULINGS X7)."""

    def __init__(self, path):
        self.path = path
        self.proc = subprocess.Popen([str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, env={'PATH': '/usr/bin:/bin'})

    def read(self, stored, app, title):
        request = {'stored': stored, 'source': 'screen_ocr', 'app': app or '', 'title': title or ''}
        self.proc.stdin.write((json.dumps(request, ensure_ascii=False) + '\n').encode('utf-8'))
        self.proc.stdin.flush()
        reply = json.loads(self.proc.stdout.readline())
        return reply['main'], reply['rest']

    def close(self):
        self.proc.stdin.close()
        self.proc.stdout.close()
        self.proc.wait(timeout=10)


def header(scene):
    """The header the agent puts in front of stored text (brain_ingest.rs)."""
    return f'[app={scene["app"] or "?"} | title={scene["title"] or "?"} | url=? | ts={STAMP}]\n'


def split_stored(stored):
    if SEPARATOR in stored:
        main, rest = stored.split(SEPARATOR, 1)
        return main, rest
    return stored, ''


def transcripts(scene, boxes, reader=None):
    """{'old'|'new': {'stored', 'main', 'rest'}} for one scene."""
    old = shipped.assemble(boxes['lines'], min_confidence=MIN_CONFIDENCE,
                           width=boxes['width'], height=boxes['height'])
    new = layout.assemble(boxes['lines'], min_confidence=MIN_CONFIDENCE, width=boxes['width'],
                          height=boxes['height'], separators=boxes.get('separators', []),
                          window=geometry(scene, boxes))
    out = {}
    for how, stored in (('old', old), ('new', new)):
        if reader is not None:
            main, rest = reader.read(header(scene) + stored, scene['app'], scene['title'])
        else:
            main, rest = split_stored(stored)
        out[how] = {'stored': stored, 'main': main, 'rest': rest}
    return out


# ----------------------------------------------------------------- measures

def norm(text):
    return re.sub(r'\s+', ' ', text).strip()


def contains(haystack, needle):
    """`needle` appears in `haystack` as whole words."""
    return re.search(r'(?<![A-Za-z0-9])' + re.escape(needle) + r'(?![A-Za-z0-9])', haystack) is not None


def leak_strings(items, role):
    """Strings of `role` that text can judge: three characters or more, and
    not also part of the content."""
    content = [norm(i['text']) for i in items if i['role'] == windows.CONTENT]
    out = []
    for item in items:
        text = norm(item['text'])
        if item['role'] != role or len(text) < 3 or text in out:
            continue
        if any(contains(c, text) for c in content):
            continue
        out.append(text)
    return out


def longest_increasing(seq):
    import bisect
    tails = []
    for value in seq:
        i = bisect.bisect_left(tails, value)
        if i == len(tails):
            tails.append(value)
        else:
            tails[i] = value
    return len(tails)


BULLETS = frozenset('\u2022\u00b7\u2023\u25e6\u25aa\u2013-*')


def junk_tokens(main, items):
    """Tokens in no truth string that are short or have no letter or digit.
    A list bullet at the start of a line is formatting, not junk."""
    truth = {token for item in items for token in item['text'].split()}
    out = []
    for line in main.split('\n'):
        tokens = line.split()
        for i, token in enumerate(tokens):
            if i == 0 and token in BULLETS and len(tokens) > 1:
                continue
            if token not in truth and (len(token) <= 2 or not any(ch.isalnum() for ch in token)):
                out.append(token)
    return out


def score(scene, main):
    items = scene['items']
    flat = norm(main)
    lines = {norm(line) for line in main.split('\n') if norm(line)}
    content = [norm(i['text']) for i in items if i['role'] == windows.CONTENT]
    found, positions, at = [], [], 0
    for text in content:
        if not contains(flat, text):
            continue
        found.append(text)
        # The occurrence after the last one found, so a repeated name (a
        # sender who writes twice) is not counted as out of order.
        match = (re.compile(r'(?<![A-Za-z0-9])' + re.escape(text) + r'(?![A-Za-z0-9])').search(flat, at)
                 or re.search(r'(?<![A-Za-z0-9])' + re.escape(text) + r'(?![A-Za-z0-9])', flat))
        positions.append(match.start())
        at = match.start()
    result = {
        'content': len(found) / max(1, len(content)),
        'order': longest_increasing(positions) / len(positions) if positions else 0.0,
        'junk': len(junk_tokens(main, items)),
    }
    for role, key in ((windows.CHROME, 'chrome'), (windows.NAVIGATION, 'nav')):
        strings = leak_strings(items, role)
        result[key + '_w'] = sum(contains(flat, s) for s in strings) / len(strings) if strings else 0.0
        result[key + '_l'] = sum(s in lines for s in strings) / len(strings) if strings else 0.0
    return result


GUTTER_NUMBER = re.compile(r'^\s*[0-9]+(\s|$)')


def code_check(main, code):
    """Whether the code reads as written: every line found in order with no
    line between them, the same leading spaces, and no line numbers. Returns
    (ok, problems)."""
    truth = [line for line in code if line.strip()]
    lines = main.split('\n')
    matched, at = [], 0
    for line in truth:
        for i in range(at, len(lines)):
            if SequenceMatcher(None, lines[i].strip(), line.strip(), autojunk=False).ratio() >= 0.8:
                matched.append((line, i))
                at = i + 1
                break
        else:
            matched.append((line, None))
    problems = [f'missing: {line.strip()}' for line, i in matched if i is None]
    found = [(line, i) for line, i in matched if i is not None]
    if found:
        span = [l for l in lines[found[0][1]:found[-1][1] + 1] if l.strip()]
        if len(span) != len(found):
            problems.append(f'{len(span)} lines where the code has {len(found)}')
        for line, i in found:
            got = len(lines[i]) - len(lines[i].lstrip(' '))
            want = len(line) - len(line.lstrip(' '))
            if got != want:
                problems.append(f'indent {got} for {want}: {line.strip()}')
        for text in span:
            if GUTTER_NUMBER.match(text) and not any(GUTTER_NUMBER.match(t) for t in truth):
                problems.append(f'line number: {text.strip()}')
    return not problems, problems


def bench(reader=None):
    """Score every scene. Returns (rows, failures)."""
    rows, failures = [], []
    for scene in all_scenes():
        boxes = load_boxes(scene['name'])
        texts = transcripts(scene, boxes, reader)
        row = {'scene': scene, 'texts': texts}
        for how in ('old', 'new'):
            row[how] = score(scene, texts[how]['main'])
            if scene['code']:
                row[how]['code_ok'], row[how]['code_problems'] = code_check(texts[how]['main'], scene['code'])
        old, new = row['old'], row['new']
        name = scene['name']
        if new['content'] < old['content'] - 0.01 - 1e-9:
            failures.append(f'{name}: content {new["content"]:.3f} below {old["content"]:.3f} - 0.01')
        if scene['kind'] == 'decoy' and new['content'] < old['content'] - 1e-9:
            failures.append(f'{name}: a decoy lost content ({new["content"]:.3f} < {old["content"]:.3f})')
        if scene['code'] and not new['code_ok']:
            failures.append(f'{name}: code ' + '; '.join(new['code_problems']))
        stored = texts['new']['stored']
        if stored.count(SEPARATOR) != 1 or '\x1e' in texts['new']['main'] + texts['new']['rest']:
            failures.append(f'{name}: the stored text does not carry exactly one separator')
        rows.append(row)
    return rows, failures


KEYS = ['content', 'order', 'chrome_w', 'chrome_l', 'nav_w', 'nav_l', 'junk']


def report(rows, failures, reader):
    print('reader:', reader.path if reader else
          'none (reading-probe is not built; scoring the assembler\'s own main text)')
    print(f'{"scene":<18}{"":<4}' + ''.join(f'{k:>9}' for k in KEYS) + '   code')
    groups = collections.defaultdict(list)
    for row in rows:
        scene = row['scene']
        groups[scene['kind']].append(row)
        for how in ('old', 'new'):
            values = row[how]
            cells = ''.join(f'{values[k]:>9d}' if k == 'junk' else f'{values[k]:>9.2f}' for k in KEYS)
            code = ''
            if scene['code']:
                code = '   ok' if values['code_ok'] else f'   {len(values["code_problems"])} problems'
            print(f'{scene["name"] if how == "old" else "":<18}{how:<4}{cells}{code}')
    for kind, label in (('window', 'windows'), ('decoy', 'decoys'), ('scene', 'flat scenes')):
        members = groups[kind]
        if not members:
            continue
        for how in ('old', 'new'):
            means = {k: sum(r[how][k] for r in members) / len(members) for k in KEYS}
            cells = ''.join(f'{means[k]:>9.2f}' for k in KEYS)
            print(f'{"MEAN " + label if how == "old" else "":<18}{how:<4}{cells}')
    every = [row for row in rows if row['scene']['kind'] in ('window', 'decoy')]
    print('\ntargets over the windows and decoys:')
    for key, limit in TARGETS.items():
        value = sum(row['new'][key] for row in every) / len(every)
        print(f'  {key:<9} {value:5.2f}  (at most {limit:.2f})  {"met" if value <= limit + 1e-9 else "NOT MET"}')
    if failures:
        print('\nhard gates FAILED:')
        for failure in failures:
            print('  ' + failure)
    else:
        print('\nhard gates: met on every scene')


# ----------------------------------------------------------------- reading screens

def bmp_bytes(png):
    """A BGRA bitmap of `png` that declares 144 dpi, as the helper's 2x capture does."""
    from PIL import Image
    image = Image.open(png).convert('RGBA')
    w, h = image.size
    r, g, b, a = image.split()
    pixels = Image.merge('RGBA', (b, g, r, a)).tobytes()
    header_bytes = struct.pack('<2sIHHI', b'BM', 54 + len(pixels), 0, 0, 54)
    dib = struct.pack('<IiiHHIIiiII', 40, w, -h, 1, 32, 0, len(pixels),
                      RETINA_PIXELS_PER_METER, RETINA_PIXELS_PER_METER, 0, 0)
    return header_bytes + dib + pixels


class ServeWorker:
    """One persistent `worker.py --serve` for the whole run."""

    def __init__(self, command):
        self.proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, env={'PATH': '/usr/bin:/bin'})
        start = time.monotonic()
        ready = json.loads(self.proc.stdout.readline())
        assert ready == {'version': 1, 'ready': True}, ready
        self.startup = time.monotonic() - start

    def run(self, png):
        start = time.monotonic()
        self.proc.stdin.write(bmp_bytes(png))
        self.proc.stdin.flush()
        reply = json.loads(self.proc.stdout.readline())
        return reply, time.monotonic() - start


def rounded(values, digits=6):
    """A normalized box rounded for the committed file, still inside the frame."""
    x, y, w, h = (round(v, digits) for v in values)
    return [x, y, min(w, round(1 - x, digits)), min(h, round(1 - y, digits))]


def read_screens(out, command, only=None):
    """OCR every rendered screen and write boxes/<name>.json."""
    from PIL import Image
    worker = ServeWorker(command)
    print(f'worker ready in {worker.startup:.1f}s', file=sys.stderr)
    BOXES.mkdir(exist_ok=True)
    for scene in all_scenes():
        name = scene['name']
        if only and name not in only:
            continue
        png = out / f'{name}.png'
        reply, seconds = worker.run(png)
        if reply.get('failed'):
            sys.exit(f'the worker refused {name}')
        width, height = Image.open(png).size
        data = {'width': width, 'height': height,
                'lines': [{'text': l['text'], 'confidence': round(l['confidence'], 4), 'box': rounded(l['box'])}
                          for l in reply['lines']],
                'separators': [rounded(s) for s in reply.get('separators', [])]}
        (BOXES / f'{name}.json').write_text(json.dumps(data, ensure_ascii=False, indent=0) + '\n', encoding='utf-8')
        print(f'{name:<18} {len(data["lines"]):4d} lines {len(data["separators"]):3d} separators {seconds:5.2f}s',
              file=sys.stderr)


# ----------------------------------------------------------------- showing

def show_text(rows, name):
    for row in rows:
        if row['scene']['name'] != name:
            continue
        for how in ('old', 'new'):
            text = row['texts'][how]
            print(f'=============== {name} {how}: main')
            print(text['main'])
            if text['rest']:
                print(f'--------------- {name} {how}: also in this window')
                print(text['rest'])
        return
    sys.exit(f'no scene named {name}')


PAGE_STYLE = '''
:root { --ink: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; --paper: #ffffff; --wash: #f5f5f7; }
@media (prefers-color-scheme: dark) { :root { --ink: #f5f5f7; --muted: #a1a1a6; --line: #3a3a3c; --paper: #1c1c1e; --wash: #2c2c2e; } }
body { margin: 0; padding: 24px 16px; background: var(--paper); color: var(--ink);
       font: 15px/1.5 -apple-system, "Helvetica Neue", sans-serif; }
main { max-width: 1400px; margin: 0 auto; }
section { display: grid; grid-template-columns: minmax(0, 3fr) minmax(0, 2fr); gap: 20px;
          padding: 20px 0; border-top: 1px solid var(--line); }
@media (max-width: 800px) { section { grid-template-columns: minmax(0, 1fr); } }
img { width: 100%; height: auto; border: 1px solid var(--line); border-radius: 8px; }
pre { margin: 0; white-space: pre; overflow-x: auto; font: 13px/1.45 Menlo, monospace;
      background: var(--wash); border-radius: 8px; padding: 12px; }
h2 { margin: 0 0 8px; font-size: 17px; } summary { color: var(--muted); cursor: pointer; margin: 10px 0 6px; }
'''


def show_page(rows, page, screens):
    parts = ['<!doctype html><html lang="en"><head><meta charset="utf-8">',
             '<meta name="viewport" content="width=device-width, initial-scale=1">',
             f'<title>Screen and text</title><style>{PAGE_STYLE}</style></head><body><main>',
             '<h1>Screen and text</h1><p>Each window as the screen showed it, beside the text Hippocampus '
             'keeps for it. Made-up windows; no real person or message.</p>']
    first = {'window': 0, 'decoy': 1, 'scene': 2}
    for row in sorted(rows, key=lambda row: first[row['scene']['kind']]):
        scene = row['scene']
        name = scene['name']
        new, old = row['texts']['new'], row['texts']['old']
        image = Path(screens) / f'{name}.png'
        try:
            source = image.resolve().relative_to(Path(page).resolve().parent).as_posix()
        except ValueError:
            source = image.resolve().as_uri()
        rest_lines = [line for line in new['rest'].split('\n') if line.strip()]
        parts.append(f'<section><div><img src="{html.escape(source)}" alt="{html.escape(name)}"></div><div>'
                     f'<h2>{html.escape(name)}</h2><pre>{html.escape(new["main"])}</pre>')
        if rest_lines:
            count = f'{len(rest_lines)} line' + ('' if len(rest_lines) == 1 else 's')
            parts.append(f'<details><summary>Also in this window ({count})</summary>'
                         f'<pre>{html.escape(new["rest"])}</pre></details>')
        parts.append(f'<details><summary>Before</summary><pre>{html.escape(old["main"])}</pre></details>'
                     '</div></section>')
    parts.append('</main></body></html>')
    Path(page).write_text(''.join(parts), encoding='utf-8')


# ----------------------------------------------------------------- engines (Oct 8 audit)

def engines(args):
    """The OCR engine comparison of docs/audits/2026-10-08-ocr-transcription.md:
    exact lines, words, character error and order over every truth line of the
    flat scenes, for each engine. Run render.py into the folder first."""
    def run_paddle(worker, png):
        start = time.monotonic()
        proc = subprocess.run([worker], input=bmp_bytes(png), capture_output=True, timeout=120)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.decode()[-400:])
        return json.loads(proc.stdout)['lines'], time.monotonic() - start

    def run_vision(probe, mode, png):
        start = time.monotonic()
        proc = subprocess.run([probe, mode, str(png)], capture_output=True, timeout=120)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.decode()[-400:])
        return json.loads(proc.stdout)['lines'], time.monotonic() - start

    def edit_distance(a, b):
        if len(a) < len(b):
            a, b = b, a
        previous = list(range(len(b) + 1))
        for i, ca in enumerate(a, 1):
            current = [i]
            for j, cb in enumerate(b, 1):
                current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
            previous = current
        return previous[-1]

    def legacy_score(truth_blocks, output_lines):
        truth = [norm(l) for block in truth_blocks for l in block]
        out = [norm(l) for l in output_lines if norm(l)]
        out_set = collections.Counter(out)
        exact = sum(1 for line in truth if out_set[line] > 0) / len(truth)
        truth_words = collections.Counter(w for line in truth for w in line.split())
        out_words = collections.Counter(w for line in out for w in line.split())
        words = sum((truth_words & out_words).values()) / sum(truth_words.values())
        truth_text, out_text = '\n'.join(truth), '\n'.join(out)
        cer = edit_distance(truth_text, out_text) / len(truth_text)
        positions = []
        for line in truth:
            best, where = 0.0, None
            for i, candidate in enumerate(out):
                ratio = SequenceMatcher(None, line, candidate, autojunk=False).ratio()
                if ratio > best:
                    best, where = ratio, i
            if best >= 0.8:
                positions.append(where)
        order = longest_increasing(positions) / len(positions) if positions else 0.0
        return {'exact': exact, 'words': words, 'cer': cer, 'order': order}

    names = sorted(scenes.SCENES)
    cache, serve = {}, None
    totals = collections.defaultdict(lambda: collections.defaultdict(float))
    print(f'{"scene":<16}{"engine":<15}{"exact":>7}{"words":>7}{"cer":>7}{"order":>7}{"sec":>7}')
    for scene in names:
        png = args.screens / f'{scene}.png'
        blocks = scenes.truth_blocks(scenes.SCENES[scene])
        for engine in args.engines.split(','):
            base = engine.split('+')[0]
            stored = args.screens / 'raw' / f'{scene}.{base}.json'
            if (scene, base) not in cache and stored.exists() and not args.fresh:
                cache[scene, base] = tuple(json.loads(stored.read_text()))
            if (scene, base) not in cache:
                if base == 'paddle':
                    cache[scene, base] = run_paddle(args.paddle, png)
                elif base == 'vision':
                    cache[scene, base] = run_vision(args.vision, 'text', png)
                elif base == 'vision-doc':
                    cache[scene, base] = run_vision(args.vision, 'document', png)
                elif base == 'paddle-serve':
                    if serve is None:
                        serve = ServeWorker(args.serve.split())
                    reply, seconds = serve.run(png)
                    cache[scene, base] = (reply.get('lines', []), seconds)
                stored.parent.mkdir(exist_ok=True)
                stored.write_text(json.dumps(cache[scene, base]))
            raw, seconds = cache[scene, base]
            if engine.endswith('+layout'):
                lines = shipped.assemble(raw, min_confidence=MIN_CONFIDENCE).splitlines()
            else:
                lines = [l['text'] for l in raw if l['confidence'] >= MIN_CONFIDENCE and l['text'].strip()]
            result = legacy_score(blocks, lines)
            for key, value in result.items():
                totals[engine][key] += value
            totals[engine]['sec'] += seconds
            print(f'{scene:<16}{engine:<15}{result["exact"]:>7.3f}{result["words"]:>7.3f}'
                  f'{result["cer"]:>7.3f}{result["order"]:>7.3f}{seconds:>7.2f}')
    print('\nmean over', len(names), 'scenes')
    for engine in args.engines.split(','):
        t = totals[engine]
        n = len(names)
        print(f'{"ALL":<16}{engine:<15}{t["exact"]/n:>7.3f}{t["words"]/n:>7.3f}'
              f'{t["cer"]/n:>7.3f}{t["order"]/n:>7.3f}{t["sec"]/n:>7.2f}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('screens', type=Path, nargs='?',
                        help='rendered screens: compare OCR engines on the flat scenes (the Oct 8 audit)')
    parser.add_argument('--text', help='print one scene\'s text, old and new')
    parser.add_argument('--show', type=Path, help='write the side-by-side page here (needs --screens-dir)')
    parser.add_argument('--screens-dir', type=Path, help='where render.py wrote the screenshots')
    parser.add_argument('--read', type=Path, help='OCR the screenshots in this folder into boxes/')
    parser.add_argument('--only', help='with --read: comma-separated scene names')
    parser.add_argument('--reader', type=Path, help='the reading-probe binary (found in target/ by default)')
    parser.add_argument('--no-reader', action='store_true', help='score the assembler\'s own output')
    parser.add_argument('--paddle', type=Path)
    parser.add_argument('--vision', type=Path)
    parser.add_argument('--engines', default='paddle,paddle+layout,vision,vision+layout,vision-doc')
    parser.add_argument('--fresh', action='store_true', help='ignore cached engine output')
    parser.add_argument('--serve', help='command for a persistent worker, e.g. "python worker.py --serve"')
    args = parser.parse_args()

    if args.screens is not None:
        return engines(args)
    if args.read is not None:
        if not args.serve:
            sys.exit('--read needs --serve "python tools/ocr/worker.py --serve"')
        return read_screens(args.read, args.serve.split(), set(args.only.split(',')) if args.only else None)
    reader_path = None if args.no_reader else (args.reader or find_reader())
    reader = Reader(reader_path) if reader_path else None
    try:
        rows, failures = bench(reader)
    finally:
        if reader is not None:
            reader.close()
    if args.text:
        return show_text(rows, args.text)
    if args.show:
        if not args.screens_dir:
            sys.exit('--show needs --screens-dir, the folder render.py wrote')
        show_page(rows, args.show, args.screens_dir)
        print('wrote', args.show)
        return 0
    report(rows, failures, reader)
    return 1 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())

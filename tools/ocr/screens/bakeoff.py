"""The reader bake-off: which OCR engine should read the screen?

    python3 tools/ocr/screens/render.py SCREENS
    python3 tools/ocr/screens/bakeoff.py read SCREENS OUT --probe PROBE [--worker WORKER] [--runs 3]
    python3 tools/ocr/screens/bakeoff.py score OUT [--json SUMMARY.json]

`read` sends every rendered screen through the capture helper's own engines
with OCRQualityProbe, built by

    scripts/swift-package.sh build -c release --package-path adapters/macos/MCICaptureHelper \
        --product OCRQualityProbe

Apple Vision reads as VisionOCRRunner does (`vision`), and with --panes also
one pane at a time (`vision_panes`). With --worker, PP-OCR reads as
PaddleOCRRunner drives the frozen worker (tools/ocr/dist/hippocampus-ocr/
hippocampus-ocr), kept warm. Each read is the first read of a focused Retina
window: the whole frame, 2 pixels per point, and the engine's own deadline
unless --deadline-ms gives another. Before timing, each run reads one
inverted screen that is not in the set, so loading models and the worker's
remembered lines stay out of the per-read cost; that read is reported as the
cold read. Run N of an engine writes OUT/<engine>-<N>/<scene>.json in the
boxes/ format, and OUT/<engine>-<N>/cost.json.

`score` holds every reading to the launch plan's gate (item 4): on the eight
flat screens and on the seven windows, exact lines at least 0.95 and words at
least 0.98, and every hard gate of the transcript bench.

  flat screens  exact, words, character error and order are the Oct 8
                audit's measures (bench.legacy_score) on the text the app
                stores: layout.py's reading of the lines with the window's
                geometry, chrome after the separator, the separator line left
                out. `shipped` is the same on the old assembler's text, the
                pipeline behind PP-OCR's 0.967 and 0.989 that day.
  windows       a window's truth is its tagged strings, not lines: a string
                is exact when it appears whole, as whole words, in the
                stored text with its line breaks read as spaces (a paragraph
                wraps), as the transcript bench finds content. Strings under
                three characters are left out, as the bench leaves them out.
  words         whitespace tokens found, order ignored (the audit's measure).
  search        tokens as SQLite FTS5's unicode61 tokenizer makes them
                (letters and digits, case and accents folded): what search
                sees.
  hard gates    bench.py's own, on the engine's reading (content at least the
                old assembler's minus 0.01 on every scene, at least the old
                on each decoy, the editor's code, one separator), and the
                same content gates against PP-OCR's reading when there is
                one: at least PP-OCR's minus 0.01 on every scene, at least
                PP-OCR's on each decoy.

All screens are synthetic: render.py draws them from scenes.py and
windows.py. Development only.
"""
import argparse
import collections
import json
import os
import statistics
import subprocess
import sys
import unicodedata
from pathlib import Path

SCREENS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCREENS_DIR))
import bench  # noqa: E402
import layout  # noqa: E402
import scenes  # noqa: E402
import shipped  # noqa: E402

GATE = {'exact': 0.95, 'words': 0.98}
WARMUP = '_warmup.png'


# ----------------------------------------------------------------- reading

def warmup_image(screens):
    """An inverted copy of the first screen: text in the same style, none of
    the same pixels."""
    from PIL import Image, ImageOps
    first = screens / f'{bench.all_scenes()[0]["name"]}.png'
    path = screens / WARMUP
    ImageOps.invert(Image.open(first).convert('RGB')).save(path)
    return path


def read(args):
    names = [scene['name'] for scene in bench.all_scenes()]
    missing = [name for name in names if not (args.screens / f'{name}.png').is_file()]
    if missing:
        sys.exit(f'render.py has not drawn: {", ".join(missing)}')
    warm = warmup_image(args.screens)
    try:
        return read_all(args, names, warm)
    finally:
        warm.unlink(missing_ok=True)


def read_all(args, names, warm):
    engines = [('vision', [])]
    if args.panes:
        engines.append(('vision_panes', ['--plan', 'panes']))
    if args.worker:
        engines.append(('paddle', ['--worker', str(args.worker)]))
    for engine, extra in engines:
        if args.only and engine not in args.only.split(','):
            continue
        for run in range(1, args.runs + 1):
            out = args.out / f'{engine}-{run}'
            out.mkdir(parents=True, exist_ok=True)
            command = [str(args.probe), '--serve', *extra]
            if args.deadline_ms:
                command += ['--deadline-ms', str(args.deadline_ms)]
            paths = [warm] + [args.screens / f'{name}.png' for name in names]
            env = {'PATH': '/usr/bin:/bin'}
            env.update({key: os.environ[key] for key in ('HOME', 'TMPDIR') if key in os.environ})
            proc = subprocess.run(command, input=''.join(f'{p}\n' for p in paths), capture_output=True,
                                  text=True, env=env, timeout=3600)
            if proc.returncode != 0:
                sys.exit(f'{engine} run {run}: the probe failed: {proc.stderr[-400:]}')
            replies = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
            if len(replies) != len(paths):
                sys.exit(f'{engine} run {run}: {len(replies)} replies for {len(paths)} screens')
            cost = {'cold': summary_cost(replies[0]), 'reads': {}}
            for name, reply in zip(names, replies[1:]):
                boxes = {'width': reply['width'], 'height': reply['height'],
                         'lines': [{'text': l['text'], 'confidence': round(l['confidence'], 4),
                                    'box': bench.rounded(l['box'])} for l in reply['lines']],
                         'separators': [bench.rounded(s) for s in reply['separators']]}
                (out / f'{name}.json').write_text(json.dumps(boxes, ensure_ascii=False, indent=0) + '\n',
                                                  encoding='utf-8')
                cost['reads'][name] = summary_cost(reply)
            (out / 'cost.json').write_text(json.dumps(cost, indent=1) + '\n', encoding='utf-8')
            reads = list(cost['reads'].values())
            print(f'{engine}-{run}: {len(reads)} screens, wall median {median(reads, "seconds"):.2f}s, '
                  f'CPU median {median(reads, "cpu_seconds"):.2f}s, timed out {sum(r["timed_out"] for r in reads)}',
                  file=sys.stderr)
    return 0


def summary_cost(reply):
    helper, worker = reply['helper'], reply['worker']
    return {'seconds': reply['seconds'], 'timed_out': reply['timed_out'], 'deadline_ms': reply['deadline_ms'],
            'regions': len(reply['regions']),
            'cpu_seconds': helper['cpu_seconds'] + worker['cpu_seconds'],
            'energy_joules': helper['energy_joules'] + worker['energy_joules'],
            'peak_footprint_mb': helper['peak_footprint_mb'] + worker['peak_footprint_mb'],
            'helper_cpu_seconds': helper['cpu_seconds'], 'worker_cpu_seconds': worker['cpu_seconds'],
            'lines': len(reply['lines'])}


def median(rows, key):
    return statistics.median(row[key] for row in rows) if rows else 0.0


# ----------------------------------------------------------------- measures

def search_tokens(text):
    """Tokens as FTS5's unicode61 tokenizer makes them: runs of letters,
    digits and private-use characters, case folded, accents removed."""
    folded = ''.join(ch for ch in unicodedata.normalize('NFKD', text) if not unicodedata.combining(ch)).casefold()
    tokens, current = [], []
    for ch in folded:
        if unicodedata.category(ch)[0] in 'LN' or unicodedata.category(ch) == 'Co':
            current.append(ch)
        elif current:
            tokens.append(''.join(current))
            current = []
    if current:
        tokens.append(''.join(current))
    return tokens


def recall(truth_tokens, out_tokens):
    truth, out = collections.Counter(truth_tokens), collections.Counter(out_tokens)
    return sum((truth & out).values()) / max(1, sum(truth.values()))


def stored_lines(scene, boxes):
    """The text the app stores for this reading, line by line, without the
    content/chrome separator."""
    stored = layout.assemble(boxes['lines'], min_confidence=bench.MIN_CONFIDENCE, width=boxes['width'],
                             height=boxes['height'], separators=boxes.get('separators', []),
                             window=bench.geometry(scene, boxes))
    return [line for line in stored.split('\n') if line.strip() and line != '\x1e']


def flat_measures(scene, boxes):
    blocks = scenes.truth_blocks(scenes.SCENES[scene['name']])
    truth = [bench.norm(line) for block in blocks for line in block]
    lines = stored_lines(scene, boxes)
    result = bench.legacy_score(blocks, lines)
    result['search'] = recall([t for line in truth for t in search_tokens(line)],
                              [t for line in lines for t in search_tokens(line)])
    old = shipped.assemble(boxes['lines'], min_confidence=bench.MIN_CONFIDENCE).splitlines()
    for key, value in bench.legacy_score(blocks, old).items():
        result['shipped_' + key] = value
    result['missed'] = [line for line in truth if line not in {bench.norm(l) for l in lines}]
    return result


def window_measures(scene, boxes):
    strings = [bench.norm(item['text']) for item in scene['items'] if len(bench.norm(item['text'])) >= 3]
    lines = [bench.norm(line) for line in stored_lines(scene, boxes)]
    # A paragraph wraps across rows, so a string may span lines: read the
    # line breaks as spaces, as the transcript bench's content measure does.
    flat = ' '.join(lines)
    found = [s for s in strings if bench.contains(flat, s)]
    return {
        'exact': len(found) / max(1, len(strings)),
        'words': recall([w for s in strings for w in s.split()], [w for line in lines for w in line.split()]),
        'search': recall([t for s in strings for t in search_tokens(s)],
                         [t for line in lines for t in search_tokens(line)]),
        'missed': [s for s in strings if s not in found],
    }


def score_folder(folder, reader):
    """Every measure for one engine run: {scene: row}, the bench's own
    failures, and its rows."""
    rows, failures = bench.bench(reader, folder)
    out = {}
    for row in rows:
        scene = row['scene']
        boxes = bench.load_boxes(scene['name'], folder)
        measures = flat_measures(scene, boxes) if scene['kind'] == 'scene' else window_measures(scene, boxes)
        measures.update({'kind': scene['kind'], 'content': row['new']['content'], 'order_t': row['new']['order'],
                         'chrome_w': row['new']['chrome_w'], 'chrome_l': row['new']['chrome_l'],
                         'junk': row['new']['junk']})
        if scene['code']:
            measures['code_ok'] = row['new']['code_ok']
        out[scene['name']] = measures
    return out, failures


def baseline_failures(candidate, baseline):
    """The transcript bench's content gates with PP-OCR's reading as the
    baseline."""
    failures = []
    for name, row in candidate.items():
        base = baseline[name]['content']
        if row['content'] < base - 0.01 - 1e-9:
            failures.append(f'{name}: content {row["content"]:.3f} below PP-OCR {base:.3f} - 0.01')
        if row['kind'] == 'decoy' and row['content'] < base - 1e-9:
            failures.append(f'{name}: a decoy lost content against PP-OCR ({row["content"]:.3f} < {base:.3f})')
    return failures


def means(rows, kind, keys):
    members = [row for row in rows.values() if row['kind'] == kind]
    return {key: statistics.mean(row[key] for row in members) for key in keys} if members else {}


def cost_summary(folder):
    path = folder / 'cost.json'
    if not path.is_file():
        return None
    cost = json.loads(path.read_text())
    reads = list(cost['reads'].values())
    walls = sorted(r['seconds'] for r in reads)
    cpus = sorted(r['cpu_seconds'] for r in reads)
    return {'reads': len(reads), 'timed_out': sum(r['timed_out'] for r in reads),
            'wall_median': statistics.median(walls), 'wall_p95': walls[round(0.95 * (len(walls) - 1))],
            'cpu_median': statistics.median(cpus), 'cpu_mean': statistics.mean(cpus),
            'cpu_p95': cpus[round(0.95 * (len(cpus) - 1))],
            'energy_median': statistics.median(r['energy_joules'] for r in reads),
            'peak_footprint_mb': max(r['peak_footprint_mb'] for r in reads),
            'regions_mean': statistics.mean(r['regions'] for r in reads),
            'cold': cost['cold']}


def score(args):
    reader_path = None if args.no_reader else (args.reader or bench.find_reader())
    reader = bench.Reader(reader_path) if reader_path else None
    folders = sorted(p for p in args.out.iterdir() if p.is_dir() and any(p.glob('*.json')))
    results = {}
    try:
        for folder in folders:
            results[folder.name] = score_folder(folder, reader)
    finally:
        if reader is not None:
            reader.close()
    print('reader:', reader.path if reader else 'none (the assembler\'s own main text)')
    paddle = [name for name in results if name.startswith('paddle')]
    baseline = results[paddle[0]][0] if paddle else None
    summary = {}
    flat_keys = ['exact', 'words', 'search', 'cer', 'order', 'shipped_exact', 'shipped_words']
    window_keys = ['exact', 'words', 'search']
    print(f'\n{"run":<12}{"flat: exact":>12}{"words":>7}{"search":>7}{"cer":>7}{"order":>7}'
          f'{"shipped":>9}{"words":>7}   {"windows: exact":>14}{"words":>7}{"search":>7}'
          f'   {"decoys":>7}  hard gates')
    for name, (rows, failures) in results.items():
        flat = means(rows, 'scene', flat_keys)
        win = means(rows, 'window', window_keys)
        decoy = means(rows, 'decoy', window_keys)
        against = baseline_failures(rows, baseline) if baseline is not None and not name.startswith('paddle') else []
        gate = {
            'flat_exact': flat['exact'] >= GATE['exact'], 'flat_words': flat['words'] >= GATE['words'],
            'window_exact': win['exact'] >= GATE['exact'], 'window_words': win['words'] >= GATE['words'],
            'hard_gates': not failures and not against,
        }
        summary[name] = {'flat': flat, 'windows': win, 'decoys': decoy, 'bench_failures': failures,
                         'pp_ocr_failures': against, 'gate': gate, 'passes': all(gate.values()),
                         'cost': cost_summary(args.out / name),
                         'targets': {key: statistics.mean(r[key] for r in rows.values()
                                                          if r['kind'] in ('window', 'decoy'))
                                     for key in ('chrome_w', 'chrome_l', 'junk')},
                         'scenes': rows}
        print(f'{name:<12}{flat["exact"]:>12.3f}{flat["words"]:>7.3f}{flat["search"]:>7.3f}{flat["cer"]:>7.3f}'
              f'{flat["order"]:>7.3f}{flat["shipped_exact"]:>9.3f}{flat["shipped_words"]:>7.3f}   '
              f'{win["exact"]:>14.3f}{win["words"]:>7.3f}{win["search"]:>7.3f}   {decoy["exact"]:>7.3f}  '
              + ('met' if gate['hard_gates'] else f'{len(failures) + len(against)} FAILED'))
    print('\ncost per read (synthetic screens; CPU is the helper plus its worker):')
    print(f'{"run":<12}{"wall med":>9}{"p95":>7}{"CPU med":>9}{"mean":>7}{"p95":>7}{"J med":>7}'
          f'{"peak MB":>9}{"regions":>9}{"timeouts":>9}   cold read')
    for name, item in summary.items():
        c = item['cost']
        if not c:
            continue
        print(f'{name:<12}{c["wall_median"]:>9.2f}{c["wall_p95"]:>7.2f}{c["cpu_median"]:>9.2f}{c["cpu_mean"]:>7.2f}'
              f'{c["cpu_p95"]:>7.2f}{c["energy_median"]:>7.2f}{c["peak_footprint_mb"]:>9.0f}{c["regions_mean"]:>9.1f}'
              f'{c["timed_out"]:>9}   {c["cold"]["seconds"]:.2f}s, {c["cold"]["cpu_seconds"]:.2f} CPU-s')
    print('\ngate: exact >= 0.95 and words >= 0.98 on the flat screens and the windows, and every hard gate')
    for name, item in summary.items():
        verdict = 'PASS' if item['passes'] else 'miss: ' + ', '.join(k for k, v in item['gate'].items() if not v)
        print(f'  {name:<12}{verdict}')
        for failure in item['bench_failures'] + item['pp_ocr_failures']:
            print(f'      {failure}')
    if args.misses:
        for name, item in summary.items():
            if args.misses != 'all' and name not in args.misses.split(','):
                continue
            print(f'\nmissed by {name}:')
            for scene, row in item['scenes'].items():
                for line in row['missed']:
                    print(f'  {scene:<18}{line}')
    if args.json:
        args.json.write_text(json.dumps(summary, indent=1, default=str) + '\n', encoding='utf-8')
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    r = sub.add_parser('read', help='read every screen with each engine')
    r.add_argument('screens', type=Path)
    r.add_argument('out', type=Path)
    r.add_argument('--probe', type=Path, required=True)
    r.add_argument('--worker', type=Path, help='the frozen PP-OCR worker; without it only Vision reads')
    r.add_argument('--runs', type=int, default=3)
    r.add_argument('--panes', action='store_true', help='also read with Vision one pane at a time (vision_panes)')
    r.add_argument('--only', help='comma-separated engines: vision, vision_panes, paddle')
    r.add_argument('--deadline-ms', type=int, help='in place of each engine\'s own deadline')
    s = sub.add_parser('score', help='score every run in OUT')
    s.add_argument('out', type=Path)
    s.add_argument('--json', type=Path, help='write the summary here')
    s.add_argument('--misses', help='list missed lines for these runs (or all)')
    s.add_argument('--reader', type=Path, help='the reading-probe binary (found in target/ by default)')
    s.add_argument('--no-reader', action='store_true')
    args = parser.parse_args()
    return read(args) if args.command == 'read' else score(args)


if __name__ == '__main__':
    raise SystemExit(main())

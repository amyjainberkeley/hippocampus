"""Score OCR engines on rendered app screens.

    python3 tools/ocr/screens/render.py OUT
    python3 tools/ocr/screens/bench.py OUT --paddle WORKER --vision PROBE [--engines a,b]

Metrics, per scene and overall:
  exact   share of truth lines that appear as an output line, verbatim after
          collapsing whitespace. A line split in two or merged with a
          neighbouring column fails.
  words   share of truth words recovered, ignoring order (pure recognition).
  cer     character edit distance between the whole truth and the whole
          output, each joined in reading order, over truth length. Interleaved
          columns and extra or missing text all cost here.
  order   of the truth lines found (similarity >= 0.8), the share that come
          out in reading order (longest increasing run).
"""
import argparse
import collections
import json
import re
import struct
import subprocess
import sys
import time
from difflib import SequenceMatcher
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import layout  # noqa: E402

MIN_CONFIDENCE = 0.5  # OCRMemoryText.minimumConfidence


def norm(text):
    return re.sub(r'\s+', ' ', text).strip()


def bmp_bytes(png):
    from PIL import Image
    image = Image.open(png).convert('RGBA')
    w, h = image.size
    r, g, b, a = image.split()
    pixels = Image.merge('RGBA', (b, g, r, a)).tobytes()
    header = struct.pack('<2sIHHI', b'BM', 54 + len(pixels), 0, 0, 54)
    dib = struct.pack('<IiiHHIIiiII', 40, w, -h, 1, 32, 0, len(pixels), 2835, 2835, 0, 0)
    return header + dib + pixels


def run_paddle(worker, png):
    start = time.monotonic()
    proc = subprocess.run([worker], input=bmp_bytes(png), capture_output=True, timeout=120)
    seconds = time.monotonic() - start
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode()[-400:])
    return json.loads(proc.stdout)['lines'], seconds


def run_vision(probe, mode, png):
    start = time.monotonic()
    proc = subprocess.run([probe, mode, str(png)], capture_output=True, timeout=120)
    seconds = time.monotonic() - start
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode()[-400:])
    return json.loads(proc.stdout)['lines'], seconds


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
        return reply.get('lines', []), time.monotonic() - start


def production_text(lines):
    """What the helper stores today: engine order, confidence floor, '\n' join."""
    kept = [l for l in lines if l['confidence'] >= MIN_CONFIDENCE and l['text'].strip()]
    return [l['text'] for l in kept]


def edit_distance(a, b):
    if len(a) < len(b):
        a, b = b, a
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


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


def score(truth_blocks, output_lines):
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('screens', type=Path)
    parser.add_argument('--paddle', type=Path)
    parser.add_argument('--vision', type=Path)
    parser.add_argument('--engines', default='paddle,paddle+layout,vision,vision+layout,vision-doc')
    parser.add_argument('--show', help='print one scene/engine output, e.g. chat_light/paddle')
    parser.add_argument('--fresh', action='store_true', help='ignore cached engine output')
    parser.add_argument('--serve', help='command for a persistent worker, e.g. "python worker.py --serve"')
    args = parser.parse_args()

    engines = args.engines.split(',')
    cache = {}
    serve = None
    totals = collections.defaultdict(lambda: collections.defaultdict(float))
    scenes = sorted(p.name[:-11] for p in args.screens.glob('*.truth.json'))
    print(f'{"scene":<16}{"engine":<15}{"exact":>7}{"words":>7}{"cer":>7}{"order":>7}{"sec":>7}')
    for scene in scenes:
        png = args.screens / f'{scene}.png'
        blocks = json.loads((args.screens / f'{scene}.truth.json').read_text())['blocks']
        for engine in engines:
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
                        print(f'serve worker ready in {serve.startup:.1f}s', file=sys.stderr)
                    cache[scene, base] = serve.run(png)
                stored.parent.mkdir(exist_ok=True)
                stored.write_text(json.dumps(cache[scene, base]))
            raw, seconds = cache[scene, base]
            if engine.endswith('+layout'):
                lines = layout.assemble(raw, min_confidence=MIN_CONFIDENCE).splitlines()
            else:
                lines = production_text(raw)
            if args.show == f'{scene}/{engine}':
                print('\n'.join(lines))
            result = score(blocks, lines)
            for key, value in result.items():
                totals[engine][key] += value
            totals[engine]['sec'] += seconds
            print(f'{scene:<16}{engine:<15}{result["exact"]:>7.3f}{result["words"]:>7.3f}'
                  f'{result["cer"]:>7.3f}{result["order"]:>7.3f}{seconds:>7.2f}')
    print('\nmean over', len(scenes), 'scenes')
    for engine in engines:
        t = totals[engine]
        n = len(scenes)
        print(f'{"ALL":<16}{engine:<15}{t["exact"]/n:>7.3f}{t["words"]/n:>7.3f}'
              f'{t["cer"]/n:>7.3f}{t["order"]/n:>7.3f}{t["sec"]/n:>7.2f}')


if __name__ == '__main__':
    main()

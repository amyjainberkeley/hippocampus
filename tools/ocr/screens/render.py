"""Render every scene and window to a Retina PNG with headless Chrome.

    python3 tools/ocr/screens/render.py OUT_DIR [--scale 2] [--only a,b]

Writes OUT_DIR/<name>.png and OUT_DIR/<name>.truth.json for the eight flat
scenes (scenes.py) and the mock app windows (windows.py). The truth lists every
string with its role (content, navigation or chrome) in reading order, plus the
window's app, title and size in points. Development only: Chrome renders with
the same text stack a browser window would use, and headless Chrome shows no
window.
"""
import argparse
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import scenes  # noqa: E402
import windows  # noqa: E402

CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'


def pages():
    """(name, html, truth) for every scene and window."""
    for name, scene in scenes.SCENES.items():
        yield name, scenes.render_html(scene), {
            'kind': 'scene', 'size': [1440, 900], 'app': None, 'title': None,
            'blocks': scenes.truth_blocks(scene), 'items': scenes.truth_items(scene)}
    for name, window in windows.WINDOWS.items():
        yield name, window['page'], {
            'kind': 'decoy' if window.get('decoy') else 'window', 'size': list(window['size']),
            'app': window['app'], 'title': window['title'], 'code': window.get('code'),
            'items': windows.truth_items(window['page'])}


def shoot(page, png, size, scale, profile):
    png.unlink(missing_ok=True)
    # Headless Chrome can linger after writing the screenshot; wait for the
    # file to settle, then stop it.
    chrome = subprocess.Popen([
        CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars',
        f'--user-data-dir={profile}', '--no-first-run',
        f'--force-device-scale-factor={scale}', f'--window-size={size[0]},{size[1]}',
        f'--screenshot={png}', page.as_uri(),
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + 60
    last = -1
    while time.monotonic() < deadline:
        if chrome.poll() is not None and png.exists():
            break
        if png.exists() and png.stat().st_size == last and last > 0:
            break
        last = png.stat().st_size if png.exists() else -1
        time.sleep(0.5)
    chrome.terminate()
    try:
        chrome.wait(timeout=10)
    except subprocess.TimeoutExpired:
        # A busy Mac can leave Chrome deaf to SIGTERM for longer; the
        # screenshot is already written by then.
        chrome.kill()
        chrome.wait(timeout=10)
    return png.exists()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('out', type=Path)
    parser.add_argument('--scale', type=float, default=2.0)
    parser.add_argument('--only', help='comma-separated names to render')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    only = set(args.only.split(',')) if args.only else None
    with tempfile.TemporaryDirectory() as tmp:
        for name, page_html, truth in pages():
            if only and name not in only:
                continue
            page = Path(tmp) / f'{name}.html'
            page.write_text(page_html, encoding='utf-8')
            png = args.out / f'{name}.png'
            if not shoot(page, png, truth['size'], args.scale, f'{tmp}/profile'):
                sys.exit(f'chrome did not render {name}')
            (args.out / f'{name}.truth.json').write_text(json.dumps(truth, indent=1, ensure_ascii=False),
                                                        encoding='utf-8')
            print(name, png.stat().st_size, file=sys.stderr)


if __name__ == '__main__':
    main()

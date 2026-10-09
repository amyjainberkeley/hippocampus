"""Render every scene to a Retina PNG with headless Chrome.

    python3 tools/ocr/screens/render.py OUT_DIR [--scale 2]

Writes OUT_DIR/<scene>.png and OUT_DIR/<scene>.truth.json. Development only:
Chrome renders with the same text stack a browser window would use.
"""
import argparse
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from scenes import SCENES, render_html, truth_blocks  # noqa: E402

CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('out', type=Path)
    parser.add_argument('--scale', type=float, default=2.0)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name, scene in SCENES.items():
            page = Path(tmp) / f'{name}.html'
            page.write_text(render_html(scene), encoding='utf-8')
            png = args.out / f'{name}.png'
            png.unlink(missing_ok=True)
            # Headless Chrome can linger after writing the screenshot; wait for
            # the file to settle, then stop it.
            chrome = subprocess.Popen([
                CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars',
                f'--user-data-dir={tmp}/profile', '--no-first-run',
                f'--force-device-scale-factor={args.scale}', '--window-size=1440,900',
                f'--screenshot={png}', page.as_uri(),
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic() + 60
            size = -1
            while time.monotonic() < deadline:
                if chrome.poll() is not None and png.exists():
                    break
                if png.exists() and png.stat().st_size == size and size > 0:
                    break
                size = png.stat().st_size if png.exists() else -1
                time.sleep(0.5)
            chrome.terminate()
            chrome.wait(timeout=10)
            if not png.exists():
                sys.exit(f'chrome did not render {name}')
            (args.out / f'{name}.truth.json').write_text(
                json.dumps({'blocks': truth_blocks(scene)}, indent=1), encoding='utf-8')
            print(name, png.stat().st_size, file=sys.stderr)


if __name__ == '__main__':
    main()

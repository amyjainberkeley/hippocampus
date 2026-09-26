"""Build-only model preparation and standalone macOS worker freezing."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request
from worker import MODELS
from bundle import source_inputs, file_hash, runtime_inventory

ROOT = Path(__file__).resolve().parent
URLS = {
    'PP-OCRv6_det_small.onnx': 'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.2/onnx/PP-OCRv6/det/PP-OCRv6_det_small.onnx',
    'PP-OCRv6_rec_small.onnx': 'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.2/onnx/PP-OCRv6/rec/PP-OCRv6_rec_small.onnx',
    'ch_ppocr_mobile_v2.0_cls_mobile.onnx': 'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.2/onnx/PP-OCRv4/cls/ch_ppocr_mobile_v2.0_cls_mobile.onnx',
}


def prepare_models():
    models = ROOT / 'models'
    models.mkdir(exist_ok=True)
    for name, digest in MODELS.items():
        path = models / name
        if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
            continue
        with urllib.request.urlopen(URLS[name], timeout=60) as response:
            data = response.read(100 * 1024 * 1024 + 1)
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError('OCR model checksum mismatch: ' + name)
        temporary = path.with_suffix('.pending')
        temporary.write_bytes(data)
        temporary.replace(path)
    return models


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT/'dist')
    parser.add_argument('--sign-identity')
    parser.add_argument('--models-only', action='store_true')
    args = parser.parse_args()
    # Freeze only the reviewed, hash-locked environment. The headless OpenCV
    # distribution intentionally replaces RapidOCR's GUI opencv-python extra.
    for line in (ROOT/'requirements.in').read_text().splitlines():
        name, version = line.split('==')
        if importlib.metadata.version(name) != version:
            raise ValueError('OCR build dependency mismatch: '+name)
    models = prepare_models()
    if args.models_only:
        return
    command = [sys.executable, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir',
               '--name', 'hippocampus-ocr', '--distpath', str(args.output),
               '--workpath', str(ROOT/'build'), '--specpath', str(ROOT/'build'),
               '--collect-all', 'rapidocr', '--collect-all', 'onnxruntime',
               '--add-data', str(models)+':models']
    if args.sign_identity:
        command += ['--codesign-identity', args.sign_identity]
    command += [str(ROOT/'worker.py')]
    subprocess.run(command, check=True)
    destination = args.output/'hippocampus-ocr'
    shutil.copy2(ROOT/'NOTICE.md', destination/'NOTICE.md')
    licenses=destination/'licenses'
    licenses.mkdir(exist_ok=True)
    for distribution in importlib.metadata.distributions():
        for relative in distribution.files or []:
            if any(word in str(relative).lower() for word in ('license','licence','copying','notice')):
                source=Path(distribution.locate_file(relative))
                if source.is_file() and '..' not in relative.parts:
                    target=licenses/distribution.metadata['Name']/relative
                    target.parent.mkdir(parents=True,exist_ok=True)
                    shutil.copy2(source,target)
    (destination/'model-manifest.json').write_text(json.dumps({'models': MODELS, 'sources': URLS}, indent=2)+'\n')
    (destination/'build-manifest.json').write_text(json.dumps({
        'source_inputs':source_inputs(),
        'executable_sha256':file_hash(destination/'hippocampus-ocr'),
        'runtime_inventory':runtime_inventory(destination),
    },indent=2)+'\n')


if __name__ == '__main__':
    main()

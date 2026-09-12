"""Offline PaddleOCR worker. One bounded BGRA BMP on stdin, JSON on stdout.

Images are never written to disk. Model downloads belong to prepare.py, never
this process. The parent enforces a wall-clock deadline and reaps this child.
"""
import hashlib
import json
import math
from pathlib import Path
import struct
import sys

MAX_EDGE = 3840
MAX_REPLY = 1024 * 1024
MODELS = {
    'PP-OCRv6_det_small.onnx': '090f04abcd9d9a7498bc4ebf677e4cb9bdce1fe4197ddb7e529f1ef44e1ff94f',
    'PP-OCRv6_rec_small.onnx': '6f327246b50388f3c176ae304bd95767ea6dc0c9ae92153ef8cbe210b3c14884',
    'ch_ppocr_mobile_v2.0_cls_mobile.onnx': 'e47acedf663230f8863ff1ab0e64dd2d82b838fceb5957146dab185a89d6215c',
}


def read_image(stream):
    header = stream.read(54)
    if len(header) != 54:
        raise ValueError('invalid image header')
    magic, size, r1, r2, offset = struct.unpack('<2sIHHI', header[:14])
    dib, w, h, planes, depth, compression, length, _, _, colors, important = struct.unpack('<IiiHHIIiiII', header[14:])
    if (magic != b'BM' or offset != 54 or dib != 40 or planes != 1 or depth != 32
            or compression != 0 or r1 or r2 or colors or important
            or not 0 < w <= MAX_EDGE or not -MAX_EDGE <= h < 0
            or length != w * -h * 4 or size != 54 + length):
        raise ValueError('invalid image dimensions or format')
    data = stream.read(length + 1)
    if len(data) != length:
        raise ValueError('invalid image length')
    import numpy as np
    return np.frombuffer(data, dtype=np.uint8).reshape(-h, w, 4)[:, :, :3].copy()


def load_engine(model_dir):
    for name, digest in MODELS.items():
        path = model_dir / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError('missing or invalid bundled OCR model')
    from rapidocr import RapidOCR
    from rapidocr.utils.download_file import DownloadFile
    # An upstream missing-model fallback must never turn into a runtime download.
    def deny_download(*args, **kwargs):
        raise ValueError('runtime model download forbidden')
    DownloadFile.run = deny_download
    return RapidOCR(params={
        # Preserve every recognition candidate for the post-OCR privacy scan.
        'Global.text_score': 0.0,
        'Global.log_level': 'critical', 'Global.use_cls': False,
        'Global.max_side_len': MAX_EDGE,
        'Global.model_root_dir': str(model_dir),
        'Det.model_path': str(model_dir / 'PP-OCRv6_det_small.onnx'),
        'Rec.model_path': str(model_dir / 'PP-OCRv6_rec_small.onnx'),
        'Cls.model_path': str(model_dir / 'ch_ppocr_mobile_v2.0_cls_mobile.onnx'),
        'EngineConfig.onnxruntime.intra_op_num_threads': 2,
        'EngineConfig.onnxruntime.inter_op_num_threads': 1,
    })


def encode_lines(texts, scores, boxes, width, height):
    if not (len(texts) == len(scores) == len(boxes)) or len(texts) > 4096:
        raise ValueError('invalid OCR result count')
    lines = []
    for text, score, box in zip(texts, scores, boxes):
        values = [float(v) for point in box for v in point]
        score = float(score)
        if len(values) != 8 or not all(math.isfinite(v) for v in values + [score]) or not 0 <= score <= 1:
            raise ValueError('invalid OCR result geometry')
        x0, x1 = max(0, min(values[::2])), min(width, max(values[::2]))
        y0, y1 = max(0, min(values[1::2])), min(height, max(values[1::2]))
        if x1 <= x0 or y1 <= y0 or not text.strip():
            continue
        lines.append({'text': text, 'confidence': score,
                      'box': [x0/width, (height-y1)/height, (x1-x0)/width, (y1-y0)/height]})
    return lines


def deny_network(event, args):
    if event in ('socket.connect', 'socket.connect_ex', 'socket.getaddrinfo', 'socket.bind'):
        raise PermissionError('OCR worker is offline')


def main():
    sys.addaudithook(deny_network)
    try:
        image = read_image(sys.stdin.buffer)
        engine = load_engine(Path(__file__).resolve().parent / 'models')
        result = engine(image)
        lines = [] if result.txts is None else encode_lines(result.txts, result.scores, result.boxes, image.shape[1], image.shape[0])
        reply = json.dumps({'version': 1, 'lines': lines}, ensure_ascii=False, allow_nan=False).encode('utf-8')
        if len(reply) > MAX_REPLY:
            raise ValueError('OCR reply too large')
        sys.stdout.buffer.write(reply)
        sys.stdout.buffer.flush()
    except Exception:
        # No input pixels, recognized text, paths, or exception contents in logs.
        sys.stderr.write('Local OCR worker failed\n')
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

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


def read_image(stream, *, framed=False):
    """One BMP from `stream`. One-shot mode also requires end of input after
    the pixels; framed (serve) mode reads exactly one image and returns None
    on a clean end of input between images."""
    header = stream.read(54)
    if framed and not header:
        return None
    if len(header) != 54:
        raise ValueError('invalid image header')
    magic, size, r1, r2, offset = struct.unpack('<2sIHHI', header[:14])
    dib, w, h, planes, depth, compression, length, _, _, colors, important = struct.unpack('<IiiHHIIiiII', header[14:])
    if (magic != b'BM' or offset != 54 or dib != 40 or planes != 1 or depth != 32
            or compression != 0 or r1 or r2 or colors or important
            or not 0 < w <= MAX_EDGE or not -MAX_EDGE <= h < 0
            or length != w * -h * 4 or size != 54 + length):
        raise ValueError('invalid image dimensions or format')
    data = stream.read(length if framed else length + 1)
    if len(data) != length:
        raise ValueError('invalid image length')
    import numpy as np
    return np.frombuffer(data, dtype=np.uint8).reshape(-h, w, 4)[:, :, :3].copy()


def load_engine(model_dir, *, threads=1, half_res_detection=False):
    for name, digest in MODELS.items():
        path = model_dir / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError('missing or invalid bundled OCR model')
    from rapidocr import RapidOCR
    from rapidocr.ch_ppocr_det.utils import DetPreProcess
    from rapidocr.utils.download_file import DownloadFile
    # An upstream missing-model fallback must never turn into a runtime download.
    def deny_download(*args, **kwargs):
        raise ValueError('runtime model download forbidden')
    DownloadFile.run = deny_download
    engine = RapidOCR(params={
        # Preserve every recognition candidate for the post-OCR privacy scan.
        'Global.text_score': 0.0,
        'Global.log_level': 'critical', 'Global.use_cls': False,
        'Global.max_side_len': MAX_EDGE,
        # The pinned upstream minimum-side resize can exceed max_side_len
        # afterwards on thin ROIs. Preserve originals for crops/box mapping;
        # the bounded detector preprocessor below owns resizing instead.
        'Global.use_preprocess_img': False,
        'Global.use_vertical_padding': False,
        'Global.model_root_dir': str(model_dir),
        'Det.model_path': str(model_dir / 'PP-OCRv6_det_small.onnx'),
        'Rec.model_path': str(model_dir / 'PP-OCRv6_rec_small.onnx'),
        'Cls.model_path': str(model_dir / 'ch_ppocr_mobile_v2.0_cls_mobile.onnx'),
        # One inference thread avoids competing pools on a busy desktop. The
        # bounded child still owns all model work; no partial result is kept.
        'EngineConfig.onnxruntime.intra_op_num_threads': threads,
        'EngineConfig.onnxruntime.inter_op_num_threads': 1,
    })

    class BoundedDetectorPreProcess(DetPreProcess):
        def resize(self, image):
            import cv2
            height, width = image.shape[:2]
            if not (0 < width <= MAX_EDGE and 0 < height <= MAX_EDGE):
                raise ValueError('invalid detector input dimensions')
            # Match normal short-side upscaling, but never let a narrow region
            # expand either edge past the capture cap. The model needs /32.
            # A Retina-sized frame is detected at half scale, which is the
            # resolution its UI text was designed for; recognition still
            # reads the original pixels. 4.6x faster with no accuracy loss
            # on the screen benchmark.
            floor = 0.5 if half_res_detection and max(height, width) >= 2560 else 1.0
            scale = min(max(floor, self.limit_side_len / min(height, width)),
                        MAX_EDGE / max(height, width))
            size = tuple(max(32, min(MAX_EDGE, round(int(n * scale) / 32) * 32))
                         for n in (width, height))
            return cv2.resize(image, size)

    detector = engine.text_det
    detector.get_preprocess = lambda _max_wh: BoundedDetectorPreProcess(
        detector.limit_side_len, detector.limit_type, detector.mean, detector.std)

    recognizer = engine.text_rec
    resize_recognition = recognizer.resize_norm_img

    def bounded_recognition(image, max_wh_ratio):
        # RapidOCR pads the whole recognition batch to this width. Refuse the
        # whole reading before allocation rather than drop candidates that the
        # privacy scan must see. ValueError propagates to the worker's failure
        # response; it is not upstream's empty/partial-result exception.
        model_height = recognizer.rec_image_shape[1]
        if (not math.isfinite(max_wh_ratio) or max_wh_ratio <= 0
                or not 0 < model_height <= MAX_EDGE
                or not 0 < int(model_height * max_wh_ratio) <= MAX_EDGE):
            raise ValueError('recognition input exceeds local OCR bounds')
        return resize_recognition(image, max_wh_ratio)

    recognizer.resize_norm_img = bounded_recognition
    engine.text_det = CoverageDetector(engine.text_det)
    return engine


# Screen text is axis-aligned, so boxes are handled as rectangles below.
MAX_LINE_RATIO = 40      # widest crop sent to recognition, as width / height
MAX_EXTRA_REGIONS = 16   # bound on second-pass detector runs per frame
INK_CELL = 4             # ink map resolution, in pixels per cell
INK_CONTRAST = 40        # local contrast that counts as ink


def _rect(quad):
    xs = [float(p[0]) for p in quad]
    ys = [float(p[1]) for p in quad]
    return [min(xs), min(ys), max(xs), max(ys)]


def _overlap_share(rect, other):
    """Share of `rect`'s area that `other` covers."""
    w = min(rect[2], other[2]) - max(rect[0], other[0])
    h = min(rect[3], other[3]) - max(rect[1], other[1])
    area = (rect[2] - rect[0]) * (rect[3] - rect[1])
    return (w * h) / area if w > 0 and h > 0 and area > 0 else 0.0


def _merge_across_sources(items):
    """Union boxes from different detector runs that overlap on one text row.

    `items` are (quad, rect, score, source). A line cut by a region edge is
    found twice, once per run; within one run the detector never overlaps
    itself. A box merged with nothing keeps the detector's own quad, so its
    crop is exactly what the detector chose.
    """
    parent = list(range(len(items)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(len(items)):
        _, a, _, source_a = items[i]
        for j in range(i + 1, len(items)):
            _, b, _, source_b = items[j]
            if source_a == source_b:
                continue
            overlap_x = min(a[2], b[2]) - max(a[0], b[0])
            overlap_y = min(a[3], b[3]) - max(a[1], b[1])
            if overlap_x > 0 and overlap_y >= 0.5 * min(a[3] - a[1], b[3] - b[1]):
                parent[find(i)] = find(j)
    groups = {}
    for i, item in enumerate(items):
        groups.setdefault(find(i), []).append(item)
    merged = []
    for group in groups.values():
        if len(group) == 1:
            quad, rect, score, _ = group[0]
            merged.append((quad, rect, score))
            continue
        rect = [min(r[0] for _, r, _, _ in group), min(r[1] for _, r, _, _ in group),
                max(r[2] for _, r, _, _ in group), max(r[3] for _, r, _, _ in group)]
        merged.append((None, rect, max(s for _, _, s, _ in group)))
    return merged


def _split_wide(image, rect):
    """Split a line too wide for recognition at its emptiest columns.

    Refusing the whole frame for one long line (a bookmarks bar, a log line)
    lost every other line on screen. Every piece is still recognized, so the
    privacy scan still sees all of the text.
    """
    import numpy as np
    x0, y0, x1, y1 = rect
    height = y1 - y0
    if height <= 0 or (x1 - x0) / height <= MAX_LINE_RATIO:
        return [rect]
    crop = image[int(y0):max(int(y0) + 1, math.ceil(y1)), int(x0):max(int(x0) + 1, math.ceil(x1))]
    gray = crop.mean(axis=2)
    ink = (np.abs(gray - np.median(gray)) > INK_CONTRAST).sum(axis=0)
    width = crop.shape[1]
    target = max(1, int(MAX_LINE_RATIO * height * 0.8))
    pieces, start = [], 0
    while width - start > MAX_LINE_RATIO * height:
        low = start + max(1, int(target * 0.6))
        high = min(width - 1, start + target)
        pieces.append([x0 + start, y0, x0 + _widest_gap(ink, low, high), y1])
        start = int(pieces[-1][2] - x0)
    pieces.append([x0 + start, y0, x1, y1])
    return pieces


def _widest_gap(ink, low, high):
    """Middle of the widest blank column run in [low, high]: a word space
    rather than the gap between two letters. The emptiest column if none."""
    best_start, best_length, run_start = None, 0, None
    for column in range(low, high + 2):
        blank = column <= high and ink[column] == 0
        if blank and run_start is None:
            run_start = column
        elif not blank and run_start is not None:
            if column - run_start > best_length:
                best_start, best_length = run_start, column - run_start
            run_start = None
    if best_start is None:
        return low + int(ink[low:high + 1].argmin())
    return best_start + best_length // 2


def _uncovered_ink(image, covered):
    """Regions with text-like contrast that no detected box covers."""
    import cv2
    import numpy as np
    height, width = image.shape[:2]
    small = cv2.resize(cv2.cvtColor(image, cv2.COLOR_BGR2GRAY),
                       (max(1, width // INK_CELL), max(1, height // INK_CELL)),
                       interpolation=cv2.INTER_AREA)
    gradient = cv2.morphologyEx(small, cv2.MORPH_GRADIENT, np.ones((3, 3), np.uint8))
    ink = (gradient > INK_CONTRAST).astype(np.uint8)
    for x0, y0, x1, y1 in covered:
        ink[max(0, int(y0 / INK_CELL) - 2):int(y1 / INK_CELL) + 3,
            max(0, int(x0 / INK_CELL) - 2):int(x1 / INK_CELL) + 3] = 0
    ink = cv2.dilate(ink, np.ones((5, 15), np.uint8))
    count, _, stats, _ = cv2.connectedComponentsWithStats(ink, connectivity=8)
    regions = []
    for i in range(1, count):
        x, y, w, h, area = (int(v) for v in stats[i])
        if area < 12:
            continue
        margin = 12
        regions.append((area, [max(0, (x - margin) * INK_CELL), max(0, (y - margin) * INK_CELL),
                               min(width, (x + w + margin) * INK_CELL),
                               min(height, (y + h + margin) * INK_CELL)]))
    regions.sort(key=lambda r: -r[0])
    return [r for _, r in regions[:MAX_EXTRA_REGIONS]]


class CoverageDetector:
    """Whole-frame detection, then a second look where text went unseen.

    The detection model misses text on large, mostly empty frames (a short
    document in a big window found nothing at 2880x1800), while the same
    text in a smaller frame is found. A second pass runs the detector on
    each uncovered patch of high-contrast pixels; dense screens rarely have
    any, so the cost lands only where it is needed.
    """

    def __init__(self, detector):
        self.detector = detector

    def __getattr__(self, name):
        return getattr(self.detector, name)

    def __call__(self, image):
        import time
        import numpy as np
        from rapidocr.ch_ppocr_det.utils import TextDetOutput
        started = time.perf_counter()
        first = self.detector(image)
        items = [] if first.boxes is None else [
            (np.asarray(b, dtype=np.float32), _rect(b), float(s), 0)
            for b, s in zip(first.boxes, first.scores)]
        seen = [r for _, r, _, _ in items]
        for source, (x0, y0, x1, y1) in enumerate(_uncovered_ink(image, seen), 1):
            found = self.detector(np.ascontiguousarray(image[y0:y1, x0:x1]))
            if found.boxes is None:
                continue
            for box, score in zip(found.boxes, found.scores):
                quad = np.asarray(box, dtype=np.float32) + np.array([x0, y0], dtype=np.float32)
                rect = _rect(quad)
                # The whole-frame box stays authoritative; a second look at
                # the same text is a duplicate, not a better crop.
                if any(_overlap_share(rect, other) > 0.3 for other in seen):
                    continue
                items.append((quad, rect, float(score), source))
        boxes, scores = [], []
        for quad, rect, score in _merge_across_sources(items):
            pieces = _split_wide(image, rect)
            if quad is not None and len(pieces) == 1:
                boxes.append(quad.tolist())
                scores.append(score)
                continue
            for x0, y0, x1, y1 in pieces:
                boxes.append([[x0, y0], [x1, y0], [x1, y1], [x0, y1]])
                scores.append(score)
        elapsed = time.perf_counter() - started
        if not boxes:
            return TextDetOutput(img=image, elapse=elapsed)
        order = sorted(range(len(boxes)), key=lambda i: (boxes[i][0][1], boxes[i][0][0]))
        return TextDetOutput(img=image, boxes=np.array([boxes[i] for i in order], dtype=np.float32),
                             scores=[scores[i] for i in order], elapse=elapsed)


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


def recognize(engine, image):
    result = engine(image)
    lines = [] if result.txts is None else encode_lines(result.txts, result.scores, result.boxes, image.shape[1], image.shape[0])
    reply = json.dumps({'version': 1, 'lines': lines}, ensure_ascii=False, allow_nan=False).encode('utf-8')
    if len(reply) > MAX_REPLY:
        raise ValueError('OCR reply too large')
    return reply


def serve():
    """Persistent mode: load the models once, then answer images until stdin
    closes. Each image gets exactly one JSON line. A frame the engine refuses
    is answered with `failed` so the parent keeps the warm process; a
    malformed frame ends the process, because the stream can no longer be
    framed. The first line announces readiness after the models load."""
    engine = load_engine(Path(__file__).resolve().parent / 'models', **SERVE_ENGINE)
    out = sys.stdout.buffer
    out.write(b'{"version":1,"ready":true}\n')
    out.flush()
    while True:
        image = read_image(sys.stdin.buffer, framed=True)
        if image is None:
            return 0
        try:
            reply = recognize(engine, image)
        except Exception:
            reply = b'{"version":1,"failed":true}'
        out.write(reply + b'\n')
        out.flush()


# The persistent worker runs one frame at a time; four threads and half-scale
# detection on Retina frames cut a 2880x1800 reading from 6.3 s to 1.4 s under
# load. See docs/audits/2026-10-08-ocr-transcription.md.
SERVE_ENGINE = {'threads': 4, 'half_res_detection': True}


def main():
    sys.addaudithook(deny_network)
    if sys.argv[1:] == ['--serve']:
        try:
            return serve()
        except Exception:
            sys.stderr.write('Local OCR worker failed\n')
            return 1
    try:
        image = read_image(sys.stdin.buffer)
        engine = load_engine(Path(__file__).resolve().parent / 'models')
        reply = recognize(engine, image)
        sys.stdout.buffer.write(reply)
        sys.stdout.buffer.flush()
    except Exception:
        # No input pixels, recognized text, paths, or exception contents in logs.
        sys.stderr.write('Local OCR worker failed\n')
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

"""Reading-order assembly for OCR line boxes (reference implementation).

Engines return text boxes, not a page. Joining them in engine order with
newlines interleaves side-by-side columns row by row and splits one visual
row into fragments. This rebuilds the page:

1. Drop low-confidence and duplicate boxes (the helper's existing rules).
2. Recursive XY-cut: split the region at the widest whitespace band that no
   box crosses, horizontally or vertically, until no band is wide enough.
3. Side-by-side regions that are all short, row-aligned cells form a table and
   are read row by row; anything else is read column by column.
4. Inside a leaf, boxes that share a visual row are joined left to right, and
   leading indentation is kept relative to the region's left edge. A box that
   overlaps another on its row horizontally is an alternative reading of the
   same text (overlapping recognition passes produce these), so it gets its
   own line instead of being glued on.

Boxes are normalized [x, y, w, h] with a bottom-left origin, as Vision and the
Paddle worker report them. The Swift port in OCRReadingOrder.swift must keep
the same thresholds; tests pin both against the same fixtures.
"""
import statistics

H_CUT = 0.8      # horizontal band, in median line heights
V_CUT = 1.5      # vertical band, in median line heights
ROW_OVERLAP = 0.5
TABLE_MAX_WORDS = 3
TABLE_ALIGNED = 0.7


class Box:
    __slots__ = ('text', 'x0', 'y0', 'x1', 'y1')

    def __init__(self, text, x0, y0, x1, y1):
        self.text, self.x0, self.y0, self.x1, self.y1 = text, x0, y0, x1, y1

    @property
    def h(self):
        return self.y1 - self.y0

    @property
    def cy(self):
        return (self.y0 + self.y1) / 2


def iou(a, b):
    ix = max(0.0, min(a.x1, b.x1) - max(a.x0, b.x0))
    iy = max(0.0, min(a.y1, b.y1) - max(a.y0, b.y0))
    inter = ix * iy
    union = (a.x1 - a.x0) * a.h + (b.x1 - b.x0) * b.h - inter
    return inter / union if union > 0 else 0.0


def bands(intervals):
    """Gaps between merged [start, end) intervals, as (size, cut position)."""
    spans = sorted(intervals)
    out = []
    end = spans[0][1]
    for start, stop in spans[1:]:
        if start > end:
            out.append((start - end, (start + end) / 2))
        end = max(end, stop)
    return out


def split(boxes, line_h):
    """Best cut as ('h'|'v', position), or None for a leaf."""
    best = None
    for axis, threshold in (('h', H_CUT), ('v', V_CUT)):
        spans = [(b.y0, b.y1) if axis == 'h' else (b.x0, b.x1) for b in boxes]
        for size, at in bands(spans):
            score = size / (line_h * threshold)
            if score >= 1 and (best is None or score > best[0]):
                best = (score, axis, at)
    return None if best is None else best[1:]


def rows(boxes):
    """Group boxes into visual rows, top to bottom; each row left to right."""
    out = []
    for box in sorted(boxes, key=lambda b: (b.cy, b.x0)):
        if out:
            row = out[-1]
            top, bottom = min(b.y0 for b in row), max(b.y1 for b in row)
            overlap = min(bottom, box.y1) - max(top, box.y0)
            if overlap >= ROW_OVERLAP * min(box.h, bottom - top):
                row.append(box)
                continue
        out.append([box])
    return [sorted(row, key=lambda b: b.x0) for row in out]


def readings(row):
    """Split a row into layers of horizontally disjoint boxes, in x order."""
    out = []
    for box in row:
        for layer in out:
            last = layer[-1]
            overlap = min(last.x1, box.x1) - max(last.x0, box.x0)
            if overlap < 0.5 * min(last.x1 - last.x0, box.x1 - box.x0):
                layer.append(box)
                break
        else:
            out.append([box])
    return out


def render_rows(boxes, left):
    lines = []
    widths = [(b.x1 - b.x0) / len(b.text) for b in boxes if len(b.text) >= 4]
    char_w = statistics.median(widths) if widths else None
    for row in rows(boxes):
        for layer in readings(row):
            text = ' '.join(b.text.strip() for b in layer)
            indent = 0
            if char_w:
                # Less than a character of offset is recognition jitter.
                columns = (layer[0].x0 - left) / char_w
                indent = 0 if columns < 1 else min(40, round(columns))
            lines.append(' ' * max(0, indent) + text)
    return lines


def is_table(columns):
    if len(columns) < 2:
        return False
    for column in columns:
        words = [len(b.text.split()) for b in column]
        if statistics.median(words) > TABLE_MAX_WORDS:
            return False
    anchor = rows(columns[0])
    centers = [sum(b.cy for b in row) / len(row) for row in anchor]
    heights = [max(b.y1 for b in row) - min(b.y0 for b in row) for row in anchor]
    aligned = total = 0
    for column in columns[1:]:
        for row in rows(column):
            cy = sum(b.cy for b in row) / len(row)
            total += 1
            if any(abs(cy - c) <= 0.3 * h for c, h in zip(centers, heights)):
                aligned += 1
    return total > 0 and aligned / total >= TABLE_ALIGNED


def cut(boxes, line_h):
    """Regions in reading order. Each region is a list of boxes.

    Depth-first with an explicit stack, so a screen of many stacked lines
    cannot exhaust the call stack."""
    out = []
    stack = [boxes]
    while stack:
        region = stack.pop()
        where = split(region, line_h)
        if where is None:
            out.append(region)
            continue
        axis, at = where
        if axis == 'h':
            stack.append([b for b in region if b.cy >= at])
            stack.append([b for b in region if b.cy < at])
            continue
        columns = [[b for b in region if (b.x0 + b.x1) / 2 < at],
                   [b for b in region if (b.x0 + b.x1) / 2 >= at]]
        # Peel further vertical splits so a table's columns are seen together.
        while True:
            last = columns[-1]
            more = split(last, line_h)
            if more is None or more[0] != 'v':
                break
            columns[-1:] = [[b for b in last if (b.x0 + b.x1) / 2 < more[1]],
                            [b for b in last if (b.x0 + b.x1) / 2 >= more[1]]]
        if is_table(columns):
            out.append(region)
            continue
        stack.extend(reversed(columns))
    return out


def assemble(lines, *, min_confidence=0.5, width=2880, height=1800):
    """Reading-order text for engine `lines` ({text, confidence, box})."""
    boxes = []
    for line in lines:
        text = line['text']
        if line['confidence'] < min_confidence or not text.strip():
            continue
        x, y, w, h = line['box']
        # To pixels with a top-left origin, so gaps compare in one unit.
        box = Box(text, x * width, (1 - y - h) * height, (x + w) * width, (1 - y) * height)
        if any(other.text == box.text and iou(other, box) >= 0.7 for other in boxes):
            continue
        boxes.append(box)
    if not boxes:
        return ''
    line_h = statistics.median(b.h for b in boxes)
    blocks = []
    for region in cut(boxes, line_h):
        left = min(b.x0 for b in region)
        blocks.append('\n'.join(render_rows(region, left)))
    return '\n\n'.join(blocks)

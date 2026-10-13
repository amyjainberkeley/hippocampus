"""Reading order and roles for OCR line boxes (reference implementation).

Engines return text boxes, not a page. Joining them in engine order with
newlines interleaves side-by-side columns row by row and splits one visual
row into fragments. This rebuilds the page:

1. Drop low-confidence, blank and duplicate boxes (the helper's rules), and
   remove U+001E, the character the stored text uses to divide content from
   chrome. A box outside the frame is "unplaced" and its text ends the page.
2. Pane separators: the OCR worker reports long straight edges that no text
   box crosses (worker.py `pane_separators`). A separator that spans at least
   90% of a region cuts it before anything else, the way the window divides
   itself: horizontal ones (bars) first, top to bottom, then vertical ones
   (sidebars, panels), left to right. A vertical separator between two sides
   that pair row for row, as a table's columns do, is a gridline, not a cut;
   two lists side by side (a file browser's columns) are panes. A pane that
   holds one row between rules, lining up item for item with the one-row pane
   above or below it, is a row of a ruled table (a receipt, a spreadsheet):
   it is read whole, and it is never a bar.
3. Recursive XY-cut inside each pane: split at the widest whitespace band no
   box crosses, horizontally or vertically, until no band is wide enough.
   Side-by-side regions that are all short, row-aligned cells form a table
   and are read row by row; the cells must line up from both sides (B1). A
   table beside other text keeps its columns together, and the text beside it
   (a form beside an order summary) is read on its own: it runs on below the
   table's last row, or stands twice as far off as the table's columns do. A
   vertical band whose two sides share no row (alternating chat bubbles) is
   not a cut: the region is read as one block, top to bottom (B2). Rows that
   overlap by a fifth of a line are shared. B3, the tolerant cut across a
   bridging box, is left out: pane separators cut the bars that bridge panes.
4. Inside a block, boxes that share a visual row are joined left to right,
   and leading indentation is kept relative to the block's left edge. A box
   that overlaps another on its row horizontally is an alternative reading
   of the same text, so it gets its own line instead of being glued on.

With the window's geometry (`window`), the reading is also sorted into
content and chrome, and stored as content blocks, then CHROME_SEPARATOR, then
chrome blocks, each in reading order; the separator is there whenever this
classification ran, even with no chrome. Nothing is dropped: chrome is moved,
never deleted. When unsure, it is content. A terminal's text is all content:
none of the rules below apply to it. Otherwise, before the cut:

- Gutter: an editor's line numbers, the longest ascending chain of integers
  down one column, alone or glued to the start of a line, that sits close to
  the lines it numbers or numbers lines of code. They come out of the code,
  and the code's left edge is measured without them. A glued line is placed
  by the width of the numbered lines' own characters. A table's column of
  numbers, far from cells that are not code, is not a gutter.
- Glyphs (RULINGS T3): a box of one or two characters, about square, half a
  line height clear of any text on its row, is an icon read as characters (a
  file icon as "D", a star as a CJK lookalike, a logo as "TR"). Icons side by
  side stand together. Code punctuation is not a glyph, and neither is data:
  a number in a column or row of numbers or the value of a label, or a pair
  of letters in a column or row of letter pairs (state codes).

Then, pane by pane, after the cut:

- Navigation: a column of four or more short items at the window's left edge
  beside something wider (a whole pane, or one region), never on the right,
  never a table, never code; a column of previews whose lines are cut short
  ("…") beside a wider reading pane; and, in a pane that is mostly
  navigation, the short lines left over in the navigation's column (a
  Compose button, a count).
- Bars: rows of the pane come off its top, one at a time, while they read
  as interface: three or more short items, a truncated tab, a breadcrumb, a
  web address, the window's title (only at the window's top edge), marks
  only, a panel's title in capitals, letter-buttons alone in their pane, or,
  for a one-row pane in the window's top band, a header with items at both
  ends or a search field. Above code only a strip comes off (a short line of
  code such as "};" or "SELECT *" is code). A pane with no separator above it
  has bars only in the window's top band. A row that lines up with the row
  below it is a table's header, not a bar, except in a pane that lies wholly
  in the top band (icons over their labels).
- Foot: a composer's placeholder ("Message #general", "iMessage", "Ask about
  your code…") alone in its region against the bottom edge of its pane, or
  the window's status bar. A message that ends a run of messages, or a
  sentence, is not a placeholder.
- Dates: in a chat app, a line centred in its pane made only of date and time
  words ("Today", "Oct 12 at 2:31 PM") divides messages; it is not said.
  Elsewhere a date is content (an invitation's date).

In content, code keeps its indentation (code blocks stacked in one pane share
a left edge); anything else is indented by none or four spaces, four only for
an offset of four characters or more, which keeps who said what in a
two-sided chat. A row's stacked lines read top first.

Digits are ASCII 0 to 9. Whitespace is the set WHITESPACE (Unicode
White_Space, which is what Swift's Character.isWhitespace and
CharacterSet.whitespacesAndNewlines use); Python's own str.split() and strip()
also treat U+001C to U+001F as space, so they are not used on text here. A
letter is any character of Unicode general category L*. Lengths count Unicode
scalars.

Cost: every rule works on sorted sweeps, bisect or lookups by value, except
`readings`, kept from the shipping assembler: it is quadratic in boxes that
overlap on one visual row, which real readings never stack more than a few
deep (4,096 boxes stacked on one row take 1.3 s of CPU here, and the shipping
assembler 1.8 s).

Boxes are normalized [x, y, w, h] with a bottom-left origin, as Vision and the
Paddle worker report them. The Swift port in OCRReadingOrder.swift must keep
the same thresholds; the parity fixtures (fixtures.py) pin both.
"""
import bisect
import math
import statistics
import unicodedata

H_CUT = 0.8      # horizontal band, in median line heights
V_CUT = 1.5      # vertical band, in median line heights
ROW_OVERLAP = 0.5
PARALLEL_OVERLAP = 0.2       # B2: two sides share a row when rows overlap by this share of the smaller height
TABLE_MAX_WORDS = 3
TABLE_ALIGNED = 0.7
TABLE_ANCHOR_ALIGNED = 0.7   # B1: share of the first column's rows matched in another column
TABLE_ROW_ALIGN = 0.3        # rows of two columns are level when their centres are this share of a row height apart
TABLE_APART = 2.0            # text beside a table stands this many times further off than its columns do
MAX_INDENT = 40
DUPLICATE_POSITIONS = 64     # earlier boxes of the same text compared, as the helper does

SEPARATOR_PAD = 2.0          # pixels a box must reach past a separator to cross it
SEPARATOR_SPAN = 0.9         # a separator cuts a region it spans this share of
PANE_MIN = 0.75              # thinnest pane, in line heights

GLYPH_MAX_CHARS = 2
GLYPH_ASPECT = (0.7, 1.5)    # width over height
GLYPH_CLEAR = 0.5            # gap to a row neighbour, in line heights
GLYPH_CHAIN_REACH = 3.0      # other numbers this close, in line heights, make a number data
GLYPH_LABEL_REACH = 6.0      # a label this far to the left makes a number its value
CODE_PUNCTUATION = frozenset('{}[]();,')

GUTTER_MIN = 3               # numbers in a gutter chain
GUTTER_MAX_DIGITS = 5
GUTTER_MAX_STEP = 4          # a chain may skip a few numbers (a line read as nothing)
GUTTER_ALIGN = 1.0           # right edges of lone numbers line up within this, in line heights
GUTTER_REACH = 3.0           # line numbers sit this close to their lines (median), in line heights, unless the lines are code
GUTTER_GAP = 10.0            # consecutive numbers of a gutter are at most this far apart, in line heights

MIN_WINDOW = (320, 240)      # points; a smaller window is not classified
TOP_BAND = (110, 0.20)       # points, share of height: where bars sit without separators
BOTTOM_BAND = (24, 0.05)
NAV_MAX_WIDTH = 0.30         # of the window's width
NAV_EDGE = 0.06              # a navigation column starts this close to the window's left edge
NAV_MIN_ROWS = 4
NAV_MAX_WORDS = 3            # median words per row
NAV_MAX_CODE = 0.2           # share of rows that look like code
NAV_WIDER = 1.5              # what sits beside navigation is at least this much wider
NAV_PANE_SHARE = 0.75        # a pane with this share of its rows in navigation is navigation
PLACEHOLDER_MAX_WORDS = 6
PLACEHOLDER_REACH = 3.0      # a composer sits this close to its pane's bottom edge, in line heights
TITLE_REACH = 1.5            # a title bar's text starts this close to the window's top edge, in line heights
SPREAD_GAP = 3.0             # items of a bar stand this far apart, in line heights
GRID_ALIGN = 0.5             # a table's cells line up within this, in line heights
PREVIEW_MIN = 2              # lines cut short in a list of previews
DATE_MAX_WORDS = 6
DATE_CENTRE = 0.05           # a date divider's centre is this close to its pane's, as a share of its width
DATE_WORDS = frozenset(
    'today yesterday tomorrow now at am pm a.m. p.m. '
    'monday tuesday wednesday thursday friday saturday sunday mon tue tues wed thu thurs fri sat sun '
    'january february march april may june july august september october november december '
    'jan feb mar apr jun jul aug sep sept oct nov dec'.split())
PREVIEW_SHARE = 0.2          # and their share of its lines
CODE_SHARE = 0.4             # share of rows that look like code for a block to be code
CODE_AHEAD = 6               # rows read from a pane's top row down to tell whether it sits above code
CHAT_INDENT = 4

CHROME_SEPARATOR = '\n\n\x1e\n'
CONTENT, CHROME = 'content', 'chrome'

WHITESPACE = frozenset('\t\n\x0b\x0c\r \x85\xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006'
                       '\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000')
DIGITS = frozenset('0123456789')
TERMINALS = frozenset({'com.apple.Terminal', 'com.googlecode.iterm2', 'com.mitchellh.ghostty',
                       'dev.warp.Warp-Stable', 'net.kovidgoyal.kitty', 'com.github.wez.wezterm',
                       'org.alacritty'})
# The Rust reader's CHAT_APPS (core/brain/src/reading.rs): apps whose windows
# are conversations, where a centred date divides messages.
CHAT_APPS = frozenset({'com.tinyspeck.slackmacgap', 'com.apple.MobileSMS', 'com.hnc.Discord',
                       'net.whatsapp.WhatsApp', 'desktop.WhatsApp', 'ru.keepcoder.Telegram',
                       'org.telegram.desktop', 'org.whispersystems.signal-desktop', 'com.microsoft.teams2',
                       'com.facebook.archon', 'com.openai.chat', 'com.anthropic.claudefordesktop'})
ELLIPSES = ('\u2026', '...')
BREADCRUMB = (' > ', ' \u203a ', ' / ', ' \u3009 ', ' \u276f ')
CODE_MARKS = frozenset('{}();=<>[]')
CODE_ENDINGS = frozenset('{}();,=[]<>:')
PROMPTS = ('$ ', '% ', '\u276f ')
# A composer's prompt is one of these as its whole text, or starts with one
# of the starts ("Message #general", "Message Maya Chen").
COMPOSER_WORDS = frozenset({'message', 'imessage', 'text message', 'reply', 'type a message',
                            'write a message', 'leave a comment', 'add a comment', 'write a comment'})
COMPOSER_STARTS = ('message ', 'type a message', 'write a message', 'leave a comment', 'add a comment',
                   'write a comment')
SENTENCE_ENDS = frozenset('.!?')


# ----------------------------------------------------------------- text, explicitly

def words(text):
    """`text` split at runs of WHITESPACE."""
    out, current = [], []
    for ch in text:
        if ch in WHITESPACE:
            if current:
                out.append(''.join(current))
                current = []
        else:
            current.append(ch)
    if current:
        out.append(''.join(current))
    return out


def trim(text):
    start, end = 0, len(text)
    while start < end and text[start] in WHITESPACE:
        start += 1
    while end > start and text[end - 1] in WHITESPACE:
        end -= 1
    return text[start:end]


def is_number(text):
    return bool(text) and all(ch in DIGITS for ch in text)


def leading_number(text):
    """(digits, rest) when `text` starts with up to GUTTER_MAX_DIGITS ASCII
    digits followed by whitespace or nothing, else None. The digits are kept
    as read ("007"); int() gives their value."""
    count = 0
    while count < len(text) and text[count] in DIGITS:
        count += 1
    if count == 0 or count > GUTTER_MAX_DIGITS:
        return None
    if count < len(text) and text[count] not in WHITESPACE:
        return None
    return text[:count], trim(text[count:])


# ----------------------------------------------------------------- geometry

class Box:
    __slots__ = ('text', 'x0', 'y0', 'x1', 'y1')

    def __init__(self, text, x0, y0, x1, y1):
        self.text, self.x0, self.y0, self.x1, self.y1 = text, x0, y0, x1, y1

    @property
    def h(self):
        return self.y1 - self.y0

    @property
    def w(self):
        return self.x1 - self.x0

    @property
    def cy(self):
        return (self.y0 + self.y1) / 2

    @property
    def cx(self):
        return (self.x0 + self.x1) / 2


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
    """Group boxes into visual rows, top to bottom; each row left to right.
    A box joins the last row when it overlaps the row's whole height by half
    the smaller of the two heights."""
    out = []
    top = bottom = 0.0
    for box in sorted(boxes, key=lambda b: (b.cy, b.x0)):
        if out:
            overlap = min(bottom, box.y1) - max(top, box.y0)
            if overlap >= ROW_OVERLAP * min(box.h, bottom - top):
                out[-1].append(box)
                top, bottom = min(top, box.y0), max(bottom, box.y1)
                continue
        out.append([box])
        top, bottom = box.y0, box.y1
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


def render_rows(boxes, left, flat=False, stacked=False):
    """Lines of a block. Indentation is kept relative to `left`, up to
    MAX_INDENT; `flat` makes any indent CHAT_INDENT spaces (prose and chat).
    `stacked` puts a row's layers in the order they sit on screen, top first
    (a name above "to me", both beside one time), not the order they formed."""
    lines = []
    widths = [(b.x1 - b.x0) / len(b.text) for b in boxes if len(b.text) >= 4]
    char_w = statistics.median(widths) if widths else None
    for row in rows(boxes):
        layers = readings(row)
        if stacked:
            layers.sort(key=lambda layer: min(b.y0 for b in layer))
        for layer in layers:
            text = ' '.join(trim(b.text) for b in layer)
            indent = 0
            if char_w:
                columns = (layer[0].x0 - left) / char_w
                if flat:
                    # Outside code an indent is none or four spaces, and an
                    # offset shorter than that (a box that starts after a
                    # checkbox) is not one.
                    indent = CHAT_INDENT if columns >= CHAT_INDENT else 0
                else:
                    # Less than a character of offset is recognition jitter.
                    indent = 0 if columns < 1 else min(MAX_INDENT, round(columns))
            lines.append(' ' * max(0, indent) + text)
    return lines


def row_span(row):
    return min(b.y0 for b in row), max(b.y1 for b in row)


def is_table(columns):
    if len(columns) < 2:
        return False
    for column in columns:
        counts = [len(words(b.text)) for b in column]
        if statistics.median(counts) > TABLE_MAX_WORDS:
            return False
    anchor = rows(columns[0])
    centers = [sum(b.cy for b in row) / len(row) for row in anchor]
    heights = [max(b.y1 for b in row) - min(b.y0 for b in row) for row in anchor]
    # A row aligns with an anchor row when their centres are within
    # TABLE_ROW_ALIGN of the anchor row's height; search the anchor rows by
    # centre.
    order = sorted(range(len(anchor)), key=lambda i: centers[i])
    ordered = [centers[i] for i in order]
    reach = TABLE_ROW_ALIGN * max(heights)
    aligned = total = 0
    matched = set()
    for column in columns[1:]:
        for row in rows(column):
            cy = sum(b.cy for b in row) / len(row)
            total += 1
            hits = [order[k] for k in range(bisect.bisect_left(ordered, cy - reach),
                                            bisect.bisect_right(ordered, cy + reach))
                    if abs(cy - centers[order[k]]) <= TABLE_ROW_ALIGN * heights[order[k]]]
            if hits:
                aligned += 1
                matched.update(hits)
    if total == 0 or aligned / total < TABLE_ALIGNED:
        return False
    # B1: a table is aligned from both sides. One short row beside a long
    # column is not a table.
    return len(matched) / len(anchor) >= TABLE_ANCHOR_ALIGNED


def parallel(left, right):
    """B2: whether two sides share a row, as columns of text do. Alternating
    chat bubbles never do: one sits below the other. Columns with different
    line pitches share rows only now and then (a sidebar beside a page can
    share one row in six), and columns offset by half a line overlap only a
    little; reading real columns as one block interleaves them, so one row
    overlapping by PARALLEL_OVERLAP is enough. A sorted sweep, so a long
    column costs n log n."""
    a, b = rows(left), rows(right)
    fewer, more = (a, b) if len(a) <= len(b) else (b, a)
    if not fewer:
        return True
    spans = sorted(row_span(row) for row in more)
    tops = [top for top, _ in spans]
    tallest = max(bottom - top for top, bottom in spans)
    shared = 0
    for row in fewer:
        top, bottom = row_span(row)
        height = bottom - top
        # Rows of the other side that start before this one ends and no
        # earlier than the tallest of them could reach.
        for other_top, other_bottom in spans[bisect.bisect_left(tops, top - tallest):bisect.bisect_left(tops, bottom)]:
            overlap = min(bottom, other_bottom) - max(top, other_top)
            if overlap >= PARALLEL_OVERLAP * min(height, other_bottom - other_top):
                shared += 1
                break
    return shared >= 1


def stands_apart(columns):
    """Whether the first of three or more columns is text beside a table,
    not the table's first column (a form beside an order summary): the other
    columns form a table without it, and it runs on below that table's last
    row, or it stands TABLE_APART times further off than the table's columns
    stand from each other. A title above a table, or a cell that wraps onto
    a second line, has no partner either, and is the table's own."""
    if len(columns) < 3 or not is_table(columns[1:]):
        return False
    table_rows = rows([b for column in columns[1:] for b in column])
    last = max(row_span(row)[1] for row in table_rows)
    if any(row_span(row)[0] >= last for row in rows(columns[0])):
        return True
    gaps = [min(b.x0 for b in columns[i + 1]) - max(b.x1 for b in columns[i]) for i in range(len(columns) - 1)]
    return gaps[0] >= TABLE_APART * max(gaps[1:])


def cut(boxes, line_h, tables=None):
    """Regions in reading order. Each region is a list of boxes. The ids of
    regions kept whole because their columns form a table go in `tables`.

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
        if not parallel(columns[0], columns[1]):
            out.append(region)
            continue
        # Peel further vertical splits so a table's columns are seen together.
        while True:
            last = columns[-1]
            more = split(last, line_h)
            if more is None or more[0] != 'v':
                break
            columns[-1:] = [[b for b in last if (b.x0 + b.x1) / 2 < more[1]],
                            [b for b in last if (b.x0 + b.x1) / 2 >= more[1]]]
        if is_table(columns) and not stands_apart(columns):
            out.append(region)
            if tables is not None:
                tables.add(id(region))
            continue
        # A table can sit beside other text (an order summary beside a
        # form): keep the columns that form one together, and read the text
        # beside it on its own.
        for i in range(1, len(columns) - 1):
            if is_table(columns[i:]):
                columns = columns[:i] + [[b for column in columns[i:] for b in column]]
                break
        stack.extend(reversed(columns))
    return out


# ----------------------------------------------------------------- panes

class Separator:
    __slots__ = ('vertical', 'at', 'start', 'end')

    def __init__(self, vertical, at, start, end):
        self.vertical, self.at, self.start, self.end = vertical, at, start, end


def to_separators(normalized, width, height):
    """Worker separators ([x, y, w, h], bottom-left, one of w and h zero) as
    pixels with a top-left origin."""
    out = []
    for item in normalized or ():
        if len(item) != 4 or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in item):
            continue
        x, y, w, h = item
        if w == 0 and h > 0:
            out.append(Separator(True, x * width, (1 - y - h) * height, (1 - y) * height))
        elif h == 0 and w > 0:
            out.append(Separator(False, (1 - y) * height, x * width, (x + w) * width))
    return out


def paired_rows(left, right):
    """Whether two sides pair one to one, row for row, as a table's columns
    do: the same number of rows, each level with its partner."""
    a, b = rows(left), rows(right)
    if len(a) != len(b):
        return False
    for row_a, row_b in zip(a, b):
        height = min(row_span(row_a)[1] - row_span(row_a)[0], row_span(row_b)[1] - row_span(row_b)[0])
        if abs(centre_y(row_a) - centre_y(row_b)) > TABLE_ROW_ALIGN * height:
            return False
    return True


def crossed(separator, boxes):
    s = separator
    if s.vertical:
        return any(b.x0 < s.at - SEPARATOR_PAD and b.x1 > s.at + SEPARATOR_PAD and b.y1 > s.start
                   and b.y0 < s.end for b in boxes)
    return any(b.y0 < s.at - SEPARATOR_PAD and b.y1 > s.at + SEPARATOR_PAD and b.x1 > s.start
               and b.x0 < s.end for b in boxes)


def panes(boxes, separators, rect, line_h):
    """The window cut at its separators: [(rect, boxes)] in reading order,
    bars before what they sit on, left before right."""
    usable = [s for s in separators if not crossed(s, boxes)]
    minimum = PANE_MIN * line_h
    out = []
    stack = [(rect, boxes)]
    while stack:
        (x0, y0, x1, y1), members = stack.pop()
        chosen = None
        across = sorted((s for s in usable if not s.vertical and y0 + minimum <= s.at <= y1 - minimum
                         and min(s.end, x1) - max(s.start, x0) >= SEPARATOR_SPAN * (x1 - x0)),
                        key=lambda s: s.at)
        if across:
            at = across[0].at
            chosen = [((x0, y0, x1, at), [b for b in members if b.cy < at]),
                      ((x0, at, x1, y1), [b for b in members if b.cy >= at])]
        else:
            down = sorted((s for s in usable if s.vertical and x0 + minimum <= s.at <= x1 - minimum
                           and min(s.end, y1) - max(s.start, y0) >= SEPARATOR_SPAN * (y1 - y0)),
                          key=lambda s: s.at)
            for s in down:
                left = [b for b in members if b.cx < s.at]
                right = [b for b in members if b.cx >= s.at]
                # A gridline between a table's columns is not a pane edge:
                # the two sides pair row for row. Two lists side by side (a
                # file browser's columns, a file tree beside code) are panes.
                if left and right and paired_rows(left, right) and is_table([left, right]):
                    continue
                chosen = [((x0, y0, s.at, y1), left), ((s.at, y0, x1, y1), right)]
                break
        if chosen is None:
            out.append(((x0, y0, x1, y1), members))
        else:
            stack.extend(reversed(chosen))
    return out


def ruled_rows(window_panes, line_h):
    """Indexes of the panes (from panes()) that are rows of a ruled table: a
    receipt, a spreadsheet's gridlines, a list with alternating backgrounds.
    Each such pane holds one row between rules, the pane above or below it
    spans the same columns, and the two rows line up item for item. A row of
    a table is read whole: its label is not cut from its amount, and it is
    never a bar. A pane with no text between two (a double rule) does not
    break the run."""
    found = set()
    previous = None  # (index, rect, row) of the last pane with text, when it held one row
    for i, (rect, boxes) in enumerate(window_panes):
        if not boxes:
            continue
        lines = rows(boxes)
        current = (i, rect, lines[0]) if len(lines) == 1 else None
        if (current is not None and previous is not None and abs(previous[1][0] - rect[0]) < 1
                and abs(previous[1][2] - rect[2]) < 1 and grid(previous[2], current[2], line_h)):
            found.update((previous[0], i))
        previous = current
    return found


# ----------------------------------------------------------------- box rules

def gutter_chain(boxes, line_h):
    """The longest ascending chain of integers down one column: [(box,
    number, rest)], each number alone in its box (rest '') or glued to the
    start of a line (rest is the line). Shorter than GUTTER_MIN when there is
    none.

    A chain grows greedily from its first number: the next is the first box,
    top to bottom then left to right, that is 1 to GUTTER_MAX_STEP more, at
    least half a line lower and at most GUTTER_GAP lines lower than the last,
    and lines up with the first number. The first chain of the greatest
    length wins, and a number already in a chain found earlier starts none.
    Boxes are looked up by their number, so a chain never scans the boxes it
    cannot use."""
    candidates = []
    for box in boxes:
        parsed = leading_number(trim(box.text))
        if parsed is not None:
            candidates.append((box, int(parsed[0]), parsed[1]))
    if len(candidates) < GUTTER_MIN:
        return []
    candidates.sort(key=lambda t: (t[0].cy, t[0].x0))
    # Positions in that order, by number, and their centres, for bisect.
    by_number = {}
    for i, (box, number, _) in enumerate(candidates):
        by_number.setdefault(number, ([], []))
        by_number[number][0].append(i)
        by_number[number][1].append(box.cy)

    def aligned(box, anchor):
        # Lone numbers are right-aligned; numbers glued to a line start
        # where the column starts.
        return (abs(box.x1 - anchor.x1) <= GUTTER_ALIGN * line_h
                or abs(box.x0 - anchor.x0) <= GUTTER_ALIGN * line_h)

    def after(last, anchor):
        """The position of the chain's next number, or None."""
        box, number, _ = candidates[last]
        found = None
        for step in range(1, GUTTER_MAX_STEP + 1):
            entry = by_number.get(number + step)
            if entry is None:
                continue
            positions, centres = entry
            for k in range(bisect.bisect_left(centres, box.cy + 0.5 * line_h), len(positions)):
                if centres[k] > box.cy + GUTTER_GAP * line_h or (found is not None and positions[k] > found):
                    break  # a gutter numbers every line; past this, it has stopped
                if aligned(candidates[positions[k]][0], anchor):
                    found = positions[k]
                    break
        return found

    best = []
    chained = set()
    for start, (anchor, _, _) in enumerate(candidates):
        if len(best) >= len(candidates) - start:
            break  # no later start can make a longer chain
        if id(anchor) in chained:
            continue  # a chain from inside a chain found already is part of it
        chain = [start]
        while True:
            following = after(chain[-1], anchor)
            if following is None:
                break
            chain.append(following)
        chained.update(id(candidates[i][0]) for i in chain)
        if len(chain) > len(best):
            best = chain
    return [candidates[i] for i in best]


def gutter(boxes, line_h):
    """An editor's line numbers: ({id(box): (number, rest)}, numbered) for
    the boxes of gutter_chain, when they sit close to the left edge of the
    lines they number or number lines of code. `numbered` holds those lines:
    a glued box itself, or the box after a lone number on its row. Empty
    when there is no such chain. A table's column of numbers is not a
    gutter: its numbers stand far from the next cell."""
    best = gutter_chain(boxes, line_h)
    if len(best) < GUTTER_MIN:
        return {}, []
    neighbour = {}
    for row in rows(boxes):
        for i, box in enumerate(row):
            neighbour[id(box)] = row[i + 1] if i + 1 < len(row) else None
    # Line numbers sit close to the lines they number (a number glued to its
    # line is as close as can be), or number lines of code, however deeply
    # indented. A table's numbers stand far from cells that are not code.
    gaps, texts, numbered = [], [], []
    for box, _, rest in best:
        if rest:
            gaps.append(0.0)
            texts.append(rest)
            numbered.append(box)
        elif neighbour.get(id(box)) is not None:
            gaps.append(neighbour[id(box)].x0 - box.x1)
            texts.append(trim(neighbour[id(box)].text))
            numbered.append(neighbour[id(box)])
    close = not gaps or statistics.median(gaps) <= GUTTER_REACH * line_h
    code = bool(texts) and sum(looks_like_code(t) for t in texts) >= CODE_SHARE * len(texts)
    if not (close or code):
        return {}, []
    return {id(box): (number, rest) for box, number, rest in best}, numbered


def has_letter(text):
    """A character of Unicode general category L* (a letter of any script)."""
    return any(unicodedata.category(ch).startswith('L') for ch in text)


def is_letter_pair(text):
    """Two letters of any script ("OR", "EN", "kg", "TR")."""
    return len(text) == 2 and all(unicodedata.category(ch).startswith('L') for ch in text)


class Cells:
    """The boxes whose text (whitespace removed) is of one kind, numbers or
    letter pairs, by height on the screen."""

    def __init__(self, boxes, kind):
        self.boxes = sorted((b for b in boxes if kind(''.join(words(b.text)))), key=lambda b: b.cy)
        self.centres = [b.cy for b in self.boxes]
        self.tallest = max((b.h for b in self.boxes), default=0.0)

    def near(self, box, reach):
        lo = bisect.bisect_left(self.centres, box.cy - reach)
        hi = bisect.bisect_right(self.centres, box.cy + reach)
        return self.boxes[lo:hi]

    def line_up(self, box, line_h):
        """Whether another of these cells stands in the box's column or on its
        row, near it."""
        for other in self.near(box, max(GLYPH_CHAIN_REACH * line_h, self.tallest)):
            if other is box:
                continue
            same_column = (min(box.x1, other.x1) - max(box.x0, other.x0) > 0
                           and abs(other.cy - box.cy) <= GLYPH_CHAIN_REACH * line_h)
            same_row = (min(box.y1, other.y1) - max(box.y0, other.y0) >= ROW_OVERLAP * min(box.h, other.h)
                        and abs(other.cx - box.cx) <= 2 * GLYPH_CHAIN_REACH * line_h)
            if same_column or same_row:
                return True
        return False


def number_in_place(box, row, index, numbers, line_h):
    """Whether a box of digits is data: in a column or row of other numbers
    (a table's column, a calendar's week, counts down a list), or the value
    of a label on its own row ("Estimate  3")."""
    if not is_number(''.join(words(box.text))):
        return False
    if numbers.line_up(box, line_h):
        return True
    return any(has_letter(other.text) and box.x0 - other.x1 <= GLYPH_LABEL_REACH * line_h
               for other in row[:index])


def pair_in_place(box, pairs, line_h):
    """Whether two letters are data: in a column or row of other letter
    pairs (a table's column of state or language codes). An icon read as
    letters ("TR") stands alone."""
    return is_letter_pair(''.join(words(box.text))) and pairs.line_up(box, line_h)


def glyph_shaped(box):
    """One or two characters, about square (RULINGS T3). Code punctuation
    is code."""
    text = ''.join(words(box.text))
    if not text or len(text) > GLYPH_MAX_CHARS or box.h <= 0:
        return False
    if all(ch in CODE_PUNCTUATION for ch in text):
        return False
    return GLYPH_ASPECT[0] <= box.w / box.h <= GLYPH_ASPECT[1]


def glyphs(boxes, line_h):
    """Boxes that are icons read as characters: glyph-shaped, and at least
    GLYPH_CLEAR line heights from any text on their row. Icons side by side
    (attach and send) stand together, so only text counts as a neighbour.
    Numbers and letter pairs in place are data."""
    numbers, pairs = Cells(boxes, is_number), Cells(boxes, is_letter_pair)
    out = []
    for row in rows(boxes):
        shaped = [glyph_shaped(box) for box in row]
        for i, box in enumerate(row):
            if not shaped[i]:
                continue
            before = next((row[j] for j in range(i - 1, -1, -1) if not shaped[j]), None)
            after = next((row[j] for j in range(i + 1, len(row)) if not shaped[j]), None)
            if before is not None and box.x0 - before.x1 < GLYPH_CLEAR * line_h:
                continue
            if after is not None and after.x0 - box.x1 < GLYPH_CLEAR * line_h:
                continue
            if number_in_place(box, row, i, numbers, line_h) or pair_in_place(box, pairs, line_h):
                continue
            out.append(box)
    return out


# ----------------------------------------------------------------- roles

def looks_like_code(text):
    text = trim(text)
    if not text:
        return False
    if any(mark in text for mark in ('::', '->', '=>')) or any(ch in CODE_MARKS for ch in text):
        return True
    return text[-1] in CODE_ENDINGS


def is_code(block_rows, terminal):
    if terminal:
        return True
    texts = [' '.join(trim(b.text) for b in row) for row in block_rows]
    if any(text.startswith(PROMPTS) for text in texts):
        return True
    return sum(looks_like_code(t) for t in texts) >= CODE_SHARE * len(texts)


def normalized(text):
    return ' '.join(words(text)).lower()


def is_address(text):
    """A web address or a domain, as a browser's address bar shows it. A
    padlock or a star read beside it is ignored."""
    parts = [part for part in words(text) if len(part) > GLYPH_MAX_CHARS]
    if len(parts) != 1:
        return False
    token = parts[0]
    host = token.split('/', 1)[0]
    return '.' in host and not host.endswith('.') and not any(ch in '(){}<>' for ch in token) and (
        '/' in token or token.startswith(('http', 'www.')))


def truncated(text):
    """Text cut short with an ellipsis, as a tab or a list shows a long title.
    A close mark read after it ("usab… ×") does not hide the cut."""
    parts = words(text)
    while parts and len(parts[-1]) <= GLYPH_MAX_CHARS and not parts[-1].endswith(ELLIPSES):
        parts.pop()
    return bool(parts) and parts[-1].endswith(ELLIPSES)


def icon_row(row):
    """A row of nothing but marks: every token one or two characters, at
    least one of them a symbol. Code punctuation ("}", "};") is code, not a
    mark."""
    tokens = [token for b in row for token in words(b.text)]
    return bool(tokens) and all(len(t) <= GLYPH_MAX_CHARS for t in tokens) and any(
        not any(unicodedata.category(ch)[0] in 'LN' for ch in t) and not all(ch in CODE_PUNCTUATION for ch in t)
        for t in tokens)


def marks_row(row):
    """A row of buttons drawn as letters (a composer's B, I, S) beside icons:
    no token longer than three characters, none a number, at least one box
    shaped like a glyph."""
    tokens = [token for b in row for token in words(b.text)]
    return (bool(tokens) and all(len(t) <= 3 and not any(ch in DIGITS for ch in t) for t in tokens)
            and any(glyph_shaped(b) for b in row))


def strip_shaped(row, title):
    """A row of interface: tabs, a toolbar, a breadcrumb, an address bar or,
    for the window's first row, its title."""
    texts = [trim(b.text) for b in row]
    joined = ' '.join(texts)
    if len(row) >= 3 and all(len(words(t)) <= 4 for t in texts):
        return True
    if any(truncated(t) for t in texts):
        return True
    if sum(joined.count(mark) for mark in BREADCRUMB) >= 2:
        return True
    if is_address(joined):
        return True
    return bool(title) and any(names_window(text, title) for text in texts)


def names_window(text, title):
    """Whether a box's text is the window's title, or most of it, or holds
    it with little else (a breadcrumb that ends in it)."""
    line, name = normalized(text), normalized(title)
    if len(line) < 4 or len(name) < 4:
        return False
    return (line in name and len(line) >= 0.5 * len(name)) or (name in line and len(name) >= 0.5 * len(line))


def prompt_words(row):
    """A field's text, short enough for a prompt, with icons read beside it
    (a magnifier as "Q") left out; '' when the row is longer than a prompt."""
    joined = ' '.join(trim(b.text) for b in row if len(''.join(words(b.text))) > GLYPH_MAX_CHARS)
    return joined if joined and len(words(joined)) <= PLACEHOLDER_MAX_WORDS else ''


def is_placeholder(row):
    """A composer's prompt: worded like one ("Message #general", "iMessage",
    "Reply"), or trailing off ("Ask about your code…"). A sentence ("Reply to
    Dana about the invoice.") and a message that starts like a prompt ("Reply
    when you can") are not prompts."""
    joined = prompt_words(row)
    if not joined:
        return False
    if joined.endswith(ELLIPSES):
        return True
    if joined[-1] in SENTENCE_ENDS:
        return False
    lowered = normalized(joined)
    return lowered in COMPOSER_WORDS or lowered.startswith(COMPOSER_STARTS)


def is_search(row):
    """A search field: "Search", or "Search" and what it searches ("Search
    mail")."""
    joined = prompt_words(row)
    if not joined or joined[-1] in SENTENCE_ENDS:
        return False
    lowered = normalized(joined)
    return lowered == 'search' or lowered.startswith('search ')


class Block:
    __slots__ = ('role', 'rule', 'boxes', 'text')

    def __init__(self, role, rule, boxes, text=None):
        self.role, self.rule, self.boxes, self.text = role, rule, boxes, text


class Reading:
    """`blocks` in reading order, each with its role and the rule that set
    it, and the `stored` string built from them (stored_text)."""

    def __init__(self, blocks, stored, classified):
        self.blocks, self.stored, self.classified = blocks, stored, classified

    @property
    def main(self):
        return self.stored.split(CHROME_SEPARATOR, 1)[0]

    @property
    def rest(self):
        parts = self.stored.split(CHROME_SEPARATOR, 1)
        return parts[1] if len(parts) == 2 else ''


class Pane:
    """A rectangle of the window between separators, and its regions.
    `ruled`: the pane is one row of a ruled table (ruled_rows)."""
    __slots__ = ('rect', 'regions', 'ruled')

    def __init__(self, rect, regions, ruled=False):
        self.rect, self.regions, self.ruled = rect, regions, ruled


class Window:
    """The window being read, in frame pixels with a top-left origin."""

    def __init__(self, window, width, height, line_h):
        self.title = window.get('title') or ''
        self.terminal = window.get('bundle_id') in TERMINALS
        self.chat = window.get('bundle_id') in CHAT_APPS
        self.scale = window.get('pixels_per_point') or 1.0
        self.x0, self.y0, self.x1, self.y1 = window_rect(window, width, height)
        self.width, self.height = self.x1 - self.x0, self.y1 - self.y0
        self.top_band = self.y0 + min(TOP_BAND[0] * self.scale, TOP_BAND[1] * self.height)
        self.bottom_band = self.y1 - min(BOTTOM_BAND[0] * self.scale, BOTTOM_BAND[1] * self.height)
        self.line_h = line_h


def window_rect(window, width, height):
    x, y, w, h = window.get('rect') or (0.0, 0.0, 1.0, 1.0)
    return x * width, (1 - y - h) * height, (x + w) * width, (1 - y) * height


def centre_y(row):
    return sum(b.cy for b in row) / len(row)


def spread(row, line_h):
    """A row whose items stand far apart: a title at one end of a bar and its
    controls at the other."""
    return len(row) >= 2 and all(b.x0 - a.x1 >= SPREAD_GAP * line_h for a, b in zip(row, row[1:]))


class Region:
    """A region of a pane, with what the role rules ask of it worked out once."""
    __slots__ = ('boxes', 'rows', 'x0', 'x1', 'top', 'bottom', 'table')

    def __init__(self, boxes, table=False):
        self.boxes = boxes
        self.rows = rows(boxes)
        self.x0, self.x1 = min(b.x0 for b in boxes), max(b.x1 for b in boxes)
        self.top, self.bottom = min(b.y0 for b in boxes), max(b.y1 for b in boxes)
        # A table worth protecting has two rows or more; one row of short
        # items is how a bar looks to the cut.
        self.table = table and len(self.rows) >= 2


def wider_beside(region, everything, skip, win):
    """Whether something at least NAV_WIDER times as wide stands to the right
    of `region`, level with it."""
    for other in everything:
        if id(other) in skip:
            continue
        if (other.x0 >= region.x1 and other.x1 - other.x0 >= NAV_WIDER * (region.x1 - region.x0)
                and other.top < region.bottom and other.bottom > region.top):
            return True
    return False


def is_navigation(region, everything, skip, win):
    """A column of short items at the window's left edge, beside something
    wider. Never on the right, never code, never a table."""
    if region.table or len(region.rows) < NAV_MIN_ROWS:
        return False
    if region.x0 - win.x0 > NAV_EDGE * win.width or region.x1 - region.x0 > NAV_MAX_WIDTH * win.width:
        return False
    counts = [sum(len(words(b.text)) for b in row) for row in region.rows]
    if statistics.median(counts) > NAV_MAX_WORDS:
        return False
    texts = [' '.join(trim(b.text) for b in row) for row in region.rows]
    if sum(looks_like_code(t) for t in texts) > NAV_MAX_CODE * len(texts):
        return False
    return wider_beside(region, everything, skip, win)


def grid(row, below, line_h):
    """Whether `row` lines up with the row below it, item for item, as a
    table's rows do. A bar's items do not line up with what is under them."""
    if len(row) < 2 or len(below) < 2:
        return False
    reach = GRID_ALIGN * line_h
    lined = sum(1 for box in row if any(abs(box.x0 - other.x0) <= reach or abs(box.x1 - other.x1) <= reach
                                        for other in below))
    return lined >= 2


def caps_label(row):
    """A panel's title set in capitals (EXPLORER, CHAT, PROBLEMS), with icons
    beside it at most."""
    labels = [trim(b.text) for b in row if has_letter(b.text)]
    if not labels or any(len(''.join(words(b.text))) > GLYPH_MAX_CHARS and not has_letter(b.text) for b in row):
        return False
    for text in labels:
        letters = [ch for ch in text if unicodedata.category(ch).startswith('L')]
        if len(letters) < 2 or any(unicodedata.category(ch) != 'Lu' for ch in letters):
            return False
        if len(words(text)) > NAV_MAX_WORDS:
            return False
    return True


def preview_lists(regions, everything, win):
    """Ids of regions that make up a list of previews (other messages, other
    notes): a column of stacked regions where several lines are cut short,
    beside a wider column. A reading pane does not cut its own lines short."""
    found = set()
    i = 0
    while i < len(regions):
        column = [regions[i]]
        x0, x1 = regions[i].x0, regions[i].x1
        j = i + 1
        while j < len(regions):
            other = regions[j]
            if min(x1, other.x1) - max(x0, other.x0) < 0.5 * min(x1 - x0, other.x1 - other.x0):
                break
            column.append(other)
            x0, x1 = min(x0, other.x0), max(x1, other.x1)
            j += 1
        column_rows = [row for region in column for row in region.rows]
        cut_short = sum(1 for row in column_rows if truncated(' '.join(trim(b.text) for b in row)))
        if (not any(region.table for region in column) and len(column_rows) >= NAV_MIN_ROWS
                and cut_short >= PREVIEW_MIN and cut_short >= PREVIEW_SHARE * len(column_rows)):
            whole = Region([b for region in column for b in region.boxes])
            if wider_beside(whole, everything, {id(region) for region in column}, win):
                found.update(id(region) for region in column)
        i = j
    return found


def date_word(token):
    """A word of a date or a time: a weekday, a month, today, a clock time,
    a day of the month or a year."""
    word = token.strip(',.').lower()
    if word in DATE_WORDS:
        return True
    digits = word
    for suffix in ('st', 'nd', 'rd', 'th', 'am', 'pm'):
        if digits.endswith(suffix) and len(digits) > len(suffix):
            digits = digits[:-len(suffix)]
            break
    return bool(digits) and all(ch in DIGITS or ch in ':/.-' for ch in digits) and any(ch in DIGITS for ch in digits)


def date_line(row, pane):
    """A divider that says when: a short line, alone on its row, centred in
    its pane, made only of date and time words ("Today", "Oct 12 at 2:31 PM")."""
    if len(row) != 1:
        return False
    box = row[0]
    tokens = words(box.text)
    if not tokens or len(tokens) > DATE_MAX_WORDS or not all(date_word(t) for t in tokens):
        return False
    if not any(has_letter(t) for t in tokens) and not any(':' in t for t in tokens):
        return False  # numbers alone are data
    px0, _, px1, _ = pane.rect
    return abs(box.cx - (px0 + px1) / 2) <= DATE_CENTRE * (px1 - px0) and box.w <= 0.5 * (px1 - px0)


def is_bar(row, below, win, pane_top, panel, single, code=False, band_pane=False):
    """Whether a pane's top row is a bar: interface in a strip, marks only, a
    panel's title in capitals, or, for a pane of one row in the window's top
    band, a header (items at both ends) or a search field. Above code (`code`:
    the rows from this one down read as code) only a strip comes off: a short
    line of code ("};", "x = 1", "SELECT *") is not a bar. A row that lines
    up with the row below it is a table's header, not a bar, except in a pane
    that lies wholly in the window's top band (`band_pane`), where icons stand
    over their labels."""
    if below is not None and not band_pane and grid(row, below, win.line_h):
        return False  # a table's header lines up with the row below it
    top_band = centre_y(row) <= win.top_band
    if not (pane_top or top_band):
        return False
    # Only a row at the window's top edge can be its title bar.
    title = win.title if row_span(row)[0] <= win.y0 + TITLE_REACH * win.line_h else ''
    if code:
        return strip_shaped(row, title)
    alone = below is None and pane_top  # the only row of a pane between separators
    return (strip_shaped(row, title) or icon_row(row) or (panel and caps_label(row))
            or (alone and marks_row(row))
            or (single and top_band and (spread(row, win.line_h) or is_search(row) or is_placeholder(row))))


def classify(window_panes, tables, win):
    """[(role, rule, boxes, pane)] in reading order, for the regions of each
    pane."""
    regions = {id(pane): [Region(boxes, id(boxes) in tables) for boxes in pane.regions] for pane in window_panes}
    everything = [region for pane in window_panes for region in regions[id(pane)]]
    out = []
    for pane in window_panes:
        mine = regions[id(pane)]
        if not mine:
            continue
        if win.terminal:
            out.extend((CONTENT, 'content', region.boxes, pane) for region in mine)
            continue
        px0, py0, px1, py1 = pane.rect
        own = {id(region) for region in mine}
        # A pane of its own beside the rest is judged whole. Otherwise each
        # region is judged on its own.
        if px1 - px0 < win.width - 1 and not any(region.table for region in mine) and is_navigation(
                Region([b for region in mine for b in region.boxes]), everything, own, win):
            out.extend((CHROME, 'navigation', region.boxes, pane) for region in mine)
            continue
        navigation = preview_lists(mine, everything, win)
        navigation.update(id(region) for region in mine if is_navigation(region, everything, {id(region)}, win))
        # In a pane that is mostly navigation, a short line left over in the
        # navigation's column (a Compose button, a count, a page counter)
        # belongs with it. Short lines beside it (a note's heading) do not.
        nav_rows = sum(len(region.rows) for region in mine if id(region) in navigation)
        if navigation and nav_rows >= NAV_PANE_SHARE * sum(len(region.rows) for region in mine):
            nav_x1 = max(region.x1 for region in mine if id(region) in navigation)
            navigation.update(id(region) for region in mine if not region.table and len(region.rows) <= 2
                              and region.x0 < nav_x1
                              and all(len(words(' '.join(b.text for b in row))) <= 4 for row in region.rows))
        rest = [region for region in mine if id(region) not in navigation]
        home = {id(b): region for region in rest for b in region.boxes}
        lines = rows([b for region in rest for b in region.boxes])
        pane_top = py0 > win.y0 + 0.5 * win.line_h  # a separator above it
        # A panel: below the window's top and narrower than it, so its title
        # may be set in capitals. A document's heading in capitals is not a
        # panel's title.
        panel = pane_top and px1 - px0 < win.width - 1
        # Bars come off the top of a pane, one row at a time, until a row
        # reads as something else. A pane with no separator above it can only
        # have bars in the window's top band. A table's rows are never bars,
        # nor are rows between rules that line up as a table's do, except in
        # a pane that lies wholly in the top band (a title bar, a toolbar),
        # where icons over their labels line up the way a table's cells do.
        top = 0
        band_pane = py1 <= win.top_band
        while (not pane.ruled and top < len(lines)
               and (band_pane or not any(home[id(b)].table for b in lines[top]))
               and is_bar(lines[top], lines[top + 1] if top + 1 < len(lines) else None, win, pane_top, panel,
                          len(lines) == 1, top + 1 < len(lines) and is_code(lines[top:top + CODE_AHEAD], False),
                          band_pane)):
            top += 1
        # At the foot of a pane: a composer's placeholder, alone in its
        # region (a message that ends a run of messages is not one), or the
        # window's status bar.
        foot = None
        if not pane.ruled and top < len(lines) and not any(home[id(b)].table for b in lines[-1]):
            last = lines[-1]
            alone = all(len(home[id(b)].rows) == 1 for b in last)
            at_foot = py1 - row_span(last)[1] <= PLACEHOLDER_REACH * win.line_h
            if at_foot and alone and is_placeholder(last):
                foot = (CHROME, 'placeholder', last, pane)
            elif centre_y(last) >= win.bottom_band and strip_shaped(last, ''):
                foot = (CHROME, 'status', last, pane)
        moved = {id(b) for row in lines[:top] for b in row}
        if foot is not None:
            moved.update(id(b) for b in foot[2])
        out.extend((CHROME, 'bar', row, pane) for row in lines[:top])
        for region in mine:
            if id(region) in navigation:
                out.append((CHROME, 'navigation', region.boxes, pane))
                continue
            # A date line between messages divides them; it is not said.
            run = []
            for row in region.rows:
                row = [b for b in row if id(b) not in moved]
                if not row:
                    continue
                if win.chat and not region.table and date_line(row, pane):
                    if run:
                        out.append((CONTENT, 'content', [b for r in run for b in r], pane))
                        run = []
                    out.append((CHROME, 'date', row, pane))
                else:
                    run.append(row)
            if run:
                out.append((CONTENT, 'content', [b for r in run for b in r], pane))
        if foot is not None:
            out.append(foot)
    return out


# ----------------------------------------------------------------- assembly

def prepare(lines, min_confidence, width, height):
    """(placed boxes, unplaced texts), as the helper keeps them."""
    boxes, unplaced, positions = [], [], {}
    for line in lines:
        text = line['text'].replace('\x1e', '')
        confidence = line['confidence']
        if not (isinstance(confidence, (int, float)) and math.isfinite(confidence)
                and min_confidence <= confidence <= 1) or not trim(text):
            continue
        x, y, w, h = line['box']
        if not (all(math.isfinite(v) for v in (x, y, w, h)) and w > 0 and h > 0
                and x >= 0 and y >= 0 and x + w <= 1 and y + h <= 1):
            unplaced.append(text)
            continue
        # To pixels with a top-left origin, so gaps compare in one unit.
        box = Box(text, x * width, (1 - y - h) * height, (x + w) * width, (1 - y) * height)
        previous = positions.setdefault(text, [])
        if any(iou(other, box) >= 0.7 for other in previous):
            continue
        boxes.append(box)
        if len(previous) < DUPLICATE_POSITIONS:
            previous.append(box)
    return boxes, unplaced


def classifiable(window, width, height):
    if not window:
        return False
    scale = window.get('pixels_per_point') or 1.0
    x0, y0, x1, y1 = window_rect(window, width, height)
    return (x1 - x0) / scale >= MIN_WINDOW[0] and (y1 - y0) / scale >= MIN_WINDOW[1]


def render(boxes, left=None, flat=False, stacked=False):
    if left is None:
        left = min(b.x0 for b in boxes)
    return '\n'.join(render_rows(boxes, left, flat, stacked))


def pane_regions(boxes, seps, rect, line_h, tables=None):
    """[Pane] in reading order: the frame cut at its separators, each pane
    cut into regions; a ruled table's row stays whole."""
    window_panes = panes(boxes, seps, rect, line_h)
    ruled = ruled_rows(window_panes, line_h)
    out = []
    for i, (pane_rect, pane_boxes) in enumerate(window_panes):
        if not pane_boxes:
            out.append(Pane(pane_rect, []))
        elif i in ruled:
            out.append(Pane(pane_rect, [pane_boxes], ruled=True))
        else:
            out.append(Pane(pane_rect, cut(pane_boxes, line_h, tables)))
    return out


def unclassified(boxes, unplaced, seps, width, height, line_h):
    blocks = []
    for pane in pane_regions(boxes, seps, (0.0, 0.0, float(width), float(height)), line_h):
        for region in pane.regions:
            blocks.append(Block(CONTENT, 'content', region, render(region)))
    page = '\n\n'.join(block.text for block in blocks)
    stored = '\n'.join(([page] if page else []) + unplaced)
    if unplaced:
        blocks.append(Block(CONTENT, 'unplaced', [], '\n'.join(unplaced)))
    return Reading(blocks, stored, False)


def code_char_width(numbers, numbered, boxes):
    """The width of a character in the lines a gutter numbers: measured on
    the lines beside lone numbers, else on the lines numbers are glued to,
    else on every other box of four characters or more. The sidebar beside
    an editor is often set in a narrower face than its code."""
    for pool in ([b for b in numbered if id(b) not in numbers], [b for b in numbered if id(b) in numbers],
                 [b for b in boxes if id(b) not in numbers]):
        widths = [(b.x1 - b.x0) / len(trim(b.text)) for b in pool if len(trim(b.text)) >= 4]
        if widths:
            return statistics.median(widths)
    return 0.0


def without_gutter(boxes, line_h):
    """(boxes with line numbers taken out, the line numbers)."""
    numbers, numbered = gutter(boxes, line_h)
    if not numbers:
        return boxes, []
    char_w = code_char_width(numbers, numbered, boxes)
    kept, taken = [], []
    for box in boxes:
        entry = numbers.get(id(box))
        if entry is None:
            kept.append(box)
            continue
        _, rest = entry
        if rest:
            # Glued to its line, with the gap between them read as one space:
            # the line ends where the box ends and is as wide as its
            # characters, so it starts that far back from the right.
            digits = leading_number(trim(box.text))[0]
            digits_end = box.x0 + box.w * len(digits) / max(1, len(trim(box.text)))
            at = max(digits_end, box.x1 - len(rest) * char_w) if char_w else digits_end
            taken.append(Box(digits, box.x0, box.y0, digits_end, box.y1))
            kept.append(Box(rest, at, box.y0, box.x1, box.y1))
        else:
            taken.append(box)
    return kept, taken


def code_left_edges(roles, win):
    """Code regions stacked in one pane share their leftmost edge, so a blank
    line in code does not reset its indentation. {role index: left edge}."""
    code = [(i, pane, members) for i, (role, _, members, pane) in enumerate(roles)
            if role == CONTENT and is_code(rows(members), win.terminal)]
    edges = {}
    for i, pane, members in code:
        x0, x1 = min(b.x0 for b in members), max(b.x1 for b in members)
        edges[i] = min(min(b.x0 for b in other) for _, other_pane, other in code
                       if other_pane is pane and min(b.x0 for b in other) < x1 and max(b.x1 for b in other) > x0)
    return edges


def read(lines, *, min_confidence=0.5, width=2880, height=1800, separators=(), window=None):
    """The reading of engine `lines` ({text, confidence, box}).

    `separators` are the worker's pane separators. `window` is the geometry
    that turns on classification: {'rect': [x, y, w, h] of the window in the
    frame (normalized, bottom-left), 'pixels_per_point', 'title',
    'bundle_id'}. Without it the reading is unclassified, as it always was."""
    boxes, unplaced = prepare(lines, min_confidence, width, height)
    if not boxes:
        text = '\n'.join(unplaced)
        return Reading([Block(CONTENT, 'unplaced', [], text)] if text else [], text, False)
    line_h = statistics.median(b.h for b in boxes)
    seps = to_separators(separators, width, height)
    if not classifiable(window, width, height):
        return unclassified(boxes, unplaced, seps, width, height, line_h)

    win = Window(window, width, height, line_h)
    if win.terminal:
        # A terminal's text is its output: numbers counting down a column
        # (`history`) and a lone "y" are what it printed.
        kept, numbers, marks = boxes, [], []
    else:
        kept, numbers = without_gutter(boxes, line_h)
        marks = glyphs(kept, line_h)
        taken = {id(b) for b in marks}
        kept = [b for b in kept if id(b) not in taken]

    tables = set()
    window_panes = pane_regions(kept, seps, (win.x0, win.y0, win.x1, win.y1), line_h, tables)
    roles = classify(window_panes, tables, win) if any(p.regions for p in window_panes) else []
    edges = code_left_edges(roles, win)
    blocks = []
    for i, (role, rule, members, _) in enumerate(roles):
        if role == CONTENT and i in edges:
            text = render(members, edges[i], stacked=True)
        else:
            text = render(members, flat=True, stacked=True)
        blocks.append(Block(role, rule, members, text))
    if numbers:
        blocks.append(Block(CHROME, 'gutter', numbers,
                            ' '.join(trim(b.text) for b in sorted(numbers, key=lambda b: b.cy))))
    if marks:
        blocks.append(Block(CHROME, 'glyph', marks,
                            ' '.join(trim(b.text) for row in rows(marks) for b in row)))
    if not any(block.role == CONTENT for block in blocks) and not unplaced:
        # Nothing reads as content. When unsure, it is content: store the
        # reading unclassified.
        return unclassified(boxes, unplaced, seps, width, height, line_h)
    if unplaced:
        blocks.append(Block(CONTENT, 'unplaced', [], '\n'.join(unplaced)))
    return Reading(blocks, stored_text(blocks), True)


def stored_text(blocks):
    """Content blocks in reading order, then CHROME_SEPARATOR, then chrome
    blocks in reading order. Lines without a place end the content, one per
    line, as they always have."""
    main = '\n\n'.join(b.text for b in blocks if b.role == CONTENT and b.rule != 'unplaced')
    main = '\n'.join(([main] if main else []) + [b.text for b in blocks if b.rule == 'unplaced'])
    return main + CHROME_SEPARATOR + '\n\n'.join(b.text for b in blocks if b.role == CHROME)


def assemble(lines, *, min_confidence=0.5, width=2880, height=1800, separators=(), window=None):
    """The stored string for engine `lines` ({text, confidence, box})."""
    return read(lines, min_confidence=min_confidence, width=width, height=height,
                separators=separators, window=window).stored

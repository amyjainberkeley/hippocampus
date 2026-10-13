"""Parity fixtures that pin the capture helper's reading order and roles to
layout.py.

    python3 tools/ocr/screens/fixtures.py            write the fixtures
    python3 tools/ocr/screens/fixtures.py --check    exit 1 if any is stale

Each fixture is two files in
adapters/macos/MCICaptureHelper/Tests/Fixtures/OCRReadingOrder/:

  <name>.json          the input, in the format of the eight fixtures already
                       there ({width, height, lines: [{text, confidence, box}]}),
                       plus `separators` (the worker's pane separators,
                       [x, y, w, h] with one of w and h zero) and, when roles
                       are on, `window` ({rect, pixels_per_point, title,
                       bundle_id}; rect is [x, y, w, h], normalized, bottom-left).
  <name>.reading.json  the expected reading: `blocks` in reading order, each
                       {role, rule, text}; `stored`, the string the helper
                       stores; `plain`, the stored string for the same lines
                       and separators without a window (no roles, no
                       separator); `classified`.

The eight committed fixtures (<name>.expected.txt) are never written here.
The windows come from boxes/ (real OCR of the mock windows); the rest are
small cases, one or two per rule, and the characters the two languages read
differently: U+001E, U+001F, NBSP, Devanagari and superscripts. All text is
made up.
"""
import argparse
import json
import sys
from pathlib import Path

SCREENS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCREENS))
import bench  # noqa: E402
import layout  # noqa: E402

FOLDER = SCREENS.parents[2] / 'adapters/macos/MCICaptureHelper/Tests/Fixtures/OCRReadingOrder'
W, H = 2880, 1800
WINDOW = {'rect': [0.0, 0.0, 1.0, 1.0], 'pixels_per_point': 2.0, 'title': 'Weekly review',
          'bundle_id': 'com.example.notes'}
WINDOWS = ['editor', 'chat', 'mail', 'article', 'video', 'notes', 'messages',
           'issue_properties', 'order_summary', 'todo_beside_notes', 'fullscreen_doc']


def line(text, x, y, w, h=30, confidence=0.95):
    """A line box from top-left pixels of a 2880 x 1800 frame."""
    return {'text': text, 'confidence': confidence,
            'box': [round(x / W, 6), round(1 - (y + h) / H, 6), round(w / W, 6), round(h / H, 6)]}


def vertical(x, top=0, bottom=H):
    return [round(x / W, 6), round(1 - bottom / H, 6), 0.0, round((bottom - top) / H, 6)]


def horizontal(y, left=0, right=W):
    return [round(left / W, 6), round(1 - y / H, 6), round((right - left) / W, 6), 0.0]


def prose(x=700, y=300, count=4, width=1500, pitch=48):
    return [line(f'Paragraph line {i} with enough words to read as prose.', x, y + i * pitch, width)
            for i in range(count)]


def case(lines, separators=(), window=WINDOW):
    data = {'width': W, 'height': H, 'lines': lines, 'separators': list(separators)}
    if window is not None:
        data['window'] = window
    return data


def editor(glued=False):
    code = ['fn main() {', '    let x = 1;', '    if x > 0 {', '        run(x);', '    }', '}']
    lines = []
    for i, text in enumerate(code):
        y = 200 + i * 40
        indent = (len(text) - len(text.lstrip())) * 15
        number = str(i + 1)
        if glued and not indent:
            start = 610 - 15 * len(number)
            lines.append(line(f'{number} {text}', start, y, 640 + 15 * len(text) - start))
        else:
            lines.append(line(number, 610 - 15 * len(number), y, 15 * len(number)))
            lines.append(line(text.lstrip(), 640 + indent, y, 15 * len(text.lstrip())))
    return lines


def small_cases():
    """{name: input} for one or two cases per rule."""
    cases = {}
    row = lambda items, y: [line(text, x, y, w) for text, x, w in items]  # noqa: E731
    cases['rule_glyph'] = case(
        row([('D', 60, 30), ('Inbox', 300, 120)], 40) + row([('D', 60, 30), ('Drafts', 100, 120)], 100)
        + row([('Ok', 60, 34)], 160) + row([('}', 60, 30)], 220)
        + row([('Estimate', 60, 150), ('3', 300, 24)], 280) + prose(y=400))
    cases['rule_glyph_icons_together'] = case(
        row([('Ask a question', 600, 300), ('e', 2500, 30), ('A', 2532, 30)], 1500) + prose())
    cases['rule_glyph_number_column'] = case(
        [line(str(n), 700, 300 + i * 50, 30) for i, n in enumerate([1, 2, 3])]
        + [line(str(v), 1100, 300 + i * 50, 80) for i, v in enumerate([212, 240, 236])] + prose(y=500))
    cases['rule_gutter'] = case(editor())
    cases['rule_gutter_glued'] = case(editor(glued=True))
    cases['rule_gutter_plain'] = case(editor(), window=None)
    cases['rule_gutter_not_a_table_column'] = case(
        [line(str(i + 1), 700, 300 + i * 50, 20) for i in range(4)]
        + [line(f'{200 + i * 13} sessions in week {i + 1}', 1300, 300 + i * 50, 500) for i in range(4)]
        + prose(y=600))
    sidebar_and_page = ([line(name, 40, 200 + i * 44, 150) for i, name in enumerate(['Inbox', 'Drafts', 'Sent', 'Trash'])]
                        + [line(f'The page says something long enough to be read {i}.', 230, 200 + i * 44, 1500)
                           for i in range(4)])
    cases['rule_pane_cut'] = case(sidebar_and_page, [vertical(210)], window=None)
    cases['rule_pane_crossed'] = case(
        sidebar_and_page + [line('A title written right across the panes', 100, 100, 1000)], [vertical(210)],
        window=None)
    cases['rule_pane_bars_first'] = case(
        [line('A wide title bar that spans both panes below', 100, 20, 2000)] + sidebar_and_page,
        [horizontal(80), vertical(210, 80)], window=None)
    grid = []
    for i, (name, stage) in enumerate([('Acme', 'Won'), ('Blue', 'Lost'), ('Cedar', 'Open')]):
        grid += [line(name, 300, 300 + i * 50, 120), line(stage, 900, 300 + i * 50, 100)]
    cases['rule_pane_gridlines'] = case(grid, [vertical(800, 280, 460)], window=None)
    cases['rule_b1_one_sided_table'] = case(
        [line(f'Item {i}', 100, 200 + i * 40, 120) for i in range(12)] + [line('Note', 600, 200, 80)], window=None)
    thread = [('in', 'Are we still on for 3?'), ('out', 'Yes, running five minutes late'),
              ('in', 'See you there'), ('out', 'Already in my bag')]
    cases['rule_b2_bubbles'] = case(
        [line(text, 200 if side == 'in' else 1700, 300 + i * 90, 600) for i, (side, text) in enumerate(thread)])
    cases['rule_b2_columns'] = case(
        [line(f'Main column line {i} with words', 100, 200 + i * 37, 900) for i in range(13)]
        + [line(f'Rail {i}', 1600, 200 + i * 45, 200) for i in range(15)])
    form = [line(t, 100, 300 + i * 60, 500) for i, t in enumerate(
        ['Shipping address', 'Sam Rivera', '41 Harbor Street', 'Portland, OR 97209', 'Visa ending in 4242'])]
    summary = [line('Order summary', 1500, 300, 260)]
    for i, (label, amount) in enumerate([('Notebook', '$18.00'), ('Pens', '$28.00'), ('Total', '$46.00')]):
        summary += [line(label, 1500, 360 + i * 60, 200), line(amount, 2200, 360 + i * 60, 120)]
    cases['rule_table_beside_form'] = case(form + summary)
    cases['rule_bars_top'] = case(
        [line('Weekly review', 100, 10, 200), line('Launch plan', 600, 10, 200), line('Recipes', 1100, 10, 200),
         line('docs.example.com/weekly-review', 100, 70, 700)] + prose(y=200))
    cases['rule_bar_truncated_tab'] = case(
        [line('Per-seat or tiered? How to p... X', 100, 10, 500), line('Stripe Docs', 700, 10, 200)] + prose(y=200))
    cases['rule_bar_title_breadcrumb'] = case(
        [line('Workspace / Weekly review', 900, 20, 400), line('Share', 2600, 20, 100)] + prose(y=200))
    cases['rule_bar_sentence_stays'] = case(
        [line('which is why the pilot ran for four weeks instead of two.', 700, 10, 1200)] + prose(y=200))
    header = []
    for i, cells in enumerate([('Week', 'Sessions', 'Questions'), ('One', '212', '48'), ('Two', '240', '61')]):
        header += [line(cell, 700 + j * 400, 20 + i * 50, 150) for j, cell in enumerate(cells)]
    cases['rule_bar_table_header_stays'] = case(header + prose(y=300))
    cases['rule_status_bar'] = case(
        prose() + [line(t, 100 + i * 400, 1765, 200) for i, t in enumerate(['main', 'Ln 9, Col 34', 'UTF-8', 'Rust'])])
    cases['rule_last_line_stays'] = case(
        prose() + [line('Retention fell to 61 percent in week three, then recovered.', 700, 1760, 1200)])
    cases['rule_placeholder'] = case(prose() + [line('Message #launch-plan', 700, 1700, 400)])
    cases['rule_placeholder_trailing_message_stays'] = case(
        prose(y=1400, count=6, pitch=48) + [line('Let me check\u2026', 700, 1690, 300)])
    side = [line(name, 40, 200 + i * 44, 180) for i, name in enumerate(['Inbox', 'Starred', 'Sent', 'Drafts'])]
    cases['rule_navigation_left'] = case(side + prose(x=700))
    cases['rule_navigation_right_stays'] = case(
        prose(x=100, width=1500) + [line(name, 2500, 200 + i * 44, 180)
                                     for i, name in enumerate(['Inbox', 'Starred', 'Sent', 'Drafts'])])
    cases['rule_navigation_todo_stays'] = case(
        [line(t, 640, 300 + i * 44, 300) for i, t in enumerate(
            ['To do', 'Book the venue', 'Email the caterer', 'Print the badges'])] + prose(x=1100, width=1600))
    previews = []
    for i, (who, snippet) in enumerate([('Dana', 'Hi Sam, phase two is wrapped up. The invoice is\u2026'),
                                        ('Ravi', 'Seat minimums: I would say three. Anything lower\u2026'),
                                        ('Jonas', 'Recall is down to 41 ms. Details in the doc\u2026')]):
        previews += [line(who, 520, 200 + i * 130, 120), line(snippet, 520, 245 + i * 130, 600)]
    cases['rule_preview_list'] = case(previews + prose(x=1400, width=1400))
    cases['rule_date_line'] = case(
        prose(x=200, count=3) + [line('Today 9:30 AM', 1340, 460, 200)] + prose(x=200, y=520, count=3))
    cases['rule_date_line_numbers_stay'] = case(
        prose(x=200, count=3) + [line('212', 1400, 460, 80)] + prose(x=200, y=520, count=3))
    cases['rule_caps_panel'] = case(
        prose(x=100, width=1700) + [line('CHAT', 2200, 200, 80)]
        + [line(f'Message {i} in the chat panel.', 2200, 260 + i * 44, 500) for i in range(4)],
        [horizontal(150), vertical(2100, 150)])
    cases['rule_caps_document_stays'] = case([line('AGENDA', 700, 200, 150)] + prose(y=260), [horizontal(150)])
    cases['rule_terminal'] = case(
        [line('$ cargo test', 40, 20, 180), line('Compiling mci v0.3.0', 100, 60, 300),
         line('test result: ok. 6 passed', 40, 100, 375)], window=dict(WINDOW, bundle_id='com.apple.Terminal'))
    cases['rule_code_blank_line'] = case(
        [line('impl Store {', 700, 200, 180), line('fn open() {}', 760, 240, 180),
         line('fn close() {}', 760, 340, 195), line('}', 700, 380, 15)])
    cases['rule_stacked_layers'] = case(
        [line('Dana Whitfield <dana@northwind.example>', 1514, 335, 512, 35), line('11:02 AM', 2602, 352, 226, 40),
         line('to me', 1512, 374, 80, 36)] + prose(x=1500, y=500, width=1300))
    cases['rule_small_window'] = case(prose(x=10, y=10, width=500),
                                      window=dict(WINDOW, rect=[0.0, 0.0, round(600 / W, 6), round(400 / H, 6)]))
    cases['rule_nothing_is_content'] = case(
        [line(t, 100 + i * 500, 20, 300) for i, t in enumerate(['Inbox', 'Drafts', 'Sent', 'Archive'])])
    cases['rule_unplaced'] = case(prose() + [{'text': 'a line with no box', 'confidence': 0.9,
                                              'box': [0.5, 0.5, 0.6, 0.1]}])
    # A window read from the whole screen: its rect sits away from the
    # frame's corner, and its left edge and top band are its own.
    rect = [round(1000 / W, 6), round(1 - 1500 / H, 6), round(1800 / W, 6), round(1100 / H, 6)]
    cases['rule_whole_screen_window'] = case(
        [line(t, 1040 + i * 420, 410, 300) for i, t in enumerate(['Weekly review', 'Launch plan', 'Recipes'])]
        + [line(name, 1020, 520 + i * 44, 160) for i, name in enumerate(['Inbox', 'Starred', 'Sent', 'Drafts'])]
        + prose(x=1500, y=520, width=1200), window=dict(WINDOW, rect=rect))
    cases['rule_deep_code_gutter'] = case(
        [box for i, text in enumerate(['let a = load(path)?;', 'let b = parse(&a)?;', 'store.put(b)?;', 'Ok(())'])
         for box in (line(str(40 + i), 580, 200 + i * 40, 30), line(text, 760, 200 + i * 40, 15 * len(text)))])
    cases['text_record_separator'] = case(
        [line('pay\x1eroll report for the quarter', 700, 300, 900), line('\x1e', 700, 360, 30)] + prose(y=420))
    cases['text_unit_separator'] = case([line('a\x1fb is one word', 700, 300, 400)] + prose(y=400))
    cases['text_nbsp'] = case(
        [line('\u00a0Invoice\u00a04471\u00a0', 700, 300, 400), line('\u00a0', 700, 360, 30)] + prose(y=420))
    cases['text_devanagari'] = case(
        [line('\u0905\u0928\u0941\u092e\u093e\u0928', 60, 200, 150), line('3', 300, 200, 24),
         line('\u0938\u094d\u0915\u094d\u0930\u0940\u0928 \u092a\u0930 \u0915\u094d\u092f\u093e \u0939\u0948', 700, 300, 600)]
        + prose(y=400))
    supers = []
    for i, mark in enumerate(['\u00b9', '\u00b2', '\u00b3', '\u2074']):
        supers += [line(mark, 600, 200 + i * 40, 15), line(f'Footnote {i + 1} says something about the text.', 640,
                                                             200 + i * 40, 600)]
    cases['text_superscripts'] = case(supers)
    return cases


def window_cases():
    out = {}
    scenes = {scene['name']: scene for scene in bench.all_scenes()}
    for name in WINDOWS:
        boxes = bench.load_boxes(name)
        out[f'window_{name}'] = {'width': boxes['width'], 'height': boxes['height'], 'lines': boxes['lines'],
                                 'separators': boxes['separators'], 'window': bench.geometry(scenes[name], boxes)}
    return out


def expected(data):
    reading = layout.read(data['lines'], width=data['width'], height=data['height'],
                          separators=data.get('separators', []), window=data.get('window'))
    plain = layout.assemble(data['lines'], width=data['width'], height=data['height'],
                            separators=data.get('separators', []))
    return {'classified': reading.classified,
            'blocks': [{'role': b.role, 'rule': b.rule, 'text': b.text} for b in reading.blocks],
            'stored': reading.stored, 'plain': plain}


def dumps(data):
    # ASCII with escapes, so U+001E, NBSP and the rest are visible in review.
    return json.dumps(data, ensure_ascii=True, indent=1) + '\n'


def all_cases():
    cases = small_cases()
    cases.update(window_cases())
    return cases


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true', help='report stale fixtures instead of writing them')
    args = parser.parse_args()
    stale = []
    for name, data in sorted(all_cases().items()):
        files = {FOLDER / f'{name}.json': dumps(data), FOLDER / f'{name}.reading.json': dumps(expected(data))}
        for path, text in files.items():
            if args.check:
                if not path.exists() or path.read_text(encoding='utf-8') != text:
                    stale.append(path.name)
            else:
                path.write_text(text, encoding='utf-8')
    if stale:
        print('stale:', ' '.join(stale))
        return 1
    print('checked' if args.check else 'wrote', len(all_cases()), 'fixtures')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

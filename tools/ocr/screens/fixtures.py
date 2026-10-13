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
The windows come from boxes/ (real OCR of the mock windows), and
window_editor_scrolled is the editor with its code pane scrolled to line 7.
The rest are small cases, one or two per rule, and the characters the two
languages read differently: U+001E, U+001F, NBSP, Devanagari and
superscripts. test_layout.py reads the same inputs, so a test and its fixture
cannot drift apart. All text is made up.
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
           'issue_properties', 'order_summary', 'todo_beside_notes', 'fullscreen_doc', 'receipt', 'invitation']


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


CHAT_WINDOW = dict(WINDOW, title='launch-plan', bundle_id='com.tinyspeck.slackmacgap')
EDITOR_WINDOW = dict(WINDOW, title='store.rs - project', bundle_id='com.microsoft.VSCode')
TERMINAL_WINDOW = dict(WINDOW, title='zsh', bundle_id='com.apple.Terminal')


def code_lines(code, x, y, pitch=40, char_w=15):
    """Lines of code as an editor shows them: each box starts at its indent."""
    out = []
    for i, text in enumerate(code):
        stripped = text.lstrip(' ')
        if stripped:
            out.append(line(stripped, x + (len(text) - len(stripped)) * char_w, y + i * pitch, char_w * len(stripped)))
    return out


def tab_strip(y=150):
    return [line('store.rs', 700, y, 150), line('main.rs', 900, y, 150), line('lib.rs', 1100, y, 120)]


def finder_columns():
    """Two lists side by side, a file browser's columns: one row pitch, unequal lengths."""
    left = [line(n, 60, 200 + i * 44, 220) for i, n in enumerate(
        ['Applications', 'Desktop', 'Documents', 'Downloads', 'Movies', 'Music'])]
    right = [line(n, 760, 200 + i * 44, 300) for i, n in enumerate(
        ['Invoice 4471.pdf', 'Contract v3.docx', 'Pricing notes.pages', 'Receipt.pdf', 'Budget.numbers'])]
    return left + right


TREE_CODE = ['fn main() {', '    let x = 1;', '    if x > 0 {', '        run(x);', '    }', '}']


def tree_beside_code():
    """A file tree beside short lines of code at the same pitch."""
    tree = [line(n, 40, 300 + i * 40, 11 * len(n)) for i, n in enumerate(
        ['brain_ingest.rs', 'retention_worker.rs', 'today.rs', 'understanding.rs', 'install.sh', 'Cargo.toml',
         'README.md'])]
    return tree + code_lines(TREE_CODE, 640, 300, char_w=16)


def form_beside_summary():
    """A checkout form beside an order summary whose rows line up with it,
    on a page with a margin."""
    form = [line(t, 300, 300 + i * 44, 500) for i, t in enumerate(
        ['Shipping address', 'Sam Rivera', '41 Harbor Street', 'Portland, OR 97209', 'Visa ending in 4242'])]
    summary = [line('Order summary', 1500, 300, 260)]
    for i, (label, amount) in enumerate([('Notebook', '$18.00'), ('Pens', '$28.00'), ('Total', '$46.00')]):
        summary += [line(label, 1500, 344 + i * 44, 200), line(amount, 2200, 344 + i * 44, 120)]
    return form + summary


def table_with_title_and_wrapped_cell():
    """A table whose first column carries its title above it and a cell that
    wraps: neither has a partner in the other columns, and both are the
    table's own."""
    cells = [('Account', 'Stage', 'Owner'), ('Acme Robotics,', 'Won', 'Chen'), ('Blue Harbor', 'Lost', 'Patel'),
             ('Cedar Labs', 'Open', 'Weber'), ('Delta Foods', 'Won', 'Chen')]
    out = [line('Q3 pipeline', 700, 250, 165)]
    y = 300
    for i, row in enumerate(cells):
        out += [line(cell, x, y, 15 * len(cell)) for cell, x in zip(row, (700, 1300, 1700))]
        if i == 1:
            y += 30
            out.append(line('west region', 700, y, 165))
        y += 44
    return out + prose(y=y + 60)


def ruled_receipt():
    """A receipt: label left, amount right, each row between rules that span
    the window. (lines, separators)"""
    items = [('Linen notebook', '$18.00'), ('Brass pen x 2', '$28.00'), ('Shipping', '$5.00'), ('Total', '$51.00')]
    lines = [line('Thanks for your order. Here is your receipt.', 200, 300, 660)]
    separators = []
    for i, (label, amount) in enumerate(items):
        y = 500 + i * 100
        separators.append(horizontal(y - 30))
        lines += [line(label, 200, y, 15 * len(label)), line(amount, 2400, y, 15 * len(amount))]
    separators.append(horizontal(500 + len(items) * 100 - 30))
    lines.append(line('Questions? Write to us any time and we will help.', 200, 1000, 735))
    return lines, separators


def ruled_sheet():
    """A spreadsheet whose horizontal gridlines span the window. (lines, separators)"""
    lines = [line('Q3 pipeline', 60, 30, 220, 26)] + [
        line(t, x, 80, 15 * len(t), 26) for t, x in (('File', 60), ('Edit', 160), ('View', 260), ('Insert', 360),
                                                       ('Format', 480), ('Data', 610))]
    lines.append(line('Acme Robotics', 200, 200, 195, 26))     # the formula bar shows the selected cell
    separators = [horizontal(170), horizontal(240), horizontal(300)]
    lines += [line(c, x, 262, 20, 26) for c, x in zip('ABCD', [300, 800, 1300, 1800])]
    table = [('Account', 'Stage', 'Owner', 'ARR'), ('Acme Robotics', 'Negotiation', 'M. Chen', '184000'),
             ('Blue Harbor', 'Proposal', 'R. Patel', '92500'), ('Cedar Labs', 'Closed won', 'J. Weber', '40000'),
             ('Delta Foods', 'Discovery', 'M. Chen', '12000'), ('Elm Street Cafe', 'Negotiation', 'R. Patel', '8000')]
    for r, cells in enumerate(table):
        y = 320 + r * 50
        lines.append(line(str(r + 1), 30, y, 15 * len(str(r + 1)), 26))
        lines += [line(cell, x, y, 15 * len(cell), 26) for cell, x in zip(cells, (600, 1100, 1600, 2100))]
        separators.append(horizontal(y + 38))
    lines.append(line('Sheet1', 120, 1760, 90, 26))
    return lines, separators


def chat_with_composer(last):
    """A chat scrolled to its foot, the composer in a box of its own below a
    rule; `last` is the last message. (lines, separators)"""
    lines = [line('Maya Chen 10:42 AM', 700, 1300, 270), line('Pushed the new onboarding flow to staging.', 700, 1340, 630),
             line('Ravi Patel 10:47 AM', 700, 1440, 285), line(last, 700, 1480, 15 * len(last)),
             line('Message #launch-plan', 700, 1700, 300)]
    return lines, [horizontal(1600)]


def note_ending(last):
    """A note whose last item sits alone near the window's foot."""
    items = ['Open loops', 'Send Jonas the benchmark doc.', 'Book the venue for the launch.']
    return [line(t, 700, 1400 + i * 44, 15 * len(t)) for i, t in enumerate(items)] + [
        line(last, 700, 1720, 15 * len(last))]


def note_beside_folders():
    """A short note beside a long folder list, in one pane."""
    folders = ['All iCloud', 'Notes', 'Launch', 'Personal', 'Work', 'Travel', 'Recipes', 'Reading', 'Ideas',
               'Archive', 'Shared', 'Recently Deleted']
    return [line(n, 40, 300 + i * 50, 15 * len(n)) for i, n in enumerate(folders)] + [
        line('Dentist on Friday', 700, 300, 400, 44),
        line('Bring the insurance card and the forms from last year,', 700, 420, 810),
        line('and leave by 8:15 so there is time to park.', 700, 460, 660), line('Call Ravi', 700, 560, 135)]


def folders_with_compose():
    """A long folder list with a Compose button above it, in one pane beside
    three lines of a page."""
    folders = ['All iCloud', 'Notes', 'Launch', 'Personal', 'Work', 'Travel', 'Recipes', 'Reading', 'Ideas',
               'Archive', 'Shared', 'Recently Deleted']
    return ([line('Compose', 40, 200, 105)] + [line(n, 40, 300 + i * 50, 15 * len(n)) for i, n in enumerate(folders)]
            + [line(f'The page says something long enough to be read {i}.', 700, 300 + i * 44, 765) for i in range(3)])


def sidebar_pane():
    """A sidebar with counts in a pane of its own, beside a page. (lines, separators)"""
    names, counts = ['Inbox', 'Starred', 'Snoozed', 'Sent', 'Drafts'], ['12', '3', '', '', '1']
    lines = [line(n, 40, 200 + i * 44, 15 * len(n)) for i, n in enumerate(names)]
    lines += [line(c, 330, 200 + i * 44, 15 * len(c)) for i, c in enumerate(counts) if c]
    return lines + prose(x=700, y=200), [vertical(400)]


def glued_gutter_mixed_fonts():
    """Line numbers glued to unindented code set in a 16-pixel face, beside a
    sidebar set in an 11-pixel face. (lines, separators)"""
    lines = []
    for i, text in enumerate(TREE_CODE):
        y, stripped = 300 + i * 40, text.lstrip()
        indent, number = (len(text) - len(stripped)) * 16, str(i + 1)
        if not indent:
            start = 640 - 16 * (len(number) + 1)
            lines.append(line(f'{number} {stripped}', start, y, 640 + 16 * len(stripped) - start))
        else:
            lines.append(line(number, 640 - 16 * (len(number) + 2), y, 16 * len(number)))
            lines.append(line(stripped, 640 + indent, y, 16 * len(stripped)))
    side = [line(n, 40, 300 + i * 40, 11 * len(n)) for i, n in enumerate(
        ['brain_ingest.rs', 'retention_worker.rs', 'today.rs', 'understanding.rs', 'install.sh', 'Cargo.toml',
         'README.md'])]
    return side + lines, [vertical(400)]


def terminal_history():
    """`history` in a terminal: numbers counting up a column, glued to the
    commands, then a prompt answered with a lone "y"."""
    commands = ['cargo build', 'cargo test -p mci-brain', 'git status', 'git diff --stat', 'ls -la']
    lines = [line('$ history', 40, 20, 135)]
    lines += [line(f'{501 + i}  {c}', 40, 60 + i * 40, 15 * (len(c) + 5)) for i, c in enumerate(commands)]
    lines += [line('$ cargo clean', 40, 260, 195), line('Remove the build folder? [y/N]', 40, 300, 450),
              line('y', 40, 340, 30)]
    return lines


def toolbar_icons_over_labels():
    """A title bar and a toolbar of icons over their labels, cut off from the
    page below by a separator. (lines, separators)"""
    names = ['View', 'Zoom', 'Insert', 'Table', 'Chart', 'Text', 'Shape']
    lines = [line('Launch party', 1340, 8, 180, 40)]
    lines += [line('0', 40 + i * 200, 66, 46, 44) for i in range(len(names))]
    lines += [line(n, 30 + i * 200, 106, 15 * len(n), 37) for i, n in enumerate(names)]
    return lines + prose(x=900, y=600), [horizontal(160)]


def invitation():
    """An invitation: centred lines, one of them its date."""
    return [line('You are invited to the launch party', 894, 773, 1086, 89),
            line('Saturday, October 21 at 7 PM', 1188, 900, 504, 52),
            line('41 Harbor Street, Portland', 1210, 980, 458, 47),
            line('Bring a friend. Dinner and drinks are on us.', 1068, 1109, 744, 52),
            line('Reply to Maya by October 18.', 1188, 1187, 504, 53)]


def review_cases():
    """Cases for the rules a review of the first port found wrong or
    untested, one or two per rule."""
    cases = {}
    # Bars: a short line of code at the top of a pane is code.
    scrolled = ['    };', '    let mut deleted = 0_u64;', '    for batch in store.batches() {',
                '        deleted += store.delete(batch)?;', '    }', '    Ok(deleted)', '}']
    cases['rule_bar_code_first_line'] = case(tab_strip() + code_lines(scrolled, 700, 300), [horizontal(200)],
                                             window=EDITOR_WINDOW)
    cases['rule_bar_json_first_line'] = case(
        tab_strip() + code_lines(['{', '  "name": "hippocampus",', '  "private": true', '}'], 700, 300),
        [horizontal(200)], window=EDITOR_WINDOW)
    cases['rule_bar_python_first_line'] = case(code_lines(['x = 1', 'y = compute(x)', 'print(y)'], 700, 60),
                                               window=EDITOR_WINDOW)
    sql = ['SELECT *', 'FROM events', 'WHERE ts > now() - 86400', 'ORDER BY ts DESC;']
    cases['rule_bar_sql_caps_first_line'] = case(
        [line(n, 40, y, 15 * len(n)) for n, y in (('EXPLORER', 100), ('query.sql', 160), ('schema.sql', 200),
                                                   ('notes.md', 240))]
        + [line('query.sql', 700, 100, 135), line('schema.sql', 900, 100, 150)] + code_lines(sql, 700, 200),
        [vertical(600), horizontal(150, 600)], window=dict(EDITOR_WINDOW, title='query.sql - project'))
    # Bars: rows between rules that line up are a table's.
    lines, separators = ruled_receipt()
    cases['rule_ruled_receipt'] = case(lines, separators, window=dict(WINDOW, title='Your receipt',
                                                                      bundle_id='com.apple.mail'))
    cases['rule_ruled_receipt_plain'] = case(lines, separators, window=None)
    lines, separators = ruled_sheet()
    cases['rule_ruled_sheet'] = case(lines, separators, window=dict(WINDOW, title='Q3 pipeline - Sheets',
                                                                    bundle_id='com.google.Chrome'))
    cases['rule_header_below_top_band_stays'] = case(
        prose(y=300) + [line('Total due', 200, 760, 135), line('$2,300.00', 2400, 760, 135)] + prose(y=900),
        [horizontal(720), horizontal(820)])
    # Bars that the first port had no small case for.
    cases['rule_marks_row'] = case([line('A sentence of the page below the bar.', 700, 200, 555),
                                    line('0 ≡', 2600, 70, 60)] + prose(y=300))
    cases['rule_letter_buttons'] = case(
        prose() + [line('BIS', 700, 1610, 120, 40), line('e', 830, 1615, 32, 32),
                   line('Message #launch-plan', 700, 1700, 300)], [horizontal(1600), horizontal(1670)])
    cases['rule_header_bar'] = case([line('# launch-plan', 700, 100, 195), line('14 members', 2500, 100, 150)]
                                    + prose(y=260), [horizontal(60), horizontal(170)])
    cases['rule_search_field'] = case([line('Search mail', 900, 90, 165)] + prose(y=260),
                                      [horizontal(60), horizontal(170)])
    close_set = []
    for i, row in enumerate([('Account', 'Stage', 'Owner'), ('Acme', 'Won', 'Chen'), ('Blue', 'Lost', 'Patel')]):
        close_set += [line(cell, 700 + j * 180, 20 + i * 44, 150) for j, cell in enumerate(row)]
    cases['rule_close_set_table_header'] = case(close_set + prose(y=300))
    cases['rule_title_bar'] = case([line('Weekly review', 1300, 12, 195)] + prose(y=200))
    cases['rule_title_heading_stays'] = case(prose(y=60, count=2) + [line('Weekly review', 700, 200, 195)]
                                             + prose(y=260))
    lines, separators = toolbar_icons_over_labels()
    cases['rule_toolbar_icons_over_labels'] = case(lines, separators, window=dict(WINDOW, title='Launch party'))
    # Panes: two lists side by side are panes; B2 with offset rows.
    side = [line(n, 40, 200 + i * 44, 15 * len(n)) for i, n in enumerate(['Inbox', 'Drafts', 'Sent', 'Trash', 'Spam'])]
    page = [line(f'The page says something long enough to be read {i}.', 400, 222 + i * 44, 765) for i in range(5)]
    cases['rule_b2_offset_columns'] = case(side + page, window=None)
    # Glyphs: two letters alone are an icon; a column of them is data.
    cases['rule_glyph_letter_pair'] = case(prose() + [line('TR', 2600, 348, 36)])
    codes = []
    for i, (city, code) in enumerate([('Portland', 'OR'), ('Seattle', 'WA'), ('Austin', 'TX'), ('Denver', 'CO')]):
        codes += [line(city, 700, 300 + i * 44, 15 * len(city)), line(code, 1200, 300 + i * 44, 32)]
    cases['rule_glyph_letter_pair_column'] = case(codes + prose(y=600))
    # Foot: a message or a note's last item is not a composer.
    lines, separators = chat_with_composer('Reply when you can, no rush')
    cases['rule_placeholder_last_message_stays'] = case(lines, separators, window=CHAT_WINDOW)
    cases['rule_placeholder_note_last_item_stays'] = case(note_ending('Search for a bigger venue.'))
    # Navigation.
    cases['rule_navigation_beside_stays'] = case(note_beside_folders(), window=dict(WINDOW, title='Notes'))
    cases['rule_navigation_leftover'] = case(folders_with_compose(), window=dict(WINDOW, title='Notes'))
    lines, separators = sidebar_pane()
    cases['rule_navigation_pane'] = case(lines, separators, window=dict(WINDOW, title='Inbox'))
    # Gutter: a glued line is placed by its own face; digits are kept as read.
    lines, separators = glued_gutter_mixed_fonts()
    cases['rule_gutter_glued_mixed_fonts'] = case(lines, separators, window=dict(EDITOR_WINDOW, title='main.rs'))
    cases['rule_gutter_digits_as_read'] = case(
        [line(text, 580, 200 + i * 40, 20 * len(text))
         for i, text in enumerate(f'{n:03d} let v{n} = {n};' for n in [7, 8, 9, 10])])
    # A terminal's output stays: numbers and a lone "y" are what it printed.
    cases['rule_terminal_numbered'] = case(terminal_history(), window=TERMINAL_WINDOW)
    # Outside code, an offset under four characters is not an indent.
    cases['rule_flat_small_offset'] = case(
        [line('To do', 640, 300, 75), line('Book the venue', 678, 344, 210), line('Email the caterer', 678, 388, 255),
         line('Print the badges', 640, 432, 240), line('Call Ravi about pricing', 640, 476, 345)]
        + prose(x=1300, y=300, width=1300))
    return cases


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
    # The gridline spans the frame, so it is a candidate cut; the rows pair
    # one to one, so it is a table's gridline and not a pane edge.
    cases['rule_pane_gridlines'] = case(grid, [vertical(800)], window=None)
    cases['rule_pane_columns_side_by_side'] = case(finder_columns(), [vertical(700), vertical(1400)],
                                                   window=dict(WINDOW, title='Documents', bundle_id='com.apple.finder'))
    cases['rule_pane_tree_beside_code'] = case(tree_beside_code(), [vertical(400)],
                                               window=dict(WINDOW, title='main.rs', bundle_id='com.microsoft.VSCode'))
    cases['rule_b1_one_sided_table'] = case(
        [line(f'Item {i}', 100, 200 + i * 40, 120) for i in range(12)] + [line('Note', 600, 200, 80)], window=None)
    thread = [('in', 'Are we still on for 3?'), ('out', 'Yes, running five minutes late'),
              ('in', 'See you there'), ('out', 'Already in my bag')]
    cases['rule_b2_bubbles'] = case(
        [line(text, 200 if side == 'in' else 1700, 300 + i * 90, 600) for i, (side, text) in enumerate(thread)])
    cases['rule_b2_columns'] = case(
        [line(f'Main column line {i} with words', 100, 200 + i * 37, 900) for i in range(13)]
        + [line(f'Rail {i}', 1600, 200 + i * 45, 200) for i in range(15)])
    cases['rule_table_beside_form'] = case(form_beside_summary())
    cases['rule_table_title_and_wrapped_cell'] = case(table_with_title_and_wrapped_cell())
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
        prose(x=200, count=3) + [line('Today 9:30 AM', 1340, 460, 200)] + prose(x=200, y=520, count=3),
        window=CHAT_WINDOW)
    cases['rule_date_line_numbers_stay'] = case(
        prose(x=200, count=3) + [line('212', 1400, 460, 80)] + prose(x=200, y=520, count=3), window=CHAT_WINDOW)
    cases['rule_date_line_document_stays'] = case(invitation(), window=dict(WINDOW, title='Launch party',
                                                                              bundle_id='com.apple.iWork.Pages'))
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
    cases.update(review_cases())
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
    out['window_editor_scrolled'] = scrolled_editor()
    return out


def scrolled_editor():
    """The editor scrolled so that its code pane starts at line 7, "    };":
    the code pane's rows above it, and their line numbers, are gone."""
    boxes = bench.load_boxes('editor')
    width, height = boxes['width'], boxes['height']
    scene = next(scene for scene in bench.all_scenes() if scene['name'] == 'editor')

    def above_line_seven(item):
        x, y, w, h = item['box']
        left, top = x * width, (1 - y - h) * height
        return 560 < left < 1800 and 150 < top < 420

    return {'width': width, 'height': height, 'lines': [l for l in boxes['lines'] if not above_line_seven(l)],
            'separators': boxes['separators'], 'window': bench.geometry(scene, boxes)}


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

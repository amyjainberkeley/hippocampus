"""The reference reading order and roles (screens/layout.py)."""
import collections
import json
import random
import sys
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'screens'))
import bench  # noqa: E402
import layout  # noqa: E402
import shipped  # noqa: E402

W, H = 2880, 1800                 # a Retina frame: 1440 x 900 points
FIXTURES = HERE.parents[1] / 'adapters/macos/MCICaptureHelper/Tests/Fixtures/OCRReadingOrder'
WINDOW = {'rect': [0.0, 0.0, 1.0, 1.0], 'pixels_per_point': 2.0, 'title': 'Weekly review',
          'bundle_id': 'com.example.notes'}


def line(text, x, y, w, h=30, confidence=0.95):
    """A line box from top-left pixels."""
    return {'text': text, 'confidence': confidence, 'box': [x / W, 1 - (y + h) / H, w / W, h / H]}


def vertical(x, top=0, bottom=H):
    return [x / W, 1 - bottom / H, 0.0, (bottom - top) / H]


def horizontal(y, left=0, right=W):
    return [left / W, 1 - y / H, (right - left) / W, 0.0]


def read(lines, separators=(), window=WINDOW):
    return layout.read(lines, width=W, height=H, separators=separators, window=window)


def prose(x=700, y=300, count=6, width=1500, pitch=48):
    return [line(f'Paragraph line {i} with enough words to read as prose.', x, y + i * pitch, width)
            for i in range(count)]


def chars(text):
    return collections.Counter(ch for ch in text if ch not in layout.WHITESPACE and ch != '\x1e')


class StoredFormatTests(unittest.TestCase):
    def test_the_eight_committed_fixtures_are_unchanged(self):
        names = sorted(p.name[:-len('.expected.txt')] for p in FIXTURES.glob('*.expected.txt'))
        self.assertEqual(len(names), 8)
        for name in names:
            fixture = json.loads((FIXTURES / f'{name}.json').read_text(encoding='utf-8'))
            with self.subTest(name=name):
                self.assertEqual(layout.assemble(fixture['lines'], width=fixture['width'],
                                                 height=fixture['height']),
                                 (FIXTURES / f'{name}.expected.txt').read_text(encoding='utf-8'))

    def test_the_separator_is_stored_whenever_classification_ran(self):
        lines = prose()
        classified = read(lines)
        self.assertTrue(classified.classified)
        self.assertEqual(classified.stored.count(layout.CHROME_SEPARATOR), 1)
        self.assertTrue(classified.stored.endswith(layout.CHROME_SEPARATOR))  # no chrome, separator anyway
        self.assertNotIn('\x1e', read(lines, window=None).stored)

    def test_a_window_under_320_by_240_points_is_not_classified(self):
        small = dict(WINDOW, rect=[0.0, 0.0, 600 / W, 400 / H])  # 300 x 200 points
        self.assertFalse(read(prose(x=10, y=10, width=500), window=small).classified)

    def test_record_separators_in_line_text_are_removed(self):
        stored = read([line('pay\x1eroll report for the quarter', 700, 300, 900)] + prose(y=400)).stored
        self.assertIn('payroll report', stored)
        self.assertEqual(stored.count('\x1e'), 1)

    def test_nothing_is_dropped_when_classifying(self):
        # Chrome is moved, never deleted: the classified text holds the same
        # characters as the unclassified reading of the same boxes.
        for scene in bench.all_scenes():
            boxes = bench.load_boxes(scene['name'])
            with self.subTest(scene=scene['name']):
                plain = layout.assemble(boxes['lines'], width=boxes['width'], height=boxes['height'],
                                        separators=boxes['separators'])
                classified = layout.assemble(boxes['lines'], width=boxes['width'], height=boxes['height'],
                                             separators=boxes['separators'], window=bench.geometry(scene, boxes))
                self.assertEqual(chars(classified), chars(plain))

    def test_nothing_is_dropped_on_random_frames(self):
        rnd = random.Random(11)
        words_ = ['D', '\u53e3', 'Ok', '}', '12', '007 fn x() {', 'Inbox', 'Today 9:30 AM', 'Message #general',
                  'Search', 'usab\u2026 \u00d7', 'docs.example.com/a', 'TEAM', 'A long line of text to read.',
                  'pay\x1eroll', '\u00a0nbsp\u00a0', '\u0905\u0928\u0941']
        for trial in range(150):
            lines = [line(rnd.choice(words_), rnd.uniform(0, W - 400), rnd.uniform(0, H - 40),
                          rnd.choice([20, 30, 60, 200, 600]), rnd.choice([24, 30, 36]))
                     for _ in range(rnd.randint(5, 60))]
            separators = [vertical(rnd.uniform(100, W - 100)) for _ in range(rnd.randint(0, 2))]
            separators += [horizontal(rnd.uniform(50, H - 50)) for _ in range(rnd.randint(0, 2))]
            with self.subTest(trial=trial):
                plain = layout.assemble(lines, width=W, height=H, separators=separators)
                classified = read(lines, separators).stored
                self.assertEqual(chars(classified), chars(plain))
                self.assertLessEqual(classified.count('\x1e'), 1)

    def test_when_nothing_reads_as_content_the_reading_is_not_classified(self):
        tabs = [line(t, 100 + i * 500, 20, 300) for i, t in enumerate(['Inbox', 'Drafts', 'Sent', 'Archive'])]
        reading = read(tabs)
        self.assertFalse(reading.classified)
        self.assertEqual(reading.stored, 'Inbox Drafts Sent Archive')

    def test_lines_without_a_place_stay_at_the_end_of_the_content(self):
        lost = {'text': 'a line with no box', 'confidence': 0.9, 'box': [0.5, 0.5, 0.6, 0.1]}
        reading = read(prose() + [lost])
        self.assertTrue(reading.main.endswith('\na line with no box'))


class ParityFixtureTests(unittest.TestCase):
    def test_the_swift_parity_fixtures_match_the_reference(self):
        # The capture helper's port reads the same files; regenerate them
        # with screens/fixtures.py after changing a rule.
        import fixtures
        cases = fixtures.all_cases()
        self.assertGreaterEqual(len(cases), 50)
        for name, data in sorted(cases.items()):
            with self.subTest(fixture=name):
                self.assertEqual((FIXTURES / f'{name}.json').read_text(encoding='utf-8'), fixtures.dumps(data))
                self.assertEqual((FIXTURES / f'{name}.reading.json').read_text(encoding='utf-8'),
                                 fixtures.dumps(fixtures.expected(data)))

    def test_every_rule_and_awkward_character_has_a_fixture(self):
        import fixtures
        names = set(fixtures.all_cases())
        for name in ('rule_glyph', 'rule_gutter', 'rule_gutter_glued', 'rule_pane_cut', 'rule_b1_one_sided_table',
                     'rule_b2_bubbles', 'rule_bars_top', 'rule_status_bar', 'rule_placeholder', 'rule_navigation_left',
                     'rule_preview_list', 'rule_date_line', 'rule_caps_panel', 'text_record_separator', 'text_nbsp',
                     'text_devanagari', 'text_superscripts', 'window_mail', 'window_chat', 'window_editor'):
            self.assertIn(name, names)


class TextTests(unittest.TestCase):
    def test_whitespace_is_the_unicode_set_not_pythons(self):
        self.assertEqual(layout.words('a\u00a0b\u3000c'), ['a', 'b', 'c'])
        self.assertEqual(layout.words('a\x1fb'), ['a\x1fb'])  # str.split() would split here
        self.assertEqual(layout.trim('\u2029 x\x1c '), 'x\x1c')
        self.assertEqual(len(layout.WHITESPACE), 25)

    def test_digits_are_ascii_only(self):
        self.assertTrue(layout.is_number('2026'))
        self.assertFalse(layout.is_number('\u00b2'))      # superscript two
        self.assertFalse(layout.is_number('\u0968'))      # Devanagari two
        self.assertIsNone(layout.leading_number('\u00b9 use std::io;'))
        self.assertEqual(layout.leading_number('007 x'), ('007', 'x'))

    def test_a_letter_is_any_script(self):
        self.assertTrue(layout.has_letter('\u0905\u0928\u0941\u092e\u093e\u0928'))  # Devanagari
        self.assertFalse(layout.has_letter('\u0941'))     # a vowel sign alone is a mark


class GlyphTests(unittest.TestCase):
    def row(self, *items, y=40):
        return [line(text, x, y, w) for text, x, w in items]

    def test_an_icon_read_as_a_letter_moves_to_chrome(self):
        reading = read(self.row(('D', 60, 30), ('Inbox', 300, 120)) + prose())
        self.assertNotIn('D', layout.words(reading.main))
        self.assertIn('D', reading.rest)

    def test_a_mark_glued_to_its_label_stays(self):
        reading = read(self.row(('D', 60, 30), ('Inbox', 100, 120)) + prose())
        self.assertIn('D Inbox', reading.main)

    def test_two_icons_side_by_side_are_both_glyphs(self):
        reading = read(self.row(('e', 2500, 30), ('A', 2532, 30), ('Ask a question', 600, 300), y=1500)
                       + prose())
        self.assertNotIn('e A', reading.main)

    def test_words_numbers_and_code_punctuation_are_not_glyphs(self):
        lines = (self.row(('Ok', 60, 34)) + self.row(('}', 60, 30), y=100)
                 + self.row(('Estimate', 60, 150), ('3', 300, 24), y=160) + prose())
        main = read(lines).main
        for word in ('Ok', '}', 'Estimate 3'):
            self.assertIn(word, main)

    def test_a_column_of_numbers_is_data(self):
        cells = [line(str(n), 700, 300 + i * 50, 30) for i, n in enumerate([1, 2, 3])]
        cells += [line(str(v), 1100, 300 + i * 50, 80) for i, v in enumerate([212, 240, 236])]
        main = read(cells + prose(y=500)).main
        self.assertIn('1 212', main)


class GutterTests(unittest.TestCase):
    code = ['fn main() {', '    let x = 1;', '    if x > 0 {', '        run(x);', '    }', '}']

    def editor(self, glued=False, numbers=None):
        lines = []
        for i, text in enumerate(self.code):
            y = 200 + i * 40
            indent = (len(text) - len(text.lstrip())) * 15
            number = str((numbers or range(1, 100))[i])
            if glued and not indent:
                # A number close to an unindented line is read as one box
                # with it; indented lines stand too far off to be glued.
                start = 610 - 15 * len(number)
                lines.append(line(f'{number} {text}', start, y, 640 + 15 * len(text) - start))
            else:
                lines.append(line(number, 610 - 15 * len(number), y, 15 * len(number)))
                lines.append(line(text.lstrip(), 640 + indent, y, 15 * len(text.lstrip())))
        return lines

    def test_line_numbers_come_out_and_indentation_is_kept(self):
        main = read(self.editor()).main
        self.assertEqual(main.split('\n'), self.code)

    def test_line_numbers_beside_deeply_indented_code_come_out(self):
        # Scrolled into a function body: no line starts near the numbers.
        body = ['        let a = load(path)?;', '        let b = parse(&a)?;', '        store.put(b)?;',
                '        Ok(())']
        lines = []
        for i, text in enumerate(body):
            lines.append(line(str(40 + i), 580, 200 + i * 40, 30))
            lines.append(line(text.strip(), 640 + 120, 200 + i * 40, 15 * len(text.strip())))
        reading = read(lines)
        self.assertEqual(reading.main.split('\n'), [text.strip() for text in body])
        self.assertIn('40 41 42 43', reading.rest)

    def test_without_the_window_the_numbers_stay_as_they_always_did(self):
        stored = read(self.editor(), window=None).stored
        self.assertIn('1 fn main() {', stored)

    def test_numbers_glued_to_lines_are_split_off(self):
        lines = self.editor(glued=True)
        self.assertIn('1 fn main() {', [l['text'] for l in lines])
        reading = read(lines)
        self.assertEqual(reading.main.split('\n'), self.code)
        self.assertIn('1 2 3 4 5 6', reading.rest)

    def test_glued_numbers_keep_their_digits_as_read(self):
        lines = [line(f'{n:03d} let v{n} = {n};', 580, 200 + i * 40, 300) for i, n in enumerate([7, 8, 9, 10])]
        reading = read(lines)
        self.assertIn('007 008 009 010', reading.rest)
        self.assertNotIn('007', reading.main)

    def test_numbers_that_do_not_count_up_are_not_a_gutter(self):
        main = read(self.editor(numbers=[7, 3, 9, 1, 5, 2])).main
        self.assertIn('7', layout.words(main))

    def test_a_tables_column_of_numbers_is_not_a_gutter(self):
        # Week numbers count up a column, far from the next cell.
        rows = [line(str(i + 1), 700, 300 + i * 50, 20) for i in range(4)]
        rows += [line(f'{200 + i * 13} sessions in week {i + 1}', 1300, 300 + i * 50, 500) for i in range(4)]
        reading = read(rows + prose(y=600))
        self.assertTrue(reading.main.startswith('1\n2\n3\n4'))
        self.assertEqual(reading.rest, '')

    def test_superscripts_are_not_line_numbers(self):
        lines = []
        for i, mark in enumerate(['\u00b9', '\u00b2', '\u00b3', '\u2074']):
            lines.append(line(mark, 600, 200 + i * 40, 15))
            lines.append(line(f'Footnote {i + 1} says something about the text.', 640, 200 + i * 40, 600))
        main = read(lines).main
        self.assertIn('\u00b2 Footnote 2', main)


class PaneTests(unittest.TestCase):
    def sidebar_and_page(self):
        side = [line(name, 40, 200 + i * 44, 150) for i, name in enumerate(['Inbox', 'Drafts', 'Sent', 'Trash'])]
        # The page starts less than 1.5 line heights from the sidebar: no gap to cut at.
        page = [line(f'The page says something long enough to be read {i}.', 230, 200 + i * 44, 1500)
                for i in range(4)]
        return side + page

    def test_a_pane_separator_cuts_where_the_gap_is_too_narrow(self):
        lines = self.sidebar_and_page()
        self.assertIn('Inbox The page', layout.assemble(lines, width=W, height=H))
        cut = layout.assemble(lines, width=W, height=H, separators=[vertical(210)])
        self.assertNotIn('Inbox The page', cut)
        self.assertTrue(cut.startswith('Inbox\nDrafts'))

    def test_a_separator_that_text_crosses_is_not_a_cut(self):
        lines = self.sidebar_and_page() + [line('A title written right across the panes', 100, 100, 1000)]
        stored = layout.assemble(lines, width=W, height=H, separators=[vertical(210)])
        self.assertIn('Inbox The page', stored)

    def test_a_tables_gridlines_do_not_cut_its_rows_apart(self):
        cells = []
        for i, (name, stage) in enumerate([('Acme', 'Won'), ('Blue', 'Lost'), ('Cedar', 'Open')]):
            cells += [line(name, 300, 300 + i * 50, 120), line(stage, 900, 300 + i * 50, 100)]
        stored = layout.assemble(cells, width=W, height=H, separators=[vertical(800, 280, 460)])
        self.assertIn('Acme Won', stored)

    def test_bars_are_cut_before_the_panes_below_them(self):
        lines = [line('A wide title bar that spans both panes below', 100, 20, 2000)] + self.sidebar_and_page()
        stored = layout.assemble(lines, width=W, height=H, separators=[horizontal(80), vertical(210, 80)])
        self.assertTrue(stored.startswith('A wide title bar'))
        self.assertNotIn('Inbox The page', stored)


class CutTests(unittest.TestCase):
    def test_one_short_row_beside_a_long_column_is_not_a_table(self):
        # B1: the shipping test was one-sided and read this row by row.
        lines = [line(f'Item {i}', 100, 200 + i * 40, 120) for i in range(12)]
        lines.append(line('Note', 600, 200, 80))
        stored = layout.assemble(lines, width=W, height=H)
        self.assertIn('Item 0\nItem 1', stored)
        self.assertIn('Item 0 Note', shipped.assemble(lines, width=W, height=H))

    def bubbles(self):
        thread = [('in', 'Are we still on for 3?'), ('out', 'Yes, running five minutes late'),
                  ('in', 'See you there'), ('out', 'Already in my bag')]
        return [line(text, 200 if side == 'in' else 1700, 300 + i * 90, 600) for i, (side, text) in enumerate(thread)]

    def test_alternating_bubbles_read_top_to_bottom_with_who_said_what(self):
        # B2: two sides that never share a row are not columns.
        self.assertEqual(read(self.bubbles()).main,
                         'Are we still on for 3?\n    Yes, running five minutes late\n'
                         'See you there\n    Already in my bag')

    def test_columns_with_different_line_pitches_are_still_columns(self):
        left = [line(f'Main column line {i} with words', 100, 200 + i * 37, 900) for i in range(13)]
        right = [line(f'Rail {i}', 1600, 200 + i * 45, 200) for i in range(15)]
        main = read(left + right).main
        self.assertTrue(main.startswith('Main column line 0'))
        self.assertNotIn('words Rail', main)

    def test_a_table_beside_a_form_keeps_its_rows(self):
        form = [line(t, 100, 300 + i * 60, 500) for i, t in enumerate(
            ['Shipping address', 'Sam Rivera', '41 Harbor Street', 'Portland, OR 97209', 'Visa ending in 4242'])]
        summary = [line('Order summary', 1500, 300, 260)]
        for i, (label, amount) in enumerate([('Notebook', '$18.00'), ('Pens', '$28.00'), ('Total', '$46.00')]):
            summary += [line(label, 1500, 360 + i * 60, 200), line(amount, 2200, 360 + i * 60, 120)]
        main = read(form + summary).main
        self.assertIn('Notebook $18.00', main)
        self.assertIn('Total $46.00', main)


class RoleTests(unittest.TestCase):
    def test_a_tab_strip_and_an_address_bar_at_the_top_move_to_chrome(self):
        bars = [line('Weekly review', 100, 10, 200), line('Launch plan', 600, 10, 200), line('Recipes', 1100, 10, 200),
                line('docs.example.com/weekly-review', 100, 70, 700)]
        reading = read(bars + prose(y=200))
        self.assertTrue(reading.main.startswith('Paragraph line 0'))
        self.assertIn('docs.example.com/weekly-review', reading.rest)

    def test_a_sentence_at_the_top_stays(self):
        top = [line('which is why the pilot ran for four weeks instead of two.', 700, 10, 1200)]
        self.assertTrue(read(top + prose(y=200)).main.startswith('which is why'))

    def test_a_table_header_at_the_top_stays(self):
        cells = []
        for i, row in enumerate([('Week', 'Sessions', 'Questions'), ('One', '212', '48'), ('Two', '240', '61')]):
            cells += [line(cell, 700 + j * 400, 20 + i * 50, 150) for j, cell in enumerate(row)]
        self.assertIn('Week Sessions Questions', read(cells + prose(y=300)).main)

    def test_a_truncated_tab_with_its_close_mark_is_a_bar(self):
        tabs = [line('Per-seat or tiered? How to p... X', 100, 10, 500), line('Stripe Docs', 700, 10, 200)]
        self.assertNotIn('Stripe Docs', read(tabs + prose(y=200)).main)

    def test_the_status_bar_moves_and_a_last_line_of_text_stays(self):
        status = [line(t, 100 + i * 400, 1765, 200) for i, t in enumerate(['main', 'Ln 9, Col 34', 'UTF-8', 'Rust'])]
        self.assertNotIn('UTF-8', read(prose() + status).main)
        last = [line('Retention fell to 61 percent in week three, then recovered.', 700, 1760, 1200)]
        self.assertIn('Retention fell', read(prose() + last).main)

    def test_a_composer_placeholder_at_the_foot_of_its_pane_moves(self):
        composer = [line('Message #launch-plan', 700, 1700, 400)]
        reading = read(prose() + composer)
        self.assertNotIn('Message #launch-plan', reading.main)
        self.assertIn('Message #launch-plan', reading.rest)

    def test_a_message_that_trails_off_among_others_stays(self):
        thread = prose(y=1400, count=6, pitch=48) + [line('Let me check…', 700, 1690, 300)]
        self.assertIn('Let me check…', read(thread).main)

    def sidebar(self, x):
        return [line(name, x, 200 + i * 44, 180) for i, name in enumerate(['Inbox', 'Starred', 'Sent', 'Drafts'])]

    def test_a_narrow_column_of_short_items_at_the_left_edge_is_navigation(self):
        reading = read(self.sidebar(40) + prose(x=700))
        self.assertNotIn('Starred', reading.main)
        self.assertIn('Starred', reading.rest)

    def test_the_same_column_on_the_right_is_content(self):
        self.assertIn('Starred', read(prose(x=100, width=1500) + self.sidebar(2500)).main)

    def test_a_to_do_list_beside_notes_is_content(self):
        todo = [line(t, 640, 300 + i * 44, 300) for i, t in enumerate(
            ['To do', 'Book the venue', 'Email the caterer', 'Print the badges'])]
        main = read(todo + prose(x=1100, width=1600)).main
        self.assertIn('Email the caterer', main)

    def test_a_list_of_previews_beside_a_reading_pane_is_navigation(self):
        previews = []
        for i, (who, snippet) in enumerate([('Dana', 'Hi Sam, phase two is wrapped up. The invoice is…'),
                                            ('Ravi', 'Seat minimums: I would say three. Anything lower…'),
                                            ('Jonas', 'Recall is down to 41 ms. Details in the doc…')]):
            previews += [line(who, 520, 200 + i * 130, 120), line(snippet, 520, 245 + i * 130, 600)]
        reading = read(previews + prose(x=1400, width=1400))
        self.assertNotIn('phase two', reading.main)
        self.assertTrue(reading.main.startswith('Paragraph line 0'))

    def test_a_centred_date_line_moves_and_centred_numbers_stay(self):
        thread = prose(x=200, count=3) + [line('Today 9:30 AM', 1340, 460, 200)] + prose(x=200, y=520, count=3)
        reading = read(thread)
        self.assertNotIn('Today', reading.main)
        self.assertEqual(reading.main.count('Paragraph line'), 6)
        numbers = prose(x=200, count=3) + [line('212', 1400, 460, 80)] + prose(x=200, y=520, count=3)
        self.assertIn('212', read(numbers).main)

    def test_a_panels_title_in_capitals_moves_but_a_documents_does_not(self):
        panel = [line('CHAT', 2200, 200, 80)] + [line(f'Message {i} in the chat panel.', 2200, 260 + i * 44, 500)
                                                 for i in range(4)]
        reading = read(prose(x=100, width=1700) + panel, separators=[horizontal(150), vertical(2100, 150)])
        self.assertNotIn('CHAT', reading.main)
        document = [line('AGENDA', 700, 200, 150)] + prose(y=260)
        self.assertIn('AGENDA', read(document, separators=[horizontal(150)]).main)

    def test_a_terminal_keeps_everything_as_content(self):
        lines = [line('$ cargo test', 40, 20, 180), line('Compiling mci v0.3.0', 100, 60, 300),
                 line('test result: ok. 6 passed', 40, 100, 375)]
        terminal = dict(WINDOW, bundle_id='com.apple.Terminal')
        reading = read(lines, window=terminal)
        self.assertEqual(reading.rest, '')
        self.assertIn('    Compiling', reading.main)


class RenderTests(unittest.TestCase):
    def test_code_keeps_its_indentation_and_prose_indents_by_four(self):
        code = [line('fn main() {', 700, 200, 165), line('let x = 1;', 760, 240, 150), line('}', 700, 280, 15)]
        self.assertEqual(read(code).main, 'fn main() {\n    let x = 1;\n}')
        chat = [line('Who is driving tomorrow morning?', 200, 200, 600),
                line('I can, if we leave at eight.', 1900, 260, 600)]
        self.assertEqual(read(chat).main.split('\n')[1], '    I can, if we leave at eight.')

    def test_a_blank_line_in_code_does_not_reset_its_indentation(self):
        code = [line('impl Store {', 700, 200, 180), line('fn open() {}', 760, 240, 180),
                line('fn close() {}', 760, 340, 195), line('}', 700, 380, 15)]
        self.assertEqual(read(code).main, 'impl Store {\n    fn open() {}\n\n    fn close() {}\n}')

    def test_a_rows_stacked_lines_read_top_first(self):
        header = [line('Dana Whitfield <dana@northwind.example>', 1514, 335, 512, 35),
                  line('11:02 AM', 2602, 352, 226, 40), line('to me', 1512, 374, 80, 36)]
        main = read(header + prose(x=1500, y=500, width=1300)).main
        self.assertLess(main.index('Dana Whitfield'), main.index('to me'))


class CostTests(unittest.TestCase):
    def test_four_thousand_boxes_assemble_in_bounded_time(self):
        # The worker sends at most 4,096 lines. Every rule here is near
        # linear; a quadratic one takes minutes at this size, even in Swift.
        rnd = random.Random(3)
        lines = [line(rnd.choice(['A', 'D', '12', '3', 'word', 'two words here', 'fn x() {']),
                      rnd.uniform(0, W - 80), rnd.uniform(0, H - 30), rnd.choice([20, 40, 80]), 24)
                 for _ in range(2048)]
        lines += [line(str(i + 1), 10, i * 0.85, 20, 0.8) for i in range(1024)]
        lines += [line(f'    let value_{i} = compute({i});', 60, i * 0.85, 900, 0.8) for i in range(1024)]
        # CPU time, so a busy machine does not fail the test: about 0.4 s.
        started = time.process_time()
        read(lines)
        layout.read(lines, width=W, height=H)
        self.assertLess(time.process_time() - started, 10.0)


if __name__ == '__main__':
    unittest.main()

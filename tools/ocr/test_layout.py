"""The reference reading order and roles (screens/layout.py)."""
import collections
import functools
import json
import random
import sys
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'screens'))
import bench  # noqa: E402
import fixtures  # noqa: E402
import layout  # noqa: E402
import shipped  # noqa: E402
# The cases here are built as the parity fixtures are, so a test and its
# fixture cannot drift apart: a 2880 x 1800 frame (1440 x 900 points).
from fixtures import H, W, WINDOW, horizontal, line, prose, vertical  # noqa: E402

FIXTURES = HERE.parents[1] / 'adapters/macos/MCICaptureHelper/Tests/Fixtures/OCRReadingOrder'


def read(lines, separators=(), window=WINDOW):
    return layout.read(lines, width=W, height=H, separators=separators, window=window)


@functools.lru_cache(maxsize=None)
def all_cases():
    return fixtures.all_cases()


def case(name):
    """The reading of a parity fixture's own input: what the Swift port is
    pinned to is what these tests check."""
    data = all_cases()[name]
    return layout.read(data['lines'], width=data['width'], height=data['height'],
                       separators=data.get('separators', []), window=data.get('window'))


def tokens(stored):
    """The stored text's words, separator taken out: what a reading may move
    but never lose, glue or split."""
    return collections.Counter(layout.words(stored.replace(layout.CHROME_SEPARATOR, '\n')))


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
        # words as the unclassified reading of the same boxes, none glued to
        # another or split.
        for scene in bench.all_scenes():
            boxes = bench.load_boxes(scene['name'])
            with self.subTest(scene=scene['name']):
                plain = layout.assemble(boxes['lines'], width=boxes['width'], height=boxes['height'],
                                        separators=boxes['separators'])
                classified = layout.assemble(boxes['lines'], width=boxes['width'], height=boxes['height'],
                                             separators=boxes['separators'], window=bench.geometry(scene, boxes))
                self.assertEqual(tokens(classified), tokens(plain))

    def test_nothing_is_dropped_on_random_frames(self):
        rnd = random.Random(11)
        words_ = ['D', '\u53e3', 'Ok', 'TR', '}', '12', '007 fn x() {', 'Inbox', 'Today 9:30 AM',
                  'Message #general', 'Search', 'usab\u2026 \u00d7', 'docs.example.com/a', 'TEAM',
                  'A long line of text to read.', 'pay\x1eroll', '\u00a0nbsp\u00a0', '\u0905\u0928\u0941']
        for trial in range(150):
            lines = [line(rnd.choice(words_), rnd.uniform(0, W - 400), rnd.uniform(0, H - 40),
                          rnd.choice([20, 30, 60, 200, 600]), rnd.choice([24, 30, 36]))
                     for _ in range(rnd.randint(5, 60))]
            separators = [vertical(rnd.uniform(100, W - 100)) for _ in range(rnd.randint(0, 2))]
            separators += [horizontal(rnd.uniform(50, H - 50)) for _ in range(rnd.randint(0, 2))]
            with self.subTest(trial=trial):
                plain = layout.assemble(lines, width=W, height=H, separators=separators)
                classified = read(lines, separators).stored
                self.assertEqual(tokens(classified), tokens(plain))
                self.assertLessEqual(classified.count('\x1e'), 1)

    def test_a_token_glued_to_another_would_be_caught(self):
        # The invariant above counts words, so it sees what a count of
        # characters cannot: two words run together, or one split in two.
        self.assertNotEqual(tokens('fn main() {'), tokens('fnmain() {'))
        self.assertNotEqual(tokens('Inbox'), tokens('In box'))
        self.assertEqual(tokens('Inbox' + layout.CHROME_SEPARATOR + 'D'), tokens('D\n\nInbox'))

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
        cases = all_cases()
        self.assertGreaterEqual(len(cases), 90)
        for name, data in sorted(cases.items()):
            with self.subTest(fixture=name):
                self.assertEqual((FIXTURES / f'{name}.json').read_text(encoding='utf-8'), fixtures.dumps(data))
                self.assertEqual((FIXTURES / f'{name}.reading.json').read_text(encoding='utf-8'),
                                 fixtures.dumps(fixtures.expected(data)))

    def test_every_rule_and_awkward_character_has_a_fixture(self):
        names = set(all_cases())
        for name in ('rule_glyph', 'rule_glyph_letter_pair', 'rule_glyph_letter_pair_column', 'rule_gutter',
                     'rule_gutter_glued', 'rule_gutter_glued_mixed_fonts', 'rule_gutter_digits_as_read', 'rule_pane_cut',
                     'rule_pane_gridlines', 'rule_pane_columns_side_by_side', 'rule_pane_tree_beside_code',
                     'rule_b1_one_sided_table', 'rule_b2_bubbles', 'rule_b2_offset_columns', 'rule_table_beside_form',
                     'rule_table_title_and_wrapped_cell', 'rule_bars_top', 'rule_marks_row', 'rule_letter_buttons',
                     'rule_header_bar', 'rule_header_below_top_band_stays', 'rule_search_field',
                     'rule_close_set_table_header', 'rule_title_bar', 'rule_title_heading_stays',
                     'rule_toolbar_icons_over_labels', 'rule_bar_code_first_line', 'rule_bar_json_first_line',
                     'rule_bar_python_first_line', 'rule_bar_sql_caps_first_line', 'rule_ruled_receipt',
                     'rule_ruled_receipt_plain', 'rule_ruled_sheet', 'rule_status_bar', 'rule_placeholder',
                     'rule_placeholder_last_message_stays', 'rule_placeholder_note_last_item_stays',
                     'rule_navigation_left', 'rule_navigation_beside_stays', 'rule_navigation_leftover',
                     'rule_navigation_pane', 'rule_preview_list', 'rule_date_line', 'rule_date_line_document_stays',
                     'rule_caps_panel', 'rule_terminal', 'rule_terminal_numbered', 'rule_flat_small_offset',
                     'text_record_separator', 'text_nbsp', 'text_devanagari', 'text_superscripts', 'window_mail',
                     'window_chat', 'window_editor', 'window_editor_scrolled', 'window_receipt', 'window_invitation'):
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

    def test_numbers_in_place_and_code_punctuation_are_not_glyphs(self):
        lines = (self.row(('}', 60, 30), y=100) + self.row(('Estimate', 60, 150), ('3', 300, 24), y=160)
                 + self.row(('Estimate', 60, 150), ('13', 300, 30), y=220) + prose())
        main = read(lines).main
        for word in ('}', 'Estimate 3', 'Estimate 13'):
            self.assertIn(word, main)

    def test_two_characters_alone_are_an_icon_as_rulings_t3_says(self):
        # The owner's "TR": two letters, about square, far from any text.
        reading = case('rule_glyph_letter_pair')
        self.assertNotIn('TR', layout.words(reading.main))
        self.assertEqual(reading.rest, 'TR')
        # "Ok" alone at the window's edge is a button, and moves the same way.
        self.assertNotIn('Ok', layout.words(case('rule_glyph').main))

    def test_a_column_of_letter_pairs_is_data(self):
        # State codes in a table: each is a pair of letters beside others.
        main = case('rule_glyph_letter_pair_column').main
        self.assertIn('Portland OR\nSeattle WA\nAustin TX\nDenver CO', main)

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
        reading = case('rule_gutter_digits_as_read')
        self.assertIn('007 008 009 010', reading.rest)
        self.assertEqual(reading.main.split('\n'), ['let v7 = 7;', 'let v8 = 8;', 'let v9 = 9;', 'let v10 = 10;'])

    def test_a_glued_line_is_placed_by_the_width_of_its_own_characters(self):
        # The code is set in a 16-pixel face and the sidebar in an 11-pixel
        # one. Measured over the whole frame, the glued lines would start a
        # few characters early and read "   fn main() {".
        reading = case('rule_gutter_glued_mixed_fonts')
        self.assertTrue(reading.main.endswith('\n\n' + '\n'.join(fixtures.TREE_CODE)))
        self.assertIn('1 2 3 4 5 6', reading.rest)

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
        # The gridline runs the frame's full height, so it is a candidate
        # cut; the two sides pair row for row, so it is a table's.
        data = all_cases()['rule_pane_gridlines']
        self.assertEqual(data['separators'], [vertical(800)])
        self.assertIn('Acme Won\nBlue Lost\nCedar Open', case('rule_pane_gridlines').stored)

    def test_two_lists_side_by_side_are_panes_not_a_table(self):
        # A file browser's columns: short names at one pitch, a hairline
        # between them. Read as a table they interleave.
        for window in (None, all_cases()['rule_pane_columns_side_by_side']['window']):
            data = all_cases()['rule_pane_columns_side_by_side']
            with self.subTest(classified=window is not None):
                stored = layout.read(data['lines'], width=W, height=H, separators=data['separators'],
                                     window=window).stored
                self.assertNotIn('Applications Invoice', stored)
                self.assertIn('Applications\nDesktop\nDocuments\nDownloads\nMovies\nMusic', stored)
                self.assertIn('Invoice 4471.pdf\nContract v3.docx', stored)

    def test_a_file_tree_beside_code_is_a_pane_and_the_code_keeps_its_indentation(self):
        main = case('rule_pane_tree_beside_code').main
        self.assertNotIn('brain_ingest.rs fn main()', main)
        self.assertTrue(main.endswith('\n\n' + '\n'.join(fixtures.TREE_CODE)))

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

    def test_columns_offset_by_half_a_line_are_still_columns(self):
        # No row overlaps another by half its height, but bubbles never
        # overlap at all: these are columns, read one after the other.
        stored = case('rule_b2_offset_columns').stored
        self.assertTrue(stored.startswith('Inbox\nDrafts\nSent\nTrash\nSpam\n\nThe page says'))
        self.assertIn('Inbox\nDrafts', shipped.assemble(all_cases()['rule_b2_offset_columns']['lines'],
                                                        width=W, height=H))

    def test_a_table_beside_a_form_keeps_its_rows_and_the_form_its_own(self):
        main = case('rule_table_beside_form').main
        self.assertIn('Shipping address\nSam Rivera\n41 Harbor Street\nPortland, OR 97209\nVisa ending in 4242', main)
        self.assertIn('Order summary\nNotebook $18.00\nPens $28.00\nTotal $46.00', main)
        self.assertNotIn('Sam Rivera Notebook', main)

    def test_a_tables_title_and_a_wrapped_cell_stay_in_the_table(self):
        # Neither has a partner in the other columns, and both are the
        # table's own: the table is read row by row.
        main = case('rule_table_title_and_wrapped_cell').main
        self.assertIn('Q3 pipeline\nAccount Stage Owner\nAcme Robotics, Won Chen\nwest region\nBlue Harbor Lost Patel',
                      main)


class RoleTests(unittest.TestCase):
    def test_a_tab_strip_and_an_address_bar_at_the_top_move_to_chrome(self):
        bars = [line('Weekly review', 100, 10, 200), line('Launch plan', 600, 10, 200), line('Recipes', 1100, 10, 200),
                line('docs.example.com/weekly-review', 100, 70, 700)]
        reading = read(bars + prose(y=200))
        self.assertTrue(reading.main.startswith('Paragraph line 0'))
        self.assertIn('docs.example.com/weekly-review', reading.rest)

    def test_a_row_of_marks_at_the_top_is_a_bar(self):
        reading = case('rule_marks_row')
        self.assertNotIn('\u2261', reading.main)
        self.assertIn('0 \u2261', reading.rest)

    def test_letter_buttons_alone_in_their_pane_are_a_bar(self):
        # A composer's formatting row: B, I, S read as letters, beside an icon.
        reading = case('rule_letter_buttons')
        self.assertNotIn('BIS', reading.main)
        self.assertIn('BIS', reading.rest)

    def test_a_short_line_of_code_at_the_top_of_a_pane_is_code(self):
        # Under a tab bar, or at the window's top: "};", "{", "x = 1" and
        # "SELECT *" look like marks or a panel's title, and are code.
        for name, first in (('rule_bar_code_first_line', '    };'), ('rule_bar_json_first_line', '{'),
                            ('rule_bar_python_first_line', 'x = 1'), ('rule_bar_sql_caps_first_line', 'SELECT *')):
            with self.subTest(case=name):
                reading = case(name)
                self.assertIn(first + '\n', reading.main)
                self.assertNotIn(first.strip(), layout.words(reading.rest))
        self.assertEqual(case('rule_bar_code_first_line').rest, 'store.rs main.rs lib.rs')

    def test_an_editor_scrolled_to_a_closing_brace_keeps_every_line_of_its_code(self):
        # The bench's own editor, its code pane scrolled so "    };" is the
        # first line in view.
        reading = case('window_editor_scrolled')
        self.assertEqual(bench.code_check(reading.main, bench.windows.EDITOR_CODE[6:]), (True, []))
        self.assertTrue(reading.main.startswith('    };\n    let mut deleted = 0_u64;\n'))

    def test_rows_between_rules_are_a_tables_rows_not_bars(self):
        # A receipt and a spreadsheet: every row is a pane of its own, the
        # look of a stack of bars, and every row is content, read whole.
        receipt = case('rule_ruled_receipt')
        self.assertIn('Linen notebook $18.00\n\nBrass pen x 2 $28.00\n\nShipping $5.00\n\nTotal $51.00', receipt.main)
        self.assertEqual(receipt.rest, '')
        self.assertIn('Brass pen x 2 $28.00', case('rule_ruled_receipt_plain').stored)
        sheet = case('rule_ruled_sheet')
        for row in ('1 Account Stage Owner ARR', '2 Acme Robotics Negotiation M. Chen 184000',
                    '6 Elm Street Cafe Negotiation R. Patel 8000'):
            self.assertIn(row, sheet.main)
        self.assertIn('A B C D', sheet.rest)

    def test_a_toolbar_of_icons_over_labels_is_a_bar(self):
        # The icons line up with their labels as a table's cells do; in a
        # pane that lies wholly in the window's top band, that is a toolbar.
        reading = case('rule_toolbar_icons_over_labels')
        self.assertTrue(reading.main.startswith('Paragraph line 0'))
        self.assertIn('View Zoom Insert Table Chart Text Shape', reading.rest)

    def test_a_sentence_at_the_top_stays(self):
        top = [line('which is why the pilot ran for four weeks instead of two.', 700, 10, 1200)]
        self.assertTrue(read(top + prose(y=200)).main.startswith('which is why'))

    def test_a_table_header_at_the_top_stays(self):
        cells = []
        for i, row in enumerate([('Week', 'Sessions', 'Questions'), ('One', '212', '48'), ('Two', '240', '61')]):
            cells += [line(cell, 700 + j * 400, 20 + i * 50, 150) for j, cell in enumerate(row)]
        self.assertIn('Week Sessions Questions', read(cells + prose(y=300)).main)

    def test_a_one_row_header_or_search_field_in_the_top_band_is_a_bar(self):
        self.assertEqual(case('rule_header_bar').rest, '# launch-plan 14 members')
        self.assertEqual(case('rule_search_field').rest, 'Search mail')

    def test_a_one_row_pane_below_the_top_band_is_not_a_header(self):
        # A total between two rules halfway down a document has items at
        # both ends, as a header does; outside the top band it is content.
        reading = case('rule_header_below_top_band_stays')
        self.assertIn('Total due $2,300.00', reading.main)
        self.assertEqual(reading.rest, '')

    def test_a_close_set_table_keeps_its_header(self):
        # Cells too close together for the cut to see a table: the header
        # lines up with the row below it, so it is not a bar.
        self.assertTrue(case('rule_close_set_table_header').main.startswith('Account Stage Owner\nAcme Won Chen'))

    def test_the_windows_title_is_a_bar_only_at_the_top_edge(self):
        self.assertEqual(case('rule_title_bar').rest, 'Weekly review')
        self.assertIn('\n\nWeekly review\n\n', case('rule_title_heading_stays').main)

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

    def test_a_last_message_that_starts_like_a_composer_stays(self):
        # The composer has its own border, and the chat is scrolled to its
        # foot: the last message ends a run of messages, so it is not alone.
        for last in ('Reply when you can, no rush', 'Message me when you land', 'Search is down again'):
            lines, separators = fixtures.chat_with_composer(last)
            with self.subTest(last=last):
                reading = read(lines, separators, window=fixtures.CHAT_WINDOW)
                self.assertIn(f'Ravi Patel 10:47 AM\n{last}', reading.main)
                self.assertEqual(reading.rest, 'Message #launch-plan')
        self.assertEqual(case('rule_placeholder_last_message_stays').rest, 'Message #launch-plan')

    def test_a_notes_last_item_alone_at_the_foot_stays(self):
        # Alone in its region at the foot of the window, and a sentence.
        for last in ('Search for a bigger venue.', 'Reply to Dana about the invoice.', 'Message Ravi about pricing.'):
            with self.subTest(last=last):
                reading = read(fixtures.note_ending(last))
                self.assertTrue(reading.main.endswith('\n\n' + last))
                self.assertEqual(reading.rest, '')
        self.assertEqual(case('rule_placeholder_note_last_item_stays').rest, '')

    def test_composer_wording_is_whole_or_a_prompts_start(self):
        def row(text):
            return [layout.Box(text, 0, 0, 15 * len(text), 30)]
        for text in ('Message #general', 'Message Maya Chen', 'iMessage', 'Reply', 'Type a message',
                     'Ask about your code…'):
            self.assertTrue(layout.is_placeholder(row(text)), text)
        for text in ('Reply when you can', 'Search', 'Search mail', 'Reply to Dana about the invoice.',
                     'Message Ravi about pricing.'):
            self.assertFalse(layout.is_placeholder(row(text)), text)
        for text in ('Search', 'Search mail', 'Search Northwind Studio'):
            self.assertTrue(layout.is_search(row(text)), text)
        self.assertFalse(layout.is_search(row('Search is down.')))

    def sidebar(self, x, names=('Inbox', 'Starred', 'Sent', 'Drafts')):
        return [line(name, x, 200 + i * 44, 180) for i, name in enumerate(names)]

    def test_a_narrow_column_of_short_items_at_the_left_edge_is_navigation(self):
        reading = read(self.sidebar(40) + prose(x=700))
        self.assertNotIn('Starred', reading.main)
        self.assertIn('Starred', reading.rest)
        # Spec C4: four rows at least. Three short lines are content.
        self.assertIn('Starred', read(self.sidebar(40, ('Inbox', 'Starred', 'Sent')) + prose(x=700)).main)

    def test_short_lines_beside_navigation_are_content(self):
        # In a pane that is mostly navigation, short lines left over in the
        # navigation's column join it; a note's lines beside it do not.
        reading = case('rule_navigation_beside_stays')
        self.assertTrue(reading.main.startswith('Dentist on Friday'))
        self.assertTrue(reading.main.endswith('Call Ravi'))
        self.assertTrue(case('rule_navigation_leftover').rest.startswith('Compose\n\nAll iCloud'))

    def test_a_sidebar_in_a_pane_of_its_own_is_navigation_counts_and_all(self):
        reading = case('rule_navigation_pane')
        self.assertTrue(reading.main.startswith('Paragraph line 0'))
        self.assertIn('Inbox\nStarred', reading.rest)
        self.assertIn('12\n3', reading.rest)

    def test_the_same_column_on_the_right_is_content(self):
        self.assertIn('Starred', read(prose(x=100, width=1500) + self.sidebar(2500)).main)

    def test_a_to_do_list_beside_notes_is_content(self):
        todo = [line(t, 640, 300 + i * 44, 300) for i, t in enumerate(
            ['To do', 'Book the venue', 'Email the caterer', 'Print the badges'])]
        main = read(todo + prose(x=1100, width=1600)).main
        self.assertIn('Email the caterer', main)

    def test_a_list_of_previews_beside_a_reading_pane_is_navigation(self):
        # Four lines of prose share no row with the previews by half a line
        # (B2), and are still read apart from them.
        reading = case('rule_preview_list')
        self.assertNotIn('phase two', reading.main)
        self.assertTrue(reading.main.startswith('Paragraph line 0'))
        self.assertIn('Dana\nHi Sam, phase two', reading.rest)

    def test_a_centred_date_line_divides_messages_in_a_chat(self):
        reading = case('rule_date_line')
        self.assertNotIn('Today', reading.main)
        self.assertEqual(reading.main.count('Paragraph line'), 6)
        self.assertIn('212', case('rule_date_line_numbers_stay').main)

    def test_outside_a_chat_a_centred_date_is_content(self):
        # The same line in a notes app, and an invitation's own date.
        data = all_cases()['rule_date_line']
        self.assertIn('Today 9:30 AM', read(data['lines']).main)
        reading = case('rule_date_line_document_stays')
        self.assertIn('Saturday, October 21 at 7 PM', reading.main)
        self.assertEqual(reading.rest, '')

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

    def test_a_terminals_numbers_and_short_answers_are_its_output(self):
        # `history` counts up a column, as a gutter does, and a lone "y" is
        # shaped like an icon: in a terminal both are what it printed.
        reading = case('rule_terminal_numbered')
        self.assertEqual(reading.rest, '')
        self.assertIn('501  cargo build\n502  cargo test -p mci-brain', reading.main)
        self.assertTrue(reading.main.endswith('Remove the build folder? [y/N]\ny'))


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

    def test_an_offset_under_four_characters_outside_code_is_not_an_indent(self):
        # Checked items start after their checkbox, two characters right of
        # the unchecked ones: recognition, not nesting.
        main = case('rule_flat_small_offset').main
        self.assertTrue(main.startswith('To do\nBook the venue\nEmail the caterer\nPrint the badges\n'))

    def test_a_rows_stacked_lines_read_top_first(self):
        header = [line('Dana Whitfield <dana@northwind.example>', 1514, 335, 512, 35),
                  line('11:02 AM', 2602, 352, 226, 40), line('to me', 1512, 374, 80, 36)]
        main = read(header + prose(x=1500, y=500, width=1300)).main
        self.assertLess(main.index('Dana Whitfield'), main.index('to me'))


class CostTests(unittest.TestCase):
    def test_four_thousand_boxes_assemble_in_bounded_time(self):
        # The worker sends at most 4,096 lines: here scattered words and
        # icons beside a numbered column of code, and a grid of numbers.
        rnd = random.Random(3)
        lines = [line(rnd.choice(['A', 'D', '12', '3', 'word', 'two words here', 'fn x() {']),
                      rnd.uniform(0, W - 80), rnd.uniform(0, H - 30), rnd.choice([20, 40, 80]), 24)
                 for _ in range(2048)]
        lines += [line(str(i + 1), 10, i * 0.85, 20, 0.8) for i in range(1024)]
        lines += [line(f'    let value_{i} = compute({i});', 60, i * 0.85, 900, 0.8) for i in range(1024)]
        grid = [line(str((r * 7 + c * 13) % 100), 40 + c * 44, 20 + r * 28, 30, 20) for r in range(64) for c in range(64)]
        # CPU time, so a busy machine does not fail the test: about 0.6 s
        # for the four readings.
        started = time.process_time()
        for frame in (lines, grid):
            read(frame)
            layout.read(frame, width=W, height=H)
        self.assertLess(time.process_time() - started, 3.0)

    def test_the_gutter_does_not_scan_every_later_number_from_each_one(self):
        # 4,096 numbers packed into one column, counting down (no chain) or
        # up (no chain at half a line apart). Scanning every later number
        # from each start took 2.2 s; looking numbers up by value, 0.01 s.
        for step in (-1, 1):
            lines = [line(str(90000 + step * i), 100, 300 + i * 0.07, 60) for i in range(4096)]
            boxes, _ = layout.prepare(lines, 0.5, W, H)
            with self.subTest(step=step):
                started = time.process_time()
                layout.gutter(boxes, 30.0)
                self.assertLess(time.process_time() - started, 0.5)

    def test_the_gutter_takes_the_chain_a_scan_of_every_later_box_takes(self):
        # The first port's chain search, which scanned every later number
        # from each start. The lookup by value must pick the same chain.
        def scanned(boxes, line_h):
            candidates = []
            for box in boxes:
                parsed = layout.leading_number(layout.trim(box.text))
                if parsed is not None:
                    candidates.append((box, int(parsed[0]), parsed[1]))
            candidates.sort(key=lambda t: (t[0].cy, t[0].x0))
            best, chained = [], set()
            for start, (anchor, _, _) in enumerate(candidates):
                if len(best) >= len(candidates) - start:
                    break
                if id(anchor) in chained:
                    continue
                chain = []
                for entry in candidates[start:]:
                    box, number, _ = entry
                    if chain and box.cy - chain[-1][0].cy > layout.GUTTER_GAP * line_h:
                        break
                    if (abs(box.x1 - anchor.x1) > layout.GUTTER_ALIGN * line_h
                            and abs(box.x0 - anchor.x0) > layout.GUTTER_ALIGN * line_h):
                        continue
                    if chain and (box.cy - chain[-1][0].cy < 0.5 * line_h
                                  or not 0 < number - chain[-1][1] <= layout.GUTTER_MAX_STEP):
                        continue
                    chain.append(entry)
                chained.update(id(box) for box, _, _ in chain)
                if len(chain) > len(best):
                    best = chain
            return best

        rnd = random.Random(5)
        for trial in range(200):
            lines = [line(str(rnd.randint(1, 30)), rnd.choice([100, 110, 130, 400]), rnd.uniform(100, 1500),
                          rnd.choice([15, 30]), 30) for _ in range(rnd.randint(3, 80))]
            lines += [line(f'{rnd.randint(1, 30)} let x{i} = {i};', 100, rnd.uniform(100, 1500), 240)
                      for i in range(rnd.randint(0, 10))]
            boxes, _ = layout.prepare(lines, 0.5, W, H)
            with self.subTest(trial=trial):
                self.assertEqual([id(box) for box, _, _ in layout.gutter_chain(boxes, 30.0)],
                                 [id(box) for box, _, _ in scanned(boxes, 30.0)])


if __name__ == '__main__':
    unittest.main()

"""The transcript bench (screens/bench.py), its scenes and its measures."""
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'screens'))
import bench  # noqa: E402
import render  # noqa: E402


def scene_named(name):
    return next(scene for scene in bench.all_scenes() if scene['name'] == name)


class SceneTests(unittest.TestCase):
    def test_every_scene_has_committed_boxes_and_content(self):
        scenes = bench.all_scenes()
        self.assertEqual(len(scenes), 19)
        for scene in scenes:
            with self.subTest(scene=scene['name']):
                boxes = bench.load_boxes(scene['name'])
                self.assertTrue(boxes['lines'])
                self.assertIn('separators', boxes)
                self.assertIn('content', {item['role'] for item in scene['items']})

    def test_the_decoys_mark_as_content_what_looks_like_chrome(self):
        def role(name, text):
            return next(item['role'] for item in scene_named(name)['items'] if item['text'] == text)
        self.assertEqual(role('issue_properties', 'Estimate'), 'content')
        self.assertEqual(role('issue_properties', '3'), 'content')
        self.assertEqual(role('order_summary', 'Total'), 'content')
        self.assertEqual(role('todo_beside_notes', 'Email the caterer'), 'content')
        self.assertEqual(role('fullscreen_doc', 'which is why the pilot ran for four weeks instead of two.'), 'content')
        self.assertEqual({item['role'] for item in scene_named('fullscreen_doc')['items']}, {'content'})

    def test_render_draws_every_scene_at_its_own_size(self):
        pages = list(render.pages())
        self.assertEqual([name for name, _, _ in pages], [scene['name'] for scene in bench.all_scenes()])
        messages = next(page for page in pages if page[0] == 'messages')
        self.assertEqual(messages[2]['size'], [1100, 760])
        self.assertIn('width: 1100px; height: 760px;', messages[1])

    def test_screens_are_read_at_the_production_density(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as tmp:
            png = Path(tmp) / 'frame.png'
            Image.new('RGB', (40, 20), 'white').save(png)
            data = bench.bmp_bytes(png)
        self.assertEqual(struct.unpack('<ii', data[38:46]), (5669, 5669))  # 144 dpi, a Retina capture


class MeasureTests(unittest.TestCase):
    items = [{'role': 'content', 'text': 'Pay the invoice by Friday'}, {'role': 'chrome', 'text': 'Reply'},
             {'role': 'chrome', 'text': 'Forward'}, {'role': 'navigation', 'text': 'Inbox'},
             {'role': 'navigation', 'text': 'Drafts'}]
    scene = {'items': items, 'code': None}

    def test_leaks_are_scored_by_whole_word_and_by_whole_line(self):
        glued = bench.score(self.scene, 'Pay the invoice by Friday Reply\nForward')
        self.assertEqual((glued['chrome_w'], glued['chrome_l']), (1.0, 0.5))
        self.assertEqual(bench.score(self.scene, 'Pay the invoice by Friday\nReplying later')['chrome_w'], 0.0)

    def test_short_strings_and_strings_inside_content_are_not_scored_as_leaks(self):
        items = self.items + [{'role': 'chrome', 'text': '12'}, {'role': 'chrome', 'text': 'invoice'}]
        self.assertEqual(bench.leak_strings(items, 'chrome'), ['Reply', 'Forward'])

    def test_junk_is_tokens_in_no_truth_string_but_not_bullets(self):
        self.assertEqual(bench.junk_tokens('\u53e3 Pay the invoice by Friday \u2606\u2261\n\u2022 Pay', self.items),
                         ['\u53e3', '\u2606\u2261'])

    def test_content_recall_and_reading_order(self):
        scene = {'items': [{'role': 'content', 'text': 'first line here'},
                           {'role': 'content', 'text': 'second line here'}], 'code': None}
        result = bench.score(scene, 'second line here\nfirst line here')
        self.assertEqual((result['content'], result['order']), (1.0, 0.5))

    def test_the_code_check_catches_numbers_indentation_and_stray_lines(self):
        code = ['fn main() {', '    run();', '}']
        self.assertEqual(bench.code_check('fn main() {\n    run();\n}', code), (True, []))
        for text in ('1 fn main() {\n2     run();\n3 }', 'fn main() {\nrun();\n}',
                     'fn main() {\n    run();', 'fn main() {\nYou\n    run();\n}'):
            with self.subTest(text=text):
                self.assertFalse(bench.code_check(text, code)[0])


class BenchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rows, cls.failures = bench.bench(None)

    def new(self, name):
        return next(row for row in self.rows if row['scene']['name'] == name)['texts']['new']

    def test_the_hard_gates_hold_on_every_scene(self):
        self.assertEqual(self.failures, [])

    def test_the_targets_hold_over_the_windows_and_decoys(self):
        rows = [row for row in self.rows if row['scene']['kind'] in ('window', 'decoy')]
        for key, limit in bench.TARGETS.items():
            with self.subTest(measure=key):
                self.assertLessEqual(sum(row['new'][key] for row in rows) / len(rows), limit)

    def test_the_mail_list_and_the_open_message_are_not_interleaved(self):
        main = self.new('mail')['main']
        self.assertTrue(main.startswith('Invoice 4471 for phase two'))
        self.assertNotIn('Seat minimums', main)  # a preview from the list
        self.assertIn('Hi Sam,\nPhase two of the brand refresh', main)

    def test_the_chats_keep_who_said_what(self):
        self.assertIn('Ravi Patel 10:47 AM\nLooks good.', self.new('chat')['main'])
        self.assertTrue(self.new('messages')['main'].startswith(
            'Are we still on for 3?\n    Yes, running five minutes late\nSee you there'))

    def test_the_editors_code_reads_as_written(self):
        main = self.new('editor')['main']
        self.assertTrue(main.startswith('use std::time::Duration;\n'))
        for chrome in ('EXPLORER', 'retention_worker.rs \u2014 hippocampus', 'Ln 9, Col 34', 'Ask about your code'):
            self.assertNotIn(chrome, main)

    def test_no_decoy_keeps_content_only_in_its_chrome(self):
        for row in self.rows:
            if row['scene']['kind'] != 'decoy':
                continue
            main, rest = (bench.norm(row['texts']['new'][part]) for part in ('main', 'rest'))
            for item in row['scene']['items']:
                text = bench.norm(item['text'])
                if item['role'] == 'content' and bench.contains(rest, text):
                    with self.subTest(scene=row['scene']['name'], text=text):
                        self.assertTrue(bench.contains(main, text))

    def test_the_side_by_side_page_shows_each_screen_beside_its_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            page = Path(tmp) / 'page.html'
            bench.show_page(self.rows, page, Path(tmp))
            text = page.read_text(encoding='utf-8')
        self.assertLess(text.index('<img src="editor.png"'), text.index('<img src="chat_light.png"'))
        self.assertIn('Also in this window', text)
        self.assertIn('<pre>', text)


class ReaderTests(unittest.TestCase):
    def test_the_bench_reads_through_the_rust_reader_when_one_is_given(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'requests.jsonl'
            probe = Path(tmp) / 'reading-probe'
            # A stand-in that answers as RULINGS X7 says: one JSON line each way.
            probe.write_text(
                f'#!{sys.executable}\n'
                'import json, sys\n'
                f'log = open({str(log)!r}, "a")\n'
                'for line in sys.stdin:\n'
                '    log.write(line)\n'
                '    log.flush()\n'
                '    body = json.loads(line)["stored"].split("\\n", 1)[1]\n'
                '    main, _, rest = body.partition("\\n\\n\\x1e\\n")\n'
                '    print(json.dumps({"main": main.upper(), "rest": rest}), flush=True)\n',
                encoding='utf-8')
            probe.chmod(0o755)
            reader = bench.Reader(probe)
            try:
                texts = bench.transcripts(scene_named('notes'), bench.load_boxes('notes'), reader)
            finally:
                reader.close()
            request = json.loads(log.read_text(encoding='utf-8').splitlines()[0])
        self.assertTrue(texts['new']['main'].startswith('LAUNCH PLAN'))
        self.assertEqual(set(request), {'stored', 'source', 'app', 'title'})
        self.assertEqual(request['source'], 'screen_ocr')
        self.assertTrue(request['stored'].startswith('[app=com.apple.Notes | title=Launch plan | url=? | ts='))


if __name__ == '__main__':
    unittest.main()

import io
import json
import struct
import subprocess
import sys
import unittest
from unittest.mock import patch
from pathlib import Path
import worker


def bitmap(w=2, h=2):
    pixels = bytes([0, 0, 255, 255]) * (w*h)
    return struct.pack('<2sIHHI', b'BM', 54+len(pixels), 0, 0, 54) + struct.pack('<IiiHHIIiiII',40,w,-h,1,32,0,len(pixels),0,0,0,0) + pixels


class WorkerTests(unittest.TestCase):
    def test_bgra_bitmap_reads_without_color_or_vertical_flip(self):
        image = worker.read_image(io.BytesIO(bitmap()))
        self.assertEqual(image.shape, (2,2,3))
        self.assertEqual(image[0,0].tolist(), [0,0,255])

    def test_rejects_truncated_or_unbounded_input(self):
        for data in [b'', bitmap()[:-1], bitmap()+b'x', b'X'*54,
                     bitmap()[:18]+struct.pack('<i',100000)+bitmap()[22:]]:
            with self.subTest(data_length=len(data)), self.assertRaises(ValueError):
                worker.read_image(io.BytesIO(data))

    def test_invalid_model_directory_fails_before_inference(self):
        with self.assertRaises(ValueError):
            worker.load_engine(Path('/nonexistent/hippocampus-models'))

    def test_output_maps_top_left_pixels_and_rejects_nonfinite(self):
        lines = worker.encode_lines(['hello'], [0.9], [[[10,20],[90,20],[90,40],[10,40]]],100,100)
        self.assertEqual(lines[0]['box'], [0.1,0.6,0.8,0.2])
        with self.assertRaises(ValueError):
            worker.encode_lines(['hello'], [float('nan')], [[[0,0],[1,0],[1,1],[0,1]]],100,100)

    def test_low_confidence_candidate_survives_for_privacy_scan(self):
        import numpy as np
        from types import SimpleNamespace
        engine = worker.load_engine(Path(__file__).parent/'models')
        # Exercise the upstream filter actually used by the configured engine.
        result = SimpleNamespace(boxes=np.array([[[0,0],[10,0],[10,10],[0,10]]]),
                                 txts=('synthetic-secret-marker',),scores=(0.1,),word_results=(None,))
        filtered = engine.filter_by_text_score(result)
        self.assertEqual(filtered.txts, ('synthetic-secret-marker',))

    def test_offline_guard_blocks_network_attempts(self):
        result = subprocess.run([sys.executable, '-c',
            "import sys,socket,worker; sys.addaudithook(worker.deny_network); socket.getaddrinfo('localhost',443)"],
            cwd=Path(__file__).parent,capture_output=True,env={'PATH':'/usr/bin:/bin'},timeout=5)
        self.assertNotEqual(result.returncode,0)
        self.assertIn(b'OCR worker is offline',result.stderr)

    def test_native_small_chat_transcription(self):
        import numpy as np
        from benchmark import render, TEXT
        engine = worker.load_engine(Path(__file__).parent/'models')
        for size in [10,12,16]:
            result=engine(np.array(render(size))[:,:,::-1].copy())
            with self.subTest(font_pixels=size):
                self.assertEqual(list(result.txts),TEXT)

    def test_blank_image_does_not_invent_text(self):
        import numpy as np
        engine = worker.load_engine(Path(__file__).parent/'models')
        result = engine(np.full((300,600,3),255,dtype=np.uint8))
        self.assertFalse(result.txts)

    def test_model_preprocessing_bounds_valid_narrow_regions(self):
        import cv2
        import numpy as np
        from rapidocr.ch_ppocr_det.utils import TextDetOutput
        engine = worker.load_engine(Path(__file__).parent/'models')
        resize = cv2.resize

        def bounded_resize(image, size, *args, **kwargs):
            # Fail BEFORE an upstream regression can allocate an oversized image.
            self.assertTrue(all(0 < n <= worker.MAX_EDGE for n in size), size)
            return resize(image, size, *args, **kwargs)

        def inspect_detector(image):
            tensor = engine.text_det.get_preprocess(max(image.shape[:2]))(image)
            self.assertEqual(tensor.shape[:2], (1, 3))
            self.assertTrue(all(32 <= n <= worker.MAX_EDGE and n % 32 == 0
                                for n in tensor.shape[2:]), tensor.shape)
            return TextDetOutput()

        with patch('cv2.resize', side_effect=bounded_resize):
            for width, height in [(3840,1),(1,3840),(3000,20),(20,3000),
                                  (3840,31),(31,3840),(767,128),(128,767),
                                  (960,540),(2560,1600)]:
                with self.subTest(width=width, height=height):
                    image = np.full((height,width,3),255,dtype=np.uint8)
                    # Run actual global preprocessing/padding and detector
                    # preprocessing; intercept only inference (no huge tensor).
                    with patch.object(type(engine.text_det), '__call__',
                                      side_effect=inspect_detector):
                        self.assertFalse(engine(image).txts)

    def test_extreme_recognition_ratio_fails_before_allocation(self):
        import numpy as np
        engine = worker.load_engine(Path(__file__).parent/'models')
        image = np.full((1,3840,3),255,dtype=np.uint8)
        with patch('cv2.resize', side_effect=AssertionError('unexpected resize')):
            with self.assertRaises(ValueError):
                engine.text_rec.resize_norm_img(image, 3840.0)

    def test_extreme_candidate_fails_whole_reading_without_partial_text(self):
        import numpy as np
        from rapidocr.ch_ppocr_det.utils import TextDetOutput
        engine = worker.load_engine(Path(__file__).parent/'models')
        image = np.full((48,3840,3),255,dtype=np.uint8)
        crops = [image[:,:200], image[:1]]
        detection = TextDetOutput(img=image, boxes=np.array([
            [[0,0],[200,0],[200,48],[0,48]],
            [[0,0],[3840,0],[3840,1],[0,1]],
        ]), scores=[1.0,1.0])
        with patch.object(engine, 'detect_and_crop', return_value=(crops,detection)):
            # The error must escape RapidOCR, not turn into a successful empty
            # or partial transcript that could bypass complete privacy review.
            with self.assertRaisesRegex(ValueError, 'recognition input'):
                engine(image)

    def test_narrow_text_retains_original_image_coordinates(self):
        import numpy as np
        from PIL import Image, ImageDraw, ImageFont
        image = Image.new('RGB',(1200,48),'white')
        draw = ImageDraw.Draw(image)
        sentence = 'Please review the latest notes.'
        font = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',20)
        draw.text((100,10),sentence,font=font,fill='black')
        engine = worker.load_engine(Path(__file__).parent/'models')
        result = engine(np.array(image)[:,:,::-1].copy())
        self.assertEqual(list(result.txts),[sentence])
        box = result.boxes[0]
        self.assertTrue(80 <= min(box[:,0]) <= 115, box)
        self.assertTrue(340 <= max(box[:,0]) <= 420, box)
        self.assertTrue(0 <= min(box[:,1]) <= 20, box)
        self.assertTrue(25 <= max(box[:,1]) <= 48, box)

if __name__ == '__main__':
    unittest.main()


class ServeModeTests(unittest.TestCase):
    """The persistent worker the capture helper keeps warm between frames."""

    def serve(self, payload):
        return subprocess.run([sys.executable, 'worker.py', '--serve'], cwd=Path(__file__).parent,
                              input=payload, capture_output=True, env={'PATH': '/usr/bin:/bin'},
                              timeout=180)

    def test_announces_ready_then_answers_each_frame_in_order(self):
        result = self.serve(bitmap(64, 32) + bitmap(32, 32))
        self.assertEqual(result.returncode, 0, result.stderr)
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(replies[0], {'version': 1, 'ready': True})
        self.assertEqual(len(replies), 3)
        for reply in replies[1:]:
            self.assertEqual(reply, {'version': 1, 'lines': []})

    def test_refused_frame_is_answered_without_ending_the_process(self):
        with patch.object(worker, 'recognize', side_effect=[ValueError('bounds'), b'{"version":1,"lines":[]}']), \
                patch.object(worker, 'load_engine', return_value=object()), \
                patch.object(sys, 'stdin', io.TextIOWrapper(io.BytesIO(bitmap() + bitmap()))), \
                patch.object(sys, 'stdout', io.TextIOWrapper(io.BytesIO())) as out:
            self.assertEqual(worker.serve(), 0)
            out.flush()
            lines = out.buffer.getvalue().splitlines()
        self.assertEqual([json.loads(l) for l in lines],
                         [{'version': 1, 'ready': True}, {'version': 1, 'failed': True},
                          {'version': 1, 'lines': []}])

    def test_malformed_frame_ends_the_process(self):
        result = self.serve(bitmap() + b'X' * 54)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, b'Local OCR worker failed\n')
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(replies), 2)

    def test_bitmap_density_declares_a_retina_capture(self):
        def with_density(value):
            data = bytearray(bitmap())
            data[38:46] = struct.pack('<ii', value, value)
            return bytes(data)
        self.assertEqual([worker.read_frame(io.BytesIO(with_density(v)))[1] for v in (0, 2835, 5668, 5669, 8504)],
                         [False, False, False, True, True])

    def test_framed_reader_returns_none_only_at_a_clean_boundary(self):
        stream = io.BytesIO(bitmap() + bitmap())
        self.assertIsNotNone(worker.read_image(stream, framed=True))
        self.assertIsNotNone(worker.read_image(stream, framed=True))
        self.assertIsNone(worker.read_image(stream, framed=True))
        with self.assertRaises(ValueError):
            worker.read_image(io.BytesIO(bitmap()[:30]), framed=True)


class CoverageDetectorTests(unittest.TestCase):
    """Real screens that the whole-frame detector alone lost."""

    @classmethod
    def setUpClass(cls):
        # The engine as the app runs it.
        cls.engine = worker.load_engine(Path(__file__).parent/'models', **worker.SERVE_ENGINE)

    def page(self, width, height, wide=False):
        import numpy as np
        from PIL import Image, ImageDraw, ImageFont
        font = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', 24)
        image = Image.new('RGB', (width, height), 'white')
        draw = ImageDraw.Draw(image)
        draw.text((40, 40), 'Normal paragraph line one for the check', fill='black', font=font)
        draw.text((40, 88), 'Normal paragraph line two for the check', fill='black', font=font)
        if wide:
            draw.text((10, 600), '  '.join('Bookmark item %d' % i for i in range(16)), fill='black', font=font)
        return np.array(image)[:, :, ::-1].copy()

    def test_sparse_retina_frame_is_read(self):
        # A short document in a large window: the first pass finds nothing.
        result = self.engine(self.page(3420, 2214))
        self.assertEqual(list(result.txts), ['Normal paragraph line one for the check',
                                             'Normal paragraph line two for the check'])

    def test_sparse_retina_window_is_read_whatever_its_size(self):
        # Most windows are narrower than 2560 pixels; the capture declares 2x.
        self.engine.frame.retina = True
        try:
            result = self.engine(self.page(2400, 1600))
        finally:
            self.engine.frame.retina = False
        self.assertEqual(list(result.txts), ['Normal paragraph line one for the check',
                                             'Normal paragraph line two for the check'])

    def test_declared_retina_frame_is_detected_at_half_scale(self):
        import numpy as np
        image = np.full((1600, 2400, 3), 255, dtype=np.uint8)
        frame = self.engine.frame
        frame.width, frame.height, frame.second_look = 2400, 1600, False
        try:
            frame.retina = False
            self.assertEqual(self.engine.text_det.get_preprocess(2400)(image).shape[2:], (1600, 2400))
            frame.retina = True
            self.assertEqual(self.engine.text_det.get_preprocess(2400)(image).shape[2:], (800, 1216))
            # A second look at a small patch stays at its native size.
            frame.second_look = True
            patch_image = np.full((128, 608, 3), 255, dtype=np.uint8)
            self.assertEqual(self.engine.text_det.get_preprocess(608)(patch_image).shape[2:], (128, 608))
        finally:
            frame.retina, frame.second_look = False, False

    def test_lines_already_read_are_not_recognized_again(self):
        from PIL import Image, ImageDraw, ImageFont
        import numpy as np
        sent = []
        inner = self.engine.text_rec.recognizer
        recognize = type(inner).__call__

        def counting(recognizer, args):
            sent.append(len(args.img))
            return recognize(recognizer, args)

        page = self.page(1400, 400)
        with patch.object(type(inner), '__call__', counting):
            first = self.engine(page)
            again = self.engine(page)
            typed = Image.fromarray(page[:, :, ::-1].copy())
            ImageDraw.Draw(typed).text((40, 200), 'One more line typed just now', fill='black',
                                       font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', 24))
            third = self.engine(np.array(typed)[:, :, ::-1].copy())
        self.assertEqual(list(again.txts), list(first.txts))
        self.assertEqual(list(again.scores), list(first.scores))
        self.assertEqual(list(third.txts), list(first.txts) + ['One more line typed just now'])
        # Only the first reading, then only the new line, reached the model.
        self.assertEqual(sent, [2, 1])

    def test_a_line_is_known_by_its_ink_not_its_margin(self):
        import numpy as np
        line = np.full((40, 300, 3), 250, dtype=np.uint8)
        line[12:28, 20:200] = 30
        wider = np.full((48, 330, 3), 250, dtype=np.uint8)
        wider[18:34, 40:220] = 30
        self.assertEqual(worker._line_key(line), worker._line_key(wider))
        other = line.copy()
        other[12:28, 60:70] = 250
        self.assertNotEqual(worker._line_key(line), worker._line_key(other))
        # Faint text beside the line is still part of it.
        faint = line.copy()
        faint[12:28, 230:280] = 244
        self.assertNotEqual(worker._line_key(line), worker._line_key(faint))

    def test_remembered_lines_stay_within_their_bound(self):
        import numpy as np
        from rapidocr.ch_ppocr_rec import TextRecInput, TextRecOutput

        class Reader:
            def __call__(self, args):
                return TextRecOutput(args.img, tuple('x' for _ in args.img), tuple(0.9 for _ in args.img))

        remembered = worker.RememberedRecognizer(Reader())
        remembered.MAX_LINES = 4
        for value in range(10):
            crop = np.full((8, 8, 3), 255, dtype=np.uint8)
            crop[2:6, 2:6] = value
            remembered(TextRecInput(img=[crop]))
        self.assertEqual(len(remembered.readings), 4)

    def test_one_wide_line_no_longer_refuses_the_frame(self):
        result = self.engine(self.page(3420, 2214, wide=True))
        text = ' '.join(result.txts)
        self.assertIn('Normal paragraph line two for the check', text)
        for i in range(16):
            self.assertIn('Bookmark item %d' % i, text)

    def test_wide_lines_split_at_gaps_within_the_recognition_bound(self):
        import numpy as np
        image = np.full((40, 4000, 3), 255, dtype=np.uint8)
        for start in range(0, 4000, 200):
            image[10:30, start + 20:start + 160] = 0  # words with blank gaps
        pieces = worker._split_wide(image, [0, 0, 4000, 40])
        self.assertGreater(len(pieces), 1)
        self.assertEqual(pieces[0][0], 0)
        self.assertEqual(pieces[-1][2], 4000)
        for (x0, _, x1, _), nxt in zip(pieces, pieces[1:] + [None]):
            self.assertLessEqual((x1 - x0) / 40, worker.MAX_LINE_RATIO)
            if nxt:
                self.assertEqual(x1, nxt[0])
                self.assertEqual(image[10:30, int(x1)].min(), 255, 'cut through ink')

    def test_a_frame_with_text_reports_its_pane_separators(self):
        try:
            reply = json.loads(worker.recognize(self.engine, self.two_panes(), retina=True))
        finally:
            self.engine.frame.retina = False
        self.assertEqual(reply['version'], 1)
        self.assertIn('The page beside the sidebar has text', [line['text'] for line in reply['lines']])
        vertical = [s for s in reply['separators'] if s[2] == 0]
        self.assertEqual(len(vertical), 1, reply['separators'])
        x, y, w, h = vertical[0]
        self.assertAlmostEqual(x, 600 / 2400, delta=2 / 2400)
        self.assertGreater(h, 0.9)

    def test_an_empty_reading_keeps_the_old_reply(self):
        import numpy as np
        reply = json.loads(worker.recognize(self.engine, np.full((400, 600, 3), 255, dtype=np.uint8)))
        self.assertEqual(reply, {'version': 1, 'lines': []})

    def two_panes(self):
        """A grey sidebar beside a white page, each with text. Its lines are
        its own: the engine is shared, and the line cache test expects to read
        its lines for the first time."""
        import numpy as np
        from PIL import Image, ImageDraw, ImageFont
        font = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', 24)
        image = Image.new('RGB', (2400, 1500), 'white')
        draw = ImageDraw.Draw(image)
        draw.rectangle([0, 0, 599, 1499], fill=(236, 236, 238))
        draw.text((40, 120), 'Inbox', fill='black', font=font)
        draw.text((40, 170), 'Drafts', fill='black', font=font)
        draw.text((680, 120), 'The page beside the sidebar has text', fill='black', font=font)
        draw.text((680, 170), 'and a second line under the first', fill='black', font=font)
        return np.array(image)[:, :, ::-1].copy()

    def test_only_boxes_from_different_runs_merge(self):
        import numpy as np
        quad = np.zeros((4, 2), dtype=np.float32)
        same = worker._merge_across_sources([(quad, [0, 0, 100, 20], 0.9, 0), (quad, [90, 0, 200, 20], 0.8, 0)])
        self.assertEqual(len(same), 2)
        across = worker._merge_across_sources([(quad, [0, 0, 100, 20], 0.9, 0), (quad, [90, 0, 200, 20], 0.8, 1)])
        self.assertEqual(len(across), 1)
        self.assertIsNone(across[0][0])
        self.assertEqual(across[0][1], [0, 0, 200, 20])


class PaneSeparatorTests(unittest.TestCase):
    """Where a window divides into panes, found from its pixels."""

    def frame(self, width=1200, height=800):
        import numpy as np
        return np.full((height, width, 3), 255, dtype=np.uint8)

    def test_a_change_of_background_is_a_vertical_separator(self):
        image = self.frame()
        image[:, :300] = 236
        separators = worker.pane_separators(image, [])
        self.assertEqual(separators, [[300 / 1200, 0.0, 0.0, 1.0]])

    def test_a_hairline_is_one_separator_and_a_bar_is_horizontal(self):
        image = self.frame()
        image[:, 400:402] = 200          # a two-pixel rule between panes
        image[:60, :] = 240              # a title bar across the top
        separators = worker.pane_separators(image, [])
        vertical = [s for s in separators if s[2] == 0]
        horizontal = [s for s in separators if s[3] == 0]
        self.assertEqual(len(vertical), 1, separators)
        self.assertAlmostEqual(vertical[0][0], 400 / 1200, delta=2 / 1200)
        self.assertEqual(len(horizontal), 1, separators)
        x, y, w, h = horizontal[0]
        # Bottom-left origin, as the line boxes use: 60 px down is 740 up.
        self.assertAlmostEqual(y, 740 / 800, delta=1 / 800)
        self.assertEqual((x, w), (0.0, 1.0))

    def test_an_edge_that_text_crosses_is_not_a_separator(self):
        image = self.frame()
        image[:, :300] = 236
        crossing = [[250.0, 390.0, 520.0, 420.0]]    # x0, y0, x1, y1 across x = 300
        beside = [[320.0, 390.0, 520.0, 420.0]]
        self.assertEqual(worker.pane_separators(image, crossing), [])
        self.assertEqual(len(worker.pane_separators(image, beside)), 1)

    def test_short_edges_and_the_frame_border_are_not_separators(self):
        image = self.frame()
        image[100:150, 200:400] = 0      # a block smaller than a pane in both directions
        image[:, :1] = 0                 # the frame's own border
        self.assertEqual(worker.pane_separators(image, []), [])

    def test_a_frame_too_small_to_hold_panes_has_no_separators(self):
        for height, width in ((1, 400), (400, 1), (7, 7)):
            with self.subTest(height=height, width=width):
                self.assertEqual(worker.pane_separators(self.frame(width, height), []), [])

    def test_a_small_gap_in_an_edge_is_bridged(self):
        image = self.frame()
        image[:, :300] = 236
        image[395:398, :300] = 255       # three pixels where the panes match
        separators = worker.pane_separators(image, [])
        self.assertEqual(len(separators), 1)
        self.assertGreater(separators[0][3], 0.99)

    def test_half_scale_analysis_reports_full_size_positions(self):
        image = self.frame(2400, 1600)
        image[:, :640] = 236
        image[:120, :] = 230
        separators = worker.pane_separators(image, [], half=True)
        vertical = [s for s in separators if s[2] == 0]
        horizontal = [s for s in separators if s[3] == 0]
        self.assertAlmostEqual(vertical[0][0], 640 / 2400, delta=2 / 2400)
        self.assertAlmostEqual(horizontal[0][1], 1480 / 1600, delta=2 / 1600)

    def test_a_reply_over_the_size_limit_drops_the_separators_and_keeps_every_line(self):
        import numpy as np
        from types import SimpleNamespace
        image = self.frame(600, 400)
        image[:, :200] = 236             # a sidebar beside the page: one vertical separator
        quads = [[[220.0, 20.0 + 18 * i], [580.0, 20.0 + 18 * i], [580.0, 32.0 + 18 * i], [220.0, 32.0 + 18 * i]]
                 for i in range(20)]
        result = SimpleNamespace(txts=tuple(f'Line {i} of the page' for i in range(20)),
                                 scores=tuple(0.9 for _ in range(20)), boxes=np.array(quads))

        class Engine:
            frame = worker.FrameState()

            def __call__(self, image):
                return result

        full = json.loads(worker.recognize(Engine(), image))
        self.assertTrue(full['separators'])
        lines_only = json.dumps({'version': 1, 'lines': full['lines']}, ensure_ascii=False,
                                allow_nan=False).encode('utf-8')
        # Lines and separators exceed the limit; lines alone fit exactly.
        with patch.object(worker, 'MAX_REPLY', len(lines_only)):
            reply = json.loads(worker.recognize(Engine(), image))
        self.assertEqual(reply, {'version': 1, 'lines': full['lines']})
        self.assertEqual(len(reply['lines']), 20)
        # Lines alone over the limit refuse the reading, never cut it short.
        with patch.object(worker, 'MAX_REPLY', len(lines_only) - 1), self.assertRaisesRegex(ValueError, 'too large'):
            worker.recognize(Engine(), image)

    def test_separators_cost_little_beside_a_reading(self):
        # A Retina window with panes and text-like noise. The reading itself
        # takes well over a second; separators must stay a small part of it.
        import time
        import numpy as np
        rng = np.random.default_rng(7)
        image = self.frame(2880, 1800)
        image[:, :560] = 236
        image[:72, :] = 228
        image[:, 2100:2102] = 200
        for row in range(120, 1760, 36):
            for start in rng.integers(600, 2700, size=12):
                image[row:row + 20, start:start + int(rng.integers(20, 140))] = 30
        rects = [[600.0 + 180 * i, 120.0 + 36 * j, 760.0 + 180 * i, 140.0 + 36 * j]
                 for i in range(8) for j in range(40)]
        timings = []
        for _ in range(5):
            started = time.process_time()
            worker.pane_separators(image, rects, half=True)
            timings.append(time.process_time() - started)
        # Under 10 ms of wall time on an idle M-series Mac. CPU time, so a
        # busy machine does not fail the test, with room for library threads.
        self.assertLess(sorted(timings)[2], 0.15)

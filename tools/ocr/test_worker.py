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
        cls.engine = worker.load_engine(Path(__file__).parent/'models', threads=2)

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

    def test_only_boxes_from_different_runs_merge(self):
        import numpy as np
        quad = np.zeros((4, 2), dtype=np.float32)
        same = worker._merge_across_sources([(quad, [0, 0, 100, 20], 0.9, 0), (quad, [90, 0, 200, 20], 0.8, 0)])
        self.assertEqual(len(same), 2)
        across = worker._merge_across_sources([(quad, [0, 0, 100, 20], 0.9, 0), (quad, [90, 0, 200, 20], 0.8, 1)])
        self.assertEqual(len(across), 1)
        self.assertIsNone(across[0][0])
        self.assertEqual(across[0][1], [0, 0, 200, 20])

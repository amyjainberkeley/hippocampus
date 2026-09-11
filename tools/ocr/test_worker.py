import io
import json
import struct
import subprocess
import sys
import unittest
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

if __name__ == '__main__':
    unittest.main()

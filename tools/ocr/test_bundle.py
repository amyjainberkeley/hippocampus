import json
import shutil
from worker import MODELS
from pathlib import Path
import tempfile
import unittest
import bundle


class BundleTests(unittest.TestCase):
    def test_missing_or_stale_build_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw)
            with self.assertRaises(ValueError):
                bundle.verify_runtime(root)
            (root/'build-manifest.json').write_text(json.dumps({'source_inputs':{},'executable_sha256':'bad'}))
            (root/'hippocampus-ocr').write_bytes(b'not a real worker')
            with self.assertRaises(ValueError):
                bundle.verify_runtime(root)

    def test_changed_native_dependency_invalidates_frozen_worker(self):
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw)
            (root/'hippocampus-ocr').write_bytes(b'synthetic bootloader')
            dependency=root/'library.dylib'
            dependency.write_bytes(b'original synthetic native library')
            shutil.copytree(bundle.ROOT/'models',root/'_internal'/'models')
            marker={'source_inputs':bundle.source_inputs(),
                    'executable_sha256':bundle.file_hash(root/'hippocampus-ocr'),
                    'runtime_inventory':bundle.runtime_inventory(root)}
            (root/'build-manifest.json').write_text(json.dumps(marker))
            bundle.verify_runtime(root)
            dependency.write_bytes(b'changed native dependency')
            with self.assertRaisesRegex(ValueError, 'inventory mismatch'):
                bundle.verify_runtime(root)

    def test_mismatched_executable_invalidates_frozen_worker(self):
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw)
            marker={'source_inputs':bundle.source_inputs(),'executable_sha256':'not-matching'}
            (root/'build-manifest.json').write_text(json.dumps(marker))
            (root/'hippocampus-ocr').write_bytes(b'wrong binary')
            with self.assertRaises(ValueError):
                bundle.verify_runtime(root)


if __name__=='__main__':
    unittest.main()

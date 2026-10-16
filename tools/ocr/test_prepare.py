"""The frozen worker leaves out video: prepare.drop_video on small libraries
built here in the shape the OpenCV wheel and PyInstaller give the worker."""
import ctypes
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import bundle
import prepare

CLANG = shutil.which('clang') or '/usr/bin/clang'


def compile_c(output, source, *flags):
    """Build `source` without chained fixups, as the OpenCV wheel's binaries
    are, so the weak-import flags live in bind opcodes."""
    c_file = output.with_name(output.name + '.c')
    c_file.write_text(source)
    subprocess.run([CLANG, '-arch', 'arm64', '-mmacosx-version-min=11.0', '-Wl,-no_fixup_chains',
                    '-o', str(output), str(c_file), *flags], check=True, capture_output=True)
    c_file.unlink()
    return output


def worker_shape(root, chained=False, keep_needs_x264=False):
    """hippocampus-ocr and _internal/ as PyInstaller lays them out: cv2.abi3.so
    links its .dylibs/ copies of a video library (which needs x264) and of
    a library it really uses, and _internal/ holds symlinks to them."""
    internal = root / '_internal'
    dylibs = internal / 'cv2' / '.dylibs'
    dylibs.mkdir(parents=True)
    compile_c(root / 'hippocampus-ocr', 'int main(void) { return 0; }\n')
    compile_c(dylibs / 'libx264.164.dylib', 'int x264_encode(void) { return 264; }\n',
              '-dynamiclib', '-install_name', '@rpath/libx264.164.dylib')
    compile_c(dylibs / 'libavcodec.61.dylib',
              'extern int x264_encode(void);\nint avcodec_version(void) { return x264_encode(); }\n',
              '-dynamiclib', '-install_name', '@rpath/libavcodec.61.dylib', '-L', str(dylibs), '-lx264.164',
              '-Wl,-rpath,@loader_path')
    keep_source = 'int keep(void) { return 41; }\n'
    keep_flags = ['-dynamiclib', '-install_name', '@rpath/libkeep.1.dylib']
    if keep_needs_x264:
        keep_source = 'extern int x264_encode(void);\nint keep(void) { return x264_encode() - 223; }\n'
        keep_flags += ['-L', str(dylibs), '-lx264.164', '-Wl,-rpath,@loader_path']
    compile_c(dylibs / 'libkeep.1.dylib', keep_source, *keep_flags)
    # A pointer to a video function is bound when the module loads, the way
    # OpenCV binds avcodec_default_get_format.
    module_source = ('extern int avcodec_version(void);\nextern int keep(void);\n'
                     'int (*video_entry)(void) = avcodec_version;\n'
                     'int module_works(void) { return keep() + 1; }\n')
    flags = ['-bundle', '-L', str(dylibs), '-lavcodec.61', '-lkeep.1', '-Wl,-rpath,@loader_path/.dylibs']
    module = internal / 'cv2' / 'cv2.abi3.so'
    if chained:
        subprocess.run([CLANG, '-arch', 'arm64', '-mmacosx-version-min=13.0', '-Wl,-fixup_chains', '-o',
                        str(module), '-x', 'c', '-', *flags], input=module_source.encode(), check=True,
                       capture_output=True)
    else:
        compile_c(module, module_source, *flags)
    for library in dylibs.iterdir():
        (internal / library.name).symlink_to(Path('cv2') / '.dylibs' / library.name)
    return module


@unittest.skipUnless(sys.platform == 'darwin' and os.path.exists(CLANG), 'builds Mach-O files with clang')
class DropVideoTests(unittest.TestCase):
    def test_video_and_its_encoders_are_left_out_and_the_module_still_loads(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            module = worker_shape(root)
            original = module.read_bytes()

            removed = prepare.drop_video(root)

            internal = root / '_internal'
            self.assertIn('_internal/cv2/.dylibs/libavcodec.61.dylib', removed)
            self.assertIn('_internal/cv2/.dylibs/libx264.164.dylib', removed)
            for name in ('libavcodec.61.dylib', 'libx264.164.dylib'):
                self.assertFalse((internal / 'cv2' / '.dylibs' / name).exists())
                self.assertFalse(os.path.lexists(internal / name), 'a dangling symlink stayed')
            self.assertTrue((internal / 'cv2' / '.dylibs' / 'libkeep.1.dylib').is_file())
            self.assertTrue((internal / 'libkeep.1.dylib').exists())
            links = dict(prepare.macho_links(module)[0])
            self.assertTrue(links['@rpath/libavcodec.61.dylib'], 'the video link is not weak')
            self.assertFalse(links['@rpath/libkeep.1.dylib'])
            subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(module)], check=True,
                           capture_output=True)
            # The module loads with the video libraries gone and still works.
            self.assertEqual(ctypes.CDLL(str(module)).module_works(), 42)
            self.assertIsNone(ctypes.c_void_p.in_dll(ctypes.CDLL(str(module)), 'video_entry').value)
            # The same module as linked, beside it, does not load at all.
            control = module.with_name('control.so')
            control.write_bytes(original)
            with self.assertRaisesRegex(OSError, 'libavcodec'):
                ctypes.CDLL(str(control))

    def test_an_encoder_something_else_needs_stops_the_build(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            worker_shape(root, keep_needs_x264=True)
            with self.assertRaisesRegex(ValueError, 'video libraries left'):
                prepare.drop_video(root)

    def test_a_module_with_chained_fixups_is_refused_rather_than_half_weakened(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            module = worker_shape(root, chained=True)
            before = module.read_bytes()
            with self.assertRaisesRegex(ValueError, 'chained fixups'):
                prepare.weaken_links(module, prepare.VIDEO_LIBRARIES)
            self.assertEqual(module.read_bytes(), before)


class FrozenWorkerTests(unittest.TestCase):
    def test_a_worker_that_carries_video_libraries_is_not_embedded(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / 'hippocampus-ocr').write_bytes(b'synthetic bootloader')
            shutil.copytree(bundle.ROOT / 'models', root / '_internal' / 'models')
            (root / '_internal' / 'libx265.215.dylib').write_bytes(b'synthetic encoder')
            marker = {'source_inputs': bundle.source_inputs(),
                      'executable_sha256': bundle.file_hash(root / 'hippocampus-ocr'),
                      'runtime_inventory': bundle.runtime_inventory(root)}
            (root / 'build-manifest.json').write_text(json.dumps(marker))
            with self.assertRaisesRegex(ValueError, 'video'):
                bundle.verify_runtime(root)

    def test_the_built_worker_carries_no_video_libraries(self):
        worker = bundle.ROOT / 'dist' / 'hippocampus-ocr'
        if not worker.is_dir():
            self.skipTest('no frozen worker in tools/ocr/dist')
        left = [path.name for path in worker.rglob('*')
                if bundle.VIDEO_LIBRARIES.search(path.name) or bundle.NEVER_SHIPPED.search(path.name)]
        self.assertEqual(left, [])


if __name__ == '__main__':
    unittest.main()

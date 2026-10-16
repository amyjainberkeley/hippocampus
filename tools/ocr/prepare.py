"""Build-only model preparation and standalone macOS worker freezing."""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import urllib.request
from worker import MODELS
from bundle import NEVER_SHIPPED, VIDEO_LIBRARIES, source_inputs, file_hash, runtime_inventory

ROOT = Path(__file__).resolve().parent
URLS = {
    'PP-OCRv6_det_small.onnx': 'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.2/onnx/PP-OCRv6/det/PP-OCRv6_det_small.onnx',
    'PP-OCRv6_rec_small.onnx': 'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.2/onnx/PP-OCRv6/rec/PP-OCRv6_rec_small.onnx',
    'ch_ppocr_mobile_v2.0_cls_mobile.onnx': 'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.2/onnx/PP-OCRv4/cls/ch_ppocr_mobile_v2.0_cls_mobile.onnx',
}


def prepare_models():
    models = ROOT / 'models'
    models.mkdir(exist_ok=True)
    for name, digest in MODELS.items():
        path = models / name
        if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
            continue
        with urllib.request.urlopen(URLS[name], timeout=60) as response:
            data = response.read(100 * 1024 * 1024 + 1)
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError('OCR model checksum mismatch: ' + name)
        temporary = path.with_suffix('.pending')
        temporary.write_bytes(data)
        temporary.replace(path)
    return models


# No video in the worker. The opencv-python-headless wheel links OpenCV's
# video module to a GPL build of FFmpeg, which brings the x264 and x265
# encoders and some seventy other libraries. Reading a screenshot never
# touches video, so the frozen worker keeps none of them: OpenCV's links to
# FFmpeg become weak, so it loads without them, and every library that only
# FFmpeg reached is removed. A video call from OpenCV would now fail; the
# worker makes none. bundle.py names the libraries (VIDEO_LIBRARIES, and
# NEVER_SHIPPED for the encoders) and refuses a worker that has one.

LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB = 0xC, 0x80000018, 0x8000001F
LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB, LC_RPATH = 0x20, 0x80000023, 0x8000001C
LC_DYLD_INFO, LC_DYLD_INFO_ONLY, LC_DYLD_CHAINED_FIXUPS = 0x22, 0x80000022, 0x80000034
LINKS = {LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB}
FAT_MAGIC, MACHO_64_MAGIC = b'\xca\xfe\xba\xbe', b'\xcf\xfa\xed\xfe'
BIND_SYMBOL_FLAGS_WEAK_IMPORT = 0x1


def is_macho(path):
    if path.is_symlink() or not path.is_file():
        return False
    with path.open('rb') as f:
        return f.read(4) in (FAT_MAGIC, MACHO_64_MAGIC)


def macho_slices(data):
    """Offsets of the 64-bit Mach-O images in a thin or universal file."""
    if data[:4] == MACHO_64_MAGIC:
        return [0]
    if data[:4] == FAT_MAGIC:
        count = struct.unpack('>I', data[4:8])[0]
        offsets = [struct.unpack('>iiIII', data[8 + 20 * i:28 + 20 * i])[2] for i in range(count)]
        return [offset for offset in offsets if data[offset:offset + 4] == MACHO_64_MAGIC]
    return []


def load_commands(data, offset):
    """(position, command) for each load command of the image at `offset`."""
    count = struct.unpack('<I', data[offset + 16:offset + 20])[0]
    position = offset + 32
    for _ in range(count):
        command, size = struct.unpack('<II', data[position:position + 8])
        yield position, command
        position += size


def command_string(data, position):
    start = position + struct.unpack('<I', data[position + 8:position + 12])[0]
    return data[start:data.index(b'\0', start)].decode('utf-8')


def macho_links(path):
    """([(install name, weak)], [rpath]) of every image in a Mach-O file."""
    data = path.read_bytes()
    links, rpaths = [], []
    for offset in macho_slices(data):
        for position, command in load_commands(data, offset):
            if command in LINKS:
                links.append((command_string(data, position), command == LC_LOAD_WEAK_DYLIB))
            elif command == LC_RPATH:
                rpaths.append(command_string(data, position))
    return links, rpaths


def uleb128(data, at):
    value = shift = 0
    while True:
        byte = data[at]
        at += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return value, at


def weaken_binds(data, start, size, ordinals):
    """Mark every symbol a bind opcode stream binds from a library in
    `ordinals` as a weak import, in place, so dyld binds it to zero when the
    library is missing. The flag lives in the opcode byte that names the
    symbol, so the stream keeps its length. Returns how many were marked."""
    at, end = start, start + size
    ordinal, symbol, marked = 0, None, set()
    while at < end:
        byte = data[at]
        opcode, immediate = byte & 0xF0, byte & 0x0F
        at += 1
        if opcode == 0x00:                                  # DONE
            continue
        if opcode == 0x10:                                  # SET_DYLIB_ORDINAL_IMM
            ordinal = immediate
        elif opcode == 0x20:                                # SET_DYLIB_ORDINAL_ULEB
            ordinal, at = uleb128(data, at)
        elif opcode == 0x30:                                # SET_DYLIB_SPECIAL_IMM
            ordinal = -immediate
        elif opcode == 0x40:                                # SET_SYMBOL_TRAILING_FLAGS_IMM
            symbol = at - 1
            at = data.index(b'\0', at) + 1
        elif opcode in (0x50, 0x90, 0xB0):                  # SET_TYPE_IMM, DO_BIND, DO_BIND_ADD_ADDR_IMM_SCALED
            pass
        elif opcode in (0x60, 0x70, 0x80, 0xA0):            # SET_ADDEND_SLEB, SET_SEGMENT_AND_OFFSET_ULEB,
            _, at = uleb128(data, at)                       # ADD_ADDR_ULEB, DO_BIND_ADD_ADDR_ULEB
        elif opcode == 0xC0:                                # DO_BIND_ULEB_TIMES_SKIPPING_ULEB
            _, at = uleb128(data, at)
            _, at = uleb128(data, at)
        elif opcode == 0xD0:                                # THREADED
            if immediate == 0x00:
                _, at = uleb128(data, at)
        else:
            raise ValueError(f'unknown bind opcode {byte:#x}')
        # What binds is the symbol in force when a bind happens, from the
        # library in force then.
        if opcode in (0x90, 0xA0, 0xB0, 0xC0) and ordinal in ordinals and symbol is not None:
            marked.add(symbol)
    for position in marked:
        data[position] |= BIND_SYMBOL_FLAGS_WEAK_IMPORT
    return len(marked)


def weaken_links(path, pattern):
    """Make `path` load without the libraries whose file names match
    `pattern`: each link to one becomes weak (the two commands share one
    layout, so only the command word changes) and each symbol bound from one
    a weak import. In place. Returns the install names changed."""
    original = path.read_bytes()
    data = bytearray(original)
    changed = []
    for offset in macho_slices(original):
        links, infos = [], []
        for position, command in load_commands(original, offset):
            if command in LINKS:
                links.append((position, command))
            elif command in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
                infos.append(position)
            elif command == LC_DYLD_CHAINED_FIXUPS:
                raise ValueError(f'{path.name} uses chained fixups, which this build cannot weaken')
        # A bind names its library by ordinal: its link's place, from one.
        ordinals = set()
        for ordinal, (position, command) in enumerate(links, 1):
            name = command_string(original, position)
            if pattern.search(os.path.basename(name)):
                ordinals.add(ordinal)
                changed.append(name)
                if command == LC_LOAD_DYLIB:
                    data[position:position + 4] = struct.pack('<I', LC_LOAD_WEAK_DYLIB)
        for position in infos if ordinals else ():
            # dyld_info_command: rebase, bind, weak bind, lazy bind and
            # export, each an (offset, size). Weak binds coalesce; they never
            # import from a library.
            fields = struct.unpack('<10I', original[position + 8:position + 48])
            for start, size in ((fields[2], fields[3]), (fields[6], fields[7])):
                if size:
                    weaken_binds(data, offset + start, size, ordinals)
    if data != original:
        path.write_bytes(bytes(data))
    return changed


def resolve_link(name, image, executable, rpaths):
    """The file dyld loads for `name` linked from `image`, with `rpaths` the
    search list (the image's own, then its loaders'), or None for a system
    library or one that is not in the bundle."""
    def expand(path, origin):
        if path.startswith('@loader_path'):
            return origin.parent / path[len('@loader_path/'):]
        if path.startswith('@executable_path'):
            return executable.parent / path[len('@executable_path/'):]
        return Path(path)
    if name.startswith('@rpath/'):
        candidates = [expand(rpath, origin) / name[len('@rpath/'):] for rpath, origin in rpaths]
    elif name.startswith('@'):
        candidates = [expand(name, image)]
    else:
        candidates = [Path(name)]
    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()
    return None


def reachable(files, roots, executable, skip=lambda image, name: False):
    """Real paths of the Mach-O files that `roots` load, following links the
    way dyld does (each image's rpaths, then its loaders')."""
    known = {path.resolve() for path in files}
    # What the main executable loads by name searches its rpaths too.
    top = tuple((rpath, executable) for rpath in macho_links(executable)[1]) if is_macho(executable) else ()
    seen, stack = set(), [(root.resolve(), top) for root in roots]
    while stack:
        image, inherited = stack.pop()
        if image in seen:
            continue
        seen.add(image)
        links, rpaths = macho_links(image)
        search = tuple((rpath, image) for rpath in rpaths) + inherited
        for name, _ in links:
            if skip(image, name):
                continue
            target = resolve_link(name, image, executable, search)
            if target in known:
                stack.append((target, search))
    return seen


def drop_video(destination, identity=None):
    """Remove FFmpeg and everything only it needs from a frozen worker, and
    weaken OpenCV's links to it. Returns the removed paths, relative."""
    executable = destination / 'hippocampus-ocr'
    files = [path for path in destination.rglob('*') if is_macho(path)]
    modules = [path for path in files if path.suffix == '.so']
    weakened = [path for path in modules if weaken_links(path, VIDEO_LIBRARIES)]
    for path in weakened:
        # The edit voids the module's signature; bundle.py signs it again
        # with the app's identity when it embeds the worker.
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity or '-', str(path)],
                       check=True, capture_output=True)
    roots = [path for path in files if path.suffix != '.dylib']
    linked = reachable(files, roots, executable)
    # A library nothing links is loaded by name at run time (libpython,
    # ONNX Runtime): it stays, and so does what it needs.
    roots += [path for path in files if path.resolve() not in linked
              and not VIDEO_LIBRARIES.search(path.name) and not NEVER_SHIPPED.search(path.name)]
    before = reachable(files, roots, executable)
    after = reachable(files, roots, executable,
                      skip=lambda image, name: VIDEO_LIBRARIES.search(os.path.basename(name)) is not None)
    removed = [path for path in files if path.resolve() in before - after
               or (path.resolve() not in after and (VIDEO_LIBRARIES.search(path.name) or NEVER_SHIPPED.search(path.name)))]
    for path in removed:
        path.unlink()
    for link in [path for path in destination.rglob('*') if path.is_symlink() and not path.exists()]:
        link.unlink()
        removed.append(link)
    left = [path for path in destination.rglob('*')
            if VIDEO_LIBRARIES.search(path.name) or NEVER_SHIPPED.search(path.name)]
    if left:
        raise ValueError('video libraries left in the OCR worker: ' + ', '.join(p.name for p in left))
    return sorted(str(path.relative_to(destination)) for path in removed)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT/'dist')
    parser.add_argument('--sign-identity')
    parser.add_argument('--models-only', action='store_true')
    args = parser.parse_args()
    # Freeze only the reviewed, hash-locked environment. The headless OpenCV
    # distribution intentionally replaces RapidOCR's GUI opencv-python extra.
    for line in (ROOT/'requirements.in').read_text().splitlines():
        name, version = line.split('==')
        if importlib.metadata.version(name) != version:
            raise ValueError('OCR build dependency mismatch: '+name)
    models = prepare_models()
    if args.models_only:
        return
    command = [sys.executable, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir',
               '--name', 'hippocampus-ocr', '--distpath', str(args.output),
               '--workpath', str(ROOT/'build'), '--specpath', str(ROOT/'build'),
               '--collect-all', 'rapidocr', '--collect-all', 'onnxruntime',
               '--add-data', str(models)+':models']
    if args.sign_identity:
        command += ['--codesign-identity', args.sign_identity]
    command += [str(ROOT/'worker.py')]
    subprocess.run(command, check=True)
    destination = args.output/'hippocampus-ocr'
    removed = drop_video(destination, args.sign_identity)
    print(f'left out {len(removed)} video libraries and links', file=sys.stderr)
    shutil.copy2(ROOT/'NOTICE.md', destination/'NOTICE.md')
    licenses=destination/'licenses'
    licenses.mkdir(exist_ok=True)
    for distribution in importlib.metadata.distributions():
        for relative in distribution.files or []:
            if any(word in str(relative).lower() for word in ('license','licence','copying','notice')):
                source=Path(distribution.locate_file(relative))
                if source.is_file() and '..' not in relative.parts:
                    target=licenses/distribution.metadata['Name']/relative
                    target.parent.mkdir(parents=True,exist_ok=True)
                    shutil.copy2(source,target)
    (destination/'model-manifest.json').write_text(json.dumps({'models': MODELS, 'sources': URLS}, indent=2)+'\n')
    (destination/'build-manifest.json').write_text(json.dumps({
        'source_inputs':source_inputs(),
        'executable_sha256':file_hash(destination/'hippocampus-ocr'),
        'runtime_inventory':runtime_inventory(destination),
    },indent=2)+'\n')


if __name__ == '__main__':
    main()

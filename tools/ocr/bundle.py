"""Verify the frozen worker matches source, then embed and sign it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from worker import MODELS

ROOT = Path(__file__).resolve().parent
SOURCES = ('worker.py','prepare.py','bundle.py','requirements.in','requirements.txt','NOTICE.md')
MACHO = {b'\xfe\xed\xfa\xcf',b'\xcf\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'}


def file_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_inputs():
    return {name:file_hash(ROOT/name) for name in SOURCES}


def runtime_inventory(source):
    result={}
    root=source.resolve()
    for path in sorted(source.rglob('*')):
        relative=path.relative_to(source).as_posix()
        if relative == 'build-manifest.json':
            continue
        if path.is_symlink():
            if not path.resolve().is_relative_to(root):
                raise ValueError('OCR runtime symlink escapes bundle')
            result[relative]={'symlink':os.readlink(path)}
        elif path.is_file():
            result[relative]={'sha256':file_hash(path)}
    return result


def verify_runtime(source):
    try:
        marker=json.loads((source/'build-manifest.json').read_text())
        executable=source/'hippocampus-ocr'
        if marker['source_inputs'] != source_inputs() or marker['executable_sha256'] != file_hash(executable):
            raise ValueError('stale OCR worker build')
        if marker['runtime_inventory'] != runtime_inventory(source):
            raise ValueError('OCR runtime inventory mismatch')
        for name, digest in MODELS.items():
            if file_hash(source/'_internal'/'models'/name) != digest:
                raise ValueError('invalid bundled OCR model')
    except (OSError, KeyError, json.JSONDecodeError) as error:
        raise ValueError('missing or invalid OCR worker build') from error


def embed(source, destination, identity):
    verify_runtime(source)
    if destination.exists():
        raise ValueError('OCR destination already exists; assemble into a fresh app')
    shutil.copytree(source,destination,symlinks=True)
    # Sign all native extensions/libraries before their containing frameworks.
    files=[]
    for path in destination.rglob('*'):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as f:
                if f.read(4) in MACHO:
                    files.append(path)
    files.sort(key=lambda p:(-len(p.parts),str(p)))
    frameworks=sorted(destination.rglob('*.framework'),key=lambda p:-len(p.parts))
    flags=['--force','--sign',identity]
    if identity != '-':
        flags += ['--options=runtime','--timestamp']
    for path in files+frameworks:
        subprocess.run(['/usr/bin/codesign',*flags,str(path)],check=True,capture_output=True)
        subprocess.run(['/usr/bin/codesign','--verify','--strict',str(path)],check=True,capture_output=True)


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--source',type=Path,default=ROOT/'dist'/'hippocampus-ocr')
    p.add_argument('--destination',type=Path,required=True)
    p.add_argument('--identity',required=True)
    args=p.parse_args()
    embed(args.source,args.destination,args.identity)


if __name__=='__main__':
    main()

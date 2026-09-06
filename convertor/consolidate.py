#!/usr/bin/env python3
"""Read-only provenance helpers for the withdrawn container migration.

Publishing is disabled. Use merge_library.py for original v1 score files.
"""
from __future__ import annotations

from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import stat

from song_bundle import encoded
from song_identity import group_sources

def log(message):
    print(f'{datetime.now().isoformat(timespec="seconds")} {message}', flush=True)


def lines(filename):
    with Path(filename).open(encoding='utf-8') as handle:
        for line in handle:
            yield json.loads(line)


def latest_songs(report):
    filename = report / 'songs.jsonl'
    return {item['key']: item for item in lines(filename)} if filename.exists() else {}


def save(filename, value):
    filename = Path(filename)
    temporary = filename.with_suffix(filename.suffix + '.tmp')
    with temporary.open('wb') as handle:
        handle.write(encoded(value))
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, filename)


def file_identity(info):
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns]


def checked_bytes(filename, digest=None, identity=None):
    descriptor = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as handle:
        before = os.fstat(handle.fileno())
        if not stat.S_ISREG(before.st_mode) or (identity is not None and file_identity(before) != identity):
            raise ValueError(f'File identity changed: {filename}')
        data = handle.read()
        if file_identity(os.fstat(handle.fileno())) != file_identity(before):
            raise ValueError(f'File changed while reading: {filename}')
    if digest is not None and hashlib.sha256(data).hexdigest() != digest:
        raise ValueError(f'SHA256 mismatch: {filename}')
    return data, file_identity(before)


def basename(value):
    if not value or value != Path(value).name or value in ('.', '..'):
        raise ValueError(f'Expected a single filename: {value!r}')
    return value


def inventory(root):
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Root must be a real directory')
    result = set()
    with os.scandir(root) as entries:
        for entry in entries:
            if not entry.is_file(follow_symlinks=False) or Path(entry.name).suffix.lower() != '.guitarget':
                raise ValueError(f'Unexpected file or directory: {entry.path}')
            result.add(entry.name)
    return result



def apply(args):
    raise ValueError("The v2 migration was withdrawn. Use merge_library.py for original v1 files.")


if __name__ == "__main__":
    raise SystemExit("This v2 migration is disabled. Use merge_library.py.")

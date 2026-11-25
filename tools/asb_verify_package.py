#!/usr/bin/env python3
"""Compare a flashable ZIP with its staged tree and its embedded payload hashes."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import tempfile
import zipfile


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def verify(stage, archive, commit):
    stage = stage.resolve(strict=True)
    if not stage.is_dir():
        raise ValueError('stage is not a directory')
    with tempfile.TemporaryDirectory(prefix='asb-zip-check-') as tmp, zipfile.ZipFile(archive) as z:
        root = Path(tmp)
        os.chmod(root, stat.S_IMODE(stage.stat().st_mode))
        seen = set()
        directories = []
        for info in z.infolist():
            name = info.filename.rstrip('/')
            p = PurePosixPath(name)
            if (not name or p.is_absolute() or any(x in ('.', '..') for x in p.parts)
                    or str(p) != name or name in seen):
                raise ValueError('unsafe or duplicate ZIP entry: ' + info.filename)
            seen.add(name)
            mode = info.external_attr >> 16
            target = root.joinpath(*p.parts)
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                directories.append((target, mode))
            elif stat.S_ISREG(mode):
                target.parent.mkdir(parents=True, exist_ok=True)
                with z.open(info) as src, target.open('wb') as dst:
                    while True:
                        data = src.read(1024 * 1024)
                        if not data:
                            break
                        dst.write(data)
                os.chmod(target, stat.S_IMODE(mode))
            else:
                raise ValueError('non-regular ZIP entry: ' + info.filename)
        for path, mode in reversed(directories):
            os.chmod(path, stat.S_IMODE(mode))
        def inventory(base):
            result = {}
            for p in base.rglob('*'):
                name = p.relative_to(base).as_posix()
                if p.is_symlink() or not (p.is_file() or p.is_dir()):
                    raise ValueError('non-regular staged/extracted entry: ' + name)
                if p.name.endswith('.DS_Store'):
                    continue
                result[name] = ('dir' if p.is_dir() else sha(p), stat.S_IMODE(p.stat().st_mode))
            return result
        expected, actual = inventory(stage), inventory(root)
        if expected != actual:
            bad = sorted(k for k in expected.keys() | actual.keys() if expected.get(k) != actual.get(k))
            raise ValueError('staged tree differs from extracted ZIP: ' + ', '.join(bad[:20]))
        manifest = json.loads((root / 'release-manifest.json').read_text())
        if manifest.get('distribution') != 'flashable-module' or manifest.get('source_commit') != commit:
            raise ValueError('manifest distribution or source commit mismatch')
        if sha(root / 'config/governor.conf') != manifest.get('shipped_config_sha256'):
            raise ValueError('config hash mismatch')
        for name, entry in manifest.get('artifacts', {}).items():
            p = PurePosixPath(name)
            if p.is_absolute() or '..' in p.parts or sha(root.joinpath(*p.parts)) != entry.get('sha256'):
                raise ValueError('artifact hash mismatch: ' + name)
        tar = subprocess.Popen(['tar', '--sort=name', '--mtime=@0', '--owner=0', '--group=0',
                                '--numeric-owner', '--format=gnu', '--exclude=./release-manifest.json',
                                '--exclude=*.DS_Store', '-cf', '-', '.'], cwd=root, stdout=subprocess.PIPE)
        digest = hashlib.sha256()
        while True:
            block = tar.stdout.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
        if tar.wait() or digest.hexdigest() != manifest.get('payload_sha256'):
            raise ValueError('extracted payload hash mismatch')
    print('Verified clean-unpacked flashable ZIP against staged tree, modes, commit and manifest hashes')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('stage', type=Path)
    p.add_argument('archive', type=Path)
    p.add_argument('commit')
    a = p.parse_args()
    try:
        verify(a.stage, a.archive, a.commit)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, json.JSONDecodeError) as exc:
        p.exit(1, 'Package verification failed: ' + str(exc) + '\n')


if __name__ == '__main__':
    main()

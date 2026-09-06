#!/usr/bin/env python3
"""Merge the audited library into ordinary v1 files, one per original GP version.

The previous, unapplied v2 staging is only a recoverable source archive. None of
those containers is published to the user's library or imported by the app.
"""
from __future__ import annotations

import argparse
import atexit
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor, wait, FIRST_COMPLETED
from datetime import datetime
import hashlib
import json
import multiprocessing
import os
from pathlib import Path
import stat
import time

import convert as runner
from consolidate import (basename, checked_bytes, file_identity, inventory, latest_songs,
                         lines, log, save)
from song_bundle import SCORE_KEYS, content_hash, encoded, extract_parts, name_key, safe_filename

BASE = Path(__file__).resolve().parent
ROOT = Path('/Users/ben/Desktop/Guitar Pro Tabs')
ARCHIVE = BASE / 'reports/consolidate-full-20260906'
METRICS = BASE / 'reports/v1-merge-analysis/source-metrics.jsonl'
DUPLICATES = BASE / 'reports/v1-merge-analysis/duplicate-versions-gp-sha.json'
_validator = None


def worker_start(timeout):
    global _validator
    runner._timeout = timeout
    _validator = runner.NativeValidator()
    atexit.register(_validator.close)


def build_version(title, entries):
    from merge_score import merge_version
    from main_guitar import select_main_guitar
    strict_failure = None
    try:
        score, detail = merge_version(title, entries)
        if set(score) != SCORE_KEYS or score['version'] != 1:
            raise ValueError('Strict merger did not produce the original v1 schema')
        validation = _validator.check(score)
        if not validation.get('valid'):
            raise ValueError('Strict merge: ' + '; '.join(validation.get('errors', [])))
        mode = 'merged'
    except Exception as error:
        strict_failure = error.as_dict() if hasattr(error, 'as_dict') else str(error)
        score, detail = select_main_guitar(title, entries)
        if set(score) != SCORE_KEYS or score['version'] != 1:
            raise ValueError('Primary guitar selection did not produce the original v1 schema')
        validation = _validator.check(score)
        if not validation.get('valid'):
            raise ValueError('Primary guitar score: ' + '; '.join(validation.get('errors', [])))
        mode = 'primary_guitar'
    return score, {'mode': mode, 'strict_failure': strict_failure, 'detail': detail,
                   'native_validation': validation}


def music_fingerprint(entries):
    def music(value):
        if isinstance(value, dict):
            return {key: music(item) for key, item in value.items()
                    if key not in ('id', 'title') and not (key in ('lyric', 'targetFret') and item is None)}
        if isinstance(value, list):
            return [music(item) for item in value]
        return value
    return content_hash([{'track': item['track_number'], 'part': item['part'],
                          'source_measures': item['source_measures'], 'score': music(item['score'])}
                         for item in sorted(entries, key=lambda item: (item['track_number'], item['part']))])


def prepare_group(task):
    archive, staging, group, versions = task
    results = []
    try:
        data, _ = checked_bytes(Path(archive) / 'songs' / group['filename'], group['sha256'])
        bundle = json.loads(data)
        parts = extract_parts(bundle)
        originals = {item['part_id']: item for item in group['originals']}
        if set(parts) != set(originals):
            raise ValueError('Archive coverage differs from original receipts')
        entries_by_source = defaultdict(list)
        originals_by_source = defaultdict(list)
        for part in bundle['collection']['parts']:
            score = parts[part['id']]
            if content_hash(score) != originals[part['id']]['content_sha256']:
                raise ValueError('Archive cannot reconstruct an original fragment')
            entries_by_source[part['source']].append({
                'source': part['source'], 'track_number': part['trackNumber'],
                'track_name': part['trackName'], 'part': part['partNumber'],
                'source_measures': part['sourceMeasures'], 'score': score})
            originals_by_source[part['source']].append(originals[part['id']])
        if set(entries_by_source) != {source for item in versions for source in item.get('equivalent_sources', [item['source']])}:
            raise ValueError('Source index differs from archive')
        for version in versions:
            equivalents = version.get('equivalent_sources', [version['source']])
            result = {**version, 'archive_key': group['key'], 'archive_filename': group['filename'],
                      'archive_sha256': group['sha256'],
                      'originals': [original for source in equivalents for original in originals_by_source[source]]}
            try:
                if len(equivalents) > 1:
                    fingerprints = {music_fingerprint(entries_by_source[source]) for source in equivalents}
                    if len(fingerprints) != 1:
                        raise ValueError('Byte-identical GP copies have different surviving score content; review instead of dropping a variant')
                score, report = build_version(version['title'], entries_by_source[version['source']])
                output = encoded(score)
                runner.publish_without_overwrite(Path(staging) / version['filename'], output)
                digest = hashlib.sha256(output).hexdigest()
                checked_bytes(Path(staging) / version['filename'], digest)
                result.update(status='ready', sha256=digest, bytes=len(output), measures=len(score['measures']),
                              bpm=score['bpm'], time_signature=score['timeSignature'], report=report)
            except Exception as error:
                result.update(status='failed', error=f'{type(error).__name__}: {error}')
            results.append(result)
    except Exception as error:
        results = [{**version, 'status': 'failed', 'error': f'{type(error).__name__}: {error}'}
                   for version in versions]
    return results


def latest_versions(report):
    filename = report / 'versions.jsonl'
    return {item['source']: item for item in lines(filename)} if filename.exists() else {}


def recover_preparation(report, staging):
    """Quarantine only incomplete writes in this verified preparation directory."""
    receipt = report / 'versions.jsonl'
    if receipt.exists() and receipt.stat().st_size:
        with receipt.open('r+b') as handle:
            handle.seek(-1, os.SEEK_END)
            if handle.read(1) != b'\n':
                end = handle.tell()
                cursor, boundary = end, 0
                while cursor:
                    start = max(0, cursor - 65536)
                    handle.seek(start)
                    block = handle.read(cursor - start)
                    index = block.rfind(b'\n')
                    if index >= 0:
                        boundary = start + index + 1
                        break
                    cursor = start
                handle.seek(boundary)
                tail = handle.read()
                recovered = report / 'interrupted-writes'
                recovered.mkdir(exist_ok=True)
                runner.publish_without_overwrite(recovered / ('receipt-tail-' + hashlib.sha256(tail).hexdigest()[:16] + '.bin'), tail)
                handle.truncate(boundary)
                handle.flush()
                os.fsync(handle.fileno())
    for filename in staging.iterdir():
        if filename.name.startswith('.guitarget-convert-'):
            info = filename.lstat()
            if not stat.S_ISREG(info.st_mode):
                raise ValueError('Unexpected temporary directory or symlink')
            recovered = report / 'interrupted-writes'
            recovered.mkdir(exist_ok=True)
            destination = recovered / (filename.name + '-' + str(info.st_ino))
            try:
                os.link(filename, destination, follow_symlinks=False)
            except FileExistsError:
                if file_identity(destination.lstat()) != file_identity(info):
                    raise ValueError('Recovery destination differs from interrupted temporary file')
            if file_identity(filename.lstat()) != file_identity(info):
                raise ValueError('Temporary file changed during recovery')
            filename.unlink()


def prepare(args):
    root, report, archive = args.root.resolve(), args.report.resolve(), args.archive.resolve()
    if report == root or root in report.parents or report == archive or archive in report.parents:
        raise ValueError('Output report must be separate from library and archive')
    groups = latest_songs(archive)
    if not groups or any(group['status'] != 'ready' for group in groups.values()):
        raise ValueError('Source archive preparation is incomplete')
    old_names = {item['path'] for group in groups.values() for item in group['originals']}
    if inventory(root) != old_names:
        raise ValueError('Library changed since the original audited conversion')
    source_groups = defaultdict(list)
    for metric in lines(args.metrics):
        source_groups[metric['song_key']].append(metric['source'])
    if set(source_groups) != set(groups):
        raise ValueError('Source index does not cover the complete archive')
    duplicate_data = json.loads(args.duplicates.read_text())
    gp_hashes = {}
    source_receipt = duplicate_data['source_receipt']
    descriptor = os.open(source_receipt['path'], os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as handle:
        before = os.fstat(handle.fileno())
        digest = hashlib.sha256()
        for line in handle:
            digest.update(line)
            record = json.loads(line)
            source = str(Path(record['source']).relative_to(root))
            source_hash = record['source_sha256']
            if source in gp_hashes and gp_hashes[source] != source_hash:
                raise ValueError('Conflicting historical GP source hashes')
            gp_hashes[source] = source_hash
        if file_identity(os.fstat(handle.fileno())) != file_identity(before) or digest.hexdigest() != source_receipt['sha256']:
            raise ValueError('Historical GP hash receipt changed')
    aliases = {}
    for duplicate in duplicate_data['gp_byte_identical_groups']:
        key, sources = duplicate['song_key'], sorted(duplicate['sources'])
        if key not in source_groups or len(sources) != len(set(sources)) or not set(sources) <= set(source_groups[key]):
            raise ValueError('Duplicate GP receipt does not match source index')
        if not duplicate['sha256'] or any(gp_hashes.get(source) != duplicate['sha256'] for source in sources):
            raise ValueError('Claimed duplicate GP files have different original bytes')
        for source in sources:
            if source in aliases:
                raise ValueError('Overlapping duplicate GP groups')
            aliases[source] = {'sources': sources, 'sha256': duplicate['sha256']}
    version_plan, used = {}, {name_key(name) for name in old_names}
    for key, group in sorted(groups.items()):
        sources = sorted(source_groups[key])
        if len(sources) != len(set(sources)) or len(sources) != group['versions']:
            raise ValueError('Duplicate or missing source version')
        sources = [source for source in sources if source not in aliases or source == aliases[source]['sources'][0]]
        version_plan[key] = []
        for index, source in enumerate(sources, 1):
            title = group['title'] if len(sources) == 1 else f"{group['title']} — 版本 {index:02d}"
            filename = safe_filename(title)
            if name_key(filename) in used:
                filename = safe_filename(title + '--' + hashlib.sha256(source.encode()).hexdigest()[:12])
            if name_key(filename) in used:
                raise ValueError('Output filename collision')
            used.add(name_key(filename))
            version_plan[key].append({'source': source, 'title': title, 'filename': filename,
                                     'equivalent_sources': aliases.get(source, {}).get('sources', [source]),
                                     'duplicate_gp_sha256': aliases.get(source, {}).get('sha256')})
    selected = sorted(groups)
    if args.limit is not None:
        selected = selected[:args.limit]
    report.mkdir(parents=True, exist_ok=args.resume)
    staging = report / 'scores'
    staging.mkdir(exist_ok=args.resume)
    plan = {'format': 'original-v1-merge-or-primary', 'root': str(root),
            'root_identity': file_identity(root.stat())[:2],
            'staging_identity': file_identity(staging.stat())[:2],
            'archive': str(archive), 'versions': sum(map(len, version_plan.values())),
            'source_versions': sum(map(len, source_groups.values())),
            'duplicate_gp_receipt_sha256': hashlib.sha256(args.duplicates.read_bytes()).hexdigest(),
            'original_fragments': len(old_names), 'groups': len(groups), 'selected_groups': len(selected),
            'created_at': datetime.now().isoformat(),
            'code_sha256': {name: hashlib.sha256((BASE / name).read_bytes()).hexdigest()
                            for name in ('merge_library.py', 'merge_score.py', 'main_guitar.py')},
            'policy': 'one distinct GP version per file; exact GP copies deduplicated; strict merge first, unchanged primary guitar/longest compatible excerpt otherwise; no arranging; original fragments retained in external verified archive'}
    if args.resume and (report / 'plan.json').exists():
        prior = json.loads((report / 'plan.json').read_text())
        for key in ('format', 'root', 'root_identity', 'staging_identity', 'archive', 'versions', 'original_fragments', 'selected_groups', 'code_sha256', 'duplicate_gp_receipt_sha256'):
            if prior[key] != plan[key]:
                raise ValueError('Resume plan differs')
    else:
        save(report / 'plan.json', plan)
    if args.resume:
        recover_preparation(report, staging)
    prior = latest_versions(report)
    complete = set()
    for key in selected:
        versions = version_plan[key]
        if all(prior.get(item['source'], {}).get('status') == 'ready' for item in versions):
            for item in versions:
                receipt = prior[item['source']]
                if receipt['filename'] != item['filename']:
                    raise ValueError('Resume filename changed')
                checked_bytes(staging / receipt['filename'], receipt['sha256'])
            complete.add(key)
    tasks = iter((str(archive), str(staging), groups[key], version_plan[key]) for key in selected if key not in complete)
    counters = Counter(item['report']['mode'] for item in prior.values() if item['status'] == 'ready')
    ready = sum(len(version_plan[key]) for key in complete)
    failed, last = 0, time.monotonic()
    log(f'Preparing v1 scores for {sum(len(version_plan[key]) for key in selected)} versions; {ready} reused')
    with (report / 'versions.jsonl').open('a' if args.resume else 'x', encoding='utf-8') as handle:
        with ProcessPoolExecutor(max_workers=args.workers, mp_context=multiprocessing.get_context('spawn'),
                                 initializer=worker_start, initargs=(args.timeout,)) as pool:
            pending = set()
            def submit():
                task = next(tasks, None)
                if task is not None:
                    pending.add(pool.submit(prepare_group, task))
            for _ in range(args.workers * 2):
                submit()
            while pending:
                done, pending = wait(pending, timeout=5, return_when=FIRST_COMPLETED)
                for future in done:
                    for item in future.result():
                        handle.write(encoded(item).decode())
                        handle.flush()
                        if item['status'] == 'ready':
                            ready += 1
                            counters[item['report']['mode']] += 1
                        else:
                            failed += 1
                            log(f"FAILED {item['filename']}: {item['error']}")
                    submit()
                if time.monotonic() - last >= 10:
                    log(f'PREPARE ready={ready} failed={failed} modes={dict(counters)}')
                    last = time.monotonic()
        handle.flush()
        os.fsync(handle.fileno())
    final = latest_versions(report)
    selected_sources = {item['source'] for key in selected for item in version_plan[key]}
    final = [item for source, item in final.items() if source in selected_sources]
    ready = sum(item['status'] == 'ready' for item in final)
    failed = sum(item['status'] != 'ready' for item in final)
    counters = Counter(item['report']['mode'] for item in final if item['status'] == 'ready')
    summary = {'ready': ready, 'failed': failed, 'modes': dict(counters)}
    save(report / 'prepare-summary.json', summary)
    log(f'PREPARED {summary}')
    if failed:
        raise ValueError('Some versions failed; original library remains unchanged')


def apply(args):
    report = args.report.resolve()
    plan = json.loads((report / 'plan.json').read_text())
    root, staging, archive = Path(plan['root']), report / 'scores', Path(plan['archive'])
    if plan['format'] != 'original-v1-merge-or-primary' or root != args.root.resolve():
        raise ValueError('Unexpected migration format or root')
    if root.is_symlink() or file_identity(root.stat())[:2] != plan['root_identity']:
        raise ValueError('Library root changed')
    if (report / 'summary.json').exists():
        raise ValueError('Migration already complete')
    if plan['selected_groups'] != plan['groups']:
        raise ValueError('A pilot cannot replace the full library')
    versions = list(latest_versions(report).values())
    if len(versions) != plan['versions'] or any(item['status'] != 'ready' for item in versions):
        raise ValueError('Not every original version has a validated output')
    if any(item['report']['mode'] not in ('merged', 'primary_guitar') for item in versions):
        raise ValueError('Arranged outputs are not authorized for this migration')
    originals = [original for item in versions for original in item['originals']]
    old_names = {basename(item['path']) for item in originals}
    new_names = {basename(item['filename']) for item in versions}
    if len(originals) != len(old_names) or len(originals) != plan['original_fragments']:
        raise ValueError('Original coverage mismatch')
    if len(new_names) != len(versions) or new_names & old_names:
        raise ValueError('Output filename collision')
    started = report / 'apply-started.json'
    resuming = started.exists()
    present = inventory(root)
    if present - old_names - new_names or (not resuming and present != old_names):
        raise ValueError('Library inventory changed')
    def check_staging():
        if not os.path.lexists(staging):
            if resuming and new_names <= present:
                return
            raise ValueError('Missing staging directory')
        info = staging.lstat()
        if not stat.S_ISDIR(info.st_mode) or file_identity(info)[:2] != plan['staging_identity']:
            raise ValueError('Staging directory changed')
        for entry in staging.iterdir():
            if entry.name not in new_names or not stat.S_ISREG(entry.lstat().st_mode):
                raise ValueError('Unexpected staging entry; resume preparation to recover interrupted writes')
    check_staging()
    archive_receipts = {}
    for item in versions:
        receipt = (item['archive_filename'], item['archive_sha256'])
        if item['archive_key'] in archive_receipts and archive_receipts[item['archive_key']] != receipt:
            raise ValueError('Inconsistent archive receipt')
        archive_receipts[item['archive_key']] = receipt
    if len(archive_receipts) != plan['groups']:
        raise ValueError('Incomplete backup archive coverage')
    def verify_archive(receipt):
        filename, digest = receipt
        checked_bytes(archive / 'songs' / basename(filename), digest)
    def verify_output(item):
        candidate = staging / item['filename']
        if not os.path.lexists(candidate) and resuming and new_names <= present:
            candidate = root / item['filename']
        data, identity = checked_bytes(candidate, item['sha256'])
        score = json.loads(data)
        if set(score) != SCORE_KEYS or score['version'] != 1:
            raise ValueError('Output is not the original app format')
        return identity
    def verify_original(item):
        if item['path'] in present:
            checked_bytes(root / item['path'], item['sha256'], item['stat'])
        elif not resuming or not new_names <= present:
            raise ValueError('Original fragment unexpectedly missing')
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for index, _ in enumerate(pool.map(verify_archive, archive_receipts.values(), buffersize=32), 1):
            if index % 5000 == 0:
                log(f'VERIFIED recoverable archive {index}/{len(archive_receipts)}')
        identities = list(pool.map(verify_output, versions, buffersize=32))
        for index, _ in enumerate(pool.map(verify_original, originals, buffersize=64), 1):
            if index % 50000 == 0:
                log(f'VERIFIED original fragment {index}/{len(originals)}')
    if not resuming:
        save(started, {'at': datetime.now().isoformat()})
    for index, (item, identity) in enumerate(zip(versions, identities), 1):
        source, destination = staging / item['filename'], root / item['filename']
        if not os.path.lexists(source) and resuming:
            checked_bytes(destination, item['sha256'], identity)
        else:
            try:
                os.link(source, destination, follow_symlinks=False)
            except FileExistsError:
                checked_bytes(destination, item['sha256'], identity)
        if file_identity(destination.lstat()) != identity:
            raise ValueError('Published score differs from verified staging')
        if index % 5000 == 0:
            log(f'PUBLISHED {index}/{len(versions)} version files')
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for _ in pool.map(lambda item: checked_bytes(root / item['filename'], item['sha256'])[1], versions, buffersize=32):
            pass
    save(report / 'verified-before-delete.json', {'versions': len(versions), 'backup_fragments': len(originals),
         'at': datetime.now().isoformat()})
    log('All v1 outputs and recoverable original content verified; removing replaced fragment files')
    for index, original in enumerate(originals, 1):
        filename = root / original['path']
        if not os.path.lexists(filename) and resuming:
            continue
        info = filename.lstat()
        if not stat.S_ISREG(info.st_mode) or file_identity(info) != original['stat']:
            raise ValueError('Original changed before replacement')
        filename.unlink()
        if index % 50000 == 0:
            log(f'REMOVED {index}/{len(originals)} replaced fragments')
    if inventory(root) != new_names:
        raise ValueError('Final library differs from manifest')
    check_staging()
    for item, identity in zip(versions, identities):
        filename = staging / item['filename']
        if not os.path.lexists(filename) and resuming:
            continue
        if file_identity(filename.lstat()) != identity:
            raise ValueError('Staging file changed before cleanup')
        filename.unlink()
    if staging.exists():
        staging.rmdir()
    if inventory(root) != new_names:
        raise ValueError('Final inventory changed during staging cleanup')
    summary = {**plan, 'completed_at': datetime.now().isoformat(), 'final_version_files': len(versions),
               'removed_fragment_files': len(originals), 'other_files': 0,
               'native_validated_versions': len(versions),
               'output_bytes': sum(item['bytes'] for item in versions),
               'modes': dict(Counter(item['report']['mode'] for item in versions)),
               'original_content_archive': str(archive / 'songs')}
    save(report / 'summary.json', summary)
    log(f'COMPLETE {len(versions)} ordinary v1 files; original fragment content recoverable outside library')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['prepare', 'apply'])
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--archive', type=Path, default=ARCHIVE)
    parser.add_argument('--metrics', type=Path, default=METRICS)
    parser.add_argument('--duplicates', type=Path, default=DUPLICATES)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--workers', type=int, default=6)
    parser.add_argument('--timeout', type=int, default=300)
    parser.add_argument('--limit', type=int)
    parser.add_argument('--resume', action='store_true')
    args = parser.parse_args()
    if args.workers < 1 or args.timeout < 1:
        parser.error('workers and timeout must be positive')
    (prepare if args.phase == 'prepare' else apply)(args)


if __name__ == '__main__':
    main()

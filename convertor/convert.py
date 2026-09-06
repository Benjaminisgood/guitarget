#!/usr/bin/env python3
"""Convert GP scores beside their originals, using Guitarget's real Swift validator."""
from __future__ import annotations

import argparse
import atexit
from collections import Counter
from concurrent.futures import FIRST_COMPLETED, ProcessPoolExecutor, wait
from datetime import datetime, timezone
import hashlib
import io
import json
import multiprocessing
import os
from pathlib import Path
import random
import select
import signal
import subprocess
import sys
import tempfile
import time

import guitarpro
from mapping import convert_song
from merge_score import merge_version
from main_guitar import select_main_guitar

ROOT = Path(__file__).resolve().parent
EXTENSIONS = {'.gp3', '.gp4', '.gp5', '.gtp', '.gpx', '.gp'}
_validator = None
_timeout = 120
_dry_run = False
V1_SCORE_KEYS = {'version', 'title', 'tuning', 'timeSignature', 'bpm', 'measures'}


def json_line(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False)


class NativeValidator:
    def __init__(self):
        self.process = None

    def close(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.kill()
            self.process.wait()
            self.process.stdin.close()
            self.process.stdout.close()
            self.process = None

    def check(self, score):
        if self.process is None or self.process.poll() is not None:
            self.process = subprocess.Popen(
                [str(ROOT / '.build' / 'validate'), '--stdin-jsonl'],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            )
        payload = (json_line({'id': 'score', 'score': score}) + '\n').encode('utf-8')
        previous_handler = signal.signal(signal.SIGALRM, native_alarm_handler)
        signal.alarm(_timeout)
        try:
            self.process.stdin.write(payload)
            self.process.stdin.flush()
            ready, _, _ = select.select([self.process.stdout], [], [], _timeout)
            if not ready:
                raise TimeoutError('native ScoreIO validation timed out')
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError('native validator closed its output unexpectedly')
            return json.loads(line)
        except BaseException:
            self.close()
            raise
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, previous_handler)


def initialize_worker(timeout, dry_run):
    global _validator, _timeout, _dry_run
    _timeout, _dry_run = timeout, dry_run
    _validator = NativeValidator()
    atexit.register(_validator.close)
    signal.signal(signal.SIGALRM, alarm_handler)


def alarm_handler(signum, frame):
    raise TimeoutError('source parsing/mapping exceeded the per-file time limit')


def native_alarm_handler(signum, frame):
    raise TimeoutError('native ScoreIO validation exceeded the per-output time limit')


def output_path(source, track_number, part):
    # Include the source extension: two same-named GP3/GP4 files cannot collide.
    suffix = f'.track-{track_number:02d}.part-{part:03d}.guitarget'
    basename = source.name
    if len((basename + suffix).encode('utf-8')) > 240:
        digest = hashlib.sha256(basename.encode('utf-8')).hexdigest()[:12]
        while len(basename.encode('utf-8')) > 180:
            basename = basename[:-1]
        basename += '-' + digest
    return source.with_name(basename + suffix)


def song_output_path(source):
    """Keep the source extension, including when a long stem needs shortening."""
    basename = source.name + '.guitarget'
    if len(basename.encode('utf-8')) > 240:
        digest = hashlib.sha256(source.name.encode('utf-8')).hexdigest()[:12]
        suffix = f'--{digest}{source.suffix}.guitarget'
        stem = source.stem
        while len((stem + suffix).encode('utf-8')) > 240:
            stem = stem[:-1]
        basename = stem + suffix
    return source.with_name(basename)


def publish_without_overwrite(destination, data):
    """Atomic exclusive publication, with byte-identical reruns allowed."""
    if os.path.lexists(destination):
        if destination.is_symlink() or not destination.is_file():
            raise FileExistsError('output exists and is not a regular file')
        if destination.read_bytes() == data:
            return 'unchanged'
        raise FileExistsError('different output already exists; preserved without overwrite')
    fd, temporary = tempfile.mkstemp(prefix='.guitarget-convert-', dir=destination.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
        try:
            os.link(temporary, destination)
        except FileExistsError:
            if not destination.is_symlink() and destination.is_file() and destination.read_bytes() == data:
                return 'unchanged'
            raise
        return 'written'
    finally:
        os.unlink(temporary)


def require_standard_v1(score):
    """Reject hidden payloads which the unmodified app would discard on import."""
    def keys(value, allowed, location):
        if not isinstance(value, dict):
            raise ValueError(f'{location} must be an object')
        unexpected = set(value) - allowed
        if unexpected:
            raise ValueError(f'{location} contains fields outside the original v1 schema: {sorted(unexpected)}')
    keys(score, V1_SCORE_KEYS, 'score')
    if type(score.get('version')) is not int or score['version'] != 1 or set(score) != V1_SCORE_KEYS:
        raise ValueError('final score must use version 1 and exactly the original v1 root fields')
    keys(score['timeSignature'], {'numerator', 'denominator'}, 'timeSignature')
    for measure in score['measures']:
        keys(measure, {'id', 'voices'}, 'measure')
        for voice in measure['voices']:
            keys(voice, {'voice', 'events'}, 'voice')
            for event in voice['events']:
                keys(event, {'id', 'startTick', 'rhythm', 'notes', 'lyric'}, 'event')
                keys(event['rhythm'], {'value', 'dotted', 'triplet'}, 'rhythm')
                for note in event['notes']:
                    keys(note, {'id', 'string', 'fret', 'velocity', 'technique', 'targetFret', 'tieToNext'}, 'note')


def merge_or_select_main_guitar(title, entries, output):
    """Only a final native-validated, ordinary v1 score may reach publication.

    Strict musical merging gets the first attempt. A structural/timing failure
    or native rejection triggers selection of the original primary guitar.
    Preserve both reports and validation responses in the audit output.
    """
    for method, combine in (('strict_merge', merge_version), ('primary_guitar', select_main_guitar)):
        report_key = 'merge_report' if method == 'strict_merge' else 'mainselection'
        validation_key = 'merge_native_validation' if method == 'strict_merge' else 'mainselection_native_validation'
        error_key = 'merge_error' if method == 'strict_merge' else 'mainselection_error'
        try:
            score, report = combine(title, entries)
            output[report_key] = report
            require_standard_v1(score)
            validation = _validator.check(score)
            output[validation_key] = validation
            output['native_validation'] = validation
            if not validation.get('valid'):
                raise ValueError(f'Guitarget ScoreIO rejected {method}: ' + '; '.join(validation.get('errors', [])))
            warnings = report.get('warnings', []) if isinstance(report, dict) else []
            warnings = [warning for warning in warnings if isinstance(warning, str)]
            output['warnings'] = list(dict.fromkeys(output.get('warnings', []) + warnings + validation.get('warnings', [])))
            output['method'] = method
            return score
        except Exception as error:
            output[error_key] = f'{type(error).__name__}: {error}'
            if report_key not in output:
                describe = getattr(error, 'as_dict', None)
                output[report_key] = describe() if callable(describe) else {'status': 'failed', 'error': output[error_key]}
            if method == 'primary_guitar':
                raise ValueError('strict merge and primary-guitar selection both failed; '
                                 f'merge: {output["merge_error"]}; main selection: {output["mainselection_error"]}') from error
            output['warnings'] = list(dict.fromkeys(output.get('warnings', []) + [
                'strict_merge_fallback: ' + output[error_key]
            ]))


def convert_file(filename):
    source = Path(filename)
    started = time.monotonic()
    record = {'source': str(source), 'status': 'failed', 'parts': [], 'outputs': []}
    try:
        if source.is_symlink() or not source.is_file():
            raise ValueError('source must be a regular, non-symlink file')
        data = source.read_bytes()
        record.update(source_sha256=hashlib.sha256(data).hexdigest(), source_bytes=len(data))
        signal.signal(signal.SIGALRM, alarm_handler)
        signal.alarm(_timeout)
        try:
            fallback_warning = None
            try:
                song = guitarpro.parse(io.BytesIO(data))
            except Exception as original_error:
                header = data[1:31].decode('latin1', errors='replace') if data else ''
                if not (header.startswith('FICHIER GUITAR PRO v') or header.startswith('FICHIER GUITARE PRO v')):
                    raise ValueError('not a readable Guitar Pro file (empty, HTML, or invalid header)') from original_error
                from legacy import gp5_bytes
                record['parser_fallback_reason'] = str(original_error)
                song = guitarpro.parse(io.BytesIO(gp5_bytes(source)))
                record['parser_fallback'] = 'TuxGuitar 1.6.4 → private GP5 copy → PyGuitarPro'
                fallback_warning = 'legacy_reader: TuxGuitar re-exported this source to GP5; legacy rhythms and effects may be normalized'
            record.update(format=song.version, title=song.title)
            if not str(song.title or '').strip():
                song.title = source.stem
            results = convert_song(song, record['source_sha256'])
            if fallback_warning:
                for item in results:
                    item['warnings'] = list(dict.fromkeys(item.get('warnings', []) + [fallback_warning]))
        finally:
            signal.alarm(0)
        record['tracks_in_source'] = len(song.tracks)
        if not results:
            record.update(status='skipped', error='no convertible six-string guitar track')
        entries = []
        for item in results:
            result = {key: value for key, value in item.items() if key != 'score'}
            score = item.get('score')
            if score is None:
                result['status'] = 'skipped' if item.get('skipped') or str(item.get('error', '')).startswith('skipped_') else 'failed'
                record['parts'].append(result)
                continue
            try:
                require_standard_v1(score)
                validation = _validator.check(score)
                result['native_validation'] = validation
                if not validation.get('valid'):
                    raise ValueError('Guitarget ScoreIO rejected score: ' + '; '.join(validation.get('errors', [])))
                result['warnings'] = list(dict.fromkeys(item.get('warnings', []) + validation.get('warnings', [])))
                encoded = (json_line(score) + '\n').encode('utf-8')
                result.update(sha256=hashlib.sha256(encoded).hexdigest(), bytes=len(encoded),
                              measures=len(score['measures']), bpm=score['bpm'], time_signature=score['timeSignature'])
                entries.append({'source': source.name, 'track_number': item['track_number'],
                                'track_name': item.get('track_name', ''), 'part': item['part'],
                                'source_measures': item.get('source_measures'), 'score': score})
                result['status'] = 'included'
            except Exception as error:
                result.update(status='failed', error=f'{type(error).__name__}: {error}')
            record['parts'].append(result)
        failed_parts = any(part['status'] == 'failed' for part in record['parts'])
        if entries:
            destination = song_output_path(source)
            output = {'path': str(destination), 'status': 'failed', 'version': 1,
                      'parts': len(entries), 'tracks': len({entry['track_number'] for entry in entries}),
                      'parts_provenance': [
                          {'source': source.name, **{key: part[key] for key in
                              ('track_number', 'track_name', 'part', 'source_measures', 'sha256', 'bytes', 'measures', 'bpm', 'time_signature')
                              if key in part}}
                          for part in record['parts'] if part['status'] == 'included'
                      ],
                      'warnings': list(dict.fromkeys(warning for part in record['parts']
                          if part['status'] == 'included' for warning in part.get('warnings', [])))}
            try:
                score = merge_or_select_main_guitar(str(song.title), entries, output)
                encoded = (json_line(score) + '\n').encode('utf-8')
                output.update(sha256=hashlib.sha256(encoded).hexdigest(), bytes=len(encoded),
                              measures=len(score['measures']), bpm=score['bpm'], time_signature=score['timeSignature'],
                              tuning=score['tuning'])
                output['status'] = 'validated' if _dry_run else publish_without_overwrite(destination, encoded)
                record['status'] = 'partial' if failed_parts else 'converted'
            except Exception as error:
                output['error'] = f'{type(error).__name__}: {error}'
                record['status'] = 'failed'
            record['outputs'].append(output)
        elif record['parts']:
            record['status'] = 'failed' if failed_parts else 'skipped'
    except Exception as error:
        record['error'] = f'{type(error).__name__}: {error}'
    record['seconds'] = round(time.monotonic() - started, 4)
    return record


def source_files(source):
    if source.is_symlink():
        raise ValueError('source root must not be a symlink')
    if source.is_file():
        return [source] if source.suffix.lower() in EXTENSIONS else []
    files = []
    for directory, directories, names in os.walk(source, followlinks=False):
        directories[:] = sorted(d for d in directories if not Path(directory, d).is_symlink())
        for name in sorted(names):
            path = Path(directory, name)
            if path.suffix.lower() in EXTENSIONS and not path.is_symlink():
                files.append(path)
    return files


def verify_sources(report_path):
    checked, failures = 0, []
    with report_path.open(encoding='utf-8') as stream:
        for line in stream:
            record = json.loads(line)
            if 'source_sha256' not in record:
                continue
            checked += 1
            try:
                source = Path(record['source'])
                if source.is_symlink() or hashlib.sha256(source.read_bytes()).hexdigest() != record['source_sha256']:
                    failures.append(record['source'])
            except OSError:
                failures.append(record['source'])
    return {'checked': checked, 'unchanged': checked - len(failures), 'failures': failures}


def verify_outputs(manifest_path):
    checked, failures = 0, []
    with manifest_path.open(encoding='utf-8') as stream:
        for line in stream:
            item = json.loads(line)
            checked += 1
            try:
                path = Path(item['path'])
                if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != item['sha256']:
                    failures.append(item['path'])
            except OSError:
                failures.append(item['path'])
    return {'checked': checked, 'matching': checked - len(failures), 'failures': failures}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='one GP file or a directory scanned recursively')
    parser.add_argument('--workers', type=int, default=min(6, os.cpu_count() or 1))
    parser.add_argument('--timeout', type=int, default=120, help='parse/map and native validation timeout seconds')
    parser.add_argument('--limit', type=int, help='only the first N source files')
    parser.add_argument('--sample', type=int, help='deterministic random sample for compatibility checks')
    parser.add_argument('--seed', type=int, default=20260906)
    parser.add_argument('--dry-run', action='store_true', help='parse/map/native-validate, without writing scores')
    parser.add_argument('--report-dir', type=Path, help='new empty report directory')
    args = parser.parse_args()
    if args.workers < 1 or args.timeout < 1:
        parser.error('workers and timeout must be positive')
    source = args.source.expanduser().absolute()
    if not source.exists():
        parser.error(f'source does not exist: {source}')
    if not (ROOT / '.build' / 'validate').is_file():
        parser.error('native validator not built; use run.sh or build_validator.sh first')
    files = source_files(source)
    total_discovered = len(files)
    if args.sample is not None:
        files = sorted(random.Random(args.seed).sample(files, min(args.sample, len(files))))
    if args.limit is not None:
        files = files[:args.limit]
    report_dir = args.report_dir or ROOT / 'reports' / datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    report_dir = report_dir.absolute()
    report_dir.mkdir(parents=True, exist_ok=True)
    if any(report_dir.iterdir()):
        parser.error('report directory must be empty; existing reports are never overwritten')
    report_path = report_dir / 'results.jsonl'
    source_counts, output_counts, part_counts, reasons, warning_counts = Counter(), Counter(), Counter(), Counter(), Counter()
    started = time.monotonic()
    completed, output_bytes = 0, 0
    last_progress = started
    metadata = {'source': str(source), 'started_at': datetime.now(timezone.utc).isoformat(),
                'source_files_discovered': total_discovered, 'source_files_selected': len(files),
                'workers': args.workers, 'dry_run': args.dry_run, 'parser': 'PyGuitarPro 0.11',
                'output_format': 'Guitarget v1: one strictly merged score or original primary-guitar selection per GP source version',
                'converter_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'mapping_sha256': hashlib.sha256((ROOT / 'mapping.py').read_bytes()).hexdigest(),
                'merge_score_sha256': hashlib.sha256((ROOT / 'merge_score.py').read_bytes()).hexdigest(),
                'main_guitar_sha256': hashlib.sha256((ROOT / 'main_guitar.py').read_bytes()).hexdigest(),
                'validator_adapter_sha256': hashlib.sha256((ROOT / 'validate.swift').read_bytes()).hexdigest(),
                'validator_binary_sha256': hashlib.sha256((ROOT / '.build' / 'validate').read_bytes()).hexdigest(),
                'validator_sources': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in
                    [ROOT.parent / 'Sources/GuitarCore/ScoreTypes.swift', ROOT.parent / 'Sources/GuitarCore/ScoreEngine.swift']}}
    (report_dir / 'run.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
    print(f'Scanned {total_discovered} GP files; converting {len(files)} with {args.workers} workers. Reports: {report_dir}', flush=True)
    context = multiprocessing.get_context('spawn')
    with report_path.open('x', encoding='utf-8') as report, (report_dir / 'outputs.jsonl').open('x', encoding='utf-8') as outputs:
        with ProcessPoolExecutor(max_workers=args.workers, mp_context=context,
                                 initializer=initialize_worker, initargs=(args.timeout, args.dry_run)) as pool:
            iterator = iter(files)
            pending = {}
            def submit_one():
                path = next(iterator, None)
                if path is not None:
                    pending[pool.submit(convert_file, str(path))] = path
            for _ in range(args.workers * 2):
                submit_one()
            while pending:
                finished, _ = wait(pending, timeout=5, return_when=FIRST_COMPLETED)
                for future in finished:
                    path = pending.pop(future)
                    try:
                        record = future.result()
                    except Exception as error:
                        record = {'source': str(path), 'status': 'failed', 'parts': [], 'outputs': [], 'error': repr(error)}
                    report.write(json_line(record) + '\n')
                    report.flush()
                    source_counts[record['status']] += 1
                    if record.get('error'):
                        reasons[record['error'].split(':', 1)[0]] += 1
                    for part in record.get('parts', []):
                        part_counts[part['status']] += 1
                        if part['status'] == 'failed':
                            reasons[part.get('error', 'unknown')] += 1
                    for item in record['outputs']:
                        output_counts[item['status']] += 1
                        for warning in item.get('warnings', []):
                            warning_counts[warning.split(':', 1)[0]] += 1
                        if item['status'] in ('written', 'unchanged'):
                            output_bytes += item['bytes']
                            outputs.write(json_line({k: item[k] for k in ('path', 'sha256', 'bytes')}) + '\n')
                        if item['status'] == 'failed':
                            reasons[item.get('error', 'unknown')] += 1
                    outputs.flush()
                    completed += 1
                    submit_one()
                now = time.monotonic()
                if now - last_progress >= 10 or completed == len(files):
                    print(f'{completed}/{len(files)} sources | source status {dict(source_counts)} | output status {dict(output_counts)} | {now-started:.1f}s', flush=True)
                    last_progress = now
    print('Verifying original GP file hashes...', flush=True)
    preservation = verify_sources(report_path)
    print('Verifying published output file hashes...', flush=True)
    integrity = verify_outputs(report_dir / 'outputs.jsonl')
    summary = {**metadata, 'finished_at': datetime.now(timezone.utc).isoformat(),
               'seconds': round(time.monotonic() - started, 2), 'sources': dict(source_counts),
               'outputs': dict(output_counts), 'parts': dict(part_counts), 'output_bytes': output_bytes,
               'source_preservation': preservation, 'output_integrity': integrity,
               'warning_counts': dict(warning_counts), 'top_failure_reasons': reasons.most_common(30)}
    (report_dir / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    lines = ['# Guitar Pro 转换结果', '', f'- 源目录：`{source}`',
             f'- 本次处理：{len(files)} / {total_discovered} 份原始谱',
             f'- 原始谱状态：{dict(source_counts)}', f'- 输出状态：{dict(output_counts)}',
             f'- 输出字节数：{output_bytes}', f'- 原文件 SHA-256 核验：{preservation["unchanged"]}/{preservation["checked"]} 保持不变',
             f'- 输出文件 SHA-256 核验：{integrity["matching"]}/{integrity["checked"]} 与已校验内容一致',
             '', '每个成功源 GP 版本只输出一份原生 v1 单吉他谱，不包含 collection、archive 等自定义字段。',
             '先尝试严格合并；合并失败或原生校验拒绝时，选择原主吉他。两者都失败则不发布。',
             '每个片段先单独经过 Swift `ScoreIO.decode` 校验，最终合并谱或选中的主吉他再次校验后才发布。',
             'converted/partial 描述候选片段的转换状态；成品实际保留范围以 method、merge_report 和 mainselection 为准。',
             '无法严格合并时保留原主吉他；若该轨仍因变速/变拍无法完整表达，则保留最长同参数连续片段。保留内容的音符、节拍和速度不改写；省略内容记录于 outputs 的 mainselection 与 warnings。',
             '转换文件位于源 GP 文件旁；尚未导入 Guitarget 的个人曲库。',
             '', '片段状态见 `results.jsonl` 的 parts，成品状态见 outputs；原片段追溯信息见 outputs.parts_provenance，成功成品及 SHA-256 见 `outputs.jsonl`。']
    (report_dir / 'summary.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)
    return 2 if preservation['failures'] or integrity['failures'] else 0


if __name__ == '__main__':
    raise SystemExit(main())

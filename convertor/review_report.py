#!/usr/bin/env python3
"""Create a readable source index and coverage summary for a finished run."""
import argparse
from collections import Counter
import csv
import json
from pathlib import Path


def review(directory):
    summary = json.loads((directory / 'summary.json').read_text())
    sources, output_status, part_status, failures, warnings = Counter(), Counter(), Counter(), Counter(), Counter()
    native_rejections, native_warnings, fallback_attempts, fallback_successes = 0, 0, 0, 0
    native_part_rejections, native_container_rejections, native_part_warnings = 0, 0, 0
    successful_sources, complete_tracks, partial_tracks, failed_tracks = 0, 0, 0, 0
    container_records = 0
    with (directory / 'source-index.csv').open('w', encoding='utf-8-sig', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['原始文件', '源状态', '成功输出份数', '失败分段数', '跳过轨道数', '失败类别', '警告类别'])
        with (directory / 'results.jsonl').open(encoding='utf-8') as records:
            for line in records:
                item = json.loads(line)
                sources[item['status']] += 1
                failed, skipped = 0, 0
                outputs = item.get('outputs', [])
                has_parts = 'parts' in item
                container_records += has_parts
                details = item.get('parts', []) if has_parts else outputs
                succeeded = sum(output['status'] in ('written', 'unchanged', 'validated') for output in outputs)
                source_errors, source_warnings = set(), set()
                tracks = {}
                if item.get('error'):
                    category = item['error'].split(':', 1)[0]
                    failures[category] += 1
                    source_errors.add(category)
                fallback_attempts += bool(item.get('parser_fallback_reason'))
                fallback_successes += bool(item.get('parser_fallback'))
                for output in outputs:
                    state = output['status']
                    output_status[state] += 1
                    validation = output.get('native_validation')
                    if validation:
                        native_warnings += bool(validation.get('warnings'))
                        if has_parts:
                            native_container_rejections += not validation.get('valid', False)
                            native_rejections += not validation.get('valid', False)
                    if has_parts:
                        if state == 'failed':
                            category = (output.get('error') or 'unknown').split(':', 1)[0]
                            failures[category] += 1
                            source_errors.add(category)
                        source_warnings.update(warning.split(':', 1)[0] for warning in output.get('warnings', []))
                for part in details:
                    state = part['status']
                    part_status[state] += 1
                    failed += state == 'failed'
                    skipped += state == 'skipped'
                    if state != 'skipped' and 'track_number' in part:
                        tracks.setdefault(part['track_number'], []).append(state)
                    if state == 'failed':
                        category = (part.get('error') or 'unknown').split(':', 1)[0]
                        failures[category] += 1
                        source_errors.add(category)
                    for warning in part.get('warnings', []):
                        category = warning.split(':', 1)[0]
                        source_warnings.add(category)
                        if succeeded and state in ('included', 'written', 'unchanged', 'validated'):
                            warnings[category] += 1
                    validation = part.get('native_validation')
                    if validation:
                        native_part_rejections += not validation.get('valid', False)
                        native_rejections += not validation.get('valid', False)
                        native_part_warnings += bool(validation.get('warnings'))
                successful_sources += succeeded > 0
                for states in tracks.values():
                    # An included part is not a usable output if the assembled
                    # container failed validation or exclusive publication.
                    good = succeeded > 0 and any(s in ('included', 'written', 'unchanged', 'validated') for s in states)
                    bad = 'failed' in states
                    complete_tracks += good and not bad
                    partial_tracks += good and bad
                    failed_tracks += not good
                writer.writerow([item['source'], item['status'], succeeded, failed, skipped,
                                 '; '.join(sorted(source_errors)), '; '.join(sorted(source_warnings))])
    coverage = {'source_status': dict(sources), 'sources_with_output': successful_sources,
                'output_status': dict(output_status), 'part_status': dict(part_status),
                'complete_eligible_tracks': complete_tracks,
                'partial_eligible_tracks': partial_tracks, 'failed_eligible_tracks': failed_tracks,
                'native_rejections': native_rejections, 'native_outputs_with_warnings': native_warnings,
                'native_part_rejections': native_part_rejections,
                'native_container_rejections': native_container_rejections,
                'native_parts_with_warnings': native_part_warnings,
                'sources_using_song_containers': container_records,
                'fallback_attempts': fallback_attempts, 'fallback_parsed': fallback_successes,
                'failure_categories': dict(failures), 'successful_output_warning_categories': dict(warnings),
                'successful_part_warning_categories': dict(warnings)}
    (directory / 'coverage.json').write_text(json.dumps(coverage, ensure_ascii=False, indent=2) + '\n')
    lines = ['# 全库转换覆盖情况', '',
             f'- 处理原始文件：{sum(sources.values()):,}',
             f'- 至少生成一份曲谱的源文件：{successful_sources:,}',
             f'- 所有目标吉他轨/分段成功：{sources["converted"]:,}；部分成功：{sources["partial"]:,}',
             f'- 无成功结果：{sources["failed"]:,}；无目标吉他轨等跳过：{sources["skipped"]:,}',
             f'- 新生成 .guitarget：{output_status["written"]:,}；已有相同内容：{output_status["unchanged"]:,}',
             f'- 原生校验拒绝的候选：{native_rejections:,}（拒绝结果不发布）',
             f'- 完整目标轨：{complete_tracks:,}；部分成功轨：{partial_tracks:,}；无成功段轨：{failed_tracks:,}',
             '', '目标轨为六弦且 GM 音色编号为 24–31 的非打击乐轨，不能将完整目标轨统计理解为完整乐队总谱。',
             ('新格式每个源 GP 文件生成一份歌曲容器；固定拍号/速度的片段保存在容器内部。旧格式报告仍按分段文档计数。'
              if container_records else '每条轨道可拆成多个固定拍号/速度的文档；输出数量不等于歌曲数量。'),
             '效果近似、被省略的歌词/文字等，见 results.jsonl 的 parts[].warnings；旧报告见 outputs[].warnings。',
             '', '## 失败类别（轨道/分段级，可能同一源文件重复出现）', '']
    lines += [f'- `{name}`：{count:,}' for name, count in failures.most_common()]
    lines += ['', '## 成功输出中的警告类别', '']
    lines += [f'- `{name}`：{count:,}' for name, count in warnings.most_common()]
    lines += ['', '逐个原文件的可筛选索引：`source-index.csv`。',
              '原文件及输出文件 SHA-256 核验：`summary.json`。']
    (directory / 'coverage.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print(json.dumps(coverage, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report_directory', type=Path)
    review(parser.parse_args().report_directory)

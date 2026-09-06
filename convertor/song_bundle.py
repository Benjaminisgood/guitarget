"""Lossless Guitarget v2 song containers shared by conversion and migration."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import unicodedata
import uuid

CONTENT_KEYS = ('tuning', 'timeSignature', 'bpm', 'measures')
SCORE_KEYS = {'version', 'title', *CONTENT_KEYS}
NAMESPACE = uuid.UUID('7cd8418c-407a-5aa9-9f28-0b86559a24d9')


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False) + '\n').encode('utf-8')


def content_hash(score):
    return hashlib.sha256(json.dumps(score, ensure_ascii=False, sort_keys=True,
                                     separators=(',', ':'), allow_nan=False).encode('utf-8')).hexdigest()


def name_key(value):
    return unicodedata.normalize('NFD', ' '.join(value.split())).casefold()


def safe_filename(title):
    name = re.sub(r'[/\x00-\x1f]', '_', title).strip().rstrip('.') or 'Untitled'
    if len((name + '.guitarget').encode('utf-8')) > 240:
        digest = hashlib.sha256(title.encode('utf-8')).hexdigest()[:12]
        while len(name.encode('utf-8')) > 215:
            name = name[:-1]
        name += '--' + digest
    return name + '.guitarget'


def part_identifier(source, track_number, part_number):
    return str(uuid.uuid5(NAMESPACE, f'{source}\0{track_number}\0{part_number}')).upper()


def make_collection(title, entries):
    """entries: source, track_number, track_name, part, source_measures, score.

    Every original score is retained. The active part uses the root content;
    inactive parts hold their own content. No UUID regeneration or quantization.
    """
    if not entries:
        raise ValueError('Cannot create a song without a valid part')
    entries = sorted(entries, key=lambda item: (item['source'], item['track_number'], item['part']))
    # Prefer a track with more written notes; always start at its first available part.
    track_sizes = {}
    for entry in entries:
        score = entry['score']
        if score.get('version') != 1 or set(score) != SCORE_KEYS:
            raise ValueError('Expected an unextended v1 score; refusing to drop unknown fields')
        track = (entry['source'], entry['track_number'])
        track_sizes[track] = track_sizes.get(track, 0) + sum(
            len(event['notes']) for measure in score['measures']
            for voice in measure['voices'] for event in voice['events'])
    preferred_track = min(track_sizes, key=lambda track: (-track_sizes[track], track))
    selected = next(entry for entry in entries if (entry['source'], entry['track_number']) == preferred_track)
    selected_id = part_identifier(selected['source'], selected['track_number'], selected['part'])
    parts, seen = [], set()
    for entry in entries:
        score = entry['score']
        identifier = part_identifier(entry['source'], entry['track_number'], entry['part'])
        if identifier in seen:
            raise ValueError('Duplicate source/track/part slot')
        seen.add(identifier)
        content = {key: score[key] for key in CONTENT_KEYS}
        source_measures = entry.get('source_measures')
        if source_measures is None:
            source_measures = list(range(1, len(score['measures']) + 1))
        if len(source_measures) != len(score['measures']):
            raise ValueError('Source measure count does not match content')
        parts.append({'id': identifier, 'source': entry['source'], 'originalTitle': score['title'],
                      'trackNumber': entry['track_number'], 'trackName': entry.get('track_name', ''),
                      'partNumber': entry['part'], 'sourceMeasures': source_measures,
                      'content': None if identifier == selected_id else content})
    return {'version': 2, 'title': title,
            **{key: selected['score'][key] for key in CONTENT_KEYS},
            'collection': {'selectedPartID': selected_id, 'parts': parts}}


def extract_parts(collection):
    """Reconstruct each original v1 score for independent content verification."""
    selected = collection['collection']['selectedPartID']
    result = {}
    for part in collection['collection']['parts']:
        content = collection if part['id'] == selected else part['content']
        result[part['id']] = {'version': 1, 'title': part['originalTitle'],
                              **{key: content[key] for key in CONTENT_KEYS}}
    return result

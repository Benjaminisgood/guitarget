"""Strict, pure v1 merging for one Guitar Pro version; no file I/O or arranging.

Entries have the same fields as song_bundle.make_collection. Inputs should
already have passed native v1 validation. Any unrepresentable combination raises
ScoreMergeError; the caller may then request an explicit arrangement policy.
"""
from __future__ import annotations

from collections import defaultdict, deque
import copy
import json
import math
import uuid


NAMESPACE = uuid.UUID("ad4cbe27-e936-54b8-89c5-b4601668e973")
SCORE_KEYS = {"version", "title", "tuning", "timeSignature", "bpm", "measures"}
VOICES = ("melody", "bass")
TECHNIQUES = {"none", "hammerOn", "pullOff", "slide", "bendHalf", "bendFull",
              "vibrato", "palmMute", "deadNote"}


class ScoreMergeError(ValueError):
    def __init__(self, reason, message, *, location=None, details=None):
        super().__init__(message)
        self.reason = reason
        self.location = location or {}
        self.details = details or {}

    def as_dict(self):
        return {"status": "strict_merge_failed", "reason": self.reason, "message": str(self),
                "location": copy.deepcopy(self.location), "details": copy.deepcopy(self.details)}


def _fail(reason, message, location=None, **details):
    raise ScoreMergeError(reason, message, location=location, details=details)


def _canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def _identity(*values):
    return str(uuid.uuid5(NAMESPACE, _canonical(values))).upper()


def _integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _fields(value, required, optional=(), location=None):
    if not isinstance(value, dict) or not set(required) <= set(value) or set(value) - set(required) - set(optional):
        _fail("unsupported_fields", "Input contains missing or unsupported score fields", location,
              required=sorted(required), optional=sorted(optional),
              actual=sorted(value) if isinstance(value, dict) else type(value).__name__)


def _duration(rhythm, location):
    _fields(rhythm, {"value", "dotted", "triplet"}, location=location)
    value, dotted, triplet = rhythm["value"], rhythm["dotted"], rhythm["triplet"]
    if (not _integer(value) or value not in (1, 2, 4, 8, 16, 32)
            or not isinstance(dotted, bool) or not isinstance(triplet, bool)
            or dotted and triplet or triplet and value != 8):
        _fail("invalid_rhythm", "Unsupported v1 rhythm", location, rhythm=rhythm)
    return (3840 // value) * (3 if dotted else 2) // 2 * (2 if triplet else 3) // 3


def _note_content(note, location):
    _fields(note, {"id", "string", "fret", "velocity", "technique", "tieToNext"}, {"targetFret"}, location)
    if (not _integer(note["string"]) or not 1 <= note["string"] <= 6
            or not _integer(note["fret"]) or not 0 <= note["fret"] <= 24
            or isinstance(note["velocity"], bool) or not isinstance(note["velocity"], (int, float))
            or not math.isfinite(note["velocity"]) or not 0 <= note["velocity"] <= 1
            or not isinstance(note["tieToNext"], bool)
            or not isinstance(note["technique"], str) or note["technique"] not in TECHNIQUES
            or note.get("targetFret") is not None and
            (not _integer(note["targetFret"]) or not 0 <= note["targetFret"] <= 24)):
        _fail("invalid_note", "Invalid string, fret, velocity, technique, target fret or tie flag", location)
    content = {key: copy.deepcopy(value) for key, value in note.items() if key != "id"}
    # Missing and null targetFret are the same v1 optional value.
    if content.get("targetFret") is None:
        content.pop("targetFret", None)
    return content


def merge_version(title: str, entries: list[dict]) -> tuple[dict, dict]:
    """Merge one source into standard v1 plus a separate, structured audit report.

    Preserve notes and rhythms, concatenate ascending part numbers, and align
    simultaneous tracks by identical source_measures. Missing track/part slots
    are reported, never filled with invented music. IDs are deterministic and
    input data is never mutated. Raises ScoreMergeError for unsupported cases.
    """
    if not isinstance(title, str) or not isinstance(entries, list) or not entries:
        _fail("invalid_input", "A title and at least one validated part are required")
    for entry in entries:
        if not isinstance(entry, dict) or not {"source", "track_number", "part", "source_measures", "score"} <= set(entry):
            _fail("invalid_input", "Part entry is missing source, track, part, measures or score")
        if not isinstance(entry["source"], str) or not entry["source"]:
            _fail("invalid_input", "Part source must be a nonempty version identifier")
        if any(not _integer(entry[key]) or entry[key] < 1 for key in ("track_number", "part")):
            _fail("invalid_input", "Track and part numbers must be positive integers")
    sources = sorted({entry["source"] for entry in entries})
    if len(sources) != 1:
        _fail("multiple_versions", "Strict merging accepts exactly one source version", sources=sources)
    source = sources[0]
    ordered = sorted(entries, key=lambda entry: (entry["part"], entry["track_number"]))
    first_score = ordered[0]["score"]
    _fields(first_score, SCORE_KEYS)
    baseline = {key: first_score[key] for key in ("tuning", "bpm", "timeSignature")}
    tuning, bpm, meter = baseline["tuning"], baseline["bpm"], baseline["timeSignature"]
    if (not isinstance(tuning, list) or len(tuning) != 6
            or any(not _integer(n) or not 0 <= n <= 127 for n in tuning)
            or isinstance(bpm, bool) or not isinstance(bpm, (int, float))
            or not math.isfinite(bpm) or not 20 <= bpm <= 300):
        _fail("invalid_metadata", "Invalid v1 tuning or tempo")
    _fields(meter, {"numerator", "denominator"})
    if any(not _integer(meter[key]) for key in meter) or (meter["numerator"], meter["denominator"]) not in ((2, 4), (3, 4), (4, 4), (6, 8)):
        _fail("unsupported_meter", "Meter is not supported by unmodified v1", meter=meter)
    capacity = meter["numerator"] * 3840 // meter["denominator"]
    grouped_parts = defaultdict(list)
    slots = set()
    for entry in ordered:
        location = {"source": source, "track_number": entry["track_number"], "part": entry["part"]}
        slot = (entry["track_number"], entry["part"])
        if slot in slots:
            _fail("duplicate_part", "The same track/part slot occurs more than once", location)
        slots.add(slot)
        score = entry["score"]
        _fields(score, SCORE_KEYS, location=location)
        if (not _integer(score["version"]) or score["version"] != 1
                or not isinstance(score["measures"], list) or not score["measures"]):
            _fail("invalid_input", "Each entry must contain a nonempty standard v1 score", location)
        for key, reason in (("tuning", "tuning_mismatch"), ("bpm", "tempo_mismatch"), ("timeSignature", "meter_mismatch")):
            if score[key] != baseline[key]:
                _fail(reason, "Strict merging cannot change " + key, location, expected=baseline[key], actual=score[key])
        numbers = entry["source_measures"]
        if (not isinstance(numbers, list) or len(numbers) != len(score["measures"])
                or any(not _integer(number) or number < 1 for number in numbers)):
            _fail("missing_measure_alignment", "Each measure needs its original one-based measure number", location)
        grouped_parts[entry["part"]].append(entry)

    tracks = sorted({entry["track_number"] for entry in ordered})
    report = {"status": "merged", "source": source, "tracks": tracks, "parts": sorted(grouped_parts),
              "gaps": [], "input_events": 0, "input_notes": 0, "deduplicated_notes": 0,
              "part_offsets": [], "voice_reassignments": 0}
    groups = []
    occurrences = []
    measure_slots = []
    previous_part = 0
    for part, part_entries in sorted(grouped_parts.items()):
        numbers = part_entries[0]["source_measures"]
        location = {"source": source, "part": part}
        if part > previous_part + 1:
            report["gaps"].append({"kind": "missing_parts", "first_part": previous_part + 1, "last_part": part - 1})
        previous_part = part
        missing = sorted(set(tracks) - {entry["track_number"] for entry in part_entries})
        if missing:
            report["gaps"].append({"kind": "missing_tracks", "part": part, "track_numbers": missing})
        for entry in part_entries[1:]:
            if entry["source_measures"] != numbers:
                _fail("measure_alignment_mismatch", "Tracks within a part do not have identical original measure order",
                      {**location, "track_number": entry["track_number"]}, expected=numbers, actual=entry["source_measures"])
        offset = len(measure_slots)
        report["part_offsets"].append({"part": part, "output_measure": offset + 1, "measures": len(numbers)})
        measure_slots.extend((part, index, number) for index, number in enumerate(numbers))
        for local_measure, original_measure in enumerate(numbers):
            interval_groups = {}
            for entry in part_entries:
                measure = entry["score"]["measures"][local_measure]
                where = {**location, "track_number": entry["track_number"], "measure": local_measure + 1,
                         "source_measure": original_measure, "output_measure": offset + local_measure + 1}
                _fields(measure, {"id", "voices"}, location=where)
                voices = measure["voices"]
                if not isinstance(voices, list) or len(voices) != 2 or {voice.get("voice") for voice in voices if isinstance(voice, dict)} != set(VOICES):
                    _fail("invalid_voices", "Each input measure must have melody and bass voices", where)
                for voice in sorted(voices, key=lambda value: VOICES.index(value["voice"])):
                    _fields(voice, {"voice", "events"}, location=where)
                    if not isinstance(voice["events"], list):
                        _fail("invalid_input", "Voice events must be a list", where)
                    for index, event in enumerate(voice["events"]):
                        origin = {**where, "voice": voice["voice"], "event_index": index}
                        _fields(event, {"id", "startTick", "rhythm", "notes"}, {"lyric"}, origin)
                        if not _integer(event["startTick"]):
                            _fail("event_out_of_bounds", "Event start must be an integer tick", origin)
                    preceding_end = 0
                    for index, event in sorted(enumerate(voice["events"]), key=lambda pair: pair[1]["startTick"]):
                        origin = {**where, "voice": voice["voice"], "event_index": index}
                        duration = _duration(event["rhythm"], origin)
                        start = event["startTick"]
                        if not _integer(start) or start < 0 or start + duration > capacity:
                            _fail("event_out_of_bounds", "Event lies outside its measure", origin, start=start, duration=duration)
                        if start < preceding_end:
                            _fail("input_voice_overlap", "An input voice already contains overlapping events", origin)
                        preceding_end = start + duration
                        if not isinstance(event["notes"], list) or event.get("lyric") is not None and not isinstance(event["lyric"], str):
                            _fail("invalid_input", "Invalid notes or lyric field", origin)
                        key = (start, duration)
                        if key not in interval_groups:
                            interval_groups[key] = {"start": (offset + local_measure) * capacity + start,
                                "end": (offset + local_measure) * capacity + start + duration,
                                "measure": offset + local_measure, "rhythm": copy.deepcopy(event["rhythm"]),
                                "notes": {}, "lyric": None, "origins": []}
                        group = interval_groups[key]
                        group["origins"].append(origin)
                        lyric = event.get("lyric")
                        if lyric is not None:
                            if group["lyric"] is not None and group["lyric"] != lyric:
                                _fail("lyric_conflict", "Simultaneous lyrics differ; strict merging cannot replace or concatenate them",
                                      origin, existing=group["lyric"], incoming=lyric)
                            group["lyric"] = lyric
                        report["input_events"] += 1
                        event_strings = set()
                        for note in event["notes"]:
                            content = _note_content(note, origin)
                            string = content["string"]
                            if string in event_strings:
                                _fail("input_chord_conflict", "An input chord contains multiple notes on one string", origin, string=string)
                            event_strings.add(string)
                            report["input_notes"] += 1
                            if string in group["notes"]:
                                existing = group["notes"][string]
                                if existing != content:
                                    reason = "same_string_conflict" if existing["fret"] != content["fret"] else "note_expression_conflict"
                                    _fail(reason, "Simultaneous notes on one string differ", origin,
                                          existing=existing, incoming=content, other=group["origins"][0])
                                report["deduplicated_notes"] += 1
                            else:
                                group["notes"][string] = content
                            occurrences.append({"group": group, "note": content, "origin": origin})
            groups.extend(interval_groups[key] for key in sorted(interval_groups))

    groups.sort(key=lambda group: (group["start"], group["end"]))
    for index, group in enumerate(groups):
        group["index"] = index
    # One string cannot sustain two separately timed notes, even if their fret
    # happens to match. Only exact same-interval duplicates were coalesced above.
    active = []
    overlap_edges = []
    for group in groups:
        active = [other for other in active if other["end"] > group["start"]]
        for other in active:
            shared = set(other["notes"]) & set(group["notes"])
            if shared:
                string = min(shared)
                reason = "same_string_conflict" if other["notes"][string]["fret"] != group["notes"][string]["fret"] else "same_string_timing_conflict"
                _fail(reason, "Overlapping note intervals share a guitar string", group["origins"][0],
                      string=string, interval=[group["start"], group["end"]],
                      other_interval=[other["start"], other["end"]], other=other["origins"][0])
            overlap_edges.append((other["index"], group["index"]))
        if len(active) >= 2:
            _fail("voice_capacity_exceeded", "More than two distinct event intervals overlap", group["origins"][0],
                  events=[other["origins"][0] for other in active] + [group["origins"][0]])
        active.append(group)

    # Tie-linked groups must keep the same voice, including across bar lines.
    parent = list(range(len(groups)))
    def find(index):
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index
    starts = defaultdict(list)
    for occurrence in occurrences:
        origin, note, group = occurrence["origin"], occurrence["note"], occurrence["group"]
        starts[(origin["track_number"], origin["voice"], note["string"], note["fret"], group["start"])].append(occurrence)
    for occurrence in occurrences:
        origin, note, group = occurrence["origin"], occurrence["note"], occurrence["group"]
        if not note["tieToNext"]:
            continue
        targets = starts[(origin["track_number"], origin["voice"], note["string"], note["fret"], group["end"])]
        if len(targets) != 1 or targets[0]["origin"]["part"] not in (origin["part"], origin["part"] + 1):
            _fail("tie_target_missing", "A tie has no unique adjacent continuation in its source track/voice", origin,
                  string=note["string"], fret=note["fret"], end_tick=group["end"])
        target = targets[0]
        if target["note"]["technique"] != "none":
            _fail("tie_expression_conflict", "A tie continuation would retrigger a technique", target["origin"])
        parent[find(group["index"])] = find(target["group"]["index"])
    graph = defaultdict(set)
    for left, right in overlap_edges:
        a, b = find(left), find(right)
        if a == b:
            _fail("tie_voice_conflict", "Tie continuity requires overlapping events in the same voice", groups[right]["origins"][0],
                  other=groups[left]["origins"][0])
        graph[a].add(b)
        graph[b].add(a)
    colors = {}
    for group in groups:
        root = find(group["index"])
        if root in colors:
            continue
        colors[root] = VOICES.index(group["origins"][0]["voice"])
        queue = deque([root])
        while queue:
            current = queue.popleft()
            for neighbor in sorted(graph[current]):
                desired = 1 - colors[current]
                if neighbor in colors and colors[neighbor] != desired:
                    _fail("tie_voice_conflict", "Tie constraints cannot fit two nonoverlapping voices", group["origins"][0])
                if neighbor not in colors:
                    colors[neighbor] = desired
                    queue.append(neighbor)

    measures = [{"id": _identity(source, "measure", index, part, local),
                 "voices": [{"voice": voice, "events": []} for voice in VOICES]}
                for index, (part, local, _) in enumerate(measure_slots)]
    for group in groups:
        color = colors[find(group["index"])]
        event_id = _identity(source, "event", group["measure"], group["start"], group["end"], color)
        event = {"id": event_id, "startTick": group["start"] % capacity,
                 "rhythm": group["rhythm"], "notes": []}
        if group["lyric"] is not None:
            event["lyric"] = group["lyric"]
        for string, note in sorted(group["notes"].items()):
            event["notes"].append({"id": _identity(source, "note", event_id, string, note), **copy.deepcopy(note)})
        measures[group["measure"]]["voices"][color]["events"].append(event)
        report["voice_reassignments"] += sum(origin["voice"] != VOICES[color] for origin in group["origins"])
    score = {"version": 1, "title": title, **copy.deepcopy(baseline), "measures": measures}
    report.update(output_measures=len(measures), output_events=len(groups),
                  output_notes=sum(len(group["notes"]) for group in groups))
    return score, report

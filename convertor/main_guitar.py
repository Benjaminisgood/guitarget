"""Select an original primary guitar track or excerpt without arranging notes.

Inputs are previously native-validated v1 fragments from one GP source. The
strict merger checks representability, but its regrouped events are not used:
the returned score retains each original measure and both original voices.
Only the title and UUIDs that collide across fragments may change.
"""
from __future__ import annotations

from collections import defaultdict
import copy
from fractions import Fraction
import json
import math
import re
import uuid

from merge_score import ScoreMergeError, merge_version


NAMESPACE = uuid.UUID("f29daf68-94b9-57b7-b4b2-85543010a7ad")
PRIMARY_NAME = re.compile(r"\b(?:main|lead)\b|主吉他|主音", re.IGNORECASE)
PARAMETERS = ("tuning", "bpm", "timeSignature")
# These failures can result from merging already-valid voices or from retaining
# a dangling tie at an excerpt boundary. Copying the original voices avoids the
# former; native v1 treats a missing tie continuation as a warning.
COPYABLE_STRICT_FAILURES = {"lyric_conflict", "tie_voice_conflict", "tie_target_missing"}


class MainGuitarSelectionError(ValueError):
    def __init__(self, reason, message):
        super().__init__(message)
        self.reason = reason

    def as_dict(self):
        return {"status": "selection_failed", "reason": self.reason, "message": str(self)}


def _error(reason, message):
    raise MainGuitarSelectionError(reason, message)


def _statistics(entries):
    result = {"sounding_measures": 0, "notes": 0, "measures": 0, "duration": Fraction(0)}
    for entry in entries:
        try:
            score = entry["score"]
            bpm = score["bpm"]
            meter = score["timeSignature"]
            if (isinstance(bpm, bool) or not isinstance(bpm, (int, float))
                    or not math.isfinite(bpm) or not 20 <= bpm <= 300
                    or any(type(meter[key]) is not int for key in ("numerator", "denominator"))
                    or (meter["numerator"], meter["denominator"]) not in ((2, 4), (3, 4), (4, 4), (6, 8))
                    or not isinstance(score["measures"], list) or not score["measures"]):
                raise ValueError("invalid tempo, meter or measures")
            count = len(score["measures"])
            result["measures"] += count
            result["duration"] += Fraction(count * meter["numerator"] * 240, meter["denominator"]) / Fraction(str(bpm))
            for measure in score["measures"]:
                notes = sum(len(event["notes"]) for voice in measure["voices"] for event in voice["events"])
                result["notes"] += notes
                result["sounding_measures"] += bool(notes)
        except (KeyError, TypeError, ValueError, ZeroDivisionError) as error:
            _error("invalid_input", f"Invalid v1 fragment statistics: {error}")
    return result


def _parameter_key(entry):
    return {key: entry["score"][key] for key in PARAMETERS}


def _failure(error):
    result = error.as_dict() if hasattr(error, "as_dict") else {"message": str(error)}
    return {**result, "status": "strict_merge_failed"}


def _copy_original_measures(title, entries):
    # Check the selected span without adopting the merger's voice/chord changes.
    strict_warning = None
    try:
        merge_version(title, entries)
    except ScoreMergeError as error:
        if error.reason not in COPYABLE_STRICT_FAILURES:
            raise
        strict_warning = _failure(error)
    score = copy.deepcopy(entries[0]["score"])
    score["title"] = title
    score["measures"] = []
    seen, changed = set(), 0

    def preserve_id(node, path):
        nonlocal changed
        try:
            identifier = uuid.UUID(node["id"])
        except (KeyError, TypeError, ValueError, AttributeError):
            _error("invalid_identity", "Original fragment contains an invalid UUID")
        if identifier in seen:
            serial = 0
            while identifier in seen:
                seed = json.dumps([entries[0]["source"], entries[0]["track_number"], path, node["id"], serial])
                identifier = uuid.uuid5(NAMESPACE, seed)
                serial += 1
            node["id"] = str(identifier).upper()
            changed += 1
        seen.add(identifier)

    for entry in entries:
        for index, measure in enumerate(copy.deepcopy(entry["score"]["measures"])):
            path = [entry["part"], index]
            preserve_id(measure, [*path, "measure"])
            for voice_index, voice in enumerate(measure["voices"]):
                for event_index, event in enumerate(voice["events"]):
                    event_path = [*path, "voice", voice_index, "event", event_index]
                    preserve_id(event, event_path)
                    for note_index, note in enumerate(event["notes"]):
                        preserve_id(note, [*event_path, "note", note_index])
            score["measures"].append(measure)
    return score, changed, strict_warning


def _tie_warnings(score):
    capacity = score["timeSignature"]["numerator"] * 3840 // score["timeSignature"]["denominator"]
    starts, tied = defaultdict(list), []
    for measure_index, measure in enumerate(score["measures"]):
        for voice in measure["voices"]:
            for event in voice["events"]:
                rhythm = event["rhythm"]
                duration = (3840 // rhythm["value"]) * (3 if rhythm["dotted"] else 2) // 2 * (2 if rhythm["triplet"] else 3) // 3
                start = measure_index * capacity + event["startTick"]
                for note in event["notes"]:
                    key = (voice["voice"], note["string"], note["fret"])
                    starts[(*key, start)].append(note)
                    if note["tieToNext"]:
                        tied.append((key, start + duration, measure_index + 1, event["startTick"]))
    return [{"measure": measure, "start_tick": tick, "voice": key[0], "string": key[1], "fret": key[2]}
            for key, end, measure, tick in tied if len(starts[(*key, end)]) != 1]


def select_main_guitar(title: str, entries: list[dict]) -> tuple[dict, dict]:
    """Keep one original guitar track, or its longest compatible excerpt.

    Rank coverage first, primary-track labels at equal sounding coverage, then
    note count, measure count and lower track number. Silent tracks are ranked
    by measure count, label and track number. Excerpts use consecutive part
    numbers and identical global parameters; sounding runs rank by original
    duration, notes, measures, then earlier part number. No notes are arranged.
    """
    if not isinstance(title, str) or not isinstance(entries, list) or not entries:
        _error("invalid_input", "A title and nonempty list of validated guitar parts are required")
    slots, sources, tracks = set(), set(), defaultdict(list)
    for entry in entries:
        if (not isinstance(entry, dict)
                or not {"source", "track_number", "part", "source_measures", "score"} <= set(entry)
                or not isinstance(entry["source"], str) or not entry["source"]
                or any(type(entry[key]) is not int or entry[key] < 1 for key in ("track_number", "part"))
                or not isinstance(entry.get("track_name", ""), str)):
            _error("invalid_input", "Invalid source, track or part entry")
        sources.add(entry["source"])
        slot = (entry["source"], entry["track_number"], entry["part"])
        if slot in slots:
            _error("duplicate_part", "A source/track/part slot occurs more than once")
        slots.add(slot)
        tracks[entry["track_number"]].append(entry)
    if len(sources) != 1:
        _error("multiple_versions", "Primary guitar selection accepts exactly one GP source version")
    for parts in tracks.values():
        parts.sort(key=lambda entry: entry["part"])
    statistics = {number: _statistics(parts) for number, parts in tracks.items()}
    labelled = {number: any(PRIMARY_NAME.search(entry.get("track_name", "")) for entry in parts)
                for number, parts in tracks.items()}
    any_sound = any(item["notes"] for item in statistics.values())

    def track_rank(number):
        item = statistics[number]
        if not any_sound:
            return item["measures"], labelled[number], -number
        return item["sounding_measures"], labelled[number], item["notes"], item["measures"], -number

    selected = max(tracks, key=track_rank)
    primary = tracks[selected]
    attempts = []

    def attempt(parts, stage):
        try:
            return _copy_original_measures(title, parts)
        except (ScoreMergeError, MainGuitarSelectionError) as error:
            attempts.append({"stage": stage, "parts": [entry["part"] for entry in parts], "error": _failure(error)})
            return None

    kept = primary
    result = attempt(kept, "full_primary_track")
    reason = "Selected the complete available primary guitar track with its original notes and voices."
    if result is None:
        runs = []
        for entry in primary:
            if (not runs or entry["part"] != runs[-1][-1]["part"] + 1
                    or _parameter_key(entry) != _parameter_key(runs[-1][-1])):
                runs.append([])
            runs[-1].append(entry)
        candidates = [(run, _statistics(run)) for run in runs]
        sounding = [item for item in candidates if item[1]["notes"]]
        if sounding:
            candidates = sounding

        def span_rank(item):
            parts, stats = item
            return stats["duration"], stats["notes"], stats["measures"], -parts[0]["part"]

        kept = max(candidates, key=span_rank)[0]
        result = attempt(kept, "compatible_contiguous_run")
        reason = "The complete primary track cannot share one v1 document; retained its longest compatible original contiguous excerpt."
        if result is None:
            candidates = [([entry], _statistics([entry])) for entry in primary]
            sounding = [item for item in candidates if item[1]["notes"]]
            # Try sounding parts first, then silent parts if none is usable.
            candidates.sort(key=lambda item: (bool(item[1]["notes"]), *span_rank(item)), reverse=True)
            for kept, _ in candidates:
                result = attempt(kept, "single_original_part")
                if result is not None:
                    break
            reason = "Retained one original primary-guitar part because larger spans could not be represented unchanged."
    if result is None:
        _error("no_valid_primary_part", "No valid original part of the selected primary guitar track could be retained")
    score, id_changes, strict_warning = result
    kept_numbers = {entry["part"] for entry in kept}
    omitted_parts = [entry["part"] for entry in primary if entry["part"] not in kept_numbers]
    omitted_tracks = [{"track_number": number, "track_name": parts[0].get("track_name", ""),
                       "parts": [entry["part"] for entry in parts]}
                      for number, parts in sorted(tracks.items()) if number != selected]
    unresolved_ties = _tie_warnings(score)
    warnings = []
    if omitted_tracks:
        warnings.append(f"Retained only the primary guitar; omitted {len(omitted_tracks)} other tracks. Original fragments remain in the external backup.")
    if omitted_parts:
        warnings.append(f"This is an original excerpt: omitted primary-track parts {omitted_parts}. Original fragments remain in the external backup.")
    if unresolved_ties:
        warnings.append(f"Retained {len(unresolved_ties)} tie flags without a unique continuation in this excerpt; no tieToNext values were cleared.")
    gaps = [{"after_part": left["part"], "before_part": right["part"]}
            for left, right in zip(kept, kept[1:]) if right["part"] != left["part"] + 1]
    if gaps:
        warnings.append("The available track has missing part numbers; no missing music or duration was invented.")
    name = next((entry.get("track_name") for entry in primary if entry.get("track_name")), "")
    report = {"status": "selected", "source": next(iter(sources)), "selected_track": selected,
              "selected_track_name": name, "kept_parts": [entry["part"] for entry in kept],
              "omitted_tracks": omitted_tracks, "omitted_parts": omitted_parts,
              "scope": "primary_track_excerpt" if omitted_parts else "full_primary_track",
              "chosen_parameters": {key: copy.deepcopy(score[key]) for key in PARAMETERS},
              "reason": reason, "warnings": warnings, "attempts": attempts,
              "selection_policy": "sounding-measure coverage, primary label, notes, measures, lower track number; silent tracks use measures, label, lower track number",
              "selected_track_statistics": {**{key: value for key, value in statistics[selected].items() if key != "duration"},
                                             "duration_seconds": float(statistics[selected]["duration"])},
              "voice_reassignments": 0, "id_reassignments": id_changes, "note_changes": 0,
              "unresolved_ties": unresolved_ties, "part_gaps": gaps, "strict_copy_warning": strict_warning}
    return score, report

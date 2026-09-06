"""Map PyGuitarPro's score model to Guitarget v1 without quantization.

This module never reads/writes files and never changes the source Song. One result
is returned per eligible guitar track and constant-meter/tempo part. Rejected
tracks and parts have score=None and an explicit error. IDs are uuid5 identities
of source_key, track, playback occurrence, voice, beat and duration fragment.

GP and Guitarget both number string 1 as the highest string. GP capo (offset) is
folded into the six MIDI tuning values; original fret numbers remain unchanged.
GP voice 0/1 become melody/bass without mixing tracks. Rhythms are exact rational
ticks; durations may be split into valid v1 rhythms with per-note ties. No note,
rest, invalid fret, unsupported timing or navigation is silently dropped.

Written notes survive unsupported playback/notation effects with explicit
warnings. Complex repeat nesting/direction jumps, swing, tempo ramps, and timing
that v1 cannot encode are rejected. Common repeat bars and alternate endings
are expanded before part splitting. JSON has only fields understood by v1.
"""
from __future__ import annotations

from collections import defaultdict
from fractions import Fraction
from functools import lru_cache
import math
from uuid import UUID, uuid5

_NAMESPACE = UUID("5e9d4ab4-7a5b-5a7c-bf62-91ae42745d90")
_SUPPORTED_METERS = {(2, 4), (3, 4), (4, 4), (6, 8)}
_MAX_PLAYBACK_MEASURES = 100_000


class ConversionError(ValueError):
    """Source content cannot be represented faithfully in Guitarget v1."""


def _name(value):
    return getattr(value, "name", str(value))


def _uid(*pieces):
    return str(uuid5(_NAMESPACE, "/".join(map(str, pieces))))


def _integer(value, what):
    value = Fraction(value)
    if value.denominator != 1:
        raise ConversionError(f"{what}: fractional tick/value {value} cannot be encoded")
    return value.numerator


# Preference: use a single ordinary/dotted symbol whenever possible. Split only
# when needed; coin-change chooses a minimum-length exact decomposition.
_RHYTHMS = []
for _value in (1, 2, 4, 8, 16, 32):
    for _dotted in (False, True):
        _RHYTHMS.append((3840 // _value * (3 if _dotted else 2) // 2,
                         {"value": _value, "dotted": _dotted, "triplet": False}))
_RHYTHMS.append((320, {"value": 8, "dotted": False, "triplet": True}))
_RHYTHMS.sort(key=lambda item: -item[0])


@lru_cache(maxsize=256)
def split_duration(ticks):
    """Return immutable (ticks,value,dotted,triplet) tuples or raise; no rounding."""
    ticks = _integer(ticks, "duration")
    if ticks <= 0 or ticks > 100_000:
        raise ConversionError(f"duration: unsupported tick length {ticks}")
    for size, rhythm in _RHYTHMS:
        if ticks == size:
            return ((size, rhythm["value"], rhythm["dotted"], rhythm["triplet"]),)
    # All target durations are multiples of 20 ticks. Bound the DP in units of
    # 20; most source rhythms hit the exact-symbol branch above.
    if ticks % 20:
        raise ConversionError(f"duration: {ticks} ticks cannot be expressed exactly")
    best = [None] * (ticks // 20 + 1)
    best[0] = ()
    for units in range(1, len(best)):
        for size, rhythm in _RHYTHMS:
            coin = size // 20
            if coin <= units and best[units - coin] is not None:
                candidate = best[units - coin] + ((size, rhythm["value"], rhythm["dotted"], rhythm["triplet"]),)
                if best[units] is None or len(candidate) < len(best[units]):
                    best[units] = candidate
    if best[-1] is None:
        raise ConversionError(f"duration: {ticks} ticks cannot be expressed exactly")
    return tuple(sorted(best[-1], key=lambda item: -item[0]))


def _duration(beat):
    d = beat.duration
    if d.value <= 0 or d.tuplet.enters <= 0 or d.tuplet.times <= 0:
        raise ConversionError("duration: invalid note value or tuplet ratio")
    return Fraction(3840, d.value) * (Fraction(3, 2) if d.isDotted else 1) * Fraction(d.tuplet.times, d.tuplet.enters)


def playback_order(headers):
    """Expand flat GP repeat sections and bitmask alternate endings.

    PyGuitarPro repeatClose is the number of additional passes (-1=no close).
    Alternative masks continue through the closing bar; immediately following
    marked alternatives are the final endings. Nested/ambiguous repeat layouts
    raise rather than guessing a playback order.
    """
    if len(headers) > _MAX_PLAYBACK_MEASURES:
        raise ConversionError("repeat: source exceeds playback measure limit")
    for index, header in enumerate(headers):
        if getattr(header, "direction", None) or getattr(header, "fromDirection", None):
            raise ConversionError(f"navigation: measure {index + 1} has unsupported D.C./D.S./Coda/Fine direction")
    blocks = {}
    pending = None
    implicit_start = 0
    consumed_alternatives = set()
    index = 0
    while index < len(headers):
        header = headers[index]
        if header.isRepeatOpen:
            if pending is not None:
                raise ConversionError(f"repeat: nested/unclosed repeat opening at measure {index + 1}")
            pending = index
        if header.repeatClose >= 0:
            start = pending if pending is not None else implicit_start
            if start > index:
                raise ConversionError("repeat: ambiguous repeat start")
            tail = index + 1
            while tail < len(headers) and headers[tail].repeatAlternative > 0 and not headers[tail].isRepeatOpen:
                if headers[tail].repeatClose >= 0:
                    raise ConversionError(f"repeat: multiple alternative closing bars at measure {tail + 1} are unsupported")
                consumed_alternatives.add(tail)
                tail += 1
            for inside in range(start, index + 1):
                if headers[inside].repeatAlternative:
                    consumed_alternatives.add(inside)
            blocks[start] = (index, tail, header.repeatClose + 1)
            pending = None
            implicit_start = tail
            index = tail
        else:
            index += 1
    for index, header in enumerate(headers):
        if header.repeatAlternative and index not in consumed_alternatives:
            raise ConversionError(f"repeat: alternate ending at measure {index + 1} has no supported repeat block")
    order = []
    index = 0
    while index < len(headers):
        if index not in blocks:
            order.append(index)
            index += 1
            continue
        close, tail, passes = blocks[index]
        if not 1 <= passes <= 128:
            raise ConversionError(f"repeat: unsupported pass count {passes}")
        for iteration in range(passes):
            mask = 0
            for source_index in range(index, tail):
                header = headers[source_index]
                if source_index == close + 1:
                    mask = 0
                if header.repeatAlternative:
                    mask = header.repeatAlternative
                if source_index > close and iteration != passes - 1:
                    continue
                if not mask or mask & (1 << iteration):
                    order.append(source_index)
                if len(order) > _MAX_PLAYBACK_MEASURES:
                    raise ConversionError("repeat: expanded score exceeds playback measure limit")
        index = tail
    if not order:
        raise ConversionError("repeat: no playable measures after expansion")
    return order


def _tempo_changes(song):
    changes = defaultdict(dict)
    conflicts = defaultdict(list)
    for track in song.tracks:
        for index, measure in enumerate(track.measures):
            for voice in measure.voices:
                cursor = Fraction(0)
                for beat in voice.beats:
                    offset = Fraction(beat.start - measure.start) if beat.start is not None else cursor
                    mix = getattr(beat.effect, "mixTableChange", None)
                    if mix and mix.tempo is not None and mix.tempo.value >= 0:
                        item = (float(mix.tempo.value), int(mix.tempo.duration))
                        if offset in changes[index] and changes[index][offset] != item:
                            conflicts[index].append(f"tempo: conflicting changes at measure {index + 1}, tick {offset}")
                        changes[index][offset] = item
                    if _name(beat.status) != "empty":
                        cursor = offset + _duration(beat)
    return changes, conflicts


def _parts(song, order):
    changes, conflicts = _tempo_changes(song)
    bpm = float(song.tempo)
    parts = []
    current = None
    playback_tick = Fraction(0)
    ramp_end = Fraction(-1)
    for occurrence, index in enumerate(order):
        header = song.measureHeaders[index]
        meter = (int(header.timeSignature.numerator), int(header.timeSignature.denominator.value))
        # GP's initial song tempo is an implicit automation at the first bar.
        # A repeat back to bar 1 replays it; a repeat to an intermediate bar
        # without explicit tempo automation keeps the current playback tempo.
        if index == 0:
            bpm = float(song.tempo)
            ramp_end = Fraction(-1)
        errors = list(conflicts[index])
        if playback_tick < ramp_end:
            errors.append(f"tempo: measure {index + 1} overlaps a gradual tempo change")
        start_bpm = bpm
        for offset, (value, duration) in sorted(changes[index].items()):
            if offset == 0:
                start_bpm = value
            elif value != start_bpm:
                errors.append(f"tempo: measure {index + 1} changes tempo inside the measure at tick {offset}")
            if duration > 0:
                errors.append(f"tempo: measure {index + 1} contains a gradual tempo change over {duration} beats")
                ramp_end = max(ramp_end, playback_tick + offset + duration * 960)
            else:
                ramp_end = playback_tick + offset
            bpm = value
        if meter not in _SUPPORTED_METERS:
            errors.append(f"meter: unsupported {meter[0]}/{meter[1]} at measure {index + 1}")
        if not math.isfinite(start_bpm) or not 20 <= start_bpm <= 300:
            errors.append(f"tempo: {start_bpm:g} BPM is outside 20..300 at measure {index + 1}")
        if _name(header.tripletFeel) != "none":
            errors.append(f"swing: {_name(header.tripletFeel)} triplet feel at measure {index + 1} cannot be silently converted to straight rhythm")
        # Invalid measures are isolated so a tempo/meter error does not reject
        # adjacent otherwise valid music with the same signature.
        key = (meter, start_bpm, occurrence if errors else None)
        if current is None or current["key"] != key:
            current = {"key": key, "meter": meter, "bpm": start_bpm, "occurrences": [], "errors": []}
            parts.append(current)
        current["occurrences"].append((occurrence, index))
        current["errors"].extend(errors)
        playback_tick += Fraction(3840 * meter[0], meter[1])
    return parts


def _warn_effects(note, beat, warnings):
    fx = note.effect
    ignored = {
        "letRing": "let ring is reduced to the written note duration",
        "harmonic": "harmonic playback is reduced to the underlying fretted note",
        "grace": "grace-note ornament is not synthesized; the main note is retained",
        "trill": "trill ornament is not synthesized; the main note is retained",
        "tremoloPicking": "tremolo picking is reduced to the written note",
        "staccato": "staccato gate length is reduced to the written note duration",
        "ghostNote": "ghost-note notation is omitted; the stored velocity is retained",
        "accentuatedNote": "accent notation is omitted; the stored velocity is retained",
        "heavyAccentuatedNote": "heavy accent notation is omitted; the stored velocity is retained",
    }
    for key, explanation in ignored.items():
        if getattr(fx, key, None):
            warnings.add(f"effect_{key}: {explanation}")
    if getattr(note, "durationPercent", 1.0) != 1.0:
        warnings.add("effect_durationPercent: per-note duration percentage is reduced to the written event duration")
    if any(getattr(getattr(fx, key, None), "value", -1) >= 0 for key in ("leftHandFinger", "rightHandFinger")):
        warnings.add("notation_fingering: left/right hand finger annotations are not represented")


def _technique(note, beat, next_note, warnings):
    _warn_effects(note, beat, warnings)
    fx = note.effect
    choices = []
    if _name(note.type) == "dead":
        choices.append(("deadNote", None))
    if fx.bend is not None and fx.bend.points:
        points = fx.bend.points
        peak = max(point.value for point in points)
        # GP stores 25-unit quarter tones. PyGuitarPro divides raw values by
        # 25 (despite its misleading bendSemitone name), so 2=one semitone,
        # 4=one whole tone. alphaTab's GP3To5Importer independently documents
        # this same raw/25 value as "amount of quarters".
        if peak in (2, 4):
            choices.append(("bendHalf" if peak == 2 else "bendFull", None))
            warnings.add("effect_bend_timing: GP bend point positions are approximated by Guitarget's fixed bend envelope")
            if any(point.vibrato for point in points) or points[0].value != 0 or points[-1].value != peak or any(a.value > b.value for a, b in zip(points, points[1:])):
                warnings.add("effect_bend_curve: complex/pre-bend/release curve reduced to one upward half/full bend")
        else:
            warnings.add(f"effect_bend_range: bend peak {peak}/2 semitones unsupported; underlying fretted note retained")
    if fx.hammer or fx.slides:
        target = next_note.value if next_note is not None else None
        if target is None or not 0 <= target <= 24 or target == note.value:
            warnings.add("effect_transition_target: hammer/pull/slide has no distinct valid following fret; underlying note retained")
        else:
            if fx.hammer:
                choices.append(("hammerOn" if target > note.value else "pullOff", target))
            if fx.slides:
                supported = [slide for slide in fx.slides if _name(slide) in ("shiftSlideTo", "legatoSlideTo")]
                if supported:
                    choices.append(("slide", target))
                if len(supported) != len(fx.slides):
                    warnings.add("effect_slide_shape: slide-in/out decorations omitted; underlying notes retained")
            if fx.hammer or any(_name(slide) in ("shiftSlideTo", "legatoSlideTo") for slide in fx.slides):
                warnings.add("effect_connection_timing: GP connection into the following note is approximated by Guitarget's within-note target motion")
    if fx.vibrato or getattr(beat.effect, "vibrato", False):
        choices.append(("vibrato", None))
    if fx.palmMute:
        choices.append(("palmMute", None))
    if len(choices) > 1:
        warnings.add("effect_combination: multiple techniques reduced to " + choices[0][0] + " (priority deadNote,bend,hammer/pull,slide,vibrato,palmMute)")
    return choices[0] if choices else ("none", None)


def _beat_warnings(beat, warnings):
    fx = beat.effect
    if beat.text:
        warnings.add("notation_text: beat text/chord instructions are not converted to lyrics")
    for key in ("chord", "fadeIn", "hasRasgueado", "tremoloBar"):
        if getattr(fx, key, None):
            warnings.add(f"effect_{key}: beat annotation/playback effect omitted; base notes retained")
    for key in ("pickStroke", "slapEffect"):
        if _name(getattr(fx, key, None)) not in ("none", "None"):
            warnings.add(f"effect_{key}: beat articulation omitted; base notes retained")
    if _name(getattr(getattr(fx, "stroke", None), "direction", None)) not in ("none", "None"):
        warnings.add("effect_stroke: strum/arpeggio timing reduced to simultaneous written chord")
    if _name(getattr(beat, "octave", None)) not in ("none", "None"):
        warnings.add("notation_octave: octave notation omitted; original string/fret pitch retained")
    mix = getattr(fx, "mixTableChange", None)
    if mix:
        for key in ("instrument", "volume", "balance", "chorus", "reverb", "phaser", "tremolo", "wah"):
            if getattr(mix, key, None) is not None:
                warnings.add(f"mixer_{key}: mixer automation is not represented")


def _raw_part(track, part):
    result = []
    for occurrence, source_index in part["occurrences"]:
        if source_index >= len(track.measures):
            raise ConversionError(f"structure: track is missing source measure {source_index + 1}")
        measure = track.measures[source_index]
        if len(measure.voices) > 2 and any(v.beats for v in measure.voices[2:]):
            raise ConversionError(f"voices: more than two voices at source measure {source_index + 1}")
        voices = []
        for voice_index in range(2):
            events = []
            cursor = Fraction(0)
            voice = measure.voices[voice_index] if voice_index < len(measure.voices) else None
            for beat_index, beat in enumerate(voice.beats if voice else []):
                if _name(beat.status) == "empty":
                    if beat.notes:
                        raise ConversionError(f"structure: empty beat contains notes in measure {source_index + 1}")
                    continue
                start = Fraction(beat.start - measure.start) if beat.start is not None else cursor
                duration = _duration(beat)
                cursor = start + duration
                events.append({"beat": beat, "beat_index": beat_index, "start": _integer(start, "event start"), "duration": duration})
            voices.append(sorted(events, key=lambda item: item["start"]))
        result.append({"occurrence": occurrence, "source_index": source_index, "voices": voices})
    return result


def _event_ticks(event):
    rhythm = event["rhythm"]
    return 3840 // rhythm["value"] * (3 if rhythm["dotted"] else 2) // 2 * (2 if rhythm["triplet"] else 3) // 3


def _bridge_tie(previous, absolute_start, containers, voice_index, capacity, source_key, track_number, part_number):
    """GP ties may reach past intervening beats which omit that string.

    Fill the sustained string into those chords/rests (and any implicit gaps).
    This preserves GP's one sounding note, while making Guitarget's required
    immediately adjacent continuation chain explicit.
    """
    original = previous["note"]
    original["tieToNext"] = True
    cursor = previous["end"]
    while cursor < absolute_start:
        measure_index, local_start = divmod(cursor, capacity)
        events = containers[(voice_index, measure_index)]
        events.sort(key=lambda event: event["startTick"])
        following = next((event for event in events if event["startTick"] + _event_ticks(event) > local_start), None)
        if following is not None and following["startTick"] < local_start:
            raise ConversionError("tie: continuation enters the middle of another rhythm event")
        if following is not None and following["startTick"] == local_start:
            length = _event_ticks(following)
            if cursor + length > absolute_start:
                raise ConversionError("tie: continuation overlaps its destination rhythm")
            if any(note["string"] == original["string"] for note in following["notes"]):
                raise ConversionError("tie: another written note occupies the sustained string")
            note = dict(original)
            note.update(id=_uid(following["id"], "tie_bridge", original["string"]), technique="none", tieToNext=True)
            note.pop("targetFret", None)
            following["notes"].append(note)
            cursor += length
            continue
        gap_end = min(absolute_start, (measure_index + 1) * capacity)
        if following is not None:
            gap_end = min(gap_end, measure_index * capacity + following["startTick"])
        for length, value, dotted, triplet in split_duration(gap_end - cursor):
            event_id = _uid(source_key, track_number, part_number, voice_index, "tie_gap", cursor)
            note = dict(original)
            note.update(id=_uid(event_id, original["string"]), technique="none", tieToNext=True)
            note.pop("targetFret", None)
            events.append({"id": event_id, "startTick": cursor % capacity,
                           "rhythm": {"value": value, "dotted": dotted, "triplet": triplet}, "notes": [note]})
            cursor += length
        events.sort(key=lambda event: event["startTick"])


def _validate_voice_strings(measures, source_indices):
    # Run after all tie bridges: a later measure may add a continuation into a
    # previously completed measure, including across the other voice's notes.
    for measure, source_index in zip(measures, source_indices):
        occupied = defaultdict(list)
        for voice_index, voice in enumerate(measure["voices"]):
            voice["events"].sort(key=lambda event: event["startTick"])
            for event in voice["events"]:
                length = _event_ticks(event)
                for note in event["notes"]:
                    start, end = event["startTick"], event["startTick"] + length
                    for previous_start, previous_end, previous_voice in occupied[note["string"]]:
                        if previous_voice != voice_index and start < previous_end and previous_start < end:
                            raise ConversionError(f"voice_conflict: string {note['string']} overlaps across voices at source measure {source_index + 1}")
                    occupied[note["string"]].append((start, end, voice_index))


def _map_part(song, track, part, source_key, part_number, warnings):
    tuning_by_number = {int(s.number): int(s.value) for s in track.strings}
    if set(tuning_by_number) != set(range(1, 7)):
        raise ConversionError("tuning: expected distinct strings numbered 1..6")
    tuning = [tuning_by_number[index] + int(track.offset) for index in range(1, 7)]
    if any(not 0 <= midi <= 127 for midi in tuning):
        raise ConversionError("tuning: capo-adjusted MIDI tuning is outside 0..127")
    if track.offset:
        warnings.add(f"capo: fret {track.offset} folded into effective open-string MIDI tuning; source fret positions retained")
    if getattr(track, "is12StringedGuitarTrack", False):
        warnings.add("instrument_12_string: six courses retained; doubled-string timbre is not represented")
    if getattr(track, "isBanjoTrack", False):
        raise ConversionError("instrument: banjo track is not a six-string guitar")
    if getattr(track, "isMute", False) or getattr(track, "isSolo", False):
        warnings.add("mixer_track_state: source mute/solo state is not applied to the independent library score")
    lyrics = getattr(song, "lyrics", None)
    if lyrics and lyrics.trackChoice == track.number and any(line.lyrics for line in lyrics.lines):
        warnings.add("lyrics: source has a separate lyric block; automatic syllable alignment is not implemented")
    raw = _raw_part(track, part)
    capacity = 3840 * part["meter"][0] // part["meter"][1]
    # Find following written notes within the same source voice and string.
    next_notes = {}
    for voice_index in range(2):
        future = {}
        for measure_index in range(len(raw) - 1, -1, -1):
            measure = raw[measure_index]
            for event in reversed(measure["voices"][voice_index]):
                beat = event["beat"]
                absolute_start = measure_index * capacity + event["start"]
                for note in beat.notes:
                    key = (measure["occurrence"], voice_index, event["beat_index"], note.string)
                    candidate = future.get(note.string)
                    if candidate is not None and candidate[1] == absolute_start + event["duration"]:
                        next_notes[key] = candidate[0]
                    else:
                        next_notes[key] = None
                        if candidate is not None and (note.effect.hammer or note.effect.slides):
                            warnings.add("effect_connection_gap: hammer/pull/slide target is separated by intervening beats or a rest; basic source notes retained")
                for note in beat.notes:
                    future[note.string] = (note, absolute_start)
    measures = []
    previous_notes = [{}, {}]
    containers = {}
    for output_index, raw_measure in enumerate(raw):
        occurrence = raw_measure["occurrence"]
        source_index = raw_measure["source_index"]
        identities = (source_key, track.number, part_number, occurrence)
        output = {"id": _uid(*identities, "measure"), "voices": []}
        for voice_index, voice_name in enumerate(("melody", "bass")):
            events = []
            containers[(voice_index, output_index)] = events
            preceding_end = 0
            for event in raw_measure["voices"][voice_index]:
                beat = event["beat"]
                start = event["start"]
                duration = _integer(event["duration"], "duration")
                if start < preceding_end:
                    raise ConversionError(f"overlap: source measure {source_index + 1}, voice {voice_index + 1} has overlapping beats")
                if start < 0 or start + duration > capacity:
                    raise ConversionError(f"capacity: source measure {source_index + 1}, voice {voice_index + 1}, tick {start}+{duration} exceeds {capacity}")
                preceding_end = start + duration
                _beat_warnings(beat, warnings)
                fragments = split_duration(duration)
                if len(fragments) > 1:
                    warnings.add("rhythm_split: unsupported duration symbol represented by exact tied supported durations")
                if len({note.string for note in beat.notes}) != len(beat.notes):
                    raise ConversionError(f"notes: duplicate string within a source chord at measure {source_index + 1}")
                if _name(beat.status) == "rest" and beat.notes:
                    raise ConversionError(f"structure: rest beat contains notes at measure {source_index + 1}")
                templates = []
                for note in beat.notes:
                    if _name(note.type) not in ("normal", "tie", "dead"):
                        raise ConversionError(f"note_type: unsupported {_name(note.type)} at measure {source_index + 1}")
                    string, fret = int(note.string), int(note.value)
                    if not 1 <= string <= 6 or not 0 <= fret <= 24:
                        raise ConversionError(f"note_range: string {string}, fret {fret} at measure {source_index + 1} is outside Guitarget range")
                    if not 0 <= tuning[string - 1] + fret <= 127:
                        raise ConversionError(f"note_pitch: MIDI pitch outside 0..127 at measure {source_index + 1}")
                    if not 0 <= note.velocity <= 127:
                        raise ConversionError(f"velocity: {note.velocity} is outside 0..127")
                    key = (occurrence, voice_index, event["beat_index"], string)
                    technique, target = _technique(note, beat, next_notes[key], warnings)
                    is_tie = _name(note.type) == "tie"
                    if is_tie:
                        previous = previous_notes[voice_index].get(string)
                        absolute_start = output_index * capacity + start
                        if previous is None or previous["end"] > absolute_start or previous["note"]["fret"] != fret:
                            raise ConversionError(f"tie: no adjacent same-voice/string/fret origin within part at source measure {source_index + 1}, string {string}")
                        if previous["note"]["technique"] == "deadNote":
                            raise ConversionError("tie: a dead note cannot sustain into a continuation")
                        if previous["end"] < absolute_start:
                            warnings.add("tie_bridge: sustained notes made explicit through intervening chords/rests or empty gaps")
                        _bridge_tie(previous, absolute_start, containers, voice_index, capacity, source_key, track.number, part_number)
                        if technique != "none":
                            warnings.add("effect_tied_continuation: continuation techniques omitted so tied note does not retrigger")
                        technique, target = "none", None
                    if technique == "deadNote" and len(fragments) > 1:
                        raise ConversionError("rhythm: a dead note cannot use tied duration fragments")
                    if target is not None and tuning[string - 1] + target > 127:
                        raise ConversionError("effect_target: target pitch is outside MIDI 0..127")
                    if technique in ("bendHalf", "bendFull") and tuning[string - 1] + fret + (1 if technique == "bendHalf" else 2) > 127:
                        raise ConversionError("bend_pitch: bent pitch is outside MIDI 0..127")
                    templates.append({"string": string, "fret": fret, "velocity": note.velocity / 127.0,
                                      "technique": technique, "targetFret": target, "tieToNext": False})
                fragment_start = start
                for fragment_index, (length, value, dotted, triplet) in enumerate(fragments):
                    event_key = (*identities, voice_index, event["beat_index"], fragment_index)
                    notes = []
                    for template in templates:
                        mapped_note = dict(template)
                        mapped_note["id"] = _uid(*event_key, "note", template["string"])
                        mapped_note["tieToNext"] = fragment_index < len(fragments) - 1
                        if fragment_index:
                            mapped_note["technique"] = "none"
                            mapped_note["targetFret"] = None
                        if mapped_note["targetFret"] is None:
                            del mapped_note["targetFret"]
                        notes.append(mapped_note)
                        previous_notes[voice_index][mapped_note["string"]] = {
                            "note": mapped_note, "end": output_index * capacity + fragment_start + length}
                    events.append({"id": _uid(*event_key, "event"), "startTick": fragment_start,
                                   "rhythm": {"value": value, "dotted": dotted, "triplet": triplet}, "notes": notes})
                    fragment_start += length
            output["voices"].append({"voice": voice_name, "events": events})
        measures.append(output)
    _validate_voice_strings(measures, [measure["source_index"] for measure in raw])
    title = str(song.title or source_key.rsplit("/", 1)[-1]).strip()
    return {"version": 1, "title": f"{title} — {track.name} — part {part_number}",
            "tuning": tuning, "timeSignature": {"numerator": part["meter"][0], "denominator": part["meter"][1]},
            "bpm": part["bpm"], "measures": measures}


def convert_song(song, source_key: str) -> list[dict]:
    """Return {track_number,track_name,part,score,warnings,error} records.

    Skipped tracks use part=0. A conversion error affects only its part, except
    unsupported global navigation, malformed global timing, or invalid tuning.
    Error/warning strings are explanatory and suitable for a JSONL audit report.
    """
    global_error = None
    global_warnings = set()
    try:
        if not song.measureHeaders:
            raise ConversionError("structure: source has no measures")
        order = playback_order(song.measureHeaders)
        if order != list(range(len(song.measureHeaders))):
            global_warnings.add("repeat_expanded: repeat bars and alternate endings expanded to playback order")
        if any(h.isRepeatOpen for h in song.measureHeaders) and not any(h.repeatClose >= 0 for h in song.measureHeaders):
            global_warnings.add("repeat_unclosed: opening repeat without closing repeat has no playback jump")
        parts = _parts(song, order)
        if len(parts) > 1:
            global_warnings.add("score_split: source split into consecutive constant-meter/tempo parts; part boundaries are separate documents")
    except (ConversionError, ValueError, TypeError, OverflowError, ZeroDivisionError) as exc:
        global_error = str(exc)
        parts = []
    results = []
    for track in song.tracks:
        base = {"track_number": int(track.number), "track_name": str(track.name)}
        skip = None
        if track.isPercussionTrack:
            skip = "skipped_percussion: percussion tracks are not guitar scores"
        elif len(track.strings) != 6:
            skip = f"skipped_string_count: track has {len(track.strings)} strings; Guitarget requires six"
        elif not 24 <= track.channel.instrument <= 31:
            skip = f"skipped_instrument: GM program {track.channel.instrument} is not guitar (24..31)"
        if skip or global_error:
            results.append({**base, "part": 0, "score": None, "warnings": sorted(global_warnings), "error": skip or global_error, "source_measures": []})
            continue
        for part_number, part in enumerate(parts, 1):
            warnings = set(global_warnings)
            score, error = None, None
            try:
                if part["errors"]:
                    raise ConversionError("; ".join(part["errors"]))
                score = _map_part(song, track, part, source_key, part_number, warnings)
            except (ConversionError, ValueError, TypeError, OverflowError, ZeroDivisionError) as exc:
                error = str(exc)
            results.append({**base, "part": part_number, "score": score, "warnings": sorted(warnings), "error": error,
                            "source_measures": [index + 1 for _, index in part["occurrences"]]})
    if not results:
        results.append({"track_number": 0, "track_name": "", "part": 0, "score": None, "warnings": [],
                        "error": global_error or "skipped_no_tracks: source has no tracks", "source_measures": []})
    return results

"""Focused musical mapping tests, using actual PyGuitarPro model objects."""
import copy
from fractions import Fraction
import importlib.util
from pathlib import Path
import unittest
import guitarpro.models as gp

spec = importlib.util.spec_from_file_location("converter_mapping", Path(__file__).parents[1] / "mapping.py")
mapping = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mapping)


def song_with_measures(count=1):
    song = gp.Song()
    song.title = "Mapping test"
    song.tempo = 120
    song.measureHeaders = []
    for i in range(count):
        song.measureHeaders.append(gp.MeasureHeader(number=i + 1, start=960 + 3840 * i))
    song.tracks = [gp.Track(song)]
    song.tracks[0].channel.instrument = 24
    return song


def beat(song, measure=0, voice=0, start=0, value=4, notes=((1, 3),), dotted=False, tuplet=(1, 1), tie=False):
    track = song.tracks[0]
    v = track.measures[measure].voices[voice]
    b = gp.Beat(v, start=track.measures[measure].start + start,
                status=gp.BeatStatus.normal if notes else gp.BeatStatus.rest,
                duration=gp.Duration(value=value, isDotted=dotted, tuplet=gp.Tuplet(*tuplet)))
    for string, fret in notes:
        b.notes.append(gp.Note(b, string=string, value=fret, velocity=95,
                               type=gp.NoteType.tie if tie else gp.NoteType.normal))
    v.beats.append(b)
    return b


def first_result(song):
    return mapping.convert_song(song, "fixture/test.gp5")[0]


def output_notes(result):
    return [n for m in result["score"]["measures"] for v in m["voices"] for e in v["events"] for n in e["notes"]]


class MappingTests(unittest.TestCase):
    def test_notes_chords_rests_voices_velocity_and_capo(self):
        song = song_with_measures()
        song.tracks[0].offset = 2
        beat(song, notes=((1, 3), (2, 1)))
        beat(song, start=960, value=2, notes=())
        beat(song, voice=1, value=1, notes=((6, 0),))
        result = first_result(song)
        self.assertIsNone(result["error"])
        score = result["score"]
        self.assertEqual(score["tuning"], [66, 61, 57, 52, 47, 42])
        self.assertEqual(score["measures"][0]["voices"][0]["events"][1]["notes"], [])
        self.assertEqual([(n["string"], n["fret"]) for n in output_notes(result)], [(1, 3), (2, 1), (6, 0)])
        self.assertEqual(output_notes(result)[0]["velocity"], 95 / 127)

    def test_ids_are_repeatable_unique_and_source_is_unchanged(self):
        song = song_with_measures(2)
        beat(song, value=4, tuplet=(3, 2))
        beat(song, measure=1)
        before = copy.deepcopy(song)
        one, two = first_result(song), first_result(song)
        self.assertEqual(one, two)
        self.assertEqual(song, before)
        ids = []
        for m in one["score"]["measures"]:
            ids.append(m["id"])
            for v in m["voices"]:
                for e in v["events"]:
                    ids.append(e["id"])
                    ids.extend(n["id"] for n in e["notes"])
        self.assertEqual(len(ids), len(set(ids)))

    def test_quarter_triplet_splits_exactly_and_does_not_retrigger(self):
        song = song_with_measures()
        b = beat(song, value=4, tuplet=(3, 2))
        b.notes[0].effect.vibrato = True
        result = first_result(song)
        self.assertIsNone(result["error"])
        events = result["score"]["measures"][0]["voices"][0]["events"]
        self.assertEqual([e["startTick"] for e in events], [0, 320])
        self.assertTrue(all(e["rhythm"] == {"value": 8, "dotted": False, "triplet": True} for e in events))
        self.assertEqual([e["notes"][0]["technique"] for e in events], ["vibrato", "none"])
        self.assertEqual([e["notes"][0]["tieToNext"] for e in events], [True, False])

    def test_unrepresentable_short_tuplet_and_fraction_are_errors(self):
        for value, tuplet in [(16, (3, 2)), (8, (7, 4)), (64, (1, 1))]:
            song = song_with_measures()
            beat(song, value=value, tuplet=tuplet)
            result = first_result(song)
            self.assertIsNone(result["score"])
            self.assertIn("duration", result["error"])

    def test_tie_across_measure_links_origin_and_suppresses_continuation_effect(self):
        song = song_with_measures(2)
        beat(song, value=1)
        b = beat(song, measure=1, tie=True)
        b.notes[0].effect.palmMute = True
        result = first_result(song)
        self.assertIsNone(result["error"])
        notes = output_notes(result)
        self.assertEqual([n["tieToNext"] for n in notes], [True, False])
        self.assertEqual(notes[1]["technique"], "none")

    def test_orphan_tie_is_error(self):
        song = song_with_measures()
        beat(song, tie=True)
        result = first_result(song)
        self.assertIsNone(result["score"])
        self.assertIn("tie:", result["error"])

    def test_tie_spans_intervening_chords_and_explicit_rest(self):
        song = song_with_measures()
        beat(song, notes=((6, 0),))
        beat(song, start=960, notes=((1, 3),))
        beat(song, start=1920, notes=())
        beat(song, start=2880, notes=((6, 0),), tie=True)
        result = first_result(song)
        self.assertIsNone(result["error"])
        events = result["score"]["measures"][0]["voices"][0]["events"]
        low_notes = [next(n for n in e["notes"] if n["string"] == 6) for e in events]
        self.assertEqual([n["tieToNext"] for n in low_notes], [True, True, True, False])
        self.assertEqual([n["technique"] for n in low_notes], ["none"] * 4)
        self.assertEqual(len(events[1]["notes"]), 2)

    def test_tie_fills_implicit_gap_across_measure(self):
        song = song_with_measures(2)
        beat(song, notes=((6, 0),))
        beat(song, measure=1, start=960, notes=((6, 0),), tie=True)
        result = first_result(song)
        self.assertIsNone(result["error"])
        events = [e for m in result["score"]["measures"] for e in m["voices"][0]["events"]]
        self.assertEqual(sum(mapping._event_ticks(e) for e in events), 5760)
        self.assertTrue(all(e["notes"][0]["tieToNext"] for e in events[:-1]))

    def test_tie_bridge_cannot_cross_other_voice_on_same_string(self):
        song = song_with_measures(2)
        beat(song, notes=((6, 0),))
        beat(song, voice=1, start=960, notes=((6, 5),))
        beat(song, measure=1, notes=((6, 0),), tie=True)
        self.assertIn("voice_conflict", first_result(song)["error"])

    def test_repeat_and_alternate_endings_expand_in_playback_order(self):
        song = song_with_measures(4)
        h = song.measureHeaders
        h[0].isRepeatOpen = True
        h[1].repeatAlternative = 1
        h[2].repeatClose = 1
        h[3].repeatAlternative = 2
        for i in range(4):
            beat(song, measure=i, notes=((1, i),))
        self.assertEqual(mapping.playback_order(h), [0, 1, 2, 0, 3])
        result = first_result(song)
        self.assertIsNone(result["error"])
        self.assertEqual([n["fret"] for n in output_notes(result)], [0, 1, 2, 0, 3])
        self.assertEqual(len({m["id"] for m in result["score"]["measures"]}), 5)

    def test_plain_and_implicit_repeats(self):
        song = song_with_measures(4)
        song.measureHeaders[1].repeatClose = 1
        song.measureHeaders[3].repeatClose = 2
        self.assertEqual(mapping.playback_order(song.measureHeaders), [0, 1, 0, 1, 2, 3, 2, 3, 2, 3])

    def test_repeat_to_first_measure_replays_initial_song_tempo(self):
        song = song_with_measures(2)
        song.tempo = 80
        song.measureHeaders[1].repeatClose = 1
        beat(song)
        second = beat(song, measure=1)
        second.effect.mixTableChange = gp.MixTableChange(tempo=gp.MixTableItem(120))
        results = mapping.convert_song(song, "repeat-tempo.gp5")
        self.assertEqual([r["score"]["bpm"] for r in results], [80, 120, 80, 120])
        self.assertEqual([r["source_measures"] for r in results], [[1], [2], [1], [2]])

    def test_repeat_to_middle_without_tempo_keeps_playback_tempo(self):
        song = song_with_measures(3)
        song.tempo = 80
        song.measureHeaders[1].isRepeatOpen = True
        song.measureHeaders[2].repeatClose = 1
        for i in range(3):
            beat(song, measure=i)
        last = song.tracks[0].measures[2].voices[0].beats[0]
        last.effect.mixTableChange = gp.MixTableChange(tempo=gp.MixTableItem(120))
        results = mapping.convert_song(song, "middle-repeat-tempo.gp5")
        self.assertEqual([r["score"]["bpm"] for r in results], [80, 120])
        self.assertEqual([r["source_measures"] for r in results], [[1, 2], [3, 2, 3]])

    def test_unsupported_navigation_rejected(self):
        song = song_with_measures()
        song.measureHeaders[0].fromDirection = gp.DirectionSign("Da Capo")
        self.assertIn("navigation:", first_result(song)["error"])

    def test_meter_and_tempo_changes_split_without_retiming(self):
        song = song_with_measures(3)
        song.measureHeaders[1].timeSignature = gp.TimeSignature(numerator=3, denominator=gp.Duration(value=4))
        song.measureHeaders[2].timeSignature = gp.TimeSignature(numerator=3, denominator=gp.Duration(value=4))
        for i in range(3):
            beat(song, measure=i)
        b = song.tracks[0].measures[2].voices[0].beats[0]
        b.effect.mixTableChange = gp.MixTableChange(tempo=gp.MixTableItem(140))
        results = mapping.convert_song(song, "meter-tempo.gp5")
        self.assertEqual([r["part"] for r in results], [1, 2, 3])
        self.assertTrue(all(r["error"] is None for r in results))
        self.assertEqual([r["score"]["bpm"] for r in results], [120, 120, 140])
        self.assertEqual([r["score"]["timeSignature"]["numerator"] for r in results], [4, 3, 3])

    def test_mid_measure_tempo_isolated_and_subsequent_music_kept(self):
        song = song_with_measures(3)
        for i in range(3):
            beat(song, measure=i)
        b = beat(song, measure=1, start=960)
        b.effect.mixTableChange = gp.MixTableChange(tempo=gp.MixTableItem(150))
        results = mapping.convert_song(song, "tempo.gp5")
        self.assertEqual(len(results), 3)
        self.assertIsNone(results[0]["error"])
        self.assertIn("inside the measure", results[1]["error"])
        self.assertIsNone(results[2]["error"])
        self.assertEqual(results[2]["score"]["bpm"], 150)

    def test_tempo_ramp_rejects_all_overlapping_measures(self):
        song = song_with_measures(4)
        b = beat(song)
        b.effect.mixTableChange = gp.MixTableChange(tempo=gp.MixTableItem(150, duration=9))
        results = mapping.convert_song(song, "ramp.gp5")
        self.assertEqual(len(results), 4)
        self.assertTrue(all(r["score"] is None for r in results[:3]))
        self.assertIsNone(results[3]["error"])
        self.assertEqual([r["source_measures"] for r in results], [[1], [2], [3], [4]])

    def test_bad_meter_does_not_reject_neighbors(self):
        song = song_with_measures(3)
        song.measureHeaders[1].timeSignature.numerator = 5
        results = mapping.convert_song(song, "meter.gp5")
        self.assertEqual(len(results), 3)
        self.assertIsNone(results[0]["error"])
        self.assertIn("unsupported 5/4", results[1]["error"])
        self.assertIsNone(results[2]["error"])

    def test_cross_voice_same_string_is_not_silently_merged(self):
        song = song_with_measures()
        beat(song, value=2)
        beat(song, voice=1, start=960, notes=((1, 7),))
        result = first_result(song)
        self.assertIsNone(result["score"])
        self.assertIn("voice_conflict", result["error"])

    def test_fret_out_of_range_is_not_clamped(self):
        song = song_with_measures()
        beat(song, notes=((1, 25),))
        self.assertIn("note_range", first_result(song)["error"])

    def test_non_guitar_and_percussion_tracks_have_explicit_skip_records(self):
        song = song_with_measures()
        song.tracks[0].channel.instrument = 0
        self.assertIn("skipped_instrument", first_result(song)["error"])
        song.tracks[0].isPercussionTrack = True
        self.assertIn("skipped_percussion", first_result(song)["error"])
        song.tracks[0].isPercussionTrack = False
        song.tracks[0].strings = song.tracks[0].strings[:4]
        self.assertIn("skipped_string_count", first_result(song)["error"])

    def test_hammer_and_pull_targets_and_combination_warning(self):
        song = song_with_measures()
        first = beat(song, notes=((1, 3),))
        second = beat(song, start=960, notes=((1, 5),))
        beat(song, start=1920, notes=((1, 2),))
        first.notes[0].effect.hammer = True
        first.notes[0].effect.vibrato = True
        second.notes[0].effect.hammer = True
        result = first_result(song)
        notes = output_notes(result)
        self.assertEqual([(n["technique"], n.get("targetFret")) for n in notes[:2]], [("hammerOn", 5), ("pullOff", 2)])
        self.assertTrue(any("effect_combination" in w for w in result["warnings"]))
        self.assertTrue(any("effect_connection_timing" in w for w in result["warnings"]))

    def test_hammer_does_not_cross_a_rest_without_notice(self):
        song = song_with_measures()
        first = beat(song, notes=((1, 3),))
        beat(song, start=960, notes=())
        beat(song, start=1920, notes=((1, 5),))
        first.notes[0].effect.hammer = True
        result = first_result(song)
        self.assertEqual(output_notes(result)[0]["technique"], "none")
        self.assertTrue(any("effect_connection_gap" in warning for warning in result["warnings"]))

    def test_bend_units_are_quarter_tones(self):
        song = song_with_measures()
        for index, peak in enumerate((2, 4, 1)):
            b = beat(song, start=index * 960)
            b.notes[0].effect.bend = gp.BendEffect(points=[gp.BendPoint(0, 0), gp.BendPoint(12, peak)])
        result = first_result(song)
        self.assertEqual([n["technique"] for n in output_notes(result)], ["bendHalf", "bendFull", "none"])
        self.assertTrue(any("effect_bend_range" in warning for warning in result["warnings"]))
        self.assertTrue(any("effect_bend_timing" in warning for warning in result["warnings"]))

    def test_exact_duration_decomposition_never_changes_ticks(self):
        for ticks in [120, 180, 240, 320, 360, 480, 640, 720, 960, 1280, 1440, 1920, 2560, 2880, 3840, 5760]:
            fragments = mapping.split_duration(ticks)
            self.assertEqual(sum(fragment[0] for fragment in fragments), ticks)
        with self.assertRaises(mapping.ConversionError):
            mapping.split_duration(Fraction(1920, 7))


if __name__ == "__main__":
    unittest.main()

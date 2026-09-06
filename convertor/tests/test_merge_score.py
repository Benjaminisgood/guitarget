"""Pure strict-merge coverage: time alignment, fidelity and explicit conflicts."""
import copy
from pathlib import Path
import sys
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from merge_score import ScoreMergeError, merge_version


def note(string=1, fret=0, **changes):
    return {"id": "shared-input-id", "string": string, "fret": fret, "velocity": 0.75,
            "technique": "none", "tieToNext": False, **changes}


def event(start=0, value=4, notes=None, **changes):
    return {"id": "shared-input-id", "startTick": start,
            "rhythm": {"value": value, "dotted": False, "triplet": False},
            "notes": notes if notes is not None else [note()], **changes}


def entry(track=1, part=1, events=None, bass=None, source_measures=None, **score_changes):
    melody = [event()] if events is None else events
    return {"source": "Artist/Song.gp5", "track_number": track, "track_name": "Guitar", "part": part,
            "source_measures": [part] if source_measures is None else source_measures,
            "score": {"version": 1, "title": f"Track {track}", "tuning": [64, 59, 55, 50, 45, 40],
                      "bpm": 80, "timeSignature": {"numerator": 4, "denominator": 4},
                      "measures": [{"id": "shared-input-id", "voices": [
                          {"voice": "melody", "events": melody}, {"voice": "bass", "events": bass or []}]}],
                      **score_changes}}


def all_events(score):
    return [event for measure in score["measures"] for voice in measure["voices"] for event in voice["events"]]


class StrictMergeTests(unittest.TestCase):
    def assert_reason(self, reason, entries):
        with self.assertRaises(ScoreMergeError) as caught:
            merge_version("Song", entries)
        self.assertEqual(caught.exception.reason, reason)
        self.assertEqual(caught.exception.as_dict()["status"], "strict_merge_failed")
        return caught.exception

    def test_simultaneous_tracks_become_one_chord_without_changing_notes(self):
        entries = [entry(1, events=[event(notes=[note(1, 3)])]), entry(2, events=[event(notes=[note(6, 5)])])]
        before = copy.deepcopy(entries)
        score, report = merge_version("One Version", entries)
        self.assertEqual(set(score), {"version", "title", "tuning", "bpm", "timeSignature", "measures"})
        self.assertEqual(len(all_events(score)), 1)
        self.assertEqual([n["string"] for n in all_events(score)[0]["notes"]], [1, 6])
        self.assertEqual(report["output_notes"], 2)
        self.assertEqual(entries, before)

    def test_identical_notes_deduplicate_and_optional_null_is_equivalent(self):
        score, report = merge_version("Song", [entry(1), entry(2, events=[event(notes=[note(targetFret=None)])])])
        self.assertEqual(len(all_events(score)[0]["notes"]), 1)
        self.assertEqual(report["deduplicated_notes"], 1)

    def test_part_numbers_concatenate_in_order_and_tracks_align_within_part(self):
        entries = [entry(2, 2, events=[event(notes=[note(6, 5)])]), entry(1, 1),
                   entry(1, 2, events=[event(notes=[note(1, 7)])])]
        score, report = merge_version("Song", entries)
        self.assertEqual(len(score["measures"]), 2)
        self.assertEqual(report["parts"], [1, 2])
        self.assertEqual(report["gaps"], [{"kind": "missing_tracks", "part": 1, "track_numbers": [2]}])
        self.assertEqual([n["fret"] for n in all_events({"measures": [score["measures"][1]]})[0]["notes"]], [7, 5])

    def test_missing_part_range_is_reported_without_inventing_measures(self):
        score, report = merge_version("Song", [entry(part=1), entry(part=3)])
        self.assertEqual(len(score["measures"]), 2)
        self.assertIn({"kind": "missing_parts", "first_part": 2, "last_part": 2}, report["gaps"])

    def test_metadata_changes_are_refused_even_between_adjacent_parts(self):
        for reason, changes in [("tempo_mismatch", {"bpm": 81}),
                                ("meter_mismatch", {"timeSignature": {"numerator": 3, "denominator": 4}}),
                                ("tuning_mismatch", {"tuning": [64, 59, 55, 50, 45, 38]})]:
            with self.subTest(reason=reason):
                error = self.assert_reason(reason, [entry(), entry(part=2, **changes)])
                self.assertEqual(error.location["part"], 2)

    def test_version_and_alignment_mismatches_are_explicit(self):
        other = entry(2)
        other["source"] = "Other.gp4"
        self.assert_reason("multiple_versions", [entry(), other])
        self.assert_reason("measure_alignment_mismatch", [entry(), entry(2, source_measures=[8])])
        self.assert_reason("duplicate_part", [entry(), entry()])

    def test_velocity_technique_and_fret_conflicts_are_located(self):
        for reason, changes in [("note_expression_conflict", {"velocity": 0.4}),
                                ("note_expression_conflict", {"technique": "vibrato"}),
                                ("same_string_conflict", {"fret": 3})]:
            with self.subTest(changes=changes):
                error = self.assert_reason(reason, [entry(), entry(2, events=[event(notes=[note(**changes)])])])
                self.assertEqual(error.location["track_number"], 2)
                self.assertEqual(error.location["source_measure"], 1)

    def test_distinct_starts_share_a_voice_when_not_overlapping(self):
        score, _ = merge_version("Song", [entry(), entry(2, events=[event(960, notes=[note(2)])])])
        voices = score["measures"][0]["voices"]
        self.assertEqual([e["startTick"] for e in voices[0]["events"]], [0, 960])
        self.assertEqual(voices[1]["events"], [])

    def test_overlapping_intervals_use_two_voices_and_preserve_durations(self):
        score, _ = merge_version("Song", [entry(events=[event(0, 2)]), entry(2, events=[event(960, 4, [note(2)])])])
        voices = score["measures"][0]["voices"]
        self.assertEqual([len(v["events"]) for v in voices], [1, 1])
        self.assertEqual([v["events"][0]["rhythm"]["value"] for v in voices], [2, 4])

    def test_overlapping_same_string_and_more_than_two_intervals_are_refused(self):
        self.assert_reason("same_string_conflict", [entry(events=[event(0, 2)]), entry(2, events=[event(960, 4, [note(1, 2)])])])
        self.assert_reason("same_string_timing_conflict", [entry(events=[event(0, 2)]), entry(2, events=[event(960)])])
        self.assert_reason("voice_capacity_exceeded", [entry(events=[event(0, 1)]),
            entry(2, events=[event(0, 2, [note(2)])]), entry(3, events=[event(960, 4, [note(3)])])])

    def test_ties_stay_in_the_same_voice_across_bars(self):
        first = entry(1, 1, events=[event(2880, notes=[note(tieToNext=True)])])
        second = entry(1, 2)
        accompaniment = entry(2, 2, events=[event(0, 2, [note(6)])])
        score, _ = merge_version("Song", [first, second, accompaniment])
        tied_voice = next(v["voice"] for v in score["measures"][0]["voices"] if v["events"])
        continuation = next(v for v in score["measures"][1]["voices"] if v["voice"] == tied_voice)
        self.assertEqual(continuation["events"][0]["notes"][0]["string"], 1)
        self.assertTrue(all_events(score)[0]["notes"][0]["tieToNext"])

    def test_missing_tie_continuation_and_conflicting_lyrics_are_refused(self):
        self.assert_reason("tie_target_missing", [entry(events=[event(notes=[note(tieToNext=True)])])])
        self.assert_reason("lyric_conflict", [entry(events=[event(lyric="one")]),
            entry(2, events=[event(notes=[note(2)], lyric="two")])])

    def test_rest_and_lyric_events_are_retained(self):
        score, _ = merge_version("Song", [entry(events=[event(notes=[], lyric="pause")]),
            entry(2, events=[event(960, notes=[note(2)], lyric="sing")])])
        self.assertEqual([(e["lyric"], len(e["notes"])) for e in all_events(score)], [("pause", 0), ("sing", 1)])

    def test_ids_are_valid_unique_and_deterministic_despite_colliding_source_ids(self):
        entries = [entry(1, 1), entry(2, 1, events=[event(notes=[note(6)])]), entry(1, 2)]
        score, _ = merge_version("Song", entries)
        again, _ = merge_version("Song", list(reversed(entries)))
        self.assertEqual(score, again)
        identities = [measure["id"] for measure in score["measures"]]
        for e in all_events(score):
            identities += [e["id"], *[n["id"] for n in e["notes"]]]
        self.assertEqual(len(identities), len(set(identities)))
        for identifier in identities:
            uuid.UUID(identifier)

    def test_unknown_score_fields_are_rejected_instead_of_lost(self):
        self.assert_reason("unsupported_fields", [entry(customMetadata="must not disappear")])

    def test_malformed_events_and_notes_produce_structured_failures(self):
        self.assert_reason("invalid_input", 3)
        self.assert_reason("invalid_input", [entry(version=True)])
        self.assert_reason("unsupported_fields", [entry(events=[None])])
        self.assert_reason("event_out_of_bounds", [entry(events=[event(), event(start="960")])])
        for changes in ({"technique": "unknown"}, {"technique": []}, {"targetFret": True}, {"targetFret": 25}):
            with self.subTest(changes=changes):
                self.assert_reason("invalid_note", [entry(events=[event(notes=[note(**changes)])])])


if __name__ == "__main__":
    unittest.main()

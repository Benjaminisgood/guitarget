"""Original primary-guitar selection: coverage, excerpts and note preservation."""
import copy
from pathlib import Path
import sys
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from main_guitar import MainGuitarSelectionError, select_main_guitar


def entry(track=1, part=1, *, name="Guitar", measures=2, chord_notes=1, bpm=80, silent=False):
    bars = []
    for index in range(measures):
        notes = [] if silent else [
            {"id": str(uuid.uuid4()), "string": string, "fret": part + 2,
             "velocity": 0.65, "technique": "none", "tieToNext": False}
            for string in range(1, chord_notes + 1)]
        bars.append({"id": str(uuid.uuid4()), "voices": [
            {"voice": "melody", "events": [{"id": str(uuid.uuid4()), "startTick": 0,
                "rhythm": {"value": 4, "dotted": False, "triplet": False},
                "notes": notes, "lyric": f"原歌词 {part}-{index}"}]},
            {"voice": "bass", "events": []}]})
    return {"source": "Artist/Original.gp5", "track_number": track, "track_name": name,
            "part": part, "source_measures": list(range((part - 1) * measures + 1, part * measures + 1)),
            "score": {"version": 1, "title": f"Original track {track} part {part}",
                      "tuning": [64, 59, 55, 50, 45, 40], "bpm": bpm,
                      "timeSignature": {"numerator": 4, "denominator": 4}, "measures": bars}}


def first_event(item):
    return item["score"]["measures"][0]["voices"][0]["events"][0]


class MainGuitarTests(unittest.TestCase):
    def test_primary_labels_win_equal_coverage_before_note_count(self):
        for name in ("Main Guitar", "Lead Guitar", "主吉他", "主音吉他"):
            with self.subTest(name=name):
                _, report = select_main_guitar("Song", [entry(1, chord_notes=4), entry(2, name=name)])
                self.assertEqual(report["selected_track"], 2)
                self.assertEqual(report["selected_track_name"], name)
                self.assertEqual(report["omitted_tracks"][0]["track_number"], 1)
                self.assertTrue(report["warnings"])

    def test_short_lead_solo_does_not_displace_complete_track(self):
        score, report = select_main_guitar("Song", [entry(1, name="Lead Solo", measures=1),
                                                    entry(2, name="Guitar", measures=16)])
        self.assertEqual(report["selected_track"], 2)
        self.assertEqual(len(score["measures"]), 16)

    def test_unlabelled_ranking_uses_sounding_coverage_then_note_count(self):
        _, report = select_main_guitar("Song", [entry(1, measures=3), entry(2, measures=2, chord_notes=6)])
        self.assertEqual(report["selected_track"], 1)
        _, report = select_main_guitar("Song", [entry(1), entry(2, chord_notes=2)])
        self.assertEqual(report["selected_track"], 2)
        _, report = select_main_guitar("Song", [entry(2), entry(1)])
        self.assertEqual(report["selected_track"], 1)

    def test_same_track_parts_concatenate_in_order_without_changing_fields(self):
        entries = [entry(3, 3), entry(3, 1), entry(3, 2)]
        before = copy.deepcopy(entries)
        score, report = select_main_guitar("One Song", entries)
        expected = copy.deepcopy(entries[1]["score"])
        expected["title"] = "One Song"
        expected["measures"] = [measure for item in sorted(entries, key=lambda item: item["part"])
                                for measure in item["score"]["measures"]]
        self.assertEqual(score, expected)
        self.assertEqual(entries, before)
        self.assertEqual(report["kept_parts"], [1, 2, 3])
        self.assertEqual(report["scope"], "full_primary_track")
        self.assertEqual(report["voice_reassignments"], 0)
        self.assertEqual(report["id_reassignments"], 0)

    def test_original_two_voices_are_not_combined_into_a_chord(self):
        item = entry(measures=1)
        bass = copy.deepcopy(first_event(item))
        bass["id"] = str(uuid.uuid4())
        bass["notes"][0].update(id=str(uuid.uuid4()), string=6)
        item["score"]["measures"][0]["voices"][1]["events"] = [bass]
        before = copy.deepcopy(item)
        score, report = select_main_guitar("Song", [item])
        expected = copy.deepcopy(item["score"])
        expected["title"] = "Song"
        self.assertEqual(score, expected)
        self.assertEqual(item, before)
        self.assertEqual(report["voice_reassignments"], 0)

    def test_tempo_changes_select_one_contiguous_run_without_joining_returns(self):
        entries = [entry(part=1, measures=2, bpm=80), entry(part=2, measures=3, bpm=120),
                   entry(part=3, measures=3, bpm=120), entry(part=4, measures=2, bpm=80)]
        before = copy.deepcopy(entries)
        score, report = select_main_guitar("Song", entries)
        self.assertEqual(report["kept_parts"], [2, 3])
        self.assertEqual(report["omitted_parts"], [1, 4])
        self.assertEqual(report["scope"], "primary_track_excerpt")
        self.assertEqual(score["bpm"], 120)
        self.assertEqual(score["measures"], entries[1]["score"]["measures"] + entries[2]["score"]["measures"])
        self.assertEqual(entries, before)
        self.assertTrue(report["warnings"])

    def test_excerpt_ranking_uses_original_duration_and_stable_ties(self):
        _, report = select_main_guitar("Song", [entry(part=1, measures=2, bpm=60),
                                                entry(part=2, measures=2, bpm=120)])
        self.assertEqual(report["kept_parts"], [1])
        # Equal original duration and note count: choose the earlier run.
        first, second = entry(part=1), entry(part=2)
        second["score"]["tuning"][-1] = 38
        _, report = select_main_guitar("Song", [second, first])
        self.assertEqual(report["kept_parts"], [1])

    def test_tuning_and_meter_changes_are_preserved_in_selected_excerpt(self):
        for parameter in ("tuning", "timeSignature"):
            with self.subTest(parameter=parameter):
                first, second = entry(part=1, measures=1), entry(part=2, measures=4)
                second["score"][parameter] = ([64, 59, 55, 50, 45, 38] if parameter == "tuning"
                                              else {"numerator": 3, "denominator": 4})
                score, report = select_main_guitar("Song", [first, second])
                self.assertEqual(report["kept_parts"], [2])
                self.assertEqual(score[parameter], second["score"][parameter])
                self.assertEqual(report["chosen_parameters"][parameter], score[parameter])

    def test_dangling_excerpt_ties_remain_set_and_are_reported(self):
        item = entry(measures=1)
        first_event(item)["notes"][0]["tieToNext"] = True
        expected = copy.deepcopy(item["score"])
        expected["title"] = "Song"
        score, report = select_main_guitar("Song", [item])
        self.assertEqual(score, expected)
        self.assertEqual(len(report["unresolved_ties"]), 1)
        self.assertTrue(any("tieToNext" in warning for warning in report["warnings"]))

    def test_incompatible_boundary_tie_falls_back_to_one_unchanged_part(self):
        first, second = entry(part=1, measures=1), entry(part=2, measures=1)
        left, right = first_event(first), first_event(second)
        left["startTick"] = 2880
        left["notes"][0]["tieToNext"] = True
        right["notes"][0].update(fret=left["notes"][0]["fret"], technique="vibrato")
        score, report = select_main_guitar("Song", [first, second])
        expected = copy.deepcopy(first["score"])
        expected["title"] = "Song"
        self.assertEqual(score, expected)
        self.assertEqual(report["kept_parts"], [1])
        self.assertEqual(report["scope"], "primary_track_excerpt")
        self.assertEqual(report["attempts"][0]["error"]["reason"], "tie_expression_conflict")

    def test_colliding_part_ids_are_repaired_without_changing_note_fields(self):
        first = entry(part=1, measures=1)
        second = copy.deepcopy(first)
        second.update(part=2, source_measures=[2])
        before = copy.deepcopy([first, second])
        score, report = select_main_guitar("Song", [first, second])
        self.assertEqual([first, second], before)
        identities = []
        for measure in score["measures"]:
            identities.append(measure["id"])
            for voice in measure["voices"]:
                for event in voice["events"]:
                    identities.append(event["id"])
                    identities.extend(note["id"] for note in event["notes"])
        self.assertEqual(len(identities), len({uuid.UUID(value) for value in identities}))
        self.assertEqual(report["id_reassignments"], 3)
        again, _ = select_main_guitar("Song", [second, first])
        self.assertEqual(score, again)
        notes = [measure["voices"][0]["events"][0]["notes"][0] for measure in score["measures"]]
        self.assertEqual([{key: value for key, value in note.items() if key != "id"} for note in notes],
                         [{key: value for key, value in first_event(first)["notes"][0].items() if key != "id"}] * 2)

    def test_all_silent_inputs_choose_longest_track_and_still_return_v1(self):
        score, report = select_main_guitar("Silent", [entry(1, name="Lead", measures=1, silent=True),
                                                     entry(2, measures=5, silent=True)])
        self.assertEqual(report["selected_track"], 2)
        self.assertEqual(len(score["measures"]), 5)
        self.assertEqual(score["version"], 1)

    def test_different_source_versions_and_duplicate_parts_are_rejected(self):
        other = entry(2)
        other["source"] = "Artist/Another.gp5"
        with self.assertRaises(MainGuitarSelectionError) as caught:
            select_main_guitar("Song", [entry(), other])
        self.assertEqual(caught.exception.reason, "multiple_versions")
        with self.assertRaises(MainGuitarSelectionError) as caught:
            select_main_guitar("Song", [entry(), entry()])
        self.assertEqual(caught.exception.reason, "duplicate_part")


if __name__ == "__main__":
    unittest.main()

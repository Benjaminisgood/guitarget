import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("song_identity", Path(__file__).parents[1] / "song_identity.py")
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)


def grouped(*sources):
    return list(identity.group_sources(list(sources)).values())


class SongIdentityTests(unittest.TestCase):
    def test_numeric_versions_need_an_unsuffixed_companion(self):
        missing = grouped("A/Artist/Artist - Song (2).gp3", "A/Artist/Artist - Song (3).gp4")
        self.assertEqual(len(missing), 2)
        paired = grouped("A/Artist/Artist - Song.gp5", "A/Artist/Artist - Song (2).gp3", "A/Artist/Artist - Song (3).gp4")
        self.assertEqual(len(paired), 1)
        self.assertEqual(paired[0]["title"], "Artist - Song")
        self.assertEqual(len(paired[0]["sources"]), 3)

    def test_explicit_versions_do_not_need_an_unsuffixed_companion(self):
        result = grouped("A/Artist/Artist - Song v2.gp3", "A/Artist/Artist - Song (ver. 3).gp4",
                         "A/Artist/Artist - Song - version 4.gp5", "A/Artist/Artist - Song [V5].gtp")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["title"], "Artist - Song")

    def test_year_live_acoustic_part_and_correct_are_preserved(self):
        names = ["Song", "Song (1994)", "Song (Live)", "Song (Acoustic)", "Song (Part 2)", "Song II", "Song (Correct)", "Song 2"]
        result = grouped(*(f"A/Artist/Artist - {name}.gp3" for name in names))
        self.assertEqual(len(result), len(names))

    def test_same_title_from_different_artists_stays_separate(self):
        result = grouped("A/Artist One/Artist One - Song.gp3", "A/Artist Two/Artist Two - Song.gp3")
        self.assertEqual(len(result), 2)

    def test_numeric_companion_must_be_same_artist(self):
        result = grouped("A/Artist One/Artist One - Song.gp3", "A/Artist Two/Artist Two - Song (2).gp3")
        self.assertIn("Artist Two - Song (2)", [group["title"] for group in result])

    def test_known_filename_artist_corrects_a_misplaced_source(self):
        result = grouped("A/Alice Cooper/Alice In Chains - Dam That River.gp3",
                         "A/Alice In Chains/Alice In Chains - Dam That River (2).gp4",
                         "A/Alice Cooper/Alice Cooper - Poison.gp3")
        self.assertEqual(len(result), 2)
        corrected = next(group for group in result if group["title"] == "Alice In Chains - Dam That River")
        self.assertEqual(len(corrected["sources"]), 2)

    def test_unknown_artist_prefix_is_retained_with_directory_artist(self):
        result = grouped("E/Exercises/Chapter One - Alternate Picking.gp3")
        self.assertEqual(result[0]["title"], "Exercises - Chapter One - Alternate Picking")

    def test_unicode_canonical_equivalence_case_and_spaces(self):
        result = grouped("B/Beyoncé/Beyoncé - Halo.gp3", "B/Beyonce\u0301/beyonce\u0301 -  HALO  (2).gp4")
        self.assertEqual(len(result), 1)
        self.assertEqual(len(result[0]["sources"]), 2)

    def test_accents_and_punctuation_are_not_removed(self):
        result = grouped("A/Mago/Mago - Song.gp3", "A/Mägo/Mägo - Song.gp3", "A/Mago/Mago - Song!.gp3")
        self.assertEqual(len(result), 3)

    def test_extensions_and_version_order_are_handled(self):
        result = grouped("A/Artist/Artist - Song.gp3.gp3", "A/Artist/Artist - Song (2) (ver 3).gp4")
        self.assertEqual(len(result), 1)
        self.assertEqual(len(result[0]["sources"]), 2)

    def test_deterministic_keys_titles_members_and_no_input_mutation(self):
        paths = ["A/Artist/Artist - Song (2).gp3", "A/Artist/Artist - Song.gp4", "B/Band/Band - Other.gp3"]
        original = list(paths)
        first = identity.group_sources(paths)
        second = identity.group_sources(list(reversed(paths)))
        self.assertEqual(first, second)
        self.assertEqual(paths, original)
        self.assertTrue(all(len(key) == 64 for key in first))

    def test_distinct_source_versions_are_all_retained(self):
        result = grouped("A/Artist/Artist - Song.gp3", "A/Artist/Artist - Song.gp4", "A/Artist/Artist - Song.gp5")
        self.assertEqual(len(result), 1)
        self.assertEqual(len(result[0]["sources"]), 3)

    def test_empty_batch_and_invalid_source(self):
        self.assertEqual(identity.group_sources([]), {})
        with self.assertRaises(ValueError):
            identity.group_sources([""])
        with self.assertRaises(ValueError):
            identity.group_sources(["Song.gp3"])


if __name__ == "__main__":
    unittest.main()

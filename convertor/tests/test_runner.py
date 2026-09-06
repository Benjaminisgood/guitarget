"""Publication, process, and failure-isolation tests independent of GP score mapping."""
from __future__ import annotations

import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
mapping_stub = types.ModuleType("mapping")
mapping_stub.convert_song = mock.Mock(side_effect=AssertionError("Unexpected mapping call"))
merge_stub = types.ModuleType("merge_score")
merge_stub.merge_version = mock.Mock(side_effect=AssertionError("Unexpected strict merge call"))
selection_stub = types.ModuleType("main_guitar")
selection_stub.select_main_guitar = mock.Mock(side_effect=AssertionError("Unexpected primary-guitar selection call"))
spec = importlib.util.spec_from_file_location("guitarget_convert_runner", ROOT / "convert.py")
runner = importlib.util.module_from_spec(spec)
with mock.patch.dict(sys.modules, {"mapping": mapping_stub, "merge_score": merge_stub, "main_guitar": selection_stub}), \
     mock.patch.object(sys, "path", [str(ROOT), *sys.path]):
    spec.loader.exec_module(runner)

review_spec = importlib.util.spec_from_file_location("guitarget_review_report", ROOT / "review_report.py")
review_report = importlib.util.module_from_spec(review_spec)
review_spec.loader.exec_module(review_report)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="guitarget runner 空格 ")
        self.directory = Path(self.temporary.name)
        self.score = json.loads((ROOT.parent / "Examples/Fingerstyle.guitarget").read_text())
        self.original_handler = signal.getsignal(signal.SIGALRM)
        merger = mock.patch.object(runner, "merge_version", side_effect=self.strict_result)
        selector = mock.patch.object(runner, "select_main_guitar", side_effect=AssertionError("Unexpected fallback"))
        self.merge = merger.start()
        self.selection = selector.start()
        self.addCleanup(merger.stop)
        self.addCleanup(selector.stop)

    def tearDown(self):
        signal.alarm(0)
        signal.signal(signal.SIGALRM, self.original_handler)
        self.temporary.cleanup()

    def part(self, track, number=1):
        score = copy.deepcopy(self.score)
        score["title"] = f"Track {track} / part {number}"
        score["bpm"] = 70 + track * 10 + number
        return {"track_number": track, "track_name": f"Guitar {track}", "part": number,
                "source_measures": list(range(1, len(score["measures"]) + 1)), "score": score}

    def valid_response(self):
        return {"id": "score", "valid": True, "errors": [], "warnings": []}

    def strict_result(self, title, entries):
        score = copy.deepcopy(entries[0]["score"])
        score["title"] = title
        return score, {"status": "merged", "input_parts": len(entries)}

    def test_output_names_keep_format_and_distinguish_long_names(self):
        gp3 = runner.output_path(self.directory / "Same Song.gp3", 1, 1)
        gp4 = runner.output_path(self.directory / "Same Song.gp4", 1, 1)
        self.assertNotEqual(gp3, gp4)
        self.assertIn(".gp3.", gp3.name)
        self.assertNotEqual(gp3, runner.output_path(self.directory / "Same Song.gp3", 2, 1))
        names = [runner.output_path(self.directory / ("曲" * 78 + ending), 1, 1)
                 for ending in ("A.gp5", "B.gp5")]
        self.assertNotEqual(*names)
        self.assertTrue(all(len(path.name.encode("utf-8")) <= 255 for path in names))

    def test_song_names_keep_source_extension_and_shorten_without_collisions(self):
        self.assertEqual(runner.song_output_path(self.directory / "Same Song.gp3").name,
                         "Same Song.gp3.guitarget")
        names = [runner.song_output_path(self.directory / ("曲" * 78 + ending))
                 for ending in ("A.gp5", "B.gp5", "A.gp4")]
        self.assertEqual(len(set(names)), 3)
        self.assertTrue(all(len(path.name.encode("utf-8")) <= 240 for path in names))
        self.assertTrue(names[0].name.endswith(".gp5.guitarget"))
        self.assertTrue(names[2].name.endswith(".gp4.guitarget"))

    def test_publication_is_exclusive_and_byte_identical_reruns_are_unchanged(self):
        destination = self.directory / "score.guitarget"
        self.assertEqual(runner.publish_without_overwrite(destination, b"first"), "written")
        original_inode = destination.stat().st_ino
        self.assertEqual(runner.publish_without_overwrite(destination, b"first"), "unchanged")
        self.assertEqual(destination.stat().st_ino, original_inode)
        with self.assertRaises(FileExistsError):
            runner.publish_without_overwrite(destination, b"different")
        self.assertEqual(destination.read_bytes(), b"first")
        self.assertEqual(list(self.directory.glob(".guitarget-convert-*")), [])

    def test_existing_symlink_directory_and_dangling_symlink_are_preserved(self):
        target = self.directory / "original.gp5"
        target.write_bytes(b"original source")
        linked = self.directory / "linked.guitarget"
        linked.symlink_to(target)
        dangling = self.directory / "dangling.guitarget"
        dangling.symlink_to(self.directory / "absent")
        directory = self.directory / "directory.guitarget"
        directory.mkdir()
        for destination in (linked, dangling, directory):
            with self.subTest(destination=destination), self.assertRaises(FileExistsError):
                runner.publish_without_overwrite(destination, b"new score")
        self.assertEqual(target.read_bytes(), b"original source")
        self.assertTrue(linked.is_symlink() and dangling.is_symlink() and directory.is_dir())

    def test_publication_race_preserves_other_writer(self):
        destination = self.directory / "racing.guitarget"
        original_link = os.link

        def race(temporary, output):
            destination.write_bytes(b"other writer")
            return original_link(temporary, output)

        with mock.patch.object(runner.os, "link", side_effect=race), self.assertRaises(FileExistsError):
            runner.publish_without_overwrite(destination, b"my score")
        self.assertEqual(destination.read_bytes(), b"other writer")
        self.assertEqual(list(self.directory.glob(".guitarget-convert-*")), [])

    def test_source_scan_ignores_output_files_and_symlinks(self):
        source = self.directory / "real.GP5"
        source.write_bytes(b"source")
        (self.directory / "score.guitarget").write_bytes(b"score")
        (self.directory / "linked.gp5").symlink_to(source)
        nested = self.directory / "nested"
        nested.mkdir()
        (nested / "real.gp3").write_bytes(b"source")
        (self.directory / "linked directory").symlink_to(nested, target_is_directory=True)
        self.assertEqual(runner.source_files(self.directory), [source, nested / "real.gp3"])
        with self.assertRaises(ValueError):
            runner.source_files(self.directory / "linked directory")

    def test_damaged_gp_is_reported_without_output_or_source_change(self):
        source = self.directory / "damaged.gp5"
        original = b"this is not a Guitar Pro document\x00\xff"
        source.write_bytes(original)
        validator = mock.Mock()
        with mock.patch.object(runner, "_validator", validator):
            result = runner.convert_file(str(source))
        self.assertEqual(result["status"], "failed")
        self.assertTrue(result["error"])
        self.assertEqual(result["outputs"], [])
        self.assertEqual(result["source_sha256"], hashlib.sha256(original).hexdigest())
        self.assertEqual(source.read_bytes(), original)
        self.assertEqual(list(self.directory.iterdir()), [source])
        validator.check.assert_not_called()

    def test_failed_track_does_not_block_a_valid_track(self):
        source = self.directory / "two tracks.gp5"
        source.write_bytes(b"original GP bytes")
        song = types.SimpleNamespace(version=(5, 1, 0), title="Two Tracks", tracks=[object(), object()])
        items = [self.part(i) for i in (1, 2)]
        validator = mock.Mock()
        validator.check.side_effect = [
            {"id": "score", "valid": False, "errors": ["intentional failure"], "warnings": []},
            {"id": "score", "valid": True, "errors": [], "warnings": []},
            {"id": "score", "valid": True, "errors": [], "warnings": []},
        ]
        with mock.patch.object(runner.guitarpro, "parse", return_value=song), \
             mock.patch.object(runner, "convert_song", return_value=items), \
             mock.patch.object(runner, "_validator", validator), mock.patch.object(runner, "_dry_run", False):
            result = runner.convert_file(str(source))
        self.assertEqual(result["status"], "partial")
        self.assertEqual([item["status"] for item in result["parts"]], ["failed", "included"])
        self.assertEqual([item["status"] for item in result["outputs"]], ["written"])
        self.assertFalse(runner.output_path(source, 1, 1).exists())
        self.assertFalse(runner.output_path(source, 2, 1).exists())
        score = json.loads(runner.song_output_path(source).read_text())
        self.assertEqual(score["version"], 1)
        self.assertNotIn("collection", score)
        self.assertEqual([part["track_number"] for part in result["outputs"][0]["parts_provenance"]], [2])
        self.assertEqual([entry["track_number"] for entry in self.merge.call_args.args[1]], [2])
        self.selection.assert_not_called()
        self.assertEqual(source.read_bytes(), b"original GP bytes")

    def test_multiple_parts_are_passed_to_merge_and_one_plain_v1_score_is_published(self):
        source = self.directory / "multi part.gp5"
        source.write_bytes(b"original GP bytes")
        song = types.SimpleNamespace(version=(5, 1, 0), title="One Song", tracks=[object(), object()])
        items = [self.part(1, 1), self.part(1, 2), self.part(2, 1)]
        original_items = copy.deepcopy(items)
        validator = mock.Mock()
        validator.check.return_value = self.valid_response()
        with mock.patch.object(runner.guitarpro, "parse", return_value=song), \
             mock.patch.object(runner, "convert_song", return_value=items), \
             mock.patch.object(runner, "_validator", validator), mock.patch.object(runner, "_dry_run", False):
            result = runner.convert_file(str(source))
            rerun = runner.convert_file(str(source))
        destination = runner.song_output_path(source)
        self.assertEqual(result["status"], "converted")
        self.assertEqual([part["status"] for part in result["parts"]], ["included"] * 3)
        self.assertEqual([output["status"] for output in result["outputs"]], ["written"])
        self.assertEqual(rerun["outputs"][0]["status"], "unchanged")
        self.assertEqual(list(self.directory.glob("*.guitarget")), [destination])
        self.assertEqual([call.args[0]["version"] for call in validator.check.call_args_list],
                         [1, 1, 1, 1, 1, 1, 1, 1])
        score = json.loads(destination.read_text())
        self.assertEqual(score["version"], 1)
        self.assertEqual(set(score), runner.V1_SCORE_KEYS)
        self.assertEqual(score["title"], "One Song")
        self.assertEqual(self.merge.call_count, 2)
        passed_entries = self.merge.call_args.args[1]
        self.assertEqual([entry["score"] for entry in passed_entries], [item["score"] for item in original_items])
        self.assertTrue(all(entry["source"] == source.name for entry in passed_entries))
        output = result["outputs"][0]
        self.assertEqual(output["method"], "strict_merge")
        self.assertEqual(output["merge_report"], {"status": "merged", "input_parts": 3})
        self.assertEqual([(part["track_number"], part["part"]) for part in output["parts_provenance"]], [(1, 1), (1, 2), (2, 1)])
        self.assertTrue(all(part["source_measures"] and part["sha256"] for part in output["parts_provenance"]))
        self.selection.assert_not_called()
        self.assertEqual(items, original_items)
        self.assertEqual(source.read_bytes(), b"original GP bytes")

    def test_native_rejected_strict_score_falls_back_to_valid_primary_guitar(self):
        source = self.directory / "strict rejected.gp5"
        source.write_bytes(b"original GP bytes")
        song = types.SimpleNamespace(version=(5, 1, 0), title="Rejected", tracks=[object()])
        validator = mock.Mock()
        validator.check.side_effect = [self.valid_response(),
            {"id": "score", "valid": False, "errors": ["strict conflict"], "warnings": []}, self.valid_response()]
        selected = copy.deepcopy(self.score)
        selected["title"] = "Original primary guitar"
        self.selection.side_effect = None
        self.selection.return_value = selected, {"status": "selected", "warnings": ["excerpt: retained the longest constant-parameter run"]}
        with mock.patch.object(runner.guitarpro, "parse", return_value=song), \
             mock.patch.object(runner, "convert_song", return_value=[self.part(1)]), \
             mock.patch.object(runner, "_validator", validator), mock.patch.object(runner, "_dry_run", False):
            result = runner.convert_file(str(source))
        self.assertEqual(result["status"], "converted")
        self.assertEqual(result["parts"][0]["status"], "included")
        output = result["outputs"][0]
        self.assertEqual(output["status"], "written")
        self.assertEqual(output["method"], "primary_guitar")
        self.assertIn("strict conflict", output["merge_error"])
        self.assertFalse(output["merge_native_validation"]["valid"])
        self.assertTrue(output["mainselection_native_validation"]["valid"])
        self.assertTrue(output["native_validation"]["valid"])
        self.assertIn("excerpt: retained the longest constant-parameter run", output["warnings"])
        self.assertEqual(json.loads(runner.song_output_path(source).read_text()), selected)
        self.assertEqual(self.merge.call_count, 1)
        self.assertEqual(self.selection.call_count, 1)

    def test_strict_builder_failure_keeps_structured_reason_and_uses_primary_guitar(self):
        class StrictFailure(ValueError):
            def as_dict(self):
                return {"status": "strict_merge_failed", "reason": "different tunings"}

        source = self.directory / "different tuning.gp5"
        source.write_bytes(b"original GP bytes")
        song = types.SimpleNamespace(version=(5, 1, 0), title="Adapted", tracks=[object()])
        self.merge.side_effect = StrictFailure("different tunings")
        self.selection.side_effect = None
        self.selection.return_value = copy.deepcopy(self.score), {"status": "selected", "omitted_parts": [2]}
        validator = mock.Mock()
        validator.check.return_value = self.valid_response()
        with mock.patch.object(runner.guitarpro, "parse", return_value=song), \
             mock.patch.object(runner, "convert_song", return_value=[self.part(1)]), \
             mock.patch.object(runner, "_validator", validator), mock.patch.object(runner, "_dry_run", False):
            result = runner.convert_file(str(source))
        output = result["outputs"][0]
        self.assertEqual(output["status"], "written")
        self.assertEqual(output["merge_report"], {"status": "strict_merge_failed", "reason": "different tunings"})
        self.assertEqual(output["mainselection"]["omitted_parts"], [2])
        self.assertEqual(validator.check.call_count, 2)
        self.assertNotIn("merge_native_validation", output)
        self.assertEqual(self.merge.call_args.args, self.selection.call_args.args)

    def test_rejected_primary_guitar_never_publishes_or_changes_existing_output(self):
        source = self.directory / "both rejected.gp5"
        source.write_bytes(b"original GP bytes")
        destination = runner.song_output_path(source)
        destination.write_bytes(b"user-owned existing score")
        song = types.SimpleNamespace(version=(5, 1, 0), title="Rejected", tracks=[object()])
        self.selection.side_effect = None
        self.selection.return_value = copy.deepcopy(self.score), {"status": "selected"}
        validator = mock.Mock()
        validator.check.side_effect = [self.valid_response(),
            {"id": "score", "valid": False, "errors": ["strict overlap"], "warnings": []},
            {"id": "score", "valid": False, "errors": ["primary guitar bad fret"], "warnings": []}]
        with mock.patch.object(runner.guitarpro, "parse", return_value=song), \
             mock.patch.object(runner, "convert_song", return_value=[self.part(1)]), \
             mock.patch.object(runner, "_validator", validator), \
             mock.patch.object(runner, "publish_without_overwrite") as publish:
            result = runner.convert_file(str(source))
        self.assertEqual(result["status"], "failed")
        output = result["outputs"][0]
        self.assertEqual(output["status"], "failed")
        self.assertIn("strict overlap", output["error"])
        self.assertIn("primary guitar bad fret", output["error"])
        self.assertFalse(output["mainselection_native_validation"]["valid"])
        publish.assert_not_called()
        self.assertEqual(destination.read_bytes(), b"user-owned existing score")
        self.assertEqual(source.read_bytes(), b"original GP bytes")

    def test_both_builders_failing_produces_no_score(self):
        source = self.directory / "cannot select.gp5"
        source.write_bytes(b"original GP bytes")
        song = types.SimpleNamespace(version=(5, 1, 0), title="Unrepresentable", tracks=[object()])
        self.merge.side_effect = ValueError("strict cannot merge")
        self.selection.side_effect = ValueError("primary guitar unavailable")
        validator = mock.Mock()
        validator.check.return_value = self.valid_response()
        with mock.patch.object(runner.guitarpro, "parse", return_value=song), \
             mock.patch.object(runner, "convert_song", return_value=[self.part(1)]), \
             mock.patch.object(runner, "_validator", validator):
            result = runner.convert_file(str(source))
        self.assertEqual(result["status"], "failed")
        self.assertIn("both failed", result["outputs"][0]["error"])
        self.assertEqual(validator.check.call_count, 1)
        self.assertEqual(list(self.directory.glob("*.guitarget")), [])

    def test_primary_guitar_excerpt_is_published_unchanged_with_complete_provenance(self):
        source = self.directory / "main guitar excerpt.gp5"
        source.write_bytes(b"original GP bytes")
        song = types.SimpleNamespace(version=(5, 1, 0), title="Primary", tracks=[object(), object()])
        items = [self.part(1, 1), self.part(1, 2), self.part(2, 1)]
        originals = copy.deepcopy(items)
        selected = copy.deepcopy(items[1]["score"])
        selection_report = {"status": "excerpt", "selected_track_number": 1,
                            "selected_parts": [2], "omitted_tracks": [2], "omitted_parts": [1],
                            "warnings": ["excerpt: original primary-guitar part 2 retained"]}
        self.merge.side_effect = ValueError("changing meter cannot be merged")
        self.selection.side_effect = None
        self.selection.return_value = selected, selection_report
        validator = mock.Mock()
        validator.check.return_value = self.valid_response()
        with mock.patch.object(runner.guitarpro, "parse", return_value=song), \
             mock.patch.object(runner, "convert_song", return_value=items), \
             mock.patch.object(runner, "_validator", validator), mock.patch.object(runner, "_dry_run", False):
            result = runner.convert_file(str(source))
        output = result["outputs"][0]
        self.assertEqual(output["method"], "primary_guitar")
        self.assertEqual(output["mainselection"], selection_report)
        self.assertEqual(json.loads(runner.song_output_path(source).read_text()), selected)
        self.assertEqual([(item["track_number"], item["part"]) for item in output["parts_provenance"]],
                         [(1, 1), (1, 2), (2, 1)])
        self.assertEqual([item["score"] for item in self.selection.call_args.args[1]],
                         [item["score"] for item in originals])
        self.assertEqual(items, originals)
        self.assertEqual(source.read_bytes(), b"original GP bytes")

    def test_primary_guitar_with_hidden_fields_is_rejected_before_native_validation(self):
        self.merge.side_effect = ValueError("strict merge unavailable")
        invalid = copy.deepcopy(self.score)
        invalid["archive"] = {"parts": []}
        self.selection.side_effect = None
        self.selection.return_value = invalid, {"status": "excerpt"}
        validator = mock.Mock()
        output = {"warnings": []}
        with mock.patch.object(runner, "_validator", validator):
            with self.assertRaisesRegex(ValueError, "both failed"):
                runner.merge_or_select_main_guitar("No hidden fields", [], output)
        self.assertIn("v1", output["mainselection_error"])
        validator.check.assert_not_called()

    def test_hidden_fields_and_v2_trigger_fallback_before_native_validation(self):
        invalid_scores = []
        version_two = copy.deepcopy(self.score)
        version_two["version"] = 2
        invalid_scores.append(version_two)
        archive = copy.deepcopy(self.score)
        archive["archive"] = {"other_parts": []}
        invalid_scores.append(archive)
        nested = copy.deepcopy(self.score)
        nested["measures"][0]["voices"][0]["events"][0]["notes"][0]["archive"] = "hidden"
        invalid_scores.append(nested)
        validator = mock.Mock()
        validator.check.return_value = self.valid_response()
        self.merge.side_effect = None
        self.selection.side_effect = None
        self.selection.return_value = copy.deepcopy(self.score), {"status": "selected"}
        for invalid in invalid_scores:
            with self.subTest(invalid=invalid.get("version")):
                self.merge.return_value = invalid, {"status": "merged"}
                validator.reset_mock()
                output = {"warnings": []}
                with mock.patch.object(runner, "_validator", validator):
                    final = runner.merge_or_select_main_guitar("V1 only", [], output)
                self.assertEqual(final, self.score)
                self.assertEqual(output["method"], "primary_guitar")
                self.assertIn("v1", output["merge_error"])
                self.assertNotIn("merge_native_validation", output)
                self.assertEqual(validator.check.call_count, 1)

    def test_output_collision_does_not_trigger_a_new_primary_guitar_selection(self):
        source = self.directory / "existing score.gp5"
        source.write_bytes(b"original GP bytes")
        destination = runner.song_output_path(source)
        destination.write_bytes(b"existing user edits")
        song = types.SimpleNamespace(version=(5, 1, 0), title="Exists", tracks=[object()])
        validator = mock.Mock()
        validator.check.return_value = self.valid_response()
        with mock.patch.object(runner.guitarpro, "parse", return_value=song), \
             mock.patch.object(runner, "convert_song", return_value=[self.part(1)]), \
             mock.patch.object(runner, "_validator", validator), mock.patch.object(runner, "_dry_run", False):
            result = runner.convert_file(str(source))
        self.assertEqual(result["status"], "failed")
        self.assertIn("different output already exists", result["outputs"][0]["error"])
        self.selection.assert_not_called()
        self.assertEqual(destination.read_bytes(), b"existing user edits")

    def test_dry_run_validates_parts_and_final_v1_score_without_publishing(self):
        source = self.directory / "dry run.gp5"
        source.write_bytes(b"original GP bytes")
        song = types.SimpleNamespace(version=(5, 1, 0), title="Dry Run", tracks=[object()])
        validator = mock.Mock()
        validator.check.return_value = self.valid_response()
        with mock.patch.object(runner.guitarpro, "parse", return_value=song), \
             mock.patch.object(runner, "convert_song", return_value=[self.part(1)]), \
             mock.patch.object(runner, "_validator", validator), mock.patch.object(runner, "_dry_run", True):
            result = runner.convert_file(str(source))
        self.assertEqual(result["status"], "converted")
        self.assertEqual(result["parts"][0]["status"], "included")
        self.assertEqual(result["outputs"][0]["status"], "validated")
        self.assertEqual([call.args[0]["version"] for call in validator.check.call_args_list], [1, 1])
        self.assertEqual(list(self.directory.glob("*.guitarget")), [])

    def test_all_failed_or_skipped_parts_produce_no_score(self):
        source = self.directory / "no candidates.gp5"
        source.write_bytes(b"original GP bytes")
        song = types.SimpleNamespace(version=(5, 1, 0), title="No Candidates", tracks=[object(), object()])
        items = [{"track_number": 1, "part": 1, "score": None, "error": "unsupported event"},
                 {"track_number": 2, "part": 0, "score": None, "error": "skipped_drums: percussion"}]
        validator = mock.Mock()
        with mock.patch.object(runner.guitarpro, "parse", return_value=song), \
             mock.patch.object(runner, "convert_song", return_value=items), \
             mock.patch.object(runner, "_validator", validator):
            failed = runner.convert_file(str(source))
        self.assertEqual(failed["status"], "failed")
        self.assertEqual([part["status"] for part in failed["parts"]], ["failed", "skipped"])
        self.assertEqual(failed["outputs"], [])
        validator.check.assert_not_called()
        with mock.patch.object(runner.guitarpro, "parse", return_value=song), \
             mock.patch.object(runner, "convert_song", return_value=items[1:]):
            skipped = runner.convert_file(str(source))
        self.assertEqual(skipped["status"], "skipped")
        self.assertEqual(skipped["outputs"], [])

    def test_review_reads_old_outputs_and_new_parts_without_counting_unpublished_parts_as_success(self):
        bad = {"valid": False, "errors": ["rejected"], "warnings": []}
        good = self.valid_response()
        records = [
            {"source": "old.gp5", "status": "partial", "outputs": [
                {"track_number": 1, "status": "written", "warnings": ["approx: old"], "native_validation": good},
                {"track_number": 1, "status": "failed", "error": "ValueError: old", "native_validation": bad}]},
            {"source": "unpublished.gp5", "status": "failed", "parts": [
                {"track_number": 2, "status": "included", "warnings": ["approx: unpublished"], "native_validation": good}],
             "outputs": [{"status": "failed", "error": "ValueError: bundle", "native_validation": bad}]},
            {"source": "new.gp5", "status": "converted", "parts": [
                {"track_number": 3, "status": "included", "warnings": ["text: new"], "native_validation": good}],
             "outputs": [{"status": "written", "native_validation": good}]},
        ]
        (self.directory / "summary.json").write_text("{}")
        (self.directory / "results.jsonl").write_text("".join(json.dumps(item) + "\n" for item in records))
        with mock.patch("sys.stdout", new=io.StringIO()):
            review_report.review(self.directory)
        coverage = json.loads((self.directory / "coverage.json").read_text())
        self.assertEqual(coverage["sources_with_output"], 2)
        self.assertEqual(coverage["complete_eligible_tracks"], 1)
        self.assertEqual(coverage["partial_eligible_tracks"], 1)
        self.assertEqual(coverage["failed_eligible_tracks"], 1)
        self.assertEqual(coverage["native_rejections"], 2)
        self.assertEqual(coverage["native_part_rejections"], 1)
        self.assertEqual(coverage["native_container_rejections"], 1)
        self.assertEqual(coverage["successful_part_warning_categories"], {"approx": 1, "text": 1})

    def test_missing_source_is_counted_as_a_failed_preservation_check(self):
        report = self.directory / "results.jsonl"
        report.write_text(json.dumps({"source": str(self.directory / "missing.gp5"),
                                      "source_sha256": "0" * 64}) + "\n")
        result = runner.verify_sources(report)
        self.assertEqual(result["checked"], 1)
        self.assertEqual(result["unchanged"], 0)
        self.assertEqual(len(result["failures"]), 1)

    @unittest.skipUnless((ROOT / ".build/validate").is_file(), "Build native validator first")
    def test_real_native_protocol_reuses_process_and_rejects_invalid_score(self):
        validator = runner.NativeValidator()
        try:
            self.assertTrue(validator.check(self.score)["valid"])
            process = validator.process
            invalid = validator.check({})
            self.assertFalse(invalid["valid"])
            self.assertTrue(invalid["errors"])
            unknown_version = copy.deepcopy(self.score)
            unknown_version["version"] = 2
            self.assertFalse(validator.check(unknown_version)["valid"])
            self.assertTrue(validator.check(self.score)["valid"])
            self.assertIs(validator.process, process)
        finally:
            validator.close()
        self.assertIsNotNone(process.poll())

    def check_timeout(self, child_code, score):
        """An outer alarm makes a missing runner deadline fail rather than hang this test."""
        real_popen = subprocess.Popen
        children = []

        def spawn(*args, **kwargs):
            child = real_popen([sys.executable, "-u", "-c", child_code], **kwargs)
            children.append(child)
            return child

        def outer_deadline(signum, frame):
            raise AssertionError("NativeValidator failed to time out the complete pipe exchange")

        validator = runner.NativeValidator()
        signal.signal(signal.SIGALRM, outer_deadline)
        started = time.monotonic()
        try:
            with mock.patch.object(runner.subprocess, "Popen", side_effect=spawn), \
                 mock.patch.object(runner, "_timeout", 1):
                signal.alarm(4)
                with self.assertRaises(TimeoutError):
                    validator.check(score)
        finally:
            signal.alarm(0)
            validator.close()
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.wait()
        self.assertLess(time.monotonic() - started, 3)
        self.assertIsNone(validator.process)

    def test_timeout_kills_and_reaps_validator_without_response(self):
        self.check_timeout("import sys,time; sys.stdin.readline(); time.sleep(30)", self.score)

    def test_timeout_covers_child_that_does_not_read_large_request(self):
        self.check_timeout("import time; time.sleep(30)", {"title": "x" * (1024 * 1024)})

    def test_timeout_covers_partial_response_line(self):
        self.check_timeout("import sys,time; sys.stdin.readline(); sys.stdout.write('{'); sys.stdout.flush(); time.sleep(30)", self.score)


if __name__ == "__main__":
    unittest.main()

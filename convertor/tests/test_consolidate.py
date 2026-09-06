"""Exercise ordinary-v1 replacement and recovery only in temporary libraries."""
from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
import uuid
from unittest import mock


CONVERTOR = Path(__file__).resolve().parents[1]
if str(CONVERTOR) not in sys.path:
    sys.path.insert(0, str(CONVERTOR))
import consolidate
import merge_library
from song_bundle import content_hash, encoded, extract_parts, make_collection, part_identifier


class V1LibraryReplacementTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="guitarget consolidation 空格 ")
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "Library"
        self.report = self.base / "Report"
        self.staging = self.report / "scores"
        self.archive = self.base / "Archive"
        self.archive_songs = self.archive / "songs"
        self.root.mkdir()
        self.staging.mkdir(parents=True)
        self.archive_songs.mkdir(parents=True)
        self.args = types.SimpleNamespace(root=self.root, report=self.report, workers=2)
        self.original_data = {}
        self.versions = []
        self.archive_data = {}
        archive_receipts = []
        for title, count in (("Artist - First", 2), ("Artist - Second", 1)):
            entries, originals = [], []
            source = f"A/Artist/{title}.gp5"
            for part in range(1, count + 1):
                score = self.leaf_score(title + f" part {part}", part)
                filename = f"{title}.gp5.track-01.part-{part:03d}.guitarget"
                data = encoded(score)
                (self.root / filename).write_bytes(data)
                self.original_data[filename] = data
                entries.append({"source": source, "track_number": 1, "track_name": "Guitar",
                                "part": part, "source_measures": [part], "score": score})
                originals.append({"path": filename, "sha256": hashlib.sha256(data).hexdigest(),
                                  "stat": consolidate.file_identity((self.root / filename).stat()),
                                  "content_sha256": content_hash(score),
                                  "part_id": part_identifier(source, 1, part)})
            filename = title + ".guitarget"
            backup = encoded(make_collection(title, entries))
            (self.archive_songs / filename).write_bytes(backup)
            self.archive_data[filename] = backup
            archive_receipt = {"key": title, "title": title, "filename": filename, "status": "ready",
                               "sha256": hashlib.sha256(backup).hexdigest(), "bytes": len(backup),
                               "originals": originals, "parts": count, "versions": 1, "tracks": 1}
            archive_receipts.append(archive_receipt)
            # Safety tests need an already-prepared valid v1 result. Original
            # metadata may vary; score-building policy has separate pure tests.
            score = self.leaf_score(title, 1)
            score["measures"] = [copy.deepcopy(entry["score"]["measures"][0]) for entry in entries]
            data = encoded(score)
            (self.staging / filename).write_bytes(data)
            self.versions.append({"source": source, "title": title, "filename": filename, "status": "ready",
                                  "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data),
                                  "originals": originals, "archive_key": title,
                                  "archive_filename": filename, "archive_sha256": archive_receipt["sha256"],
                                  "report": {"mode": "merged"}})
        (self.archive / "songs.jsonl").write_bytes(b"".join(encoded(item) for item in archive_receipts))
        self.plan = {"format": "original-v1-merge-or-primary", "archive": str(self.archive),
                     "root": str(self.root), "root_identity": consolidate.file_identity(self.root.stat())[:2],
                     "staging_identity": consolidate.file_identity(self.staging.stat())[:2],
                     "versions": 2, "original_fragments": 3, "groups": 2, "selected_groups": 2}
        consolidate.save(self.report / "plan.json", self.plan)
        self.write_version_receipt()
        self.quiet = mock.patch.object(merge_library, "log")
        self.quiet.start()

    def tearDown(self):
        self.quiet.stop()
        self.temporary.cleanup()

    @staticmethod
    def leaf_score(title, part):
        return {
            "version": 1, "title": title, "tuning": [64, 59, 55, 50, 45, 40],
            "timeSignature": {"numerator": 4 if part == 1 else 3, "denominator": 4},
            "bpm": 80.0 if part == 1 else 120.0,
            "measures": [{"id": str(uuid.uuid4()), "voices": [
                {"voice": "melody", "events": [{
                    "id": str(uuid.uuid4()), "startTick": 0,
                    "rhythm": {"value": 4, "dotted": False, "triplet": False},
                    "notes": [{"id": str(uuid.uuid4()), "string": 1, "fret": part + 2,
                               "velocity": 0.75, "technique": "none", "tieToNext": False}],
                    "lyric": "保留歌词"}]},
                {"voice": "bass", "events": []}]}],
        }

    def write_version_receipt(self):
        (self.report / "versions.jsonl").write_bytes(b"".join(encoded(item) for item in self.versions))

    def assert_originals_unchanged(self):
        for filename, data in self.original_data.items():
            self.assertTrue((self.root / filename).is_file(), filename)
            self.assertEqual((self.root / filename).read_bytes(), data, filename)

    def assert_complete(self):
        self.assertEqual(consolidate.inventory(self.root), {item["filename"] for item in self.versions})
        reconstructed = 0
        for item in self.versions:
            data = (self.root / item["filename"]).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), item["sha256"])
            score = json.loads(data)
            self.assertEqual(score["version"], 1)
            self.assertEqual(set(score), {"version", "title", "tuning", "bpm", "timeSignature", "measures"})
            self.assertEqual(len(score["measures"]), len(item["originals"]))
            backup = (self.archive_songs / item["archive_filename"]).read_bytes()
            self.assertEqual(backup, self.archive_data[item["archive_filename"]])
            parts = extract_parts(json.loads(backup))
            self.assertEqual(len(parts), len(item["originals"]))
            for original in item["originals"]:
                self.assertEqual(content_hash(parts[original["part_id"]]), original["content_sha256"])
                reconstructed += 1
        self.assertEqual(reconstructed, 3)
        summary = json.loads((self.report / "summary.json").read_text())
        self.assertEqual(summary["final_version_files"], 2)
        self.assertEqual(summary["removed_fragment_files"], 3)
        self.assertEqual(summary["original_content_archive"], str(self.archive_songs))
        self.assertFalse(self.staging.exists())

    def mark_started(self):
        consolidate.save(self.report / "apply-started.json", {"at": "test interruption"})

    def publish_all(self):
        self.mark_started()
        for item in self.versions:
            os.link(self.staging / item["filename"], self.root / item["filename"])

    def remove_all_originals(self):
        for filename in self.original_data:
            (self.root / filename).unlink()

    def test_apply_replaces_three_fragments_with_two_v1_files_and_keeps_backup(self):
        merge_library.apply(self.args)
        self.assert_complete()
        verified = json.loads((self.report / "verified-before-delete.json").read_text())
        self.assertEqual(verified["backup_fragments"], 3)
        self.assertEqual(verified["versions"], 2)

    def test_corrupt_staging_bytes_preserve_every_original(self):
        filename = self.staging / self.versions[0]["filename"]
        filename.write_bytes(filename.read_bytes() + b"corrupted")
        with self.assertRaises(ValueError):
            merge_library.apply(self.args)
        self.assert_originals_unchanged()
        self.assertEqual(consolidate.inventory(self.root), set(self.original_data))
        self.assertFalse((self.report / "verified-before-delete.json").exists())

    def test_corrupt_archive_preserves_every_original(self):
        filename = self.archive_songs / self.versions[0]["archive_filename"]
        filename.write_bytes(filename.read_bytes() + b"corrupted")
        with self.assertRaises(ValueError):
            merge_library.apply(self.args)
        self.assert_originals_unchanged()
        self.assertEqual(consolidate.inventory(self.root), set(self.original_data))
        self.assertFalse((self.report / "verified-before-delete.json").exists())

    def test_v2_output_is_rejected_even_with_updated_file_hash(self):
        item = self.versions[0]
        filename = self.staging / item["filename"]
        data = self.archive_data[item["archive_filename"]]
        filename.write_bytes(data)
        item["sha256"] = hashlib.sha256(data).hexdigest()
        item["bytes"] = len(data)
        self.write_version_receipt()
        with self.assertRaisesRegex(ValueError, "original app format"):
            merge_library.apply(self.args)
        self.assert_originals_unchanged()
        self.assertFalse((self.report / "verified-before-delete.json").exists())

    def test_arranged_receipt_is_rejected_even_for_valid_v1_and_keeps_originals(self):
        staged = {path.name: path.read_bytes() for path in self.staging.iterdir()}
        item = self.versions[0]
        score = json.loads(staged[item["filename"]])
        self.assertEqual(score["version"], 1)
        self.assertEqual(set(score), {"version", "title", "tuning", "bpm", "timeSignature", "measures"})
        item["report"]["mode"] = "arranged"
        self.write_version_receipt()
        with self.assertRaisesRegex(ValueError, "Arranged outputs are not authorized"):
            merge_library.apply(self.args)
        self.assert_originals_unchanged()
        self.assertEqual(consolidate.inventory(self.root), set(self.original_data))
        self.assertEqual({path.name: path.read_bytes() for path in self.staging.iterdir()}, staged)
        self.assertFalse((self.report / "apply-started.json").exists())
        self.assertFalse((self.report / "verified-before-delete.json").exists())
        self.assertFalse((self.report / "summary.json").exists())

    def test_music_fingerprint_ignores_identity_but_preserves_pitch_tempo_and_part_structure(self):
        entries = [{"source": "A/original.gp5", "track_number": 1, "track_name": "Guitar",
                    "part": part, "source_measures": [part],
                    "score": self.leaf_score(f"Original part {part}", part)} for part in (1, 2)]
        original = copy.deepcopy(entries)
        fingerprint = merge_library.music_fingerprint(entries)
        renamed = copy.deepcopy(entries)

        def replace_ids(value):
            if isinstance(value, dict):
                for key, item in value.items():
                    if key == "id":
                        value[key] = str(uuid.uuid4())
                    else:
                        replace_ids(item)
            elif isinstance(value, list):
                for item in value:
                    replace_ids(item)

        for entry in renamed:
            entry["source"] = "A/duplicate-download.gp5"
            entry["track_name"] = "Renamed guitar"
            entry["score"]["title"] = "Different display title"
            replace_ids(entry["score"])
            entry["score"]["measures"][0]["voices"][0]["events"][0]["notes"][0]["targetFret"] = None
        self.assertEqual(merge_library.music_fingerprint(list(reversed(renamed))), fingerprint)

        missing_lyric = copy.deepcopy(entries)
        del missing_lyric[0]["score"]["measures"][0]["voices"][0]["events"][0]["lyric"]
        null_lyric = copy.deepcopy(missing_lyric)
        null_lyric[0]["score"]["measures"][0]["voices"][0]["events"][0]["lyric"] = None
        self.assertEqual(merge_library.music_fingerprint(missing_lyric),
                         merge_library.music_fingerprint(null_lyric))

        for change in ("pitch", "tempo", "part_number", "part_count", "source_measures", "track_number"):
            with self.subTest(change=change):
                changed = copy.deepcopy(entries)
                if change == "pitch":
                    changed[0]["score"]["measures"][0]["voices"][0]["events"][0]["notes"][0]["fret"] += 1
                elif change == "tempo":
                    changed[0]["score"]["bpm"] += 1
                elif change == "part_number":
                    changed[0]["part"] = 3
                elif change == "part_count":
                    changed.pop()
                elif change == "source_measures":
                    changed[0]["source_measures"] = [99]
                else:
                    changed[0]["track_number"] = 2
                self.assertNotEqual(merge_library.music_fingerprint(changed), fingerprint)
        self.assertEqual(entries, original)

    def test_existing_destination_is_not_overwritten(self):
        target = self.root / self.versions[0]["filename"]
        target.write_bytes(b"an existing user file")
        with self.assertRaises(ValueError):
            merge_library.apply(self.args)
        self.assertEqual(target.read_bytes(), b"an existing user file")
        self.assert_originals_unchanged()

    def test_resume_after_partial_publication(self):
        self.mark_started()
        item = self.versions[0]
        os.link(self.staging / item["filename"], self.root / item["filename"])
        merge_library.apply(self.args)
        self.assert_complete()

    def test_resume_after_partial_original_deletion(self):
        self.publish_all()
        (self.root / next(iter(self.original_data))).unlink()
        merge_library.apply(self.args)
        self.assert_complete()

    def test_resume_after_partial_staging_cleanup(self):
        self.publish_all()
        self.remove_all_originals()
        (self.staging / self.versions[0]["filename"]).unlink()
        merge_library.apply(self.args)
        self.assert_complete()

    def test_resume_after_all_staging_was_removed_before_summary(self):
        self.publish_all()
        self.remove_all_originals()
        for item in self.versions:
            (self.staging / item["filename"]).unlink()
        self.staging.rmdir()
        merge_library.apply(self.args)
        self.assert_complete()

    def test_staging_directory_symlink_cannot_redirect_cleanup_into_library(self):
        self.publish_all()
        for item in self.versions:
            (self.staging / item["filename"]).unlink()
        self.staging.rmdir()
        self.staging.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises((ValueError, OSError)):
            merge_library.apply(self.args)
        self.assert_originals_unchanged()
        for item in self.versions:
            self.assertEqual(hashlib.sha256((self.root / item["filename"]).read_bytes()).hexdigest(), item["sha256"])

    def test_preparation_recovery_quarantines_truncated_receipt_tail(self):
        receipt = self.report / "versions.jsonl"
        complete = receipt.read_bytes()
        # Exercise both reverse chunk scanning and an interrupted UTF-8 byte
        # sequence, without decoding or dropping any of the damaged tail.
        tail = b'{"source":"unfinished","padding":"' + b"x" * 70000 + b"\xe4\xb8"
        receipt.write_bytes(complete + tail)
        with self.assertRaises((json.JSONDecodeError, UnicodeDecodeError)):
            merge_library.latest_versions(self.report)
        merge_library.recover_preparation(self.report, self.staging)
        self.assertEqual(receipt.read_bytes(), complete)
        self.assertEqual(merge_library.latest_versions(self.report),
                         {item["source"]: item for item in self.versions})
        quarantined = list((self.report / "interrupted-writes").iterdir())
        self.assertEqual(len(quarantined), 1)
        self.assertEqual(quarantined[0].read_bytes(), tail)
        merge_library.recover_preparation(self.report, self.staging)
        self.assertEqual(list((self.report / "interrupted-writes").iterdir()), quarantined)
        self.assert_originals_unchanged()

    def test_preparation_recovery_quarantines_orphan_temp_and_keeps_valid_scores(self):
        staged = {path.name: path.read_bytes() for path in self.staging.iterdir()}
        orphan = self.staging / ".guitarget-convert-interrupted"
        interrupted_data = b'{"version":1,"title":"partially written'
        orphan.write_bytes(interrupted_data)
        identity = consolidate.file_identity(orphan.stat())
        merge_library.recover_preparation(self.report, self.staging)
        self.assertFalse(orphan.exists())
        self.assertEqual({path.name: path.read_bytes() for path in self.staging.iterdir()}, staged)
        quarantined = list((self.report / "interrupted-writes").iterdir())
        self.assertEqual(len(quarantined), 1)
        self.assertEqual(quarantined[0].read_bytes(), interrupted_data)
        self.assertEqual(consolidate.file_identity(quarantined[0].stat()), identity)
        merge_library.recover_preparation(self.report, self.staging)
        self.assertEqual(list((self.report / "interrupted-writes").iterdir()), quarantined)
        self.assert_originals_unchanged()

    def test_apply_refuses_orphan_staging_temp_before_deleting_originals(self):
        orphan = self.staging / ".guitarget-convert-interrupted"
        orphan.write_bytes(b"incomplete score")
        with self.assertRaisesRegex(ValueError, "Unexpected staging entry"):
            merge_library.apply(self.args)
        self.assert_originals_unchanged()
        self.assertEqual(consolidate.inventory(self.root), set(self.original_data))
        self.assertEqual(orphan.read_bytes(), b"incomplete score")
        self.assertFalse((self.report / "apply-started.json").exists())
        self.assertFalse((self.report / "verified-before-delete.json").exists())

    def test_preparation_recovery_resumes_after_quarantine_link_before_unlink(self):
        staged = {path.name: path.read_bytes() for path in self.staging.iterdir()}
        orphan = self.staging / ".guitarget-convert-interrupted"
        orphan.write_bytes(b"unfinished output")
        identity = consolidate.file_identity(orphan.stat())
        recovered = self.report / "interrupted-writes"
        recovered.mkdir()
        destination = recovered / (orphan.name + "-" + str(orphan.stat().st_ino))
        os.link(orphan, destination)
        merge_library.recover_preparation(self.report, self.staging)
        self.assertFalse(orphan.exists())
        self.assertEqual(destination.read_bytes(), b"unfinished output")
        self.assertEqual(consolidate.file_identity(destination.stat()), identity)
        self.assertEqual({path.name: path.read_bytes() for path in self.staging.iterdir()}, staged)
        self.assert_originals_unchanged()

    def test_preparation_recovery_refuses_different_quarantine_destination(self):
        staged = {path.name: path.read_bytes() for path in self.staging.iterdir()}
        orphan = self.staging / ".guitarget-convert-interrupted"
        orphan.write_bytes(b"unfinished output")
        identity = consolidate.file_identity(orphan.stat())
        recovered = self.report / "interrupted-writes"
        recovered.mkdir()
        destination = recovered / (orphan.name + "-" + str(orphan.stat().st_ino))
        # Identical contents alone do not prove that the earlier isolation link
        # succeeded: an unrelated destination must still remain untouched.
        destination.write_bytes(orphan.read_bytes())
        destination_identity = consolidate.file_identity(destination.stat())
        with self.assertRaisesRegex(ValueError, "Recovery destination differs"):
            merge_library.recover_preparation(self.report, self.staging)
        self.assertEqual(orphan.read_bytes(), b"unfinished output")
        self.assertEqual(consolidate.file_identity(orphan.stat()), identity)
        self.assertEqual(destination.read_bytes(), b"unfinished output")
        self.assertEqual(consolidate.file_identity(destination.stat()), destination_identity)
        self.assertEqual({path.name: path.read_bytes() for path in self.staging.iterdir() if path != orphan}, staged)
        self.assert_originals_unchanged()

    def test_withdrawn_consolidate_apply_always_refuses(self):
        for args in (self.args, None):
            with self.subTest(args=args), self.assertRaisesRegex(ValueError, "withdrawn"):
                consolidate.apply(args)
        self.assert_originals_unchanged()
        self.assertFalse((self.report / "apply-started.json").exists())


if __name__ == "__main__":
    unittest.main()

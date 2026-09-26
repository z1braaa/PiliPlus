"""Campaign acceptance: comparable trials, source gaps, budgets and checkpoints."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tool import vod_auto_test as vod
from tool import vod_campaign as campaign


NOW = 1_790_000_000
BV = ["BV1aaaaaaaaa", "BV1bbbbbbbbb", "BV1ccccccccc", "BV1ddddddddd"]


def candidates():
    return [{"bvid": bvid, "pubdate": NOW - days * 86400, "view": views,
             "duration": 120, "title": "private title"}
            for bvid, days, views in zip(BV, (1, 1, 40, 40), (100, 200000, 100, 200000))]


def manifest(record):
    return vod.normalize_manifest({
        "video_urls": ["https://upos-sz-mirrorali.bilivideo.com/upgcxcode/1/a.m4s?sign=private-video"],
        "audio_urls": ["https://upos-sz-mirrorali.bilivideo.com/upgcxcode/1/b.m4s?sign=private-audio"],
        "quality": 32, "codec": "avc1.64001f", "width": 854, "height": 480,
        "view": {**record, "page_duration": 120}, "source_route": "official_video_html",
        "acquisition_attempts": [{"stage": "video_html", "status": "ok"}]})


def simulated_playback(args, *, acquired_manifest, baseline, on_sample):
    source = {key: acquired_manifest[key] for key in
              ("quality", "quality_label", "codec", "width", "height", "view")}
    report = {"status": "completed", "source": source,
              "quality_check": vod.quality_policy(acquired_manifest, args.quality_code, args.allow_lower_quality)}
    rows = []
    for index, mode in enumerate(args.order, 1):
        row = {"trial": index, "mode": mode, "status": "measured",
               "comparison_key": hashlib.sha256(args.bvid.encode()).hexdigest(),
               "quality": source["quality"], "codec": source["codec"], "width": source["width"], "height": source["height"],
               "start_seconds": args.start_seconds, "duration_seconds": args.duration_seconds,
               "concurrency": args.concurrency, "chunk_kib": args.chunk_kib,
               "initial_progress_seconds": 1 if mode == "hw-direct" else 2,
               "seek_progress_seconds": None, "cache_pause_seconds": None}
        rows.append(row)
        on_sample(report, row)
    return report, rows, 0


class CampaignTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        library = self.directory / "libmpv"
        library.touch()
        self.args = vod.parser().parse_args([
            "campaign", "--library", str(library), "--output", str(self.directory / "report"),
            "--seek-seconds", "30", "--duration-seconds", "8", "--seed", "17"])

    def execute(self, records=None, source=None, player=None):
        records = candidates() if records is None else records
        source = source or (lambda args, timeout: manifest(next(r for r in records if r["bvid"] == args.bvid)))
        with patch.object(vod, "base_report", return_value={"kind": "stratified_vod_campaign"}), \
             patch.object(vod, "resolve_executable", return_value="/fixture/dart"), \
             patch.object(campaign.time, "time", return_value=NOW), \
             patch.object(campaign, "acquire_catalog", return_value={"candidates": records, "attempts": []}), \
             patch.object(vod, "acquire_anonymous_manifest", side_effect=source) as acquire, \
             patch.object(vod, "playback", side_effect=player or simulated_playback) as playback:
            report, rows, status = campaign.campaign(self.args)
        return report, rows, status, acquire, playback

    def test_four_strata_fixed_source_paired_trials_and_anonymous_quality_are_explicit(self):
        report, rows, status, acquire, player = self.execute()
        self.assertEqual(status, 0)
        self.assertEqual(report["status"], "completed")
        self.assertEqual((acquire.call_count, player.call_count, len(rows)), (4, 4, 16))
        self.assertEqual(report["selection"]["policy"]["seed"], 17)
        self.assertEqual(report["summary"]["measured_trials"], 16)
        for call in player.call_args_list:
            args = call.args[0]
            self.assertEqual(args.order[0], args.order[3])
            self.assertEqual(args.order[1], args.order[2])
            self.assertNotEqual(args.order[0], args.order[1])
            same_video = [row for row in rows if row["bvid"] == args.bvid]
            self.assertEqual(len({row["comparison_key"] for row in same_video}), 1)
        for video in report["videos"]:
            self.assertFalse(video["quality_check"]["requested_quality_reproduced"])
            self.assertEqual(video["source"]["quality"], 32)
        public = "".join(path.read_text(encoding="utf-8-sig") for path in Path(self.args.output).iterdir())
        for secret in ("private-video", "private-audio", "private title", "/upgcxcode/"):
            self.assertNotIn(secret, public)
        self.assertIn("480p", public)
        self.assertTrue(all("p95" not in video["metrics"] for video in report["summary"]["videos"]))

    def test_source_failure_retains_not_run_counts_and_other_videos_continue(self):
        def source(args, timeout):
            if args.bvid == BV[0]:
                raise vod.HarnessError("access_restricted", stage="video_html", http_status=412)
            return manifest(next(r for r in candidates() if r["bvid"] == args.bvid))
        report, rows, status, _, player = self.execute(source=source)
        self.assertEqual(status, 1)
        self.assertEqual(player.call_count, 3)
        first = next(video for video in report["summary"]["videos"] if video["bvid"] == BV[0])
        for mode in ("hw-direct", "parallel"):
            self.assertEqual(first["modes"][mode], {"trials": 2, "measured": 0, "failed_or_timeout": 0, "not_run": 2})
        self.assertEqual(first["metrics"], {})
        self.assertEqual(report["summary"]["measured_trials"], 12)
        self.assertEqual(report["summary"]["unmeasured_trials"], 4)

    def test_changed_view_band_is_excluded_before_native_playback(self):
        def source(args, timeout):
            record = next(r for r in candidates() if r["bvid"] == args.bvid)
            if args.bvid == BV[0]:
                record["view"] = 200001
            return manifest(record)
        report, _, _, _, player = self.execute(source=source)
        first = next(video for video in report["videos"] if video["catalog"]["bvid"] == BV[0])
        self.assertEqual(first["error"]["classification"], "catalog_metadata_changed")
        self.assertEqual(player.call_count, 3)

    def test_multi_page_total_duration_cannot_validate_short_or_unknown_first_page(self):
        for actual_length, classification in ((10, "video_too_short_for_fixed_positions"), (None, "page_duration_not_verified")):
            with self.subTest(page_duration=actual_length):
                def source(args, timeout):
                    result = manifest(next(r for r in candidates() if r["bvid"] == args.bvid))
                    result["view"]["page_duration"] = actual_length
                    return result
                report, rows, _, _, player = self.execute(source=source)
                player.assert_not_called()
                self.assertEqual(len(rows), 16)
                self.assertTrue(all(video["error"]["classification"] == classification for video in report["videos"]))

    def test_strict_requested_quality_generates_no_actual_playback_samples(self):
        self.args.require_quality = True
        report, rows, status, _, _ = self.execute(player=vod.playback)
        self.assertEqual(status, 1)
        self.assertTrue(all(row["status"] == "not_run" for row in rows))
        self.assertTrue(all(video["error"]["classification"] == "requested_quality_not_reproduced" for video in report["videos"]))

    def test_missing_control_strata_are_reported_as_gaps(self):
        report, rows, status, _, _ = self.execute(records=candidates()[:2])
        self.assertEqual(status, 0)
        self.assertEqual(report["status"], "completed_with_gaps")
        self.assertFalse(report["coverage_complete"])
        self.assertEqual(report["selection"]["shortages"]["older-low"], 1)
        self.assertEqual(len(rows), 8)

    def test_empty_catalog_still_writes_readable_report_without_media_run(self):
        report, rows, status, source, player = self.execute(records=[])
        self.assertEqual((status, rows), (1, []))
        source.assert_not_called()
        player.assert_not_called()
        self.assertEqual(report["error"]["classification"], "no_eligible_public_videos")
        page = (Path(self.args.output) / "index.html").read_text()
        self.assertIn("未取得可测样本", page)
        self.assertIn("已测量 0 次", page)

    def test_budget_exhaustion_after_discovery_never_launches_media(self):
        clock = [0]
        def discover(args, timeout):
            clock[0] = 100
            return {"candidates": candidates(), "attempts": []}
        self.args.campaign_budget_seconds = 5
        with patch.object(campaign.time, "monotonic", side_effect=lambda: clock[0]), \
             patch.object(campaign, "acquire_catalog", side_effect=discover), \
             patch.object(vod, "base_report", return_value={"kind": "stratified_vod_campaign"}), \
             patch.object(vod, "resolve_executable", return_value="/fixture/dart"), \
             patch.object(campaign.time, "time", return_value=NOW), \
             patch.object(vod, "acquire_anonymous_manifest") as source, patch.object(vod, "playback") as player:
            report, rows, status = campaign.campaign(self.args)
        source.assert_not_called()
        player.assert_not_called()
        self.assertEqual((status, len(rows), report["summary"]["measured_trials"]), (1, 16, 0))

    def test_interrupt_preserves_completed_trial_and_marks_remaining_not_run(self):
        def interrupted(args, **kwargs):
            def callback(report, row):
                kwargs["on_sample"](report, row)
                raise KeyboardInterrupt()
            return simulated_playback(args, **{**kwargs, "on_sample": callback})
        report, rows, status, _, _ = self.execute(player=interrupted)
        self.assertEqual(status, 130)
        self.assertEqual(report["status"], "interrupted")
        self.assertEqual(len(rows), 16)
        self.assertEqual(report["summary"]["measured_trials"], 1)
        saved = json.loads((Path(self.args.output) / "report.json").read_text())
        self.assertEqual(len(saved["samples"]), 16)
        first = [row for row in rows if row["bvid"] == rows[0]["bvid"]]
        self.assertEqual(len({row["comparison_key"] for row in first}), 1)

    def test_discovery_worker_receives_old_age_threshold_and_keeps_attempt_counts(self):
        payload = {"candidates": candidates(), "attempts": [{"source": "precious", "status": "ok", "candidates": 50}],
                   "sampling_strategy": {"older_days": 45}}
        self.args.old_min_days = 45
        with patch.object(vod, "run_command", return_value={"timed_out": False, "exit_code": 0, "stdout": json.dumps(payload)}) as worker:
            result = campaign.acquire_catalog(self.args, 10)
        self.assertEqual(json.loads(worker.call_args.kwargs["payload"])["older_days"], 45)
        self.assertEqual(result["attempts"][0]["candidates"], 50)
        self.assertEqual(result["sampling_strategy"]["older_days"], 45)

    def test_partial_playback_cannot_be_reported_as_completed(self):
        def partial(args, **kwargs):
            rows = []
            def callback(report, row):
                if not rows:
                    kwargs["on_sample"](report, row)
                    rows.append(row)
            report, _, _ = simulated_playback(args, **{**kwargs, "on_sample": callback})
            report.update(status="not_reproduced", error={"classification": "checkpoint_failed"})
            return report, rows, 1
        report, rows, status, _, _ = self.execute(player=partial)
        self.assertEqual(status, 1)
        self.assertEqual(report["status"], "incomplete")
        self.assertEqual(len(rows), 16)
        self.assertEqual(report["summary"]["unmeasured_trials"], 12)

    def test_html_uses_verified_metadata_and_escapes_public_error_fields(self):
        report, _, _, _, _ = self.execute()
        video = report["videos"][0]
        video["verified_metadata"]["view"] = 321
        video["error"] = {"classification": "<script>alert(1)</script>"}
        campaign.write_campaign_html(self.args.output, report)
        page = (Path(self.args.output) / "index.html").read_text()
        self.assertIn("321 次", page)
        self.assertIn("&lt;script&gt;", page)
        self.assertNotIn("<script>alert(1)</script>", page)


if __name__ == "__main__":
    unittest.main()

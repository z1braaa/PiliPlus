"""Safety and comparability checks for the Python orchestration layer."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("vod_auto_test", Path(__file__).parents[1] / "vod_auto_test.py")
vod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(vod)


def fixture_manifest(quality=80):
    return {
        "video_urls": ["https://upos-sz-mirrorali.bilivideo.com/upgcxcode/1/2/3/3.m4s?sign=private-signature&deadline=9999999999"],
        "audio_urls": ["https://upos-sz-mirrorali.bilivideo.com/upgcxcode/1/2/4/4.m4s?sign=audio-secret"],
        "quality": quality, "codec": "avc1.640028", "width": 1920, "height": 1080,
        "audio_codec": "mp4a.40.2",
    }


class QualityAndPrivacyTests(unittest.TestCase):
    def test_anonymous_api_quality_is_selected_stream_not_requested_label(self):
        original = fixture_manifest(64)
        response = {"code": 0, "data": {"quality": 120, "dash": {
            "video": [{"id": 64, "codecs": original["codec"], "width": 1280, "height": 720,
                       "baseUrl": original["video_urls"][0]}],
            "audio": [{"baseUrl": original["audio_urls"][0], "codecs": "mp4a.40.2"}],
        }}}
        manifest = vod.manifest_from_playurl(response, 120)
        self.assertEqual((manifest["quality"], manifest["width"], manifest["height"]), (64, 1280, 720))
        quality = vod.quality_policy(manifest, 120, False)
        self.assertFalse(quality["benchmark_allowed"])
        self.assertFalse(quality["requested_quality_reproduced"])
        allowed = vod.quality_policy(manifest, 120, True)
        self.assertTrue(allowed["benchmark_allowed"])
        self.assertFalse(allowed["requested_quality_reproduced"])

    def test_manifest_must_supply_actual_codec_and_resolution(self):
        original = fixture_manifest()
        del original["width"]
        with self.assertRaises(vod.HarnessError) as caught:
            vod.normalize_manifest(original)
        self.assertEqual(caught.exception.classification, "invalid_metadata")

    def test_manifest_rejects_credentials_arbitrary_hosts_and_mixed_paths(self):
        for address in ("https://user:secret@upos-sz-mirrorali.bilivideo.com/upgcxcode/a.m4s",
                        "https://attacker.example/upgcxcode/a.m4s", "http://127.0.0.1/upgcxcode/a.m4s"):
            with self.subTest(address=address), self.assertRaises(vod.HarnessError):
                vod.validate_media_url(address)
        original = fixture_manifest()
        original["video_urls"].append(original["video_urls"][0].replace("/3/3.m4s", "/9/9.m4s"))
        with self.assertRaises(vod.HarnessError):
            vod.normalize_manifest(original)

    def test_url_and_unknown_exception_text_never_enter_public_report(self):
        secret = fixture_manifest()["video_urls"][0]
        error = vod.safe_error(RuntimeError("cookie=account-secret " + secret))
        public = vod.sanitize_native_result({"status": "failed", "error_category": "upstream_failure",
                                            "metrics": {"file_loaded_seconds": None, "log": secret},
                                            "checks": {"file_loaded": False}, "debug": secret, "error": secret})
        encoded = json.dumps({"error": error, "native": public})
        self.assertNotIn("private-signature", encoded)
        self.assertNotIn("account-secret", encoded)
        self.assertNotIn("https://", encoded)
        self.assertEqual(error["classification"], "unexpected_error")

    def test_quality_mismatch_generates_no_native_run_or_signed_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "private.json"
            manifest.write_text(json.dumps(fixture_manifest(64)), encoding="utf-8")
            args = vod.parser().parse_args(["playback", "--manifest", str(manifest), "--library", "/missing/libmpv",
                                           "--quality-code", "120"])
            with patch.object(vod, "base_report", return_value={"kind": "native_playback_comparison"}), \
                 patch.object(vod, "run_command") as native:
                report, rows, status = vod.playback(args)
            self.assertEqual(status, 1)
            self.assertEqual(rows, [])
            self.assertEqual(report["error"]["classification"], "requested_quality_not_reproduced")
            self.assertFalse(report["quality_check"]["requested_quality_reproduced"])
            native.assert_not_called()
            directory = Path(temporary) / "output"
            vod.write_report(directory, report, rows)
            self.assertNotIn("private-signature", (directory / "report.json").read_text())
            self.assertNotIn("audio-secret", (directory / "report.json").read_text())

    def test_hw_mode_changes_host_and_preserves_signed_resource(self):
        before = fixture_manifest()["video_urls"][0]
        after = vod.hw_url(before)
        self.assertEqual(vod.urlparse(after).hostname, "upos-sz-mirrorhw.bilivideo.com")
        self.assertEqual(vod.urlparse(before).path, vod.urlparse(after).path)
        self.assertEqual(vod.urlparse(before).query, vod.urlparse(after).query)


class StatisticsTests(unittest.TestCase):
    def test_mixed_baselines_are_rejected_instead_of_averaged(self):
        rows = [{"comparison_key": "one", "mode": "base-direct", "status": "measured"},
                {"comparison_key": "two", "mode": "parallel", "status": "measured"}]
        with self.assertRaises(vod.HarnessError) as caught:
            vod.summarize_samples(rows)
        self.assertEqual(caught.exception.classification, "mixed_comparison_baselines")

    def test_failures_and_unknown_metrics_are_not_zero_successes(self):
        rows = [{"comparison_key": "same", "mode": "parallel", "status": "measured", "file_loaded_seconds": 2},
                {"comparison_key": "same", "mode": "parallel", "status": "measured", "file_loaded_seconds": None},
                {"comparison_key": "same", "mode": "parallel", "status": "timeout", "file_loaded_seconds": 60}]
        result = vod.summarize_samples(rows)["parallel"]
        self.assertEqual(result["failures_or_timeouts"], 1)
        self.assertEqual(result["file_loaded_seconds"], {"samples": 1, "median": 2, "min": 2, "max": 2})
        self.assertNotIn("p95", json.dumps(result).lower())

    def test_actual_position_and_codec_change_comparison_identity(self):
        manifest = vod.normalize_manifest(fixture_manifest())
        args = vod.parser().parse_args(["playback", "--bvid", "BV1234567890", "--library", "/unused"])
        before = vod.comparison_key(manifest, args)
        args.start_seconds = 70
        self.assertNotEqual(before, vod.comparison_key(manifest, args))
        args.start_seconds = 0
        manifest["codec"] = "hev1.1.6.L120.90"
        self.assertNotEqual(before, vod.comparison_key(manifest, args))
        manifest = vod.normalize_manifest(fixture_manifest())
        args.runtime_artifacts = {"libmpv_sha256": "same", "proxy_sha256": "p0"}
        p0_key = vod.comparison_key(manifest, args)
        args.runtime_artifacts["proxy_sha256"] = "different_transport"
        changed_key = vod.comparison_key(manifest, args)
        self.assertNotEqual(p0_key, changed_key)
        with self.assertRaises(vod.HarnessError):
            vod.summarize_samples([
                {"comparison_key": p0_key, "mode": "parallel", "status": "measured"},
                {"comparison_key": changed_key, "mode": "parallel", "status": "measured"},
            ])

    def test_trial_and_duration_limits_are_real_parser_constraints(self):
        with self.assertRaises(Exception):
            vod.parse_order(",".join(["parallel"] * 7))
        with self.assertRaises(Exception):
            vod.bounded_number(float, 5, 180)("nan")
        self.assertEqual(vod.parse_order("hw-direct,parallel,parallel,hw-direct"),
                         ("hw-direct", "parallel", "parallel", "hw-direct"))
        with self.assertRaises(SystemExit), patch("sys.stderr"):
            vod.parser().parse_args(["playback", "--bvid", "BV1234567890", "--library", "/unused", "--chunk-kib", "8192"])


class RegressionTests(unittest.TestCase):
    def test_regression_machine_events_exclude_hidden_and_skipped_tests(self):
        events = [
            {"type": "testStart", "test": {"id": 0, "hidden": True}},
            {"type": "testDone", "testID": 0, "result": "success"},
            {"type": "testStart", "test": {"id": 1, "hidden": False, "suiteID": []}},
            {"type": "testDone", "testID": 1, "result": "success"},
            {"type": "testStart", "test": {"id": 2, "hidden": False}},
            {"type": "testDone", "testID": 2, "result": "success", "skipped": True},
            {"type": "testStart", "test": {"id": 3, "hidden": False}},
            {"type": "testDone", "testID": 3, "result": "error"},
        ]
        result = vod.parse_regression_output("flutter", "\n".join(map(json.dumps, events)))
        self.assertEqual((result["passed"], result["failed"], result["skipped"]), (1, 1, 1))
        result = vod.parse_regression_output("dart", "PASS something\n13/14 checks passed.\n")
        self.assertEqual((result["passed"], result["failed"]), (13, 1))
        self.assertFalse(vod.parse_regression_output("dart", "no summary")["count_verified"])

    def test_native_whitelist_preserves_unknown_as_none(self):
        result = vod.sanitize_native_result({"status": "passed", "metrics": {"cache_pause_count": None,
                                               "cache_pause_seconds": None, "initial_progress_seconds": 0.51},
                                               "checks": {"positive_time_progress": True}})
        self.assertIsNone(result["cache_pause_count"])
        self.assertEqual(result["initial_progress_seconds"], 0.51)
        self.assertEqual(result["native_status"], "passed")

    def test_segment_cache_metrics_preserve_null_without_copying_unknown_data(self):
        result = vod.sanitize_native_result({"status": "passed", "metrics": {}, "checks": {},
                                            "segments": {"startup": {"cache_pause_count": None, "cache_pause_seconds": None,
                                                                        "private_log": "sign=private"},
                                                         "seek": {"cache_pause_count": 1, "cache_pause_seconds": 0.2}}})
        self.assertIsNone(result["startup_cache_pause_count"])
        self.assertIsNone(result["startup_cache_pause_seconds"])
        self.assertEqual(result["seek_cache_pause_count"], 1)
        self.assertEqual(result["seek_cache_pause_seconds"], 0.2)
        self.assertNotIn("sign=", json.dumps(result))

    def test_native_success_requires_decoded_dual_tracks_start_and_seek_checks(self):
        good = {"native_status": "passed", "file_loaded": True, "both_tracks_present": True,
                "both_tracks_decoded": True, "positive_time_progress": True, "start_position_verified": True,
                "seek_position_verified": True, "seek_progress_seconds": 0.5}
        self.assertTrue(vod.native_measurement_succeeded(good, 0, False))
        self.assertTrue(vod.native_measurement_succeeded(good, 0, True))
        for missing in ("file_loaded", "both_tracks_present", "both_tracks_decoded", "start_position_verified"):
            altered = {key: value for key, value in good.items() if key != missing}
            with self.subTest(missing=missing):
                self.assertFalse(vod.native_measurement_succeeded(altered, 0, False))
        for progress in (None, -1, True, float("nan"), float("inf")):
            self.assertFalse(vod.native_measurement_succeeded({**good, "seek_progress_seconds": progress}, 0, True))
        self.assertFalse(vod.native_measurement_succeeded({**good, "seek_position_verified": False}, 0, True))

    def test_flutter_mixed_json_output_does_not_crash_or_count_unknown_events(self):
        # Flutter output can contain JSON-looking scalar/null log lines.
        events = [None, [], "startup", 12, {"type": "testStart", "test": None},
                  {"type": "testStart", "test": "not a test"},
                  {"type": "testDone", "testID": [], "result": "success"},
                  {"type": "testDone", "testID": 999, "result": "success"},
                  {"type": "testStart", "test": {"id": 1, "hidden": False}},
                  {"type": "testDone", "testID": 1, "result": "success", "skipped": False}]
        counts = vod.parse_regression_output("flutter", "\n".join(map(json.dumps, events)))
        self.assertEqual(counts, {"passed": 1, "failed": 0, "skipped": 0, "count_verified": True,
                                  "framework_events": 0, "framework_failures": 0})

    def test_real_flutter_failed_loader_is_not_a_failed_user_assertion(self):
        # Recorded from Flutter 3.47.5 with a deliberately invalid method call.
        # Unlike successful loading, its testDone has hidden=false.
        path = "/tmp/compiler-failure-fixture_test.dart"
        events = [
            {"type": "suite", "suite": {"id": 0, "platform": "vm", "path": path}},
            {"type": "testStart", "test": {"id": 1, "name": "loading " + path,
                 "suiteID": 0, "groupIDs": [], "line": None, "url": None}},
            {"type": "testDone", "testID": 1, "result": "error", "skipped": False, "hidden": False},
            {"type": "testDone", "testID": 1, "result": "error", "skipped": False, "hidden": False},
            {"type": "done", "success": False},
        ]
        counts = vod.parse_regression_output("flutter", "\n".join(map(json.dumps, events)))
        self.assertEqual(counts, {"passed": 0, "failed": 0, "skipped": 0,
            "count_verified": False, "framework_events": 1, "framework_failures": 1})
        events.extend([
            {"type": "testStart", "test": {"id": 2, "name": "loading " + path,
                 "suiteID": 0, "groupIDs": [2], "line": 7, "url": "file:///tmp/user_test.dart"}},
            {"type": "testDone", "testID": 2, "result": "error", "hidden": False},
        ])
        self.assertEqual(vod.parse_regression_output("flutter", "\n".join(map(json.dumps, events)))["failed"], 1)

    def test_real_flutter_done_hidden_marks_loading_and_suite_hooks(self):
        # Reduced real --machine output: hidden is attached to testDone.
        events = [
            {"type": "suite", "suite": {"id": 0, "platform": "vm", "path": "fixture_test.dart"}},
            {"type": "testStart", "test": {"id": 1, "name": "loading fixture_test.dart", "suiteID": 0,
                                             "groupIDs": [], "line": None, "url": None}},
            {"type": "testDone", "testID": 1, "result": "success", "skipped": False, "hidden": True},
            {"type": "testStart", "test": {"id": 3, "name": "(setUpAll)", "suiteID": 0, "groupIDs": [2]}},
            {"type": "testDone", "testID": 3, "result": "success", "skipped": False, "hidden": True},
            {"type": "testStart", "test": {"id": 4, "name": "real assertion", "suiteID": 0, "groupIDs": [2]}},
            {"type": "testDone", "testID": 4, "result": "success", "skipped": False, "hidden": False},
            {"type": "testStart", "test": {"id": 5, "name": "(tearDownAll)", "suiteID": 0, "groupIDs": [2]}},
            {"type": "testDone", "testID": 5, "result": "error", "skipped": False, "hidden": True},
        ]
        counts = vod.parse_regression_output("flutter", "\n".join(map(json.dumps, events)))
        self.assertEqual(counts, {"passed": 1, "failed": 0, "skipped": 0, "count_verified": True,
                                  "framework_events": 3, "framework_failures": 1})


class OrchestrationTests(unittest.TestCase):
    def test_fixed_sources_reach_private_pipes_and_bridges_are_closed(self):
        inputs, bridges = [], []
        class FakeBridge:
            def __init__(self, dart, payload, timeout):
                self.payload = payload
                self.closed = False
                self.urls = {"video_url": "http://127.0.0.1:19999/video-token",
                             "audio_url": "http://127.0.0.1:19999/audio-token", "candidate_count": 8}
                bridges.append(self)
            def close(self):
                self.closed = True
        def fake_native(command, *, timeout, payload=None):
            self.assertNotIn("private-signature", " ".join(command))
            inputs.append(json.loads(payload))
            network_timeout = command[command.index("--network-timeout-seconds") + 1]
            self.assertEqual(network_timeout, "60" if "127.0.0.1" in inputs[-1]["video_url"] else "5")
            return {"exit_code": 0, "timed_out": False, "elapsed_seconds": 0.1,
                    "stdout": json.dumps({"status": "passed", "metrics": {"file_loaded_seconds": 0.5,
                                            "initial_progress_seconds": 0.8, "cache_pause_count": 0,
                                            "cache_pause_seconds": 0},
                                           "checks": {"file_loaded": True, "both_tracks_present": True,
                                                      "both_tracks_decoded": True, "positive_time_progress": True,
                                                      "start_position_verified": True}})}
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / "tool").mkdir()
            (repo / "tool/native_mpv_probe.py").touch()
            for relative in ("tool/cdn_benchmark_bridge.dart", "lib/http/cdn_playback_proxy.dart",
                             "lib/http/cdn_origin_policy.dart", "lib/utils/cdn_startup_trace.dart"):
                source = repo / relative
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text("// fixture " + source.name, encoding="utf-8")
            library = repo / "libmpv.dylib"
            library.touch()
            manifest = repo / "private.json"
            manifest.write_text(json.dumps(fixture_manifest()))
            args = vod.parser().parse_args(["playback", "--manifest", str(manifest), "--library", str(library),
                                           "--order", "hw-direct,parallel,base-direct,parallel"])
            with patch.object(vod, "REPO", repo), patch.object(vod, "base_report", return_value={}), \
                 patch.object(vod, "resolve_executable", return_value="dart"), \
                 patch.object(vod, "run_command", side_effect=fake_native), patch.object(vod, "Bridge", FakeBridge):
                report, rows, status = vod.playback(args)
            self.assertEqual(status, 0)
            self.assertEqual(len(rows), 4)
            self.assertEqual(len({row["comparison_key"] for row in rows}), 1)
            self.assertEqual(inputs[2]["video_url"], fixture_manifest()["video_urls"][0])
            self.assertEqual(vod.urlparse(inputs[0]["video_url"]).hostname, "upos-sz-mirrorhw.bilivideo.com")
            self.assertEqual(bridges[0].payload["video_urls"], fixture_manifest()["video_urls"])
            self.assertTrue(all(bridge.closed for bridge in bridges))
            encoded = json.dumps(report)
            self.assertNotIn("private-signature", encoded)
            self.assertNotIn("audio-secret", encoded)
            self.assertNotIn("http://", encoded)
            self.assertEqual(len(report["runtime_artifacts"]["orchestrator_sha256"]), 64)
            self.assertEqual(report["runtime_artifacts"]["proxy_sha256"],
                             vod.sha256_file(repo / "lib/http/cdn_playback_proxy.dart"))


class ProcessSafetyTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix", "detached process and pipe fixture requires POSIX")
    def test_timeout_does_not_drain_a_pipe_held_by_detached_descendant(self):
        with tempfile.TemporaryDirectory() as temporary:
            pid_file = Path(temporary) / "detached-pid.txt"
            code = (
                "import pathlib,subprocess,sys,time;"
                "p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(1.5)'],start_new_session=True);"
                "pathlib.Path(sys.argv[1]).write_text(str(p.pid));time.sleep(2)"
            )
            began = time.monotonic()
            try:
                result = vod.run_command([sys.executable, "-c", code, str(pid_file)], timeout=0.25)
                self.assertTrue(result["timed_out"])
                self.assertEqual(result["stdout"], "")
                self.assertLess(time.monotonic() - began, 1.0, "deadline must not wait for detached output writer")
            finally:
                if pid_file.exists():
                    try:
                        os.kill(int(pid_file.read_text()), vod.signal.SIGTERM)
                    except ProcessLookupError:
                        pass

    @unittest.skipUnless(os.name == "posix", "nonblocking bridge fixture requires POSIX")
    def test_large_bridge_payload_cannot_block_before_handshake_deadline(self):
        observed = []
        real_launch = vod.launch
        def nonreading_bridge(*_args, **kwargs):
            process = real_launch([sys.executable, "-c", "import time;time.sleep(1.5)"], **kwargs)
            observed.append(process)
            return process
        payload = {"video_urls": ["x" * 16_384] * 4, "audio_urls": ["y" * 16_384] * 4}
        began = time.monotonic()
        with patch.object(vod, "launch", side_effect=nonreading_bridge):
            with self.assertRaises(vod.HarnessError) as caught:
                vod.Bridge("unused", payload, timeout=0.15)
        self.assertEqual(caught.exception.classification, "bridge_timeout")
        self.assertLess(time.monotonic() - began, 1.0)
        self.assertIsNotNone(observed[0].poll())
        self.assertTrue(observed[0].stdin.closed)
        self.assertTrue(observed[0].stdout.closed)

    @unittest.skipUnless(os.name == "posix", "nonblocking bridge fixture requires POSIX")
    def test_bridge_transmits_complete_large_private_payload(self):
        real_launch = vod.launch
        child = (
            "import json,sys;data=json.loads(sys.stdin.readline());"
            "assert len(data['video_urls'][0])==16384;"
            "print(json.dumps({'video_url':'http://127.0.0.1:1234/video','audio_url':'http://127.0.0.1:1234/audio','candidate_count':8}),flush=True);"
            "sys.stdin.read()"
        )
        def reading_bridge(*_args, **kwargs):
            return real_launch([sys.executable, "-c", child], **kwargs)
        payload = {"video_urls": ["x" * 16_384] * 4, "audio_urls": ["y" * 16_384] * 4}
        with patch.object(vod, "launch", side_effect=reading_bridge):
            bridge = vod.Bridge("unused", payload, timeout=1)
        try:
            self.assertEqual(bridge.urls["candidate_count"], 8)
            self.assertIsNone(bridge.process.poll())
        finally:
            bridge.close()

    def test_timeout_is_bounded_and_parent_is_reaped(self):
        observed = []
        real_launch = vod.launch
        def capture(*args, **kwargs):
            process = real_launch(*args, **kwargs)
            observed.append(process)
            return process
        began = time.monotonic()
        with patch.object(vod, "launch", side_effect=capture):
            result = vod.run_command([sys.executable, "-c", "import time;time.sleep(30)"], timeout=0.15)
        self.assertTrue(result["timed_out"])
        self.assertIsNotNone(observed[0].poll())
        self.assertLess(time.monotonic() - began, 4)

    @unittest.skipUnless(os.name == "posix", "process-group assertion requires POSIX")
    def test_timeout_stops_a_spawned_descendant(self):
        with tempfile.TemporaryDirectory() as temporary:
            pid_file = Path(temporary) / "pid.txt"
            code = (
                "import pathlib,subprocess,sys,time;"
                "p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)']);"
                "pathlib.Path(sys.argv[1]).write_text(str(p.pid));time.sleep(30)"
            )
            result = vod.run_command([sys.executable, "-c", code, str(pid_file)], timeout=0.5)
            self.assertTrue(result["timed_out"])
            pid = int(pid_file.read_text())
            state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
            self.assertTrue(not state or state.startswith("Z"), "descendant must not remain running")

    def test_bridge_handshake_timeout_closes_child_and_pipe(self):
        observed = []
        real_launch = vod.launch
        def sleeping_bridge(*_args, **kwargs):
            process = real_launch([sys.executable, "-c", "import sys,time;sys.stdin.readline();time.sleep(30)"], **kwargs)
            observed.append(process)
            return process
        with patch.object(vod, "launch", side_effect=sleeping_bridge):
            with self.assertRaises(vod.HarnessError) as caught:
                vod.Bridge("unused", fixture_manifest(), timeout=0.15)
        self.assertEqual(caught.exception.classification, "bridge_timeout")
        self.assertIsNotNone(observed[0].poll())
        self.assertTrue(observed[0].stdin.closed)
        self.assertTrue(observed[0].stdout.closed)


if __name__ == "__main__":
    unittest.main()

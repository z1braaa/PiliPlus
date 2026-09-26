"""State and safety checks for the native probe; no network / libmpv required."""

import importlib.util
import functools
import http.server
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
import wave


MODULE = Path(__file__).resolve().parents[1] / "native_mpv_probe.py"
SPEC = importlib.util.spec_from_file_location("native_mpv_probe", MODULE)
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class NativeProbeTests(unittest.TestCase):
    def test_cache_unknown_is_not_zero(self):
        observation = probe.CacheObservation()
        observation.update(None, 1)
        self.assertEqual(observation.snapshot(5), {
            "cache_pause_count": None, "cache_pause_seconds": None,
        })

    def test_observed_no_cache_pause_is_zero(self):
        observation = probe.CacheObservation()
        observation.update(False, 1)
        self.assertEqual(observation.snapshot(5), {
            "cache_pause_count": 0, "cache_pause_seconds": 0.0,
        })

    def test_cache_transitions_and_open_interval(self):
        observation = probe.CacheObservation()
        for value, timestamp in [(False, 0), (True, 1), (True, 2), (False, 4), (True, 6)]:
            observation.update(value, timestamp)
        self.assertEqual(observation.snapshot(8), {
            "cache_pause_count": 2, "cache_pause_seconds": 5.0,
        })
        observation.update(False, 9)
        self.assertEqual(observation.snapshot(10)["cache_pause_seconds"], 6.0)

    def test_edl_uses_byte_lengths_and_preserves_signed_queries(self):
        video = "https://cdn.example/片段?sign=secret;part=1"
        audio = "http://127.0.0.1:1234/audio?token=private"
        result = probe.build_edl(video, audio)
        self.assertIn(f"%{len(video.encode())}%{video};", result)
        self.assertIn(f"%{len(audio.encode())}%{audio}", result)

    def test_start_is_actual_loadfile_option_for_both_versions(self):
        self.assertEqual(probe.loadfile_arguments("edl", 70, "mpv 0.37.0"),
                         ["loadfile", "edl", "replace", "start=70.000000"])
        self.assertEqual(probe.loadfile_arguments("edl", 70, "mpv 0.40.0-dev"),
                         ["loadfile", "edl", "replace", "-1", "start=70.000000"])
        with self.assertRaisesRegex(probe.ProbeFailure, "mpv_version_unknown"):
            probe.loadfile_arguments("edl", 0, None)

    def test_validation_rejects_missing_track_or_unsafe_url(self):
        for value in [None, {}, {"video_url": "file:///private", "audio_url": "https://cdn.example/a"},
                      {"video_url": "https://user:private@cdn.example/v", "audio_url": "https://cdn.example/a"}]:
            with self.assertRaisesRegex(probe.ProbeFailure, "invalid_input"):
                probe.validate_payload(value)

    def test_cli_missing_library_is_classified_and_redacted(self):
        secret = "signed-private-secret"
        payload = {"video_url": f"https://cdn.example/v?sign={secret}",
                   "audio_url": f"https://cdn.example/a?sign={secret}"}
        result = subprocess.run(
            [sys.executable, str(MODULE), "--library", "/nonexistent-library"],
            input=json.dumps(payload) + "\n", text=True, capture_output=True, timeout=5,
        )
        self.assertEqual(result.returncode, 2)
        report = json.loads(result.stdout)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["error_category"], "library_not_found")
        self.assertNotIn(secret, result.stdout + result.stderr)
        self.assertNotIn("https://cdn.example", result.stdout + result.stderr)
        self.assertIsNone(report["metrics"]["cache_pause_count"])

    def test_invalid_json_emits_one_safe_report(self):
        result = subprocess.run(
            [sys.executable, str(MODULE), "--library", "/nonexistent-library"],
            input="private-signed-url-not-json\n", text=True, capture_output=True, timeout=5,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["error_category"], "invalid_input")
        self.assertNotIn("private-signed", result.stdout + result.stderr)

    def test_transport_timeout_is_recorded_and_bounded(self):
        payload = json.dumps({"video_url": "https://cdn.example/v", "audio_url": "https://cdn.example/a"}) + "\n"
        for seconds in (5, 60):
            result = subprocess.run(
                [sys.executable, str(MODULE), "--library", "/nonexistent-library",
                 "--network-timeout-seconds", str(seconds)],
                input=payload, text=True, capture_output=True, timeout=5,
            )
            self.assertEqual(json.loads(result.stdout)["conditions"]["network_timeout_seconds"], seconds)
        for seconds in (0, 61):
            result = subprocess.run(
                [sys.executable, str(MODULE), "--library", "/nonexistent-library",
                 "--network-timeout-seconds", str(seconds)],
                input=payload, text=True, capture_output=True, timeout=5,
            )
            self.assertEqual(result.returncode, 2)
            self.assertEqual(json.loads(result.stdout)["error_category"], "invalid_network_timeout")


def write_media_fixture(directory):
    """Small seekable uncompressed AVI + PCM WAV, generated without packages."""
    pack = lambda fmt, *values: struct.pack("<" + fmt, *values)

    def chunk(tag, data):
        return tag + pack("I", len(data)) + data + (b"\0" if len(data) % 2 else b"")

    def group(tag, data):
        return chunk(b"LIST", tag + data)

    width, height, fps, frame_count = 32, 24, 25, 500
    frame_bytes = width * height * 3
    avih = pack("IIIIIIIIII", 40000, frame_bytes * fps, 0, 0x10, frame_count,
                0, 1, frame_bytes, width, height) + pack("IIII", 0, 0, 0, 0)
    strh = pack("4s4sIHHIIIIIIIIhhhh", b"vids", b"DIB ", 0, 0, 0,
                0, 1, fps, 0, frame_count, frame_bytes, 0xffffffff, 0,
                0, 0, width, height)
    strf = pack("IiiHHIIiiII", 40, width, height, 1, 24, 0, frame_bytes, 0, 0, 0, 0)
    header = group(b"hdrl", chunk(b"avih", avih) +
                   group(b"strl", chunk(b"strh", strh) + chunk(b"strf", strf)))
    frames, indices, offset = [], [], 4
    for frame in range(frame_count):
        data = bytes([frame % 200, 80, 160]) * (width * height)
        packed = chunk(b"00db", data)
        frames.append(packed)
        indices.append(pack("4sIII", b"00db", 0x10, offset, len(data)))
        offset += len(packed)
    body = b"AVI " + header + group(b"movi", b"".join(frames)) + chunk(b"idx1", b"".join(indices))
    (directory / "video.avi").write_bytes(chunk(b"RIFF", body))
    with wave.open(str(directory / "audio.wav"), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(22050)
        audio.writeframes(bytes(22050 * 20 * 2))


@unittest.skipUnless(os.environ.get("PILIPLUS_MPV_LIBRARY"), "set PILIPLUS_MPV_LIBRARY for bundled native integration")
class NativeFixtureTests(unittest.TestCase):
    def test_real_dual_track_nonzero_start_and_absolute_seek(self):
        class QuietHandler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args):
                pass

        with tempfile.TemporaryDirectory(prefix="piliplus-mpv-fixture-") as temporary:
            write_media_fixture(Path(temporary))
            server = http.server.ThreadingHTTPServer(
                ("127.0.0.1", 0), functools.partial(QuietHandler, directory=temporary)
            )
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f"http://127.0.0.1:{server.server_port}"
            try:
                result = subprocess.run(
                    [sys.executable, str(MODULE), "--library", os.environ["PILIPLUS_MPV_LIBRARY"],
                     "--start-seconds", "2", "--duration-seconds", "2", "--seek-seconds", "8",
                     "--timeout-seconds", "15"],
                    input=json.dumps({"video_url": base + "/video.avi", "audio_url": base + "/audio.wav"}) + "\n",
                    capture_output=True, text=True, timeout=22,
                )
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(result.stderr, "")
            report = json.loads(result.stdout)
            self.assertEqual(report["status"], "passed")
            self.assertTrue(all(report["checks"].values()))
            self.assertAlmostEqual(report["metrics"]["seek_position_seconds"], 8, delta=1)
            self.assertGreater(report["metrics"]["playback_progress_seconds"], 1)
            self.assertGreater(report["metrics"]["seek_progress_seconds"], 0.5)
            self.assertNotIn(base, result.stdout)


if __name__ == "__main__":
    unittest.main()

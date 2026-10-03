"""Audio-only evidence and redaction checks; no account, network or native library."""

import json
from pathlib import Path
import subprocess
import sys
import unittest

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
import live_native_playback_probe as probe


class FakePlayer:
    def __init__(self, position=2, buffering=False, tracks=("audio",), mute=True):
        self.properties = {
            "time-pos": position, "paused-for-cache": buffering,
            "pause": False, "audio-params/samplerate": 48000,
            "track-list/count": len(tracks), "mute": mute, "volume": 0,
        }
        self.types = {f"track-list/{i}/type": value for i, value in enumerate(tracks)}

    def number(self, key, *args):
        return self.properties.get(key)

    def string(self, key):
        return self.types.get(key)

    def tracks_decoded(self):
        return True


class LiveAudioProbeTests(unittest.TestCase):
    def test_only_audio_requires_decoding_silence_and_progress(self):
        sample, position = probe.snapshot(FakePlayer(), 1, True)
        self.assertTrue(sample["playing"])
        self.assertTrue(sample["audio_decoded"])
        self.assertTrue(sample["silent_output_confirmed"])
        self.assertFalse(sample["video_track_present"])
        self.assertEqual(position, 2)
        for player, previous in [
            (FakePlayer(tracks=("audio", "video")), 1),
            (FakePlayer(buffering=True), 1),
            (FakePlayer(buffering=None), 1),
            (FakePlayer(mute=False), 1),
            (FakePlayer(position=1), 1),
            (FakePlayer(), None),
        ]:
            with self.subTest(properties=player.properties, previous=previous):
                self.assertFalse(probe.snapshot(player, previous, True)[0]["playing"])

    def test_missing_decode_is_not_playback(self):
        player = FakePlayer()
        player.properties["audio-params/samplerate"] = None
        self.assertFalse(probe.snapshot(player, 1, True)[0]["playing"])

    def test_cli_never_echoes_private_input_or_library_path(self):
        secret = "do-not-print-private-value"
        for payload in [
            json.dumps({"live_url": f"https://cdn.example/audio?sign={secret}"}),
            json.dumps({"live_url": f"file:///private/{secret}"}),
            secret,
        ]:
            result = subprocess.run(
                [sys.executable, str(TOOL / "live_native_playback_probe.py"),
                 "--library", f"/nonexistent/{secret}", "--audio-only",
                 "--duration-seconds", "2"],
                input=payload + "\n", text=True, capture_output=True, timeout=5,
            )
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stderr, "")
            report = json.loads(result.stdout)
            self.assertFalse(report["playing"])
            self.assertIn(report["error_category"], {"library_not_found", "invalid_input"})
            self.assertNotIn(secret, result.stdout + result.stderr)
            self.assertNotIn("cdn.example", result.stdout + result.stderr)

    def test_duration_bound_and_argument_errors_are_redacted(self):
        for duration in ["0", "1201", "nan", "inf", "private-rejected-value"]:
            result = subprocess.run(
                [sys.executable, str(TOOL / "live_native_playback_probe.py"),
                 "--library", "/nonexistent", "--audio-only",
                 "--duration-seconds", duration],
                input="{}\n", text=True, capture_output=True, timeout=5,
            )
            self.assertEqual(result.returncode, 2)
            self.assertEqual(json.loads(result.stdout)["error_category"], "invalid_arguments")
            self.assertEqual(result.stderr, "")
            self.assertNotIn("private-rejected-value", result.stdout)


if __name__ == "__main__":
    unittest.main()

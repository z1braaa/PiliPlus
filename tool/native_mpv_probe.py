#!/usr/bin/env python3
"""Headless VOD transport probe using the app's bundled libmpv.

Read one JSON object containing video_url/audio_url from stdin. Never write
signed URLs, native log messages, exception text, or paths to the report.
Position and playback-restart measurements are proxies, not visible first
frame / audible first sound measurements. No app configuration is read/written.
"""

from __future__ import annotations

import argparse
import contextlib
import ctypes
import json
import math
import os
from pathlib import Path
import re
import sys
import time
from urllib.parse import urlsplit


MPV_FORMAT_FLAG = 3
MPV_FORMAT_INT64 = 4
MPV_FORMAT_DOUBLE = 5
MPV_EVENT_SHUTDOWN = 1
MPV_EVENT_END_FILE = 7
MPV_EVENT_FILE_LOADED = 8
MPV_EVENT_PLAYBACK_RESTART = 21
MPV_EVENT_PROPERTY_CHANGE = 22
APP_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.2 Safari/605.1.15"
)
APP_OPTIONS = {
    "config": "no",
    "load-scripts": "no",
    "ytdl": "no",
    "terminal": "no",
    "msg-level": "all=no",
    "vo": "null",
    "ao": "null",
    "hwdec": "no",
    "volume": "0",
    "vid": "auto",
    "aid": "auto",
    "pause": "no",
    "idle": "yes",
    "network-timeout": "5",
    "user-agent": APP_USER_AGENT,
    "referrer": "https://www.bilibili.com/",
    # Match Pref.initBuffer defaults at 1x speed, rather than a tiny smoke cache.
    "cache": "yes",
    "cache-secs": "16.000",
    "demuxer-hysteresis-secs": "10.667",
    "demuxer-max-bytes": "4194304",
    "demuxer-max-back-bytes": "4194304",
}


class ProbeFailure(Exception):
    """The message is a fixed safe classification, never a native message."""


class MpvEvent(ctypes.Structure):
    _fields_ = [
        ("event_id", ctypes.c_int),
        ("error", ctypes.c_int),
        ("reply_userdata", ctypes.c_uint64),
        ("data", ctypes.c_void_p),
    ]


class MpvProperty(ctypes.Structure):
    _fields_ = [
        ("name", ctypes.c_char_p),
        ("format", ctypes.c_int),
        ("data", ctypes.c_void_p),
    ]


class MpvEndFile(ctypes.Structure):
    _fields_ = [("reason", ctypes.c_int), ("error", ctypes.c_int)]


def rounded(value: float | None) -> float | None:
    return round(value, 4) if value is not None else None


class CacheObservation:
    """Count observed paused-for-cache transitions; missing is never zero."""

    def __init__(self) -> None:
        self.known = False
        self.active_since: float | None = None
        self.count = 0
        self.seconds = 0.0

    def update(self, value: bool | None, now: float) -> None:
        if value is None:
            return
        self.known = True
        if value and self.active_since is None:
            self.count += 1
            self.active_since = now
        elif not value and self.active_since is not None:
            self.seconds += max(0.0, now - self.active_since)
            self.active_since = None

    def snapshot(self, now: float) -> dict:
        if not self.known:
            return {"cache_pause_count": None, "cache_pause_seconds": None}
        total = self.seconds
        if self.active_since is not None:
            total += max(0.0, now - self.active_since)
        return {"cache_pause_count": self.count, "cache_pause_seconds": rounded(total)}


def build_edl(video_url: str, audio_url: str) -> str:
    # Length-prefixed names preserve semicolons and signed query parameters.
    return (
        "edl://!no_chapters;"
        f"%{len(video_url.encode('utf-8'))}%{video_url};"
        "!new_stream;!no_chapters;"
        f"%{len(audio_url.encode('utf-8'))}%{audio_url}"
    )


def loadfile_arguments(edl: str, start_seconds: float, version: str | None) -> list[str]:
    match = re.search(r"\bmpv\s+v?(\d+)\.(\d+)", version or "")
    if not match:
        raise ProbeFailure("mpv_version_unknown")
    release = (int(match.group(1)), int(match.group(2)))
    # mpv 0.38 added the playlist insertion index before the options map.
    arguments = ["loadfile", edl, "replace"]
    if release >= (0, 38):
        arguments.append("-1")
    arguments.append(f"start={start_seconds:.6f}")
    return arguments


def validate_payload(payload: object) -> tuple[str, str]:
    if not isinstance(payload, dict):
        raise ProbeFailure("invalid_input")
    urls = []
    for key in ("video_url", "audio_url"):
        value = payload.get(key)
        if not isinstance(value, str) or not value or len(value) > 32768:
            raise ProbeFailure("invalid_input")
        if any(ord(character) < 32 for character in value):
            raise ProbeFailure("invalid_input")
        try:
            parsed = urlsplit(value)
            valid = parsed.scheme in ("http", "https") and bool(parsed.hostname)
            if parsed.username is not None or parsed.password is not None:
                valid = False
        except ValueError:
            valid = False
        if not valid:
            raise ProbeFailure("invalid_input")
        urls.append(value)
    return urls[0], urls[1]


@contextlib.contextmanager
def suppress_native_output():
    """libmpv/FFmpeg stderr must not leak signed URLs even on codec errors."""
    sys.stdout.flush()
    sys.stderr.flush()
    saved = [os.dup(1), os.dup(2)]
    null_fd = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(null_fd, 1)
        os.dup2(null_fd, 2)
        yield
    finally:
        sys.stdout.flush()
        sys.stderr.flush()
        for target, original in zip((1, 2), saved):
            os.dup2(original, target)
            os.close(original)
        os.close(null_fd)


def load_library(library_path: Path):
    if not library_path.is_file():
        raise ProbeFailure("library_not_found")
    loaded = []
    # Frameworks use @rpath dependencies which a Python executable does not
    # inherit from PiliPlus.app. Load only sibling bundled frameworks globally.
    frameworks = next(
        (parent for parent in library_path.resolve().parents if parent.name == "Frameworks"),
        None,
    )
    if frameworks is not None:
        names = [
            "Ass", "Avcodec", "Avfilter", "Avformat", "Avutil", "Dav1d",
            "Freetype", "Fribidi", "Harfbuzz", "Mbedcrypto", "Mbedtls",
            "Mbedx509", "Png16", "Swresample", "Swscale", "Uchardet", "Xml2",
        ]
        candidates = [frameworks / f"{name}.framework/Versions/A/{name}" for name in names]
        pending = [candidate for candidate in candidates if candidate.is_file()]
        for _ in range(len(pending) + 1):
            progressed = False
            for candidate in pending[:]:
                try:
                    loaded.append(ctypes.CDLL(str(candidate), mode=ctypes.RTLD_GLOBAL))
                    pending.remove(candidate)
                    progressed = True
                except OSError:
                    pass
            if not pending or not progressed:
                break
    try:
        lib = ctypes.CDLL(str(library_path), mode=ctypes.RTLD_GLOBAL)
    except OSError:
        raise ProbeFailure("library_load_failed") from None
    loaded.append(lib)
    return lib, loaded


class NativePlayer:
    def __init__(self, lib):
        self.lib = lib
        lib.mpv_create.argtypes = []
        lib.mpv_create.restype = ctypes.c_void_p
        lib.mpv_initialize.argtypes = [ctypes.c_void_p]
        lib.mpv_initialize.restype = ctypes.c_int
        lib.mpv_set_option_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
        lib.mpv_set_option_string.restype = ctypes.c_int
        lib.mpv_command.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p)]
        lib.mpv_command.restype = ctypes.c_int
        lib.mpv_wait_event.argtypes = [ctypes.c_void_p, ctypes.c_double]
        lib.mpv_wait_event.restype = ctypes.POINTER(MpvEvent)
        lib.mpv_get_property.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
        lib.mpv_get_property.restype = ctypes.c_int
        lib.mpv_get_property_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        lib.mpv_get_property_string.restype = ctypes.c_void_p
        lib.mpv_observe_property.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_int]
        lib.mpv_observe_property.restype = ctypes.c_int
        lib.mpv_free.argtypes = [ctypes.c_void_p]
        lib.mpv_free.restype = None
        lib.mpv_terminate_destroy.argtypes = [ctypes.c_void_p]
        lib.mpv_terminate_destroy.restype = None
        self.handle = lib.mpv_create()
        if not self.handle:
            raise ProbeFailure("player_create_failed")

    def initialize(self, network_timeout_seconds: float = 5.0,
                   buffer_seconds: float = 16.0, buffer_mib: float = 4.0) -> None:
        options = dict(APP_OPTIONS)
        options["network-timeout"] = f"{network_timeout_seconds:.6f}"
        options["cache-secs"] = f"{buffer_seconds:.6f}"
        options["demuxer-hysteresis-secs"] = f"{buffer_seconds * 2 / 3:.6f}"
        options["demuxer-max-bytes"] = str(round(buffer_mib * 1048576))
        options["demuxer-max-back-bytes"] = str(round(buffer_mib * 1048576))
        for name, value in options.items():
            result = self.lib.mpv_set_option_string(self.handle, name.encode(), value.encode())
            # Bundled mobile-style builds compile Lua/JavaScript support out;
            # their scripting toggles are consequently absent (option-not-found).
            if name in ("load-scripts", "ytdl") and result == -5:
                continue
            if result < 0:
                raise ProbeFailure("player_option_rejected")
        if self.lib.mpv_initialize(self.handle) < 0:
            raise ProbeFailure("player_initialize_failed")
        self.lib.mpv_observe_property(self.handle, 1, b"paused-for-cache", MPV_FORMAT_FLAG)

    def command(self, arguments: list[str]) -> None:
        argv = (ctypes.c_char_p * (len(arguments) + 1))(
            *(argument.encode() for argument in arguments), None
        )
        if self.lib.mpv_command(self.handle, argv) < 0:
            raise ProbeFailure("player_command_rejected")

    def number(self, name: str, kind: int = MPV_FORMAT_DOUBLE):
        value_type = {
            MPV_FORMAT_FLAG: ctypes.c_int,
            MPV_FORMAT_INT64: ctypes.c_int64,
            MPV_FORMAT_DOUBLE: ctypes.c_double,
        }[kind]
        value = value_type()
        if self.lib.mpv_get_property(self.handle, name.encode(), kind, ctypes.byref(value)) < 0:
            return None
        result = value.value
        if kind == MPV_FORMAT_DOUBLE and not math.isfinite(result):
            return None
        return bool(result) if kind == MPV_FORMAT_FLAG else result

    def string(self, name: str) -> str | None:
        pointer = self.lib.mpv_get_property_string(self.handle, name.encode())
        if not pointer:
            return None
        try:
            return ctypes.string_at(pointer).decode("utf-8", errors="replace")
        finally:
            self.lib.mpv_free(pointer)

    def tracks_present(self) -> bool:
        count = self.number("track-list/count", MPV_FORMAT_INT64)
        if count is None or count < 2 or count > 100:
            return False
        types = {self.string(f"track-list/{index}/type") for index in range(count)}
        return "audio" in types and "video" in types

    def tracks_decoded(self) -> bool:
        width = self.number("video-params/w", MPV_FORMAT_INT64)
        samplerate = self.number("audio-params/samplerate", MPV_FORMAT_INT64)
        return width is not None and width > 0 and samplerate is not None and samplerate > 0

    def close(self) -> None:
        if self.handle:
            self.lib.mpv_terminate_destroy(self.handle)
            self.handle = None


def empty_report(args) -> dict:
    return {
        "schema_version": 1,
        "status": "failed",
        "error_category": None,
        "metrics": {
            "file_loaded_seconds": None,
            "playback_progress_seconds": None,
            "initial_progress_seconds": None,
            "cache_pause_count": None,
            "cache_pause_seconds": None,
            "seek_restart_seconds": None,
            "seek_position_seconds": None,
            "seek_progress_seconds": None,
        },
        "segments": {
            "startup": {"cache_pause_count": None, "cache_pause_seconds": None},
            "seek": {"cache_pause_count": None, "cache_pause_seconds": None},
        },
        "timeline": [],
        "checks": {
            "file_loaded": False,
            "both_tracks_present": False,
            "both_tracks_decoded": False,
            "positive_time_progress": False,
            "start_position_verified": False,
            "seek_position_verified": None if args.seek_seconds is None else False,
        },
        "conditions": {
            "start_seconds": args.start_seconds,
            "duration_seconds": args.duration_seconds,
            "seek_seconds": args.seek_seconds,
            "timeout_seconds": args.timeout_seconds,
            "video_output": "null",
            "audio_output": "null",
            "hardware_decode": "no",
            "cache_profile": ("app_defaults_at_1x" if getattr(args, "buffer_seconds", 16) == 16
                              and getattr(args, "buffer_mib", 4) == 4 else "explicit_at_1x"),
            "cache_seconds": getattr(args, "buffer_seconds", 16),
            "demuxer_max_bytes": round(getattr(args, "buffer_mib", 4) * 1048576),
            "demuxer_max_back_bytes": round(getattr(args, "buffer_mib", 4) * 1048576),
            "demuxer_hysteresis_seconds": round(getattr(args, "buffer_seconds", 16) * 2 / 3, 3),
            "network_timeout_seconds": args.network_timeout_seconds,
            "http_header_profile": "app_browser_pc_user_agent_and_bilibili_referer",
            "mpv_version": None,
        },
        "limitations": [
            "Headless position and restart event proxies; no GUI first frame or audible first sound measurement.",
            "Cache pauses are libmpv paused-for-cache observations, not all visible or audible stalls.",
            "Each process has a fresh player; remote CDN cache warmth is uncontrolled.",
            "Cache profile is explicit; user app preferences are not read or modified by this tool.",
        ],
    }


def run_probe(args, video_url: str, audio_url: str, report: dict) -> None:
    player = None
    overall_cache = CacheObservation()
    segment_cache = CacheObservation()
    segment = "startup"
    began = time.monotonic()
    deadline = began + args.timeout_seconds
    first_position = None
    last_position = None
    seek_began = None
    seek_restart_seen = False
    seek_near_seen = False
    next_sample = 0.0
    try:
        lib, dependencies = load_library(Path(args.library))
        player = NativePlayer(lib)
        player.initialize(args.network_timeout_seconds, getattr(args, "buffer_seconds", 16),
                          getattr(args, "buffer_mib", 4))
        version = player.string("mpv-version")
        # Keep only the canonical version token; vendor build text is unnecessary.
        version_match = re.search(r"\bmpv\s+v?\d+\.\d+(?:\.\d+)?", version or "")
        report["conditions"]["mpv_version"] = version_match.group(0) if version_match else None
        began = time.monotonic()
        # Loading the library is setup, not the media loading timing origin.
        deadline = began + args.timeout_seconds
        player.command(loadfile_arguments(build_edl(video_url, audio_url), args.start_seconds, version))
        while time.monotonic() < deadline:
            event_pointer = player.lib.mpv_wait_event(player.handle, 0.05)
            now = time.monotonic()
            cache_flag = None
            if event_pointer:
                event = event_pointer.contents
                if event.event_id == MPV_EVENT_FILE_LOADED:
                    if report["metrics"]["file_loaded_seconds"] is None:
                        report["metrics"]["file_loaded_seconds"] = rounded(now - began)
                    report["checks"]["file_loaded"] = True
                elif event.event_id == MPV_EVENT_PLAYBACK_RESTART and segment == "seek":
                    if report["metrics"]["seek_restart_seconds"] is None:
                        report["metrics"]["seek_restart_seconds"] = rounded(now - seek_began)
                    seek_restart_seen = True
                elif event.event_id == MPV_EVENT_PROPERTY_CHANGE and event.data:
                    prop = ctypes.cast(event.data, ctypes.POINTER(MpvProperty)).contents
                    if prop.name == b"paused-for-cache" and prop.format == MPV_FORMAT_FLAG and prop.data:
                        cache_flag = bool(ctypes.cast(prop.data, ctypes.POINTER(ctypes.c_int)).contents.value)
                elif event.event_id == MPV_EVENT_END_FILE and event.data:
                    end = ctypes.cast(event.data, ctypes.POINTER(MpvEndFile)).contents
                    if end.reason != 5:  # EDL / format redirect is not terminal.
                        raise ProbeFailure("media_error" if end.error < 0 else "media_ended_before_target")
                elif event.event_id == MPV_EVENT_SHUTDOWN:
                    raise ProbeFailure("player_shutdown")
            # Poll supplements events; unsupported properties remain null.
            if cache_flag is None:
                cache_flag = player.number("paused-for-cache", MPV_FORMAT_FLAG)
            overall_cache.update(cache_flag, now)
            segment_cache.update(cache_flag, now)
            position = player.number("time-pos")
            if now - began >= next_sample and len(report["timeline"]) < 1201:
                report["timeline"].append({
                    "elapsed_seconds": rounded(now - began),
                    "position_seconds": rounded(position) if position is not None else None,
                    "cache_duration_seconds": player.number("demuxer-cache-duration"),
                    "cache_speed_bytes_s": player.number("cache-speed"),
                    "paused_for_cache": bool(cache_flag) if cache_flag is not None else None,
                })
                next_sample = now - began + 0.5
            if position is None:
                continue
            if segment == "startup":
                if first_position is None:
                    first_position = position
                    report["checks"]["start_position_verified"] = abs(position - args.start_seconds) <= 1.0
                if position >= args.start_seconds + 0.1:
                    if report["metrics"]["initial_progress_seconds"] is None:
                        report["metrics"]["initial_progress_seconds"] = rounded(now - began)
                if last_position is not None and position > last_position + 0.01:
                    report["checks"]["positive_time_progress"] = True
                last_position = position
                if position < args.start_seconds + args.duration_seconds:
                    continue
                report["metrics"]["playback_progress_seconds"] = rounded(now - began)
                report["checks"]["both_tracks_present"] = player.tracks_present()
                report["checks"]["both_tracks_decoded"] = player.tracks_decoded()
                if not all(report["checks"][key] for key in (
                    "file_loaded", "both_tracks_present", "both_tracks_decoded",
                    "positive_time_progress", "start_position_verified"
                )):
                    raise ProbeFailure("playback_checks_failed")
                report["segments"]["startup"] = segment_cache.snapshot(now)
                if args.seek_seconds is None:
                    report["status"] = "passed"
                    return
                # Reject an effectively no-op seek rather than claiming recovery.
                if abs(position - args.seek_seconds) < 0.5:
                    raise ProbeFailure("seek_target_too_close")
                seek_began = time.monotonic()
                player.command(["seek", f"{args.seek_seconds:.6f}", "absolute+exact"])
                segment = "seek"
                segment_cache = CacheObservation()
            else:
                # Ignore the old position until the seek restart event arrives.
                # Then verify the target and another one second of progression.
                if not seek_restart_seen:
                    continue
                if not seek_near_seen:
                    if abs(position - args.seek_seconds) <= 1.0:
                        seek_near_seen = True
                        report["checks"]["seek_position_verified"] = True
                        report["metrics"]["seek_position_seconds"] = rounded(position)
                    else:
                        continue
                if position >= args.seek_seconds + 1.0:
                    report["metrics"]["seek_progress_seconds"] = rounded(now - seek_began)
                    report["status"] = "passed"
                    return
        report["status"] = "timeout"
        report["error_category"] = "seek_timeout" if segment == "seek" else "playback_timeout"
    except ProbeFailure as error:
        report["status"] = "failed"
        report["error_category"] = str(error)
    finally:
        now = time.monotonic()
        report["metrics"].update(overall_cache.snapshot(now))
        report["segments"][segment] = segment_cache.snapshot(now)
        if player is not None:
            player.close()


def bounded_number(value: str) -> float:
    try:
        result = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("requires a finite nonnegative number") from None
    if not math.isfinite(result) or result < 0 or result > 86400:
        raise argparse.ArgumentTypeError("requires a finite nonnegative number at most 86400")
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True)
    parser.add_argument("--duration-seconds", type=bounded_number, default=8.0)
    parser.add_argument("--start-seconds", type=bounded_number, default=0.0)
    parser.add_argument("--seek-seconds", type=bounded_number)
    parser.add_argument("--timeout-seconds", type=bounded_number, default=60.0)
    parser.add_argument("--network-timeout-seconds", type=bounded_number, default=5.0)
    parser.add_argument("--buffer-seconds", type=bounded_number, default=16.0)
    parser.add_argument("--buffer-mib", type=bounded_number, default=4.0)
    args = parser.parse_args(argv)
    report = empty_report(args)
    try:
        if not 0 < args.duration_seconds <= 600 or not 0 < args.timeout_seconds <= 600:
            raise ProbeFailure("invalid_duration_or_timeout")
        if not 0 < args.network_timeout_seconds <= 60:
            raise ProbeFailure("invalid_network_timeout")
        if not 0 < args.buffer_seconds <= 3600 or not 0 < args.buffer_mib <= 2048:
            raise ProbeFailure("invalid_buffer_profile")
        # Bound input and use stdin rather than command arguments / signed URLs
        # in process listings. Never save the original payload to disk.
        line = sys.stdin.readline(131073)
        if len(line) > 131072:
            raise ProbeFailure("invalid_input")
        try:
            payload = json.loads(line)
        except (ValueError, TypeError):
            raise ProbeFailure("invalid_input") from None
        video_url, audio_url = validate_payload(payload)
        with suppress_native_output():
            run_probe(args, video_url, audio_url, report)
    except ProbeFailure as error:
        report["status"] = "failed"
        report["error_category"] = str(error)
    except Exception:
        report["status"] = "failed"
        report["error_category"] = "probe_internal_error"
    print(json.dumps(report, ensure_ascii=True, allow_nan=False, separators=(",", ":")))
    return 0 if report["status"] == "passed" else 2


if __name__ == "__main__":
    raise SystemExit(main())

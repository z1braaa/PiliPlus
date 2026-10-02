#!/usr/bin/env python3
"""Stream safe playback observations from the compiled app's bundled libmpv.

The first stdin line is {"live_url": "..."}. Signed URLs remain in memory and
are never included in process arguments, logs, reports, or exceptions. Later
stdin lines may request stop. No application accounts or preferences are read.
Decoded tracks and time progression are headless playback evidence, not visible
frames, audible sound, or proof that a server credited intimacy watching time.
"""

from __future__ import annotations

import argparse
import ctypes
import json
import math
import os
from pathlib import Path
import sys
import threading
import time
from urllib.parse import urlsplit

from native_mpv_probe import (
    APP_OPTIONS,
    MPV_EVENT_END_FILE,
    MPV_EVENT_SHUTDOWN,
    MPV_FORMAT_FLAG,
    MpvEndFile,
    NativePlayer,
    ProbeFailure,
    load_library,
    suppress_native_output,
)


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        # argparse's usual text can echo the rejected input or library path.
        raise ProbeFailure("invalid_arguments")


def duration(value: str) -> float:
    try:
        result = float(value)
    except (ValueError, OverflowError):
        raise argparse.ArgumentTypeError("invalid_duration") from None
    if not math.isfinite(result) or not 0 < result <= 1200:
        raise argparse.ArgumentTypeError("invalid_duration")
    return result


def read_url() -> str:
    line = sys.stdin.readline(65537)
    if len(line) > 65536:
        raise ProbeFailure("invalid_input")
    try:
        payload = json.loads(line)
        value = payload.get("live_url") if isinstance(payload, dict) else None
        if not isinstance(value, str) or not value or len(value) > 32768:
            raise ValueError
        if any(ord(character) < 32 or ord(character) == 127 for character in value):
            raise ValueError
        parsed = urlsplit(value)
        if (
            parsed.scheme not in ("http", "https")
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
        ):
            raise ValueError
        return value
    except (ValueError, TypeError):
        raise ProbeFailure("invalid_input") from None


def receive_controls(stopped: threading.Event) -> None:
    """A daemon reader keeps blocking stdin separate from the native event loop."""
    try:
        while not stopped.is_set():
            line = sys.stdin.readline(4097)
            if not line:
                # A parent may close stdin after the first payload. Playback
                # still remains bounded by the deadline or process termination.
                return
            if len(line) > 4096:
                stopped.set()
                return
            if line.strip() == "stop":
                stopped.set()
                return
            try:
                control = json.loads(line)
            except (ValueError, TypeError):
                continue
            if isinstance(control, dict) and (
                control.get("stop") is True or control.get("command") == "stop"
            ):
                stopped.set()
                return
    except Exception:
        # No traceback or input may escape from the control thread.
        stopped.set()


def emit(output, snapshot: dict) -> None:
    output.write(json.dumps(snapshot, allow_nan=False, separators=(",", ":")) + "\n")
    output.flush()


def snapshot(player: NativePlayer, previous: float | None) -> tuple[dict, float | None]:
    position = player.number("time-pos")
    cache_pause = player.number("paused-for-cache", MPV_FORMAT_FLAG)
    paused = player.number("pause", MPV_FORMAT_FLAG)
    decoded = player.tracks_decoded()
    # Unknown cache state cannot establish uninterrupted watching time. Decode
    # parameters alone are insufficient: every sample needs fresh progression.
    buffering = cache_pause is not False
    advancing = (
        position is not None and previous is not None and position > previous + 0.01
    )
    return {
        "playing": advancing and decoded and not buffering and paused is False,
        "buffering": buffering,
        "position": round(position, 4) if position is not None else None,
        "tracks_decoded": decoded,
    }, position


def run(args, live_url: str, output) -> None:
    player = None
    stopped = threading.Event()
    try:
        library, dependencies = load_library(Path(args.library))
        player = NativePlayer(library)
        # Process-local defaults only; no app preferences or source are changed.
        APP_OPTIONS["referrer"] = "https://live.bilibili.com/"
        player.initialize()
        player.command(["loadfile", live_url, "replace"])
        threading.Thread(target=receive_controls, args=(stopped,), daemon=True).start()
        began = time.monotonic()
        deadline = began + args.duration_seconds
        next_sample = began
        previous = None
        while not stopped.is_set() and time.monotonic() < deadline:
            now = time.monotonic()
            event_pointer = player.lib.mpv_wait_event(
                player.handle, min(0.05, max(0.0, next_sample - now))
            )
            if event_pointer:
                event = event_pointer.contents
                if event.event_id == MPV_EVENT_END_FILE and event.data:
                    end = ctypes.cast(event.data, ctypes.POINTER(MpvEndFile)).contents
                    if end.reason != 5:  # Format redirects are not terminal.
                        raise ProbeFailure("media_error" if end.error < 0 else "media_ended")
                elif event.event_id == MPV_EVENT_SHUTDOWN:
                    raise ProbeFailure("player_shutdown")
            now = time.monotonic()
            if now >= next_sample:
                current, previous = snapshot(player, previous)
                emit(output, current)
                next_sample = now + 1.0
    finally:
        stopped.set()
        if player is not None:
            player.close()


def main(argv: list[str] | None = None) -> int:
    # A private duplicate preserves the JSON channel while the native stdout
    # and stderr descriptors remain suppressed for the player's entire lifetime.
    output = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
    error_category = None
    try:
        with suppress_native_output():
            try:
                parser = SafeArgumentParser(description=__doc__)
                parser.add_argument("--library", required=True)
                parser.add_argument("--duration-seconds", type=duration, default=1200.0)
                args = parser.parse_args(argv)
                live_url = read_url()
                run(args, live_url, output)
            except ProbeFailure as error:
                # Only allow fixed classifications from this tool or its helper.
                reason = str(error)
                known = {
                    "invalid_arguments", "invalid_input", "library_not_found",
                    "library_load_failed", "player_create_failed",
                    "player_option_rejected", "player_initialize_failed",
                    "player_command_rejected", "media_error", "media_ended",
                    "player_shutdown",
                }
                error_category = reason if reason in known else "probe_internal_error"
            except Exception:
                error_category = "probe_internal_error"
            final = {
                "playing": False,
                "buffering": False,
                "position": None,
                "tracks_decoded": False,
            }
            if error_category is not None:
                final["error_category"] = error_category
            emit(output, final)
        return 2 if error_category is not None else 0
    except (BrokenPipeError, OSError):
        # The parent owns this session; a closed output must not print traceback.
        return 2
    finally:
        try:
            output.close()
        except (BrokenPipeError, OSError):
            pass


if __name__ == "__main__":
    raise SystemExit(main())

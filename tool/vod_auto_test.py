#!/usr/bin/env python3
"""Account-free regression and native-player comparisons; Python standard library.

Signed media addresses are passed to child processes through stdin, never argv or
reports. Native measurements are headless mpv signals, not GUI frame/audio tests.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import selectors
import shutil
import signal
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from urllib.parse import quote, urlencode, urlparse, urlunparse
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError


REPO = Path(__file__).resolve().parents[1]
MODES = ("base-direct", "hw-direct", "parallel")
DEFAULT_ORDER = ("base-direct", "hw-direct", "parallel", "parallel", "hw-direct", "base-direct")
MEDIA_DOMAINS = ("bilivideo.com", "bilivideo.cn", "bilivideo.net", "akamaized.net")
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.2 Safari/605.1.15",
           "Referer": "https://www.bilibili.com/"}
WBI_MIX = (46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27,
           43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13)
QUALITY_NAMES = {16: "360p", 32: "480p", 64: "720p", 74: "720p60", 80: "1080p",
                 112: "1080p+", 116: "1080p60", 120: "4K", 125: "HDR", 126: "Dolby", 127: "8K"}


class HarnessError(Exception):
    """A public classification without arbitrary upstream exception text."""

    def __init__(self, classification: str, **details):
        super().__init__(classification)
        self.classification = classification
        self.details = details


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def safe_error(error):
    if isinstance(error, HarnessError):
        return {"classification": error.classification, **error.details}
    if isinstance(error, subprocess.TimeoutExpired):
        kind = "timeout"
    elif isinstance(error, HTTPError):
        return {"classification": "http_error", "http_status": error.code}
    elif isinstance(error, (TimeoutError, URLError)):
        kind = "network_error"
    elif isinstance(error, FileNotFoundError):
        kind = "dependency_missing"
    elif isinstance(error, (ValueError, KeyError, TypeError, json.JSONDecodeError)):
        kind = "invalid_data"
    else:
        kind = "unexpected_error"
    return {"classification": kind, "exception_type": type(error).__name__}


def launch(command, **kwargs):
    return subprocess.Popen(command, cwd=REPO, text=True, start_new_session=(os.name == "posix"), **kwargs)


def stop_process(process, grace=1.0):
    """Terminate the process group even if its leader has already exited."""
    if os.name == "posix":
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except PermissionError:
            # macOS can reject signaling an already orphaned zombie group.
            # An active leader is a real cleanup failure and must not be hidden.
            if process.poll() is None:
                raise
    elif process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass
    if os.name == "posix":
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            if process.poll() is None:
                raise
    elif process.poll() is None:
        process.kill()
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass


def run_command(command, *, timeout, payload=None):
    started = time.monotonic()
    process = launch(command, stdin=subprocess.PIPE if payload is not None else subprocess.DEVNULL,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        stdout, _stderr = process.communicate(input=payload, timeout=timeout)
        return {"exit_code": process.returncode, "timed_out": False,
                "elapsed_seconds": round(time.monotonic() - started, 3), "stdout": stdout}
    except subprocess.TimeoutExpired:
        stop_process(process)
        # A detached descendant may still hold an inherited output pipe open.
        # Never drain that pipe without a deadline after killing the group.
        return {"exit_code": process.returncode, "timed_out": True,
                "elapsed_seconds": round(time.monotonic() - started, 3), "stdout": ""}
    finally:
        # Do not leave spawned descendants alive after either success or failure.
        try:
            stop_process(process)
        finally:
            for pipe in (process.stdin, process.stdout, process.stderr):
                if pipe and not pipe.closed:
                    pipe.close()


def resolve_executable(supplied, name):
    path = supplied or shutil.which(name)
    if not path or not Path(path).is_file() or not os.access(path, os.X_OK):
        raise HarnessError("dependency_missing", dependency=name)
    return str(Path(path).resolve())


def git_baseline():
    result = {}
    for name, arguments in (("commit", ["rev-parse", "HEAD"]),
                            ("branch", ["branch", "--show-current"]),
                            ("description", ["describe", "--tags", "--always", "--dirty"])):
        try:
            call = run_command(["git", *arguments], timeout=5)
            value = call["stdout"].strip()
            result[name] = value if call["exit_code"] == 0 and re.fullmatch(r"[A-Za-z0-9_./+-]{1,200}", value) else None
        except Exception:
            result[name] = None
    try:
        call = run_command(["git", "status", "--porcelain"], timeout=5)
        result["working_tree_dirty"] = bool(call["stdout"].strip()) if call["exit_code"] == 0 else None
    except Exception:
        result["working_tree_dirty"] = None
    return result


def base_report(kind):
    return {"schema_version": 1, "kind": kind, "created_at_utc": utc_now(),
            "git": git_baseline(), "python_version": platform.python_version(),
            "platform": platform.system(), "network_region": "not_verified_by_tool",
            "credentials": "none; application login data is not read"}


def write_report(directory, report, rows):
    directory = Path(directory).expanduser()
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    names = list(dict.fromkeys(name for row in rows for name in row)) or ["status"]
    with (directory / "samples.csv").open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=names)
        writer.writeheader()
        writer.writerows(rows)
    return directory / "report.json"


def parse_regression_output(kind, stdout):
    if kind == "dart":
        matches = re.findall(r"(\d+)/(\d+) checks passed\.", stdout)
        if not matches:
            return {"passed": None, "failed": None, "skipped": 0, "count_verified": False}
        passed, total = map(int, matches[-1])
        if passed > total:
            raise HarnessError("invalid_test_count")
        return {"passed": passed, "failed": total - passed, "skipped": 0, "count_verified": True}
    tests, counts = {}, {"passed": 0, "failed": 0, "skipped": 0, "count_verified": False,
                         "framework_events": 0, "framework_failures": 0}
    for line in stdout.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") == "testStart":
            test = event.get("test")
            if isinstance(test, dict) and isinstance(test.get("id"), int):
                tests[test["id"]] = test
        elif event.get("type") == "testDone":
            identifier = event.get("testID")
            if not isinstance(identifier, int) or identifier not in tests:
                continue
            test = tests[identifier]
            # test_api puts `hidden` on testDone, not normally on testStart.
            # Loading and setUpAll/tearDownAll are framework lifecycle events,
            # not user test cases. Still retain their failures separately.
            if event.get("hidden") is True or test.get("hidden") is True:
                counts["framework_events"] += 1
                if event.get("result") in ("error", "failure"):
                    counts["framework_failures"] += 1
                continue
            if event.get("result") not in ("success", "error", "failure"):
                continue
            counts["count_verified"] = True
            if event.get("skipped"):
                counts["skipped"] += 1
            elif event.get("result") == "success":
                counts["passed"] += 1
            elif event.get("result") in ("error", "failure"):
                counts["failed"] += 1
    return counts


def regress(args):
    report = base_report("regression")
    rows = []
    dependencies = {}
    for name in ("dart", "flutter"):
        try:
            dependencies[name] = resolve_executable(getattr(args, name), name)
        except Exception as error:
            report.setdefault("dependency_errors", {})[name] = safe_error(error)
    targets = [
        ("dart", "tool/cdn_proxy_smoke_test.dart"),
        ("dart", "tool/cdn_multi_origin_test.dart"),
        ("dart", "tool/cdn_startup_test.dart"),
        ("flutter", "test/pages/setting/parallel_cdn_settings_test.dart"),
        ("flutter", "test/utils/video_playback_routing_test.dart"),
        ("flutter", "test/utils/accounts/deleted_account_test.dart"),
    ]
    for kind, target in targets:
        row = {"suite": target, "runner": kind, "status": "not_run", "passed": None,
               "failed": None, "skipped": None, "timed_out": False, "elapsed_seconds": None}
        if kind not in dependencies:
            row["classification"] = "dependency_missing"
        else:
            try:
                command = [dependencies[kind], target] if kind == "dart" else [dependencies[kind], "test", "--machine", target]
                result = run_command(command, timeout=args.timeout_seconds)
                row.update({key: result[key] for key in ("exit_code", "timed_out", "elapsed_seconds")})
                row.update(parse_regression_output(kind, result["stdout"]))
                row["status"] = "timeout" if result["timed_out"] else (
                    "passed" if result["exit_code"] == 0 and row["count_verified"] and not row["failed"] and not row.get("framework_failures") else "failed")
            except Exception as error:
                row.update(status="failed", **safe_error(error))
        rows.append(row)
    report["suites"] = rows
    report["totals"] = {"passed": sum(row["passed"] or 0 for row in rows),
                        "failed": sum(row["failed"] or 0 for row in rows),
                        "skipped": sum(row["skipped"] or 0 for row in rows),
                        "framework_events": sum(row.get("framework_events", 0) for row in rows),
                        "framework_failures": sum(row.get("framework_failures", 0) for row in rows),
                        "suite_failures": sum(row["status"] == "failed" for row in rows),
                        "timeouts": sum(row["status"] == "timeout" for row in rows),
                        "not_run": sum(row["status"] == "not_run" for row in rows)}
    return report, rows, 0 if all(row["status"] == "passed" for row in rows) else 1


def validate_media_url(value):
    if not isinstance(value, str) or len(value) > 16_384:
        raise HarnessError("invalid_media_address")
    uri = urlparse(value)
    host = (uri.hostname or "").lower()
    if (uri.scheme != "https" or uri.username or uri.password or uri.port not in (None, 443)
            or not any(host == domain or host.endswith("." + domain) for domain in MEDIA_DOMAINS)
            or not uri.path.startswith("/upgcxcode/") or not uri.path.endswith((".m4s", ".mp4"))):
        raise HarnessError("unsupported_media_address")
    return value


def integer_field(value, name, minimum=1, maximum=100_000):
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise HarnessError("invalid_metadata", field=name)
    return value


def normalize_manifest(data):
    if not isinstance(data, dict):
        raise HarnessError("invalid_manifest")
    streams = {}
    for field in ("video_urls", "audio_urls"):
        urls = data.get(field)
        if not isinstance(urls, list) or not 1 <= len(urls) <= 4:
            raise HarnessError("invalid_manifest_stream_count", field=field)
        streams[field] = list(dict.fromkeys(validate_media_url(url) for url in urls))
        if len({urlparse(url).path for url in streams[field]}) != 1:
            raise HarnessError("mixed_stream_paths", field=field)
    codec = data.get("codec")
    if not isinstance(codec, str) or not re.fullmatch(r"[A-Za-z0-9_. -]{1,80}", codec):
        raise HarnessError("invalid_metadata", field="codec")
    metadata = {"quality": integer_field(data.get("quality"), "quality", maximum=1000),
                "codec": codec, "width": integer_field(data.get("width"), "width"),
                "height": integer_field(data.get("height"), "height")}
    audio_codec = data.get("audio_codec")
    if isinstance(audio_codec, str) and re.fullmatch(r"[A-Za-z0-9_. -]{1,80}", audio_codec):
        metadata["audio_codec"] = audio_codec
    streams.update(metadata)
    streams["quality_label"] = QUALITY_NAMES.get(metadata["quality"], "unknown")
    streams["manifest_fingerprint"] = hashlib.sha256(json.dumps(
        {**metadata, **{key: streams[key] for key in ("video_urls", "audio_urls")}}, sort_keys=True).encode()).hexdigest()
    return streams


def get_json(url, timeout=18):
    with urlopen(Request(url, headers=HEADERS), timeout=timeout) as response:
        return json.load(response)


def require_api_success(response, operation):
    if not isinstance(response, dict) or response.get("code") != 0 or not isinstance(response.get("data"), dict):
        code = response.get("code") if isinstance(response, dict) else None
        raise HarnessError("anonymous_api_unavailable", operation=operation,
                           api_code=code if isinstance(code, int) else None)
    return response["data"]


def stream_urls(stream):
    base = stream.get("baseUrl") or stream.get("base_url")
    backups = stream.get("backupUrl") or stream.get("backup_url") or []
    return list(dict.fromkeys([base, *backups]))[:4] if base else []


def manifest_from_playurl(response, requested_quality, preferred_codec="avc"):
    data = require_api_success(response, "playurl")
    dash = data.get("dash") or {}
    videos, audios = dash.get("video") or [], dash.get("audio") or []
    if not videos or not audios:
        raise HarnessError("anonymous_dash_unavailable")
    exact = [video for video in videos if video.get("id") == requested_quality]
    if not exact:
        lower = [video for video in videos if isinstance(video.get("id"), int) and video["id"] <= requested_quality]
        if not lower:
            raise HarnessError("requested_quality_unavailable", requested_quality=requested_quality)
        highest = max(video["id"] for video in lower)
        exact = [video for video in lower if video["id"] == highest]
    video = next((video for video in exact if video.get("codecs", "").startswith(preferred_codec)), exact[0])
    audio = audios[0]
    return normalize_manifest({"video_urls": stream_urls(video), "audio_urls": stream_urls(audio),
                               "quality": video.get("id"), "codec": video.get("codecs"),
                               "width": video.get("width"), "height": video.get("height"),
                               "audio_codec": audio.get("codecs")})


def anonymous_manifest(bvid, page, quality, preferred_codec):
    view = require_api_success(get_json("https://api.bilibili.com/x/web-interface/view?" + urlencode({"bvid": bvid})), "view")
    pages = view.get("pages") or []
    selected = next((item for item in pages if item.get("page") == page), None)
    if selected is None:
        raise HarnessError("video_page_unavailable", page=page)
    nav = get_json("https://api.bilibili.com/x/web-interface/nav")
    # Anonymous nav may use code=-101 while still supplying public WBI images.
    images = nav.get("data", {}).get("wbi_img", {})
    source = "".join(urlparse(images[field]).path.rsplit("/", 1)[-1].split(".")[0] for field in ("img_url", "sub_url"))
    if len(source) < 64:
        raise HarnessError("anonymous_wbi_unavailable")
    key = "".join(source[index] for index in WBI_MIX)
    params = {"bvid": bvid, "cid": selected["cid"], "qn": quality, "fnval": 16,
              "fnver": 0, "fourk": 1, "wts": int(time.time())}
    cleaned = {name: "".join(char for char in str(value) if char not in "!'()*") for name, value in params.items()}
    query = urlencode(sorted(cleaned.items()), quote_via=quote)
    signed = "https://api.bilibili.com/x/player/wbi/playurl?" + query + "&w_rid=" + hashlib.md5((query + key).encode()).hexdigest()
    manifest = manifest_from_playurl(get_json(signed), quality, preferred_codec)
    manifest.update(bvid=bvid, page=page)
    return manifest


def acquire_anonymous_manifest(args, timeout):
    # Isolate even DNS / response-body reads behind a real wall-clock deadline.
    # This private pipe carries addresses; it is never echoed or written to disk.
    worker = (
        "import json,sys\n"
        "from tool.vod_auto_test import anonymous_manifest,safe_error\n"
        "try:\n"
        " p=json.load(sys.stdin)\n"
        " r=anonymous_manifest(p['bvid'],p['page'],p['quality'],p['codec'])\n"
        " print(json.dumps({'manifest':r}))\n"
        "except Exception as e:\n"
        " print(json.dumps({'error':safe_error(e)}));sys.exit(1)\n"
    )
    call = run_command([sys.executable, "-c", worker], timeout=timeout,
                       payload=json.dumps({"bvid": args.bvid, "page": args.page,
                                           "quality": args.quality_code, "codec": args.codec}))
    if call["timed_out"]:
        raise HarnessError("anonymous_api_deadline_exceeded")
    data = json.loads(call["stdout"])
    if call["exit_code"] != 0:
        error = data.get("error", {})
        category = error.get("classification", "anonymous_api_unavailable")
        if not isinstance(category, str) or not re.fullmatch(r"[a-z_]{1,80}", category):
            category = "anonymous_api_unavailable"
        public = {}
        if isinstance(error.get("http_status"), int) and 100 <= error["http_status"] <= 599:
            public["http_status"] = error["http_status"]
        if isinstance(error.get("api_code"), int) and abs(error["api_code"]) < 1_000_000:
            public["api_code"] = error["api_code"]
        if error.get("operation") in ("view", "playurl"):
            public["operation"] = error["operation"]
        raise HarnessError(category, **public)
    return normalize_manifest(data["manifest"])


def quality_policy(manifest, requested, allow_lower):
    actual = manifest["quality"]
    matches = actual == requested
    return {"requested_quality": requested, "requested_quality_label": QUALITY_NAMES.get(requested, "unknown"),
            "actual_quality": actual, "actual_quality_label": manifest["quality_label"],
            "requested_quality_reproduced": matches,
            "benchmark_allowed": matches or (allow_lower and actual < requested)}


def hw_url(url):
    uri = urlparse(validate_media_url(url))
    return urlunparse(uri._replace(netloc="upos-sz-mirrorhw.bilivideo.com"))


class Bridge:
    def __init__(self, dart, payload, timeout):
        if os.name != "posix":
            raise HarnessError("bridge_platform_unsupported")
        deadline = time.monotonic() + timeout
        self.process = launch([dart, str(REPO / "tool/cdn_benchmark_bridge.dart")],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.urls = None
        try:
            message = (json.dumps(payload) + "\n").encode("utf-8")
            if len(message) > 262_144:
                raise HarnessError("bridge_payload_too_large")
            input_fd, output_fd = self.process.stdin.fileno(), self.process.stdout.fileno()
            os.set_blocking(input_fd, False)
            os.set_blocking(output_fd, False)
            received = bytearray()
            sent = 0
            with selectors.DefaultSelector() as selector:
                selector.register(input_fd, selectors.EVENT_WRITE, "write")
                selector.register(output_fd, selectors.EVENT_READ, "read")
                while b"\n" not in received:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise HarnessError("bridge_timeout")
                    for key, _ in selector.select(remaining):
                        try:
                            if key.data == "write":
                                sent += os.write(input_fd, message[sent:sent + 16_384])
                                if sent == len(message):
                                    selector.unregister(input_fd)
                            else:
                                block = os.read(output_fd, 4096)
                                if not block:
                                    raise HarnessError("bridge_closed_before_ready")
                                received.extend(block)
                                if len(received) > 65_536:
                                    raise HarnessError("bridge_response_too_large")
                        except BlockingIOError:
                            continue
            data = json.loads(received.split(b"\n", 1)[0])
            if sent != len(message):
                raise HarnessError("bridge_ready_before_payload_consumed")
            for field in ("video_url", "audio_url"):
                uri = urlparse(data.get(field, ""))
                if uri.scheme != "http" or uri.hostname not in ("127.0.0.1", "::1", "localhost"):
                    raise HarnessError("invalid_bridge_response")
            self.urls = data
        except BaseException:
            self.close()
            raise

    def close(self):
        try:
            stop_process(self.process)
        finally:
            for pipe in (self.process.stdin, self.process.stdout):
                if pipe and not pipe.closed:
                    pipe.close()


def sanitize_native_result(result):
    """Whitelist primitive mpv metrics. Never copy arbitrary native log/error text."""
    if not isinstance(result, dict):
        raise HarnessError("invalid_native_response")
    source_metrics = result.get("metrics", {})
    if not isinstance(source_metrics, dict):
        raise HarnessError("invalid_native_metrics")
    numeric = {"file_loaded_seconds", "playback_progress_seconds", "initial_progress_seconds",
               "cache_pause_count", "cache_pause_seconds", "seek_restart_seconds",
               "seek_position_seconds", "seek_progress_seconds"}
    safe = {}
    for key in numeric:
        value = source_metrics.get(key)
        if value is None or (isinstance(value, (int, float)) and not isinstance(value, bool) and abs(value) < 1e12):
            if key in source_metrics:
                safe[key] = value
    segments = result.get("segments", {})
    if isinstance(segments, dict):
        for segment in ("startup", "seek"):
            values = segments.get(segment, {})
            if isinstance(values, dict):
                for metric in ("cache_pause_count", "cache_pause_seconds"):
                    value = values.get(metric)
                    if metric in values and (value is None or (isinstance(value, (int, float))
                            and not isinstance(value, bool) and 0 <= value < 1e12)):
                        safe[f"{segment}_{metric}"] = value
    checks = result.get("checks", {})
    if not isinstance(checks, dict):
        raise HarnessError("invalid_native_checks")
    for key in ("file_loaded", "both_tracks_present", "both_tracks_decoded", "positive_time_progress", "start_position_verified", "seek_position_verified"):
        if isinstance(checks.get(key), bool):
            safe[key] = checks[key]
    status = result.get("status")
    if status in ("passed", "failed", "timeout"):
        safe["native_status"] = status
    category = result.get("error_category")
    if isinstance(category, str) and re.fullmatch(r"[a-z_]{1,80}", category):
        safe["classification"] = category
    conditions = result.get("conditions", {})
    if isinstance(conditions, dict):
        for key in ("cache_seconds", "demuxer_max_bytes", "demuxer_max_back_bytes", "demuxer_hysteresis_seconds", "network_timeout_seconds"):
            value = conditions.get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool) and 0 <= value < 1e12:
                safe[key] = value
        for key in ("video_output", "audio_output", "cache_profile", "mpv_version", "http_header_profile"):
            value = conditions.get(key)
            if isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_. /()-]{1,80}", value):
                safe[key] = value
    return safe


def native_measurement_succeeded(result, exit_code, seek_requested):
    mandatory = ("file_loaded", "both_tracks_present", "both_tracks_decoded",
                 "positive_time_progress", "start_position_verified")
    if exit_code != 0 or result.get("native_status") != "passed" or not all(result.get(key) is True for key in mandatory):
        return False
    if seek_requested:
        progress = result.get("seek_progress_seconds")
        if result.get("seek_position_verified") is not True or not isinstance(progress, (int, float)) or isinstance(progress, bool) or not math.isfinite(progress) or progress < 0:
            return False
    return True


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_order(raw):
    order = tuple(part.strip() for part in raw.split(","))
    if not 1 <= len(order) <= 18 or any(mode not in MODES for mode in order) or any(order.count(mode) > 6 for mode in MODES):
        raise argparse.ArgumentTypeError("order must contain 1–18 known modes, at most 6 trials per mode")
    return order


def comparison_key(manifest, args):
    values = {"manifest_fingerprint": manifest["manifest_fingerprint"], "quality": manifest["quality"],
              "codec": manifest["codec"], "width": manifest["width"], "height": manifest["height"],
              "start_seconds": args.start_seconds, "duration_seconds": args.duration_seconds,
              "seek_seconds": args.seek_seconds, "concurrency": args.concurrency, "chunk_kib": args.chunk_kib,
              "runtime_artifacts": getattr(args, "runtime_artifacts", {})}
    return hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()


def summarize_samples(samples):
    keys = {sample["comparison_key"] for sample in samples}
    if len(keys) > 1:
        raise HarnessError("mixed_comparison_baselines")
    summary = {}
    for mode in MODES:
        selected = [sample for sample in samples if sample["mode"] == mode]
        successful = [sample for sample in selected if sample["status"] == "measured"]
        stats = {"trials": len(selected), "measured": len(successful),
                 "failures_or_timeouts": len(selected) - len(successful)}
        for metric in ("file_loaded_seconds", "initial_progress_seconds", "playback_progress_seconds",
                       "cache_pause_count", "cache_pause_seconds", "startup_cache_pause_count", "startup_cache_pause_seconds",
                       "seek_cache_pause_count", "seek_cache_pause_seconds", "seek_restart_seconds", "seek_progress_seconds"):
            values = [sample[metric] for sample in successful if isinstance(sample.get(metric), (int, float))]
            if values:
                stats[metric] = {"samples": len(values), "median": statistics.median(values),
                                 "min": min(values), "max": max(values)}
        summary[mode] = stats
    return summary


def playback(args):
    report = base_report("native_playback_comparison")
    rows = []
    report["measurement_boundary"] = (
        "Headless native libmpv events and position progress; not PiliPlus GUI first moving frame, "
        "first audible sound, or proof of subjective smoothness. No P95 or performance benefit claim.")
    report["plan"] = {"order": list(args.order), "concurrency": args.concurrency, "chunk_kib": args.chunk_kib,
                      "start_seconds": args.start_seconds, "duration_seconds": args.duration_seconds,
                      "seek_seconds": args.seek_seconds, "trial_deadline_seconds": args.deadline_seconds,
                      "total_budget_seconds": args.total_budget_seconds,
                      "network_timeout_seconds_by_mode": {"base-direct": 5, "hw-direct": 5, "parallel": 60},
                      "url_policy": "same signed URL set for all trials; no credential or URL output"}
    started = time.monotonic()
    manifest = None
    try:
        if args.manifest:
            manifest_path = Path(args.manifest)
            if manifest_path.stat().st_size > 1_048_576:
                raise HarnessError("manifest_too_large")
            manifest = normalize_manifest(json.loads(manifest_path.read_text(encoding="utf-8")))
        else:
            manifest = acquire_anonymous_manifest(args, min(60, args.total_budget_seconds))
        report["source"] = {key: manifest[key] for key in ("quality", "quality_label", "codec", "width", "height", "manifest_fingerprint")}
        report["source"].update(origin="provided_manifest" if args.manifest else "anonymous_official_api",
                                bvid=args.bvid, page=args.page, video_url_count=len(manifest["video_urls"]),
                                audio_url_count=len(manifest["audio_urls"]))
        report["quality_check"] = quality_policy(manifest, args.quality_code, args.allow_lower_quality)
        if not report["quality_check"]["benchmark_allowed"]:
            raise HarnessError("requested_quality_not_reproduced", requested_quality=args.quality_code,
                               actual_quality=manifest["quality"])
        if not Path(args.library).is_file():
            raise HarnessError("dependency_missing", dependency="libmpv")
        if not (REPO / "tool/native_mpv_probe.py").is_file():
            raise HarnessError("dependency_missing", dependency="native_mpv_probe")
        report["runtime_artifacts"] = {"libmpv_sha256": sha256_file(args.library),
                                       "native_probe_sha256": sha256_file(REPO / "tool/native_mpv_probe.py"),
                                       "orchestrator_sha256": sha256_file(Path(__file__))}
        # The proxy can change while the Python scripts and mpv stay identical.
        # Keep transport implementations in the comparison identity as well.
        for label, path in (("bridge", "tool/cdn_benchmark_bridge.dart"),
                            ("proxy", "lib/http/cdn_playback_proxy.dart"),
                            ("origin_policy", "lib/http/cdn_origin_policy.dart"),
                            ("startup_trace", "lib/utils/cdn_startup_trace.dart")):
            report["runtime_artifacts"][label + "_sha256"] = sha256_file(REPO / path)
        args.runtime_artifacts = report["runtime_artifacts"]
        dart = resolve_executable(args.dart, "dart") if "parallel" in args.order else None
        group = comparison_key(manifest, args)
        for index, mode in enumerate(args.order, 1):
            row = {"trial": index, "mode": mode, "comparison_key": group, "quality": manifest["quality"],
                   "requested_quality": args.quality_code, "requested_quality_reproduced": report["quality_check"]["requested_quality_reproduced"],
                   "codec": manifest["codec"], "width": manifest["width"], "height": manifest["height"],
                   "start_seconds": args.start_seconds, "status": "not_run", "timed_out": False}
            remaining = args.total_budget_seconds - (time.monotonic() - started)
            if remaining <= 0:
                row["classification"] = "total_budget_exhausted"
                rows.append(row)
                continue
            trial_timeout = min(args.deadline_seconds, remaining)
            trial_started = time.monotonic()
            bridge = None
            try:
                video, audio = manifest["video_urls"][0], manifest["audio_urls"][0]
                if mode == "hw-direct":
                    video, audio = hw_url(video), hw_url(audio)
                elif mode == "parallel":
                    bridge_started = time.monotonic()
                    bridge = Bridge(dart, {"video_urls": manifest["video_urls"], "audio_urls": manifest["audio_urls"],
                                           "concurrency": args.concurrency, "chunk_kib": args.chunk_kib}, min(15, trial_timeout))
                    video, audio = bridge.urls["video_url"], bridge.urls["audio_url"]
                    count = bridge.urls.get("candidate_count")
                    row["candidate_count"] = count if isinstance(count, int) and 0 <= count <= 100 else None
                    row["bridge_setup_seconds"] = round(time.monotonic() - bridge_started, 3)
                native_timeout = trial_timeout - (time.monotonic() - trial_started)
                if native_timeout <= 0:
                    raise HarnessError("trial_budget_exhausted")
                command = [sys.executable, str(REPO / "tool/native_mpv_probe.py"), "--library", args.library,
                           "--duration-seconds", str(args.duration_seconds), "--start-seconds", str(args.start_seconds),
                           "--timeout-seconds", str(native_timeout), "--network-timeout-seconds", "60" if mode == "parallel" else "5"]
                if args.seek_seconds is not None:
                    command += ["--seek-seconds", str(args.seek_seconds)]
                native = run_command(command, timeout=native_timeout,
                                     payload=json.dumps({"video_url": video, "audio_url": audio}) + "\n")
                row.update(timed_out=native["timed_out"], elapsed_seconds=round(time.monotonic() - trial_started, 3))
                if native["timed_out"]:
                    row.update(status="timeout", classification="native_deadline_exceeded")
                else:
                    safe = sanitize_native_result(json.loads(native["stdout"]))
                    row.update(safe)
                    row["status"] = "measured" if native_measurement_succeeded(safe, native["exit_code"], args.seek_seconds is not None) else "failed"
                    if safe.get("native_status") == "timeout":
                        row.update(status="timeout", timed_out=True)
                    if row["status"] == "failed" and "classification" not in row:
                        row["classification"] = "native_playback_failed"
            except Exception as error:
                row.update(status="failed", **safe_error(error))
            finally:
                if bridge:
                    bridge.close()
            rows.append(row)
        report["summary"] = summarize_samples(rows)
        report["status"] = "completed" if rows and all(row["status"] == "measured" for row in rows) else "incomplete"
    except Exception as error:
        report.update(status="not_reproduced", error=safe_error(error))
    report["elapsed_seconds"] = round(time.monotonic() - started, 3)
    report["samples"] = rows
    return report, rows, 0 if report.get("status") == "completed" else 1


def bounded_number(kind, minimum, maximum):
    def parse(value):
        try:
            number = kind(value)
        except ValueError:
            raise argparse.ArgumentTypeError("requires a number") from None
        if not minimum <= number <= maximum:
            raise argparse.ArgumentTypeError(f"must be between {minimum} and {maximum}")
        return number
    return parse


def parser():
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    regression = commands.add_parser("regress", help="bounded existing transport and Flutter regressions")
    regression.add_argument("--dart")
    regression.add_argument("--flutter")
    regression.add_argument("--timeout-seconds", type=bounded_number(float, 1, 240), default=180)
    regression.add_argument("--output", default=str(REPO / "outputs" / ("vod-regress-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))))
    test = commands.add_parser("playback", help="account-free, fixed-source headless native mpv comparisons")
    source = test.add_mutually_exclusive_group(required=True)
    source.add_argument("--bvid", type=lambda value: value if re.fullmatch(r"BV[A-Za-z0-9]{10}", value) else (_ for _ in ()).throw(argparse.ArgumentTypeError("requires a BV identifier")))
    source.add_argument("--manifest", help="local JSON; private media URLs remain in memory only")
    test.add_argument("--page", type=bounded_number(int, 1, 1000), default=1)
    test.add_argument("--quality-code", type=bounded_number(int, 1, 1000), default=80)
    test.add_argument("--codec", choices=("avc", "hev", "av01"), default="avc")
    test.add_argument("--allow-lower-quality", action="store_true", help="explicitly allow lower quality; requested quality still remains not reproduced")
    test.add_argument("--library", required=True, help="libmpv dynamic library; no app credentials are read")
    test.add_argument("--dart")
    test.add_argument("--order", type=parse_order, default=DEFAULT_ORDER)
    test.add_argument("--concurrency", type=bounded_number(int, 1, 32), default=8)
    test.add_argument("--chunk-kib", type=bounded_number(int, 64, 4096), default=1024)
    test.add_argument("--duration-seconds", type=bounded_number(float, 1, 60), default=8)
    test.add_argument("--start-seconds", type=bounded_number(float, 0, 86400), default=0)
    test.add_argument("--seek-seconds", type=bounded_number(float, 0, 86400))
    test.add_argument("--deadline-seconds", type=bounded_number(float, 5, 180), default=90)
    test.add_argument("--total-budget-seconds", type=bounded_number(float, 5, 1800), default=600)
    test.add_argument("--output", default=str(REPO / "outputs" / ("vod-playback-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))))
    return root


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        report, rows, status = regress(args) if args.command == "regress" else playback(args)
        write_report(args.output, report, rows)
        # A bounded public summary; no subprocess stdout, URLs, paths, or error text.
        print(json.dumps({"status": report.get("status", "passed" if status == 0 else "failed"),
                          "totals": report.get("totals"), "sample_count": len(rows),
                          "error": report.get("error")}, ensure_ascii=False))
        return status
    except KeyboardInterrupt:
        print('{"status":"interrupted"}', file=sys.stderr)
        return 130
    except Exception as error:
        print(json.dumps({"status": "failed", "error": safe_error(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

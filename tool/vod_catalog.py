"""Offline video strata, predeclared batch plans, and paired native summaries.

Discovery metadata is a lead, not evidence that a CDN has cached a video. No
network requests or account access occur here. Unknown/rounded statistics never
silently enter a target stratum, and media URLs are never copied into results.
"""

from __future__ import annotations

from collections import Counter
import hashlib
import html
import json
import math
import re
import statistics


STRATA = ("recent-low", "recent-popular", "older-low", "older-popular")
METRICS = ("file_loaded_seconds", "initial_progress_seconds", "playback_progress_seconds",
           "cache_pause_count", "cache_pause_seconds", "startup_cache_pause_count",
           "startup_cache_pause_seconds", "seek_cache_pause_count", "seek_cache_pause_seconds",
           "seek_restart_seconds", "seek_progress_seconds")
DEFAULT_ORDER = ("hw-direct", "parallel", "parallel", "hw-direct")


class CatalogError(ValueError):
    """The classification is fixed public text; upstream text is never included."""

    def __init__(self, classification, **details):
        super().__init__(classification)
        self.classification = classification
        self.details = details


def _integer(value, field, minimum=0):
    if isinstance(value, str) and re.fullmatch(r"[0-9]{1,16}", value):
        value = int(value)
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise CatalogError("unknown_" + field)
    return value


def _duration(value):
    if isinstance(value, str) and ":" in value:
        parts = value.split(":")
        if len(parts) not in (2, 3) or any(not re.fullmatch(r"[0-9]{1,6}", part) for part in parts):
            raise CatalogError("unknown_duration")
        numbers = list(map(int, parts))
        if any(number >= 60 for number in numbers[1:]):
            raise CatalogError("unknown_duration")
        value = sum(number * 60 ** index for index, number in enumerate(reversed(numbers)))
    return _integer(value, "duration", minimum=1)


def normalize_video(record):
    if not isinstance(record, dict):
        raise CatalogError("invalid_video_metadata")
    bvid = record.get("bvid")
    if not isinstance(bvid, str) or not re.fullmatch(r"BV[A-Za-z0-9]{10}", bvid):
        raise CatalogError("invalid_bvid")
    stat = record.get("stat") if isinstance(record.get("stat"), dict) else {}
    view = record.get("view", stat.get("view", record.get("play")))
    title_fingerprint = record.get("title_fingerprint")
    if not isinstance(title_fingerprint, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", title_fingerprint):
        title = record.get("title")
        if title is not None and not isinstance(title, str):
            raise CatalogError("invalid_title_metadata")
        title_fingerprint = hashlib.sha256(html.unescape(title or "").encode("utf-8")).hexdigest()
    else:
        title_fingerprint = title_fingerprint.lower()
    return {"bvid": bvid, "pubdate": _integer(record.get("pubdate"), "pubdate", minimum=1),
            "view": _integer(view, "view"), "duration": _duration(record.get("duration")),
            "title_fingerprint": title_fingerprint}


def extract_candidates(payload, source="auto", max_candidates=2000):
    """Extract whitelisted leads from API dictionaries/lists or INITIAL_STATE HTML.

    The return value may contain missing metadata. Pass authoritative view data
    through normalize_video/classify_video again before accepting a candidate.
    `source` is a caller label only; it never changes validation or trusts an API.
    """
    if not isinstance(source, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,60}", source):
        raise CatalogError("invalid_source_label")
    max_candidates = _integer(max_candidates, "max_candidates", minimum=1)
    if max_candidates > 2000:
        raise CatalogError("catalog_limit_exceeded")
    if isinstance(payload, str):
        if len(payload) > 5_000_000:
            raise CatalogError("discovery_payload_too_large")
        marker = re.search(r"(?:window\.)?__INITIAL_STATE__\s*=\s*", payload)
        if marker is None:
            return []
        try:
            payload, _ = json.JSONDecoder().raw_decode(payload[marker.end():].lstrip())
        except (ValueError, RecursionError):
            raise CatalogError("initial_state_unavailable") from None
    if not isinstance(payload, (dict, list)):
        raise CatalogError("invalid_discovery_payload")
    result, stack, visited = [], [payload], 0
    while stack and len(result) < max_candidates:
        item = stack.pop()
        visited += 1
        if visited > 20_000:
            raise CatalogError("discovery_structure_too_large")
        if isinstance(item, dict):
            if isinstance(item.get("bvid"), str) and re.fullmatch(r"BV[A-Za-z0-9]{10}", item["bvid"]):
                stat = item.get("stat") if isinstance(item.get("stat"), dict) else {}
                title = item.get("title")
                fingerprint = item.get("title_fingerprint")
                if isinstance(fingerprint, str) and re.fullmatch(r"[0-9a-fA-F]{64}", fingerprint):
                    fingerprint = fingerprint.lower()
                else:
                    fingerprint = hashlib.sha256(html.unescape(title if isinstance(title, str) else "").encode()).hexdigest()
                numeric = {}
                for field, value in (("pubdate", item.get("pubdate")),
                                     ("view", item.get("view", stat.get("view", item.get("play")))),
                                     ("duration", item.get("duration"))):
                    try:
                        numeric[field] = _duration(value) if field == "duration" else _integer(value, field, minimum=1 if field == "pubdate" else 0)
                    except CatalogError:
                        numeric[field] = None
                result.append({"bvid": item["bvid"], **numeric,
                               "title_fingerprint": fingerprint})
            stack.extend(reversed([value for value in item.values() if isinstance(value, (dict, list))]))
        elif isinstance(item, list):
            stack.extend(reversed([value for value in item if isinstance(value, (dict, list))]))
    return result


def _policy(now, recent_days, older_days, low_views, popular_views, min_duration_seconds):
    if isinstance(now, float) and math.isfinite(now):
        now = int(now)
    now = _integer(now, "clock", minimum=1)
    if any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value)
           for value in (recent_days, older_days)) or not 0 < recent_days < older_days <= 3650:
        raise CatalogError("invalid_age_thresholds")
    low_views = _integer(low_views, "low_views", minimum=1)
    popular_views = _integer(popular_views, "popular_views", minimum=1)
    if low_views >= popular_views:
        raise CatalogError("invalid_view_thresholds")
    return {"now": now, "recent_days": recent_days, "older_days": older_days,
            "low_views": low_views, "popular_views": popular_views,
            "min_duration_seconds": _integer(min_duration_seconds, "min_duration", minimum=1)}


def _classify(video, policy):
    age = policy["now"] - video["pubdate"]
    if age < 0:
        raise CatalogError("future_publication")
    if video["duration"] < policy["min_duration_seconds"]:
        raise CatalogError("duration_below_minimum")
    age_band = "recent" if age <= policy["recent_days"] * 86400 else (
        "older" if age >= policy["older_days"] * 86400 else None)
    view_band = "low" if video["view"] <= policy["low_views"] else (
        "popular" if video["view"] >= policy["popular_views"] else None)
    return f"{age_band}-{view_band}" if age_band and view_band else None


def classify_video(record, *, now, recent_days=7, older_days=30, low_views=10_000,
                   popular_views=100_000, min_duration_seconds=30):
    """Return the stratum or None for the predeclared middle/gap bands."""
    policy = _policy(now, recent_days, older_days, low_views, popular_views, min_duration_seconds)
    return _classify(normalize_video(record), policy)


def select_catalog(records, *, now, recent_days=7, older_days=30, low_views=10_000,
                   popular_views=100_000, quota_per_stratum=1, max_videos=12,
                   min_duration_seconds=30, seed=0):
    policy = _policy(now, recent_days, older_days, low_views, popular_views, min_duration_seconds)
    quota = _integer(quota_per_stratum, "quota", minimum=1)
    maximum = _integer(max_videos, "max_videos", minimum=1)
    if quota > 3 or maximum > 12:
        raise CatalogError("catalog_limit_exceeded")
    if isinstance(seed, bool) or not isinstance(seed, int) or abs(seed) >= 2**31:
        raise CatalogError("invalid_seed")
    policy.update(quota_per_stratum=quota, max_videos=maximum, seed=seed)
    pools, rejected, unique, conflicts = {stratum: [] for stratum in STRATA}, Counter(), {}, set()
    for index, raw in enumerate(records):
        if index >= 10_000:
            raise CatalogError("catalog_input_limit_exceeded")
        try:
            video = normalize_video(raw)
        except CatalogError as error:
            rejected[error.classification] += 1
            continue
        previous = unique.get(video["bvid"])
        if previous:
            if any(previous[field] != video[field] for field in ("pubdate", "view", "duration")):
                conflicts.add(video["bvid"])
            else:
                rejected["duplicate"] += 1
                previous["title_fingerprint"] = min(previous["title_fingerprint"], video["title_fingerprint"])
        else:
            unique[video["bvid"]] = video
    rejected["conflicting_duplicate"] = len(conflicts)
    for bvid, video in unique.items():
        if bvid in conflicts:
            continue
        try:
            stratum = _classify(video, policy)
        except CatalogError as error:
            rejected[error.classification] += 1
            continue
        if stratum is None:
            rejected["outside_strata"] += 1
            continue
        pools[stratum].append({**video, "stratum": stratum})
    for pool in pools.values():
        pool.sort(key=lambda video: hashlib.sha256(f"{seed}:{video['bvid']}".encode()).hexdigest())
    selected = []
    for round_index in range(quota):
        for stratum in STRATA:
            if len(selected) < maximum and len(pools[stratum]) > round_index:
                selected.append(pools[stratum][round_index])
    selected_counts = Counter(video["stratum"] for video in selected)
    return {"selected": selected, "policy": policy,
            "pool_counts": {stratum: len(pools[stratum]) for stratum in STRATA},
            "shortages": {stratum: max(0, quota - selected_counts[stratum]) for stratum in STRATA},
            "rejected_counts": dict(sorted((key, value) for key, value in rejected.items() if value)),
            "selection_basis": "metadata and fixed seed only; no playback results or cache assertion"}


def plan_batch(selected, order=DEFAULT_ORDER, seed=0):
    if not isinstance(seed, int) or isinstance(seed, bool) or abs(seed) >= 2**31:
        raise CatalogError("invalid_seed")
    order = tuple(order)
    if not 1 <= len(order) <= 18 or any(mode not in ("base-direct", "hw-direct", "parallel") for mode in order) or any(order.count(mode) > 6 for mode in order):
        raise CatalogError("invalid_trial_order")
    selected = list(selected)
    if len(selected) > 12 or len({video.get("bvid") for video in selected}) != len(selected):
        raise CatalogError("invalid_selected_catalog")
    plans, trials = [], []
    for index, video in enumerate(selected):
        normalized = normalize_video(video)
        stratum = video.get("stratum")
        if stratum not in STRATA:
            raise CatalogError("invalid_stratum")
        actual = order
        # Mirror the standard two-mode ABBA order for alternating videos.
        if order == DEFAULT_ORDER and (index + seed) % 2:
            actual = ("parallel", "hw-direct", "hw-direct", "parallel")
        plans.append({"bvid": normalized["bvid"], "stratum": stratum, "order": list(actual)})
        for video_trial, mode in enumerate(actual, 1):
            trials.append({"batch_trial": len(trials) + 1, "bvid": normalized["bvid"],
                           "stratum": stratum, "video_trial": video_trial, "mode": mode})
    return {"video_plans": plans, "trials": trials, "planned_trial_count": len(trials),
            "order": list(order), "seed": seed, "selection_locked": True}


def _valid_metric(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0


def summarize_batch(samples, catalog):
    """Pair only within each selected video and its unchanged comparison key.

    Layer medians summarize per-video differences, giving each video one vote.
    Missing and failed measurements are neither zeros nor proof of improvement.
    """
    catalog = list(catalog)
    if len(catalog) > 12:
        raise CatalogError("catalog_limit_exceeded")
    by_video = {}
    for video in catalog:
        normalized = normalize_video(video)
        if video.get("stratum") not in STRATA or normalized["bvid"] in by_video:
            raise CatalogError("invalid_selected_catalog")
        by_video[normalized["bvid"]] = {"stratum": video["stratum"], "samples": []}
    for index, sample in enumerate(samples):
        if index >= 216:
            raise CatalogError("sample_limit_exceeded")
        if not isinstance(sample, dict) or sample.get("bvid") not in by_video:
            raise CatalogError("unplanned_video_sample")
        if sample.get("stratum", by_video[sample["bvid"]]["stratum"]) != by_video[sample["bvid"]]["stratum"]:
            raise CatalogError("sample_stratum_changed")
        by_video[sample["bvid"]]["samples"].append(sample)
    videos = []
    layers = {stratum: {"selected_videos": sum(video["stratum"] == stratum for video in catalog),
                        "paired_videos": 0, "metrics": {}} for stratum in STRATA}
    layer_differences = {stratum: {metric: [] for metric in METRICS} for stratum in STRATA}
    for bvid, entry in by_video.items():
        rows = entry["samples"]
        keys = set()
        baselines = set()
        for row in rows:
            key = row.get("comparison_key")
            if key is not None:
                if not isinstance(key, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", key):
                    raise CatalogError("invalid_comparison_key")
                keys.add(key)
            if row.get("status") == "measured":
                if key is None:
                    raise CatalogError("missing_comparison_key")
                actual_quality = row.get("actual_quality", row.get("quality"))
                if not isinstance(actual_quality, int) or isinstance(actual_quality, bool) or actual_quality < 1:
                    raise CatalogError("missing_actual_quality")
                codec = row.get("codec")
                if not isinstance(codec, str) or not re.fullmatch(r"[A-Za-z0-9_. -]{1,80}", codec):
                    raise CatalogError("missing_actual_codec")
                start = row.get("start_seconds")
                if not _valid_metric(start):
                    raise CatalogError("missing_actual_start")
                if any(isinstance(row.get(field), bool) or not isinstance(row.get(field), int) or row[field] <= 0 for field in ("width", "height")):
                    raise CatalogError("missing_actual_resolution")
                baselines.add(json.dumps([actual_quality, codec, row.get("width"), row.get("height"), start,
                                          row.get("duration_seconds"), row.get("concurrency"), row.get("chunk_kib")]))
        if len(keys) > 1 or len(baselines) > 1:
            raise CatalogError("mixed_video_baselines", bvid=bvid)
        per_mode = {}
        for mode in ("hw-direct", "parallel"):
            chosen = [row for row in rows if row.get("mode") == mode]
            per_mode[mode] = {"trials": len(chosen), "measured": sum(row.get("status") == "measured" for row in chosen),
                              "failed_or_timeout": sum(row.get("status") in ("failed", "timeout") for row in chosen),
                              "not_run": sum(row.get("status") == "not_run" for row in chosen)}
        paired = all(per_mode[mode]["measured"] > 0 for mode in per_mode)
        result = {"bvid": bvid, "stratum": entry["stratum"], "comparison_key": next(iter(keys), None),
                  "paired": paired, "modes": per_mode, "metrics": {}}
        if paired:
            layers[entry["stratum"]]["paired_videos"] += 1
        for metric in METRICS:
            mode_values = {mode: [row[metric] for row in rows if row.get("mode") == mode and row.get("status") == "measured"
                                 and _valid_metric(row.get(metric))] for mode in per_mode}
            if all(mode_values[mode] for mode in mode_values):
                hw = statistics.median(mode_values["hw-direct"])
                parallel = statistics.median(mode_values["parallel"])
                difference = parallel - hw
                result["metrics"][metric] = {"hw_median": hw, "parallel_median": parallel,
                                               "parallel_minus_hw": difference,
                                               "relative_change_percent": 100 * difference / hw if hw else None,
                                               "hw_samples": len(mode_values["hw-direct"]),
                                               "parallel_samples": len(mode_values["parallel"])}
                layer_differences[entry["stratum"]][metric].append(difference)
        videos.append(result)
    for stratum in STRATA:
        for metric, differences in layer_differences[stratum].items():
            if differences:
                layers[stratum]["metrics"][metric] = {"paired_videos": len(differences),
                                                       "median_parallel_minus_hw": statistics.median(differences),
                                                       "min_parallel_minus_hw": min(differences),
                                                       "max_parallel_minus_hw": max(differences)}
    return {"videos": videos, "strata": layers,
            "interpretation": "Native proxy metrics only; positive difference means parallel is slower/more paused. "
                              "No P95, causal claim, or proof that any CDN lacked a cached copy."}

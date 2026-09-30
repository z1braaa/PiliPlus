#!/usr/bin/env python3
"""Explicit-private-manifest CDN ablations; acquisition is intentionally absent.

Modes isolate the source pool and parallelism while retaining the same smart
selection/adaptation algorithm. Native timing is headless, not GUI acceptance.
"""
from __future__ import annotations

import argparse
from collections import Counter
import csv
import ctypes as C
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import resource
import selectors
import statistics
import sys
import time
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))
from tool import native_mpv_probe as native
from tool import vod_auto_test as vod

MODES = ('hw-direct', 'fixed-h-auto', 'fixed-h-smart', 'pool-auto', 'smart')
DEFAULT_ORDER = MODES + tuple(reversed(MODES))
MEMORY = ('buffered_payload_bytes', 'peak_buffered_payload_bytes',
          'hedge_buffered_payload_bytes', 'peak_hedge_buffered_payload_bytes',
          'active_origin_requests')
TRACE_INTS = ('t_ms', 'request_id', 'parent_id', 'transfer_id', 'range_start', 'range_end',
              'range_suffix', 'http', 'upstream_bytes', 'delivered_bytes',
              'active_origin_requests', 'buffered_payload_bytes', 'hedge_buffered_payload_bytes')
TRACE_LABELS = ('event', 'track', 'domain', 'phase', 'priority')


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def cache_known(row):
    return type(row.get('cache_pause_count')) is int and row['cache_pause_count'] >= 0 and number(row.get('cache_pause_seconds')) and row['cache_pause_seconds'] >= 0


def atomic_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.new')
    with temporary.open('w', encoding='utf-8') as stream:
        json.dump(data, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def audit_stats(data):
    """Retain raw signed integers; no arbitrary strings/URL-bearing diagnostics."""
    if not isinstance(data, dict):
        raise vod.HarnessError('invalid_bridge_stats')
    result = {}
    for key in ('observed_upstream_body_bytes', 'diagnostic_upstream_body_bytes', 'upstream_requests', 'elapsed_ms', 'clock_origin_unix_ms',
                'request_events_limit', 'request_events_dropped', 'host_request_counts_limit', 'host_request_counts_dropped'):
        if type(data.get(key)) is int:
            result[key] = data[key]
    result['raw_memory_counter_audit'] = {}
    for key in MEMORY:
        value = data.get(key)
        entry = {'present': key in data, 'type': type(value).__name__ if key in data else 'missing',
                 'valid_nonnegative_integer': type(value) is int and 0 <= value <= 1_000_000_000_000,
                 'negative': number(value) and value < 0}
        if value is None or type(value) in (bool, int) or number(value):
            entry['raw_value'] = value
            if key in data:
                result[key] = value
        result['raw_memory_counter_audit'][key] = entry
    if isinstance(data.get('diagnostics_enabled'), bool):
        result['diagnostics_enabled'] = data['diagnostics_enabled']
    if data.get('event_clock') == 'proxy_monotonic':
        result['event_clock'] = 'proxy_monotonic'
    hosts = data.get('selected_hosts', [])
    result['selected_hosts'] = [host for host in hosts[:100] if isinstance(host, str)
        and re.fullmatch(r'[A-Za-z0-9.-]{1,253}', host)] if isinstance(hosts, list) else []
    host_counts = data.get('host_request_counts', {})
    result['host_request_counts'] = {host: value for host, value in host_counts.items()
        if isinstance(host, str) and re.fullmatch(r'[A-Za-z0-9.-]{1,253}', host) and type(value) is int} if isinstance(host_counts, dict) else {}
    flushed = data.get('track_flushed_body_bytes', {})
    result['track_flushed_body_bytes'] = {key: value for key, value in flushed.items()
        if key in ('video', 'audio', 'unknown') and type(value) is int} if isinstance(flushed, dict) else {}
    for key in ('failures', 'range_failures', 'request_events'):
        entries = data.get(key, [])
        clean = []
        for entry in entries[:12000] if isinstance(entries, list) else []:
            if not isinstance(entry, dict):
                continue
            item = {}
            for field, value in entry.items():
                if field in TRACE_INTS and type(value) is int:
                    item[field] = value
                elif field in ('accepted', 'validator_checked', 'etag_equal', 'modified_equal', 'encoding_identity') and type(value) is bool:
                    item[field] = value
                elif field in TRACE_LABELS + ('host', 'kind', 'reason') and isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_. /-]{1,180}', value):
                    item[field] = value
                elif field not in TRACE_LABELS and type(value) is int:
                    # Diagnostic numeric fields cannot expose signed URLs.
                    item[field] = value
            clean.append(item)
        result[key] = clean
    return result


class AuditedBridge(vod.Bridge):
    def __init__(self, executable, payload, timeout, compiled=False):
        launch = vod.launch
        if compiled:
            def frozen(command, **kwargs):
                if len(command) == 2 and command[0] == executable and Path(command[1]) == REPO / 'tool/cdn_benchmark_bridge.dart':
                    command = [executable]
                return launch(command, **kwargs)
            vod.launch = frozen
        try:
            super().__init__(executable, payload, timeout)
        finally:
            vod.launch = launch

    def stats(self):
        os.write(self.process.stdin.fileno(), b'stats\n')
        received = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout.fileno(), selectors.EVENT_READ)
            deadline = time.monotonic() + 10
            while b'\n' not in received:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise vod.HarnessError('bridge_stats_timeout')
                block = os.read(self.process.stdout.fileno(), 65536)
                if not block or len(received) + len(block) > 8_000_000:
                    raise vod.HarnessError('bridge_stats_invalid')
                received.extend(block)
        return audit_stats(json.loads(received.split(b'\n', 1)[0]))


# ABI matches bundled media-kit libmpv generated bindings (mpv_node/list/union).
# Unknown formats are never dereferenced. Returned nodes are freed once.
class Node(C.Structure):
    pass
class NodeList(C.Structure):
    pass
class NodeUnion(C.Union):
    _fields_ = [('string', C.c_void_p), ('flag', C.c_int), ('int64', C.c_int64),
                ('double', C.c_double), ('list', C.POINTER(NodeList)), ('bytes', C.c_void_p)]
Node._fields_ = [('u', NodeUnion), ('format', C.c_uint)]
NodeList._fields_ = [('num', C.c_int), ('values', C.POINTER(Node)), ('keys', C.POINTER(C.c_char_p))]


def decode_node(node, depth=0):
    if depth > 5:
        raise ValueError('node_depth')
    if node.format == 0:
        return None
    if node.format == 3:
        return bool(node.u.flag)
    if node.format == 4:
        return int(node.u.int64)
    if node.format == 5:
        return float(node.u.double) if math.isfinite(node.u.double) else None
    if node.format in (7, 8) and node.u.list:
        items = node.u.list.contents
        if not 0 <= items.num <= 256 or (items.num and not items.values):
            raise ValueError('node_list')
        if node.format == 7:
            return [decode_node(items.values[index], depth + 1) for index in range(items.num)]
        if items.num and not items.keys:
            raise ValueError('node_keys')
        result = {}
        for index in range(items.num):
            raw = items.keys[index]
            if raw is None:
                raise ValueError('node_key_missing')
            key = raw.decode('ascii', errors='strict')
            if key in ('seekable-ranges', 'start', 'end', 'fw-bytes', 'total-bytes', 'raw-input-rate', 'cache-end', 'reader-pts'):
                result[key] = decode_node(items.values[index], depth + 1)
        return result
    # Strings/byte arrays and future formats cannot enter cache evidence.
    return None


def cache_state_sanitize(data):
    result = {'status': 'unknown', 'seekable_ranges': [], 'ranges_truncated': False}
    if not isinstance(data, dict):
        return result
    ranges = data.get('seekable-ranges')
    if isinstance(ranges, list) and ranges:
        valid = [item for item in ranges if isinstance(item, dict) and number(item.get('start'))
                 and number(item.get('end')) and 0 <= item['start'] <= item['end']]
        if len(valid) == len(ranges) and len(valid) <= 32:
            result.update(status='reported_ranges', seekable_ranges=[{'start': item['start'], 'end': item['end']} for item in valid])
        elif len(ranges) > 32:
            result['ranges_truncated'] = True
    for key in ('fw-bytes', 'total-bytes', 'raw-input-rate', 'cache-end', 'reader-pts'):
        if number(data.get(key)):
            result[key] = data[key]
    return result


def seek_cache_evidence(snapshot, target):
    ranges = snapshot.get('seekable_ranges', [])
    covered = any(item['start'] <= target <= item['end'] for item in ranges)
    status = ('target_within_reported_cache' if covered else
              'target_outside_reported_ranges' if snapshot.get('status') == 'reported_ranges' else 'unknown')
    return {'classification': status, 'target_seconds': target, 'pre_seek_cache_state': snapshot,
            'main_demuxer_target_cached': True if covered else False if snapshot.get('status') == 'reported_ranges' else None,
            'network_recovery_case': 'not_reproduced_cached_target' if covered else 'not_proven_end_to_end_uncached',
            'uncached_seek_confirmed': False if covered else None,
            'boundary': 'mpv reports the main demuxer only, not all EDL audio/video demuxers. Main range exclusion does not prove audio/OS/CDN uncached. Missing/empty/truncated ranges remain unknown.'}


def cpu_snapshot():
    usage = resource.getrusage(resource.RUSAGE_SELF)
    return {'wall': time.monotonic(), 'user': usage.ru_utime, 'system': usage.ru_stime,
            'peak_rss_bytes': usage.ru_maxrss if sys.platform == 'darwin' else usage.ru_maxrss * 1024}


def cpu_delta(before, after):
    wall = max(0, after['wall'] - before['wall'])
    user, system = max(0, after['user'] - before['user']), max(0, after['system'] - before['system'])
    return {'wall_seconds': round(wall, 4), 'user_cpu_seconds': round(user, 4),
            'system_cpu_seconds': round(system, 4),
            'cpu_percent': round((user + system) / wall * 100, 2) if wall else None,
            'peak_rss_bytes': after['peak_rss_bytes'],
            'boundary': 'This native child and its threads only; excludes bridge and parent. Multi-core CPU percent may exceed 100; RSS is process high-water, not payload or cache bytes.'}


def native_run(args, payload):
    """Reuse native ABI/library/options, adding real post-seek observation."""
    report = native.empty_report(args)
    report['metrics'].update(post_seek_observation_completed_seconds=None)
    report['checks'].update(post_seek_observation_completed=False if args.seek_seconds is not None else None)
    report['conditions']['post_seek_seconds'] = args.post_seek_seconds
    report['conditions']['hardware_decode'] = args.hardware_decode
    report['native_cache_samples'] = []
    report['official_contract'] = {'abi_header': 'https://raw.githubusercontent.com/mpv-player/mpv/v0.36.0/libmpv/client.h',
        'properties': 'https://raw.githubusercontent.com/mpv-player/mpv/v0.36.0/DOCS/man/input.rst', 'abi_reference_version': 'v0.36.0',
        'boundary': 'Actual mpv version is recorded separately; unsupported properties remain unknown.'}
    report['seek_cache_evidence'] = {'classification': 'not_requested' if args.seek_seconds is None else 'unknown'}
    player = None
    overall, segment_cache = native.CacheObservation(), native.CacheObservation()
    began = time.monotonic()
    cpu_began = cpu_snapshot()
    segment = 'startup'
    first_position = last_position = seek_began = None
    seek_restart = seek_near = False
    next_sample = 0
    try:
        video, audio = native.validate_payload(payload)
        lib, dependencies = native.load_library(Path(args.library))
        lib.mpv_client_api_version.argtypes = []
        lib.mpv_client_api_version.restype = C.c_ulong
        api_version = lib.mpv_client_api_version()
        report['conditions']['libmpv_client_api_version'] = {'packed': api_version,
            'major': api_version >> 16, 'minor': api_version & 0xffff}
        lib.mpv_free_node_contents.argtypes = [C.POINTER(Node)]
        lib.mpv_free_node_contents.restype = None
        player = native.NativePlayer(lib)
        original_options = native.APP_OPTIONS
        native.APP_OPTIONS = {**original_options, 'hwdec': args.hardware_decode}
        try:
            player.initialize(args.network_timeout_seconds, args.buffer_seconds, args.buffer_mib)
        finally:
            native.APP_OPTIONS = original_options
        version = player.string('mpv-version')
        match = re.search(r'\bmpv\s+v?\d+\.\d+(?:\.\d+)?', version or '')
        report['conditions']['mpv_version'] = match.group(0) if match else None
        report['conditions']['hardware_decode_requested'] = args.hardware_decode
        def state():
            node = Node()
            if lib.mpv_get_property(player.handle, b'demuxer-cache-state', 6, C.byref(node)) < 0:
                return {'status': 'unknown', 'seekable_ranges': []}
            try:
                return cache_state_sanitize(decode_node(node))
            except (ValueError, UnicodeError):
                return {'status': 'unknown', 'seekable_ranges': []}
            finally:
                lib.mpv_free_node_contents(C.byref(node))
        began = time.monotonic()
        cpu_load_began = previous_cpu = cpu_snapshot()
        report['clock_alignment'] = {'loadfile_issued_unix_ms': time.time_ns() // 1_000_000,
            'monotonic_zero_seconds': began, 'seek_issued_unix_ms': None,
            'boundary': 'Proxy/native clocks have separate monotonic origins. Unix-ms anchors permit approximate alignment, subject to scheduling, millisecond precision and wall-clock adjustments.'}
        deadline = began + args.timeout_seconds
        player.command(native.loadfile_arguments(native.build_edl(video, audio), 0, version))
        while time.monotonic() < deadline:
            pointer = lib.mpv_wait_event(player.handle, 0.05)
            now = time.monotonic()
            cache_flag = None
            if pointer:
                event = pointer.contents
                if event.event_id == native.MPV_EVENT_FILE_LOADED:
                    if report['metrics']['file_loaded_seconds'] is None:
                        report['metrics']['file_loaded_seconds'] = native.rounded(now - began)
                    report['checks']['file_loaded'] = True
                elif event.event_id == native.MPV_EVENT_PLAYBACK_RESTART and segment == 'seek':
                    if report['metrics']['seek_restart_seconds'] is None:
                        report['metrics']['seek_restart_seconds'] = native.rounded(now - seek_began)
                    seek_restart = True
                elif event.event_id == native.MPV_EVENT_PROPERTY_CHANGE and event.data:
                    prop = C.cast(event.data, C.POINTER(native.MpvProperty)).contents
                    if prop.name == b'paused-for-cache' and prop.format == native.MPV_FORMAT_FLAG and prop.data:
                        cache_flag = bool(C.cast(prop.data, C.POINTER(C.c_int)).contents.value)
                elif event.event_id == native.MPV_EVENT_END_FILE and event.data:
                    end = C.cast(event.data, C.POINTER(native.MpvEndFile)).contents
                    if end.reason != 5:
                        raise native.ProbeFailure('media_error' if end.error < 0 else 'media_ended_before_target')
                elif event.event_id == native.MPV_EVENT_SHUTDOWN:
                    raise native.ProbeFailure('player_shutdown')
            if cache_flag is None:
                cache_flag = player.number('paused-for-cache', native.MPV_FORMAT_FLAG)
            overall.update(cache_flag, now)
            segment_cache.update(cache_flag, now)
            position = player.number('time-pos')
            if now - began >= next_sample and len(report['timeline']) < 1201:
                report['timeline'].append({'elapsed_seconds': native.rounded(now - began),
                    'position_seconds': native.rounded(position),
                    'cache_duration_seconds': player.number('demuxer-cache-duration'),
                    'cache_speed_bytes_s': player.number('cache-speed'), 'paused_for_cache': cache_flag})
                current_cpu = cpu_snapshot()
                report['native_cache_samples'].append({'elapsed_seconds': native.rounded(now - began),
                    'position_seconds': native.rounded(position), 'segment': segment, 'cache_state': state(),
                    'process_cpu': cpu_delta(cpu_load_began, current_cpu),
                    'interval_cpu': cpu_delta(previous_cpu, current_cpu),
                    'decoder_frame_drop_count': player.number('decoder-frame-drop-count', native.MPV_FORMAT_INT64),
                    'frame_drop_count': player.number('frame-drop-count', native.MPV_FORMAT_INT64),
                    'estimated_frame_number': player.number('estimated-frame-number', native.MPV_FORMAT_INT64),
                    'hardware_decode_current': safe_native_token(player.string('hwdec-current'))})
                previous_cpu = current_cpu
                next_sample = now - began + 0.5
            if position is None:
                continue
            if segment == 'startup':
                if first_position is None:
                    first_position = position
                    report['checks']['start_position_verified'] = abs(position) <= 1
                if position >= 0.1 and report['metrics']['initial_progress_seconds'] is None:
                    report['metrics']['initial_progress_seconds'] = native.rounded(now - began)
                if last_position is not None and position > last_position + 0.01:
                    report['checks']['positive_time_progress'] = True
                last_position = position
                if position < args.duration_seconds:
                    continue
                report['metrics']['playback_progress_seconds'] = native.rounded(now - began)
                report['checks'].update(both_tracks_present=player.tracks_present(), both_tracks_decoded=player.tracks_decoded())
                if not all(report['checks'][key] for key in ('file_loaded', 'both_tracks_present', 'both_tracks_decoded', 'positive_time_progress', 'start_position_verified')):
                    raise native.ProbeFailure('playback_checks_failed')
                report['segments']['startup'] = segment_cache.snapshot(now)
                if args.seek_seconds is None:
                    report['status'] = 'passed'
                    break
                if abs(position - args.seek_seconds) < 0.5:
                    raise native.ProbeFailure('seek_target_too_close')
                report['seek_cache_evidence'] = seek_cache_evidence(state(), args.seek_seconds)
                seek_began = time.monotonic()
                report['clock_alignment']['seek_issued_unix_ms'] = time.time_ns() // 1_000_000
                player.command(['seek', f'{args.seek_seconds:.6f}', 'absolute+exact'])
                segment, segment_cache = 'seek', native.CacheObservation()
            elif seek_restart:
                if not seek_near:
                    if abs(position - args.seek_seconds) > 1:
                        continue
                    seek_near = True
                    report['checks']['seek_position_verified'] = True
                    report['metrics']['seek_position_seconds'] = native.rounded(position)
                if position >= args.seek_seconds + 1 and report['metrics']['seek_progress_seconds'] is None:
                    report['metrics']['seek_progress_seconds'] = native.rounded(now - seek_began)
                if position >= args.seek_seconds + args.post_seek_seconds:
                    report['metrics']['post_seek_observation_completed_seconds'] = native.rounded(now - seek_began)
                    report['checks']['post_seek_observation_completed'] = True
                    report['status'] = 'passed'
                    break
        else:
            report.update(status='timeout', error_category='seek_timeout' if segment == 'seek' else 'playback_timeout')
    except native.ProbeFailure as error:
        report.update(status='failed', error_category=str(error))
    except Exception:
        report.update(status='failed', error_category='probe_internal_error')
    finally:
        now = time.monotonic()
        report['metrics'].update(overall.snapshot(now))
        report['segments'][segment] = segment_cache.snapshot(now)
        report['process_cpu'] = cpu_delta(cpu_began, cpu_snapshot())
        if player is not None:
            player.close()
    return report


def native_safe(raw):
    result = vod.sanitize_native_result(raw)
    for key in ('post_seek_observation_completed_seconds',):
        value = raw.get('metrics', {}).get(key)
        result[key] = value if value is None or number(value) else None
    post_seek_completed = raw.get('checks', {}).get('post_seek_observation_completed')
    result['post_seek_observation_completed'] = post_seek_completed if type(post_seek_completed) is bool else None
    def safe_cpu(value):
        return {key: value.get(key) if number(value.get(key)) else None
                for key in ('wall_seconds', 'user_cpu_seconds', 'system_cpu_seconds', 'cpu_percent', 'peak_rss_bytes')} if isinstance(value, dict) else {'status': 'unknown'}
    def safe_state(value):
        if not isinstance(value, dict):
            return cache_state_sanitize(None)
        state = cache_state_sanitize({'seekable-ranges': value.get('seekable_ranges'),
            **{key: value.get(key) for key in ('fw-bytes', 'total-bytes', 'raw-input-rate', 'cache-end', 'reader-pts')}})
        if value.get('ranges_truncated') is True:
            state.update(status='unknown', seekable_ranges=[], ranges_truncated=True)
        return state
    samples = []
    for sample in raw.get('native_cache_samples', [])[:1201] if isinstance(raw.get('native_cache_samples'), list) else []:
        if not isinstance(sample, dict):
            continue
        item = {key: sample.get(key) if number(sample.get(key)) else None for key in
                ('elapsed_seconds', 'position_seconds', 'decoder_frame_drop_count', 'frame_drop_count', 'estimated_frame_number')}
        item.update(segment=sample.get('segment') if sample.get('segment') in ('startup', 'seek') else 'unknown',
                    cache_state=safe_state(sample.get('cache_state')), process_cpu=safe_cpu(sample.get('process_cpu')),
                    interval_cpu=safe_cpu(sample.get('interval_cpu')),
                    hardware_decode_current=safe_native_token(sample.get('hardware_decode_current')))
        samples.append(item)
    result['native_cache_samples'] = samples
    result['process_cpu'] = safe_cpu(raw.get('process_cpu'))
    cache = raw.get('seek_cache_evidence', {})
    if isinstance(cache, dict) and number(cache.get('target_seconds')):
        result['seek_cache_evidence'] = seek_cache_evidence(safe_state(cache.get('pre_seek_cache_state')), cache['target_seconds'])
    else:
        result['seek_cache_evidence'] = {'classification': 'not_requested' if isinstance(cache, dict) and cache.get('classification') == 'not_requested' else 'unknown'}
    clock = raw.get('clock_alignment', {})
    result['clock_alignment'] = {key: clock.get(key) if isinstance(clock, dict) and number(clock.get(key)) else None
        for key in ('loadfile_issued_unix_ms', 'monotonic_zero_seconds', 'seek_issued_unix_ms')}
    result['official_contract'] = {'abi_header': 'https://raw.githubusercontent.com/mpv-player/mpv/v0.36.0/libmpv/client.h',
        'properties': 'https://raw.githubusercontent.com/mpv-player/mpv/v0.36.0/DOCS/man/input.rst', 'abi_reference_version': 'v0.36.0'}
    api = raw.get('conditions', {}).get('libmpv_client_api_version', {})
    result['libmpv_client_api_version'] = {key: api.get(key) if type(api.get(key)) is int else None
                                         for key in ('packed', 'major', 'minor')} if isinstance(api, dict) else {'status': 'unknown'}
    return result


def safe_native_token(value):
    return value if isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_. -]{1,100}', value) else None


def mode_payload(mode, manifest, args):
    if mode not in MODES or mode == 'hw-direct':
        return None
    return {'video_urls': manifest['video_urls'], 'audio_urls': manifest['audio_urls'],
            'duration_seconds': manifest['view']['page_duration'], 'auto_select': True, 'adaptive': True,
            'parallel': mode in ('fixed-h-smart', 'smart'), 'fixed_huawei': mode.startswith('fixed-h-'),
            'diagnostics': args.diagnostics, 'concurrency': args.concurrency, 'chunk_kib': args.chunk_kib,
            'request_timeout_seconds': 10}


def timed_profile(mode, profile, equal_timeout):
    return equal_timeout if profile == 'equal' else 5 if mode == 'hw-direct' else 60


def parse_pairs(items, converter=str):
    result = {}
    for item in items:
        key, separator, value = item.partition('=')
        if not separator or not re.fullmatch(r'BV[A-Za-z0-9]{10}', key) or key in result:
            raise vod.HarnessError('invalid_or_duplicate_bv_mapping')
        result[key] = converter(value)
    return result


def case_plan(manifest, observed, target, post_seek):
    duration = manifest.get('view', {}).get('page_duration')
    if not number(duration) or duration <= 2:
        return {'status': 'not_applicable', 'classification': 'page_duration_unknown'}
    if observed >= duration - 1:
        return {'status': 'not_applicable', 'classification': 'media_too_short_for_requested_observation', 'page_duration_seconds': duration}
    seek = None if target == 'none' else float(target) if target != 'auto' else round(duration * 0.75, 3)
    if seek is not None and (not number(seek) or seek < 0 or seek + post_seek >= duration - 0.5 or abs(seek - observed) < 1):
        return {'status': 'not_applicable', 'classification': 'invalid_or_nearby_seek_target', 'page_duration_seconds': duration}
    return {'status': 'planned', 'start_seconds': 0, 'observation_seconds': observed,
            'seek_seconds': seek, 'post_seek_seconds': post_seek if seek is not None else None,
            'page_duration_seconds': duration, 'covers_90_seconds_from_zero': observed >= 90,
            'covers_90_to_150_seconds_from_zero': observed >= 150}


def comparison_identity(manifest, condition, artifacts):
    return hashlib.sha256(json.dumps({'source_fingerprint': manifest['manifest_fingerprint'],
        'actual_quality': manifest['quality'], 'codec': manifest['codec'], 'width': manifest['width'],
        'height': manifest['height'], 'condition': condition, 'runtime_artifacts': artifacts}, sort_keys=True).encode()).hexdigest()


def summary_rows(rows):
    result = {}
    for group_id in dict.fromkeys(row['group_id'] for row in rows):
        group = [row for row in rows if row['group_id'] == group_id]
        result[group_id] = {}
        for mode in dict.fromkeys(row['mode'] for row in group):
            selected = [row for row in group if row['mode'] == mode]
            valid = [row for row in selected if row['status'] == 'measured']
            stats = {'planned': len(selected), 'measured': len(valid),
                     'status_counts': dict(Counter(row['status'] for row in selected)),
                     'failed': sum(row['status'] == 'failed' for row in selected),
                     'timeout': sum(row['status'] == 'timeout' for row in selected),
                     'not_run': sum(row['status'] == 'not_run' for row in selected),
                     'not_applicable': sum(row['status'] == 'not_applicable' for row in selected),
                     'cache_unknown_measured': sum(not cache_known(row) for row in valid)}
            for field in ('initial_progress_seconds', 'seek_progress_seconds', 'seek_restart_seconds', 'post_seek_observation_completed_seconds'):
                values = [row[field] for row in valid if number(row.get(field))]
                stats[field] = {'samples': len(values), 'median': statistics.median(values) if values else None}
            stats['cache_by_trial'] = [{key: row.get(key) for key in ('trial', 'status', 'cache_pause_count', 'cache_pause_seconds', 'classification')} for row in selected]
            result[group_id][mode] = stats
    return result


def bridge_cpu(pid):
    call = vod.run_command(['ps', '-p', str(pid), '-o', 'cputime=', '-o', 'rss='], timeout=2)
    fields = call['stdout'].split()
    if call['exit_code'] != 0 or len(fields) != 2 or not re.fullmatch(r'[0-9:.-]+', fields[0]) or not fields[1].isdigit():
        return {'status': 'unknown'}
    return {'status': 'reported', 'process_cpu_time_text': fields[0], 'rss_bytes': int(fields[1]) * 1024,
            'boundary': 'Bridge process only; sampled before/after native playback; CPU text may be second-quantized and RSS is not a peak.'}


def run(args):
    locations = parse_pairs(args.manifest, Path)
    expected = parse_pairs(args.actual_quality, int)
    if set(locations) != set(expected):
        raise vod.HarnessError('every_manifest_requires_explicit_actual_quality')
    cases = parse_pairs(args.case)
    if set(cases) - set(locations):
        raise vod.HarnessError('case_without_matching_manifest')
    if not re.fullmatch(r'[a-f0-9]{40}', args.reference_source) or not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', args.runtime_label):
        raise vod.HarnessError('invalid_reference_source_or_runtime_label')
    manifests = {}
    for bv, path in locations.items():
        if path.stat().st_mode & 0o077 or path.stat().st_size > 1_048_576:
            raise vod.HarnessError('manifest_not_private_or_too_large')
        manifest = vod.normalize_manifest(json.loads(path.read_text(encoding='utf-8')))
        if manifest.get('view', {}).get('bvid') not in (None, bv):
            raise vod.HarnessError('manifest_bvid_mismatch', bvid=bv)
        if manifest['quality'] != expected[bv]:
            raise vod.HarnessError('actual_quality_expectation_mismatch', bvid=bv, expected=expected[bv], actual=manifest['quality'])
        manifests[bv] = manifest
    if not Path(args.library).is_file():
        raise vod.HarnessError('native_library_missing')
    executable = vod.resolve_executable(args.bridge_executable or args.dart, 'dart')
    frozen_files = {'ablation_tool': Path(__file__), 'native_probe': REPO / 'tool/native_mpv_probe.py',
                    'orchestrator': REPO / 'tool/vod_auto_test.py', 'libmpv': Path(args.library),
                    'bridge_source': REPO / 'tool/cdn_benchmark_bridge.dart',
                    'proxy_source': REPO / 'lib/http/cdn_playback_proxy.dart',
                    'origin_policy': REPO / 'lib/http/cdn_origin_policy.dart', 'bridge_executable': Path(executable)}
    frozen_files['startup_trace'] = REPO / 'lib/utils/cdn_startup_trace.dart'
    frozen_files.update({'manifest_' + bv: path for bv, path in locations.items()})
    artifacts = {key + '_sha256': vod.sha256_file(path) for key, path in frozen_files.items()}
    def freeze_check():
        if any(vod.sha256_file(path) != artifacts[key + '_sha256'] for key, path in frozen_files.items()):
            raise vod.HarnessError('frozen_runtime_changed')
    order = tuple(args.order.split(','))
    if not order or len(order) > 20 or any(mode not in MODES for mode in order):
        raise vod.HarnessError('invalid_ablation_order')
    timeout_profiles = ('equal', 'app') if args.timeout_profile == 'both' else (args.timeout_profile,)
    rows, conditions = [], {}
    for bv, manifest in manifests.items():
        values = cases.get(bv, f'{args.duration_seconds}:auto').split(':')
        if len(values) != 2:
            raise vod.HarnessError('invalid_case_observation_seek')
        observed = float(values[0])
        if not number(observed) or not 1 <= observed <= 600:
            raise vod.HarnessError('invalid_observation_seconds')
        case = case_plan(manifest, observed, values[1], args.post_seek_seconds)
        for timeout_profile in timeout_profiles:
            group_id = f'{bv}-{args.buffer_seconds:g}s-{args.buffer_mib:g}MiB-{timeout_profile}'
            condition = {**case, 'timeout_profile': timeout_profile,
                         'mpv_timeouts': {mode: timed_profile(mode, timeout_profile, args.equal_network_timeout) for mode in MODES},
                         'proxy_upstream_timeout_seconds': 10, 'buffer_seconds': args.buffer_seconds,
                         'buffer_mib': args.buffer_mib, 'concurrency': args.concurrency,
                         'chunk_kib': args.chunk_kib, 'diagnostics': args.diagnostics,
                         'runtime_label': args.runtime_label}
            condition['hardware_decode_requested'] = args.hardware_decode
            conditions[group_id] = condition
            key = comparison_identity(manifest, condition, artifacts)
            for trial, mode in enumerate(order, 1):
                rows.append({'group_id': group_id, 'bvid': bv, 'trial': trial, 'mode': mode,
                             'status': 'not_run' if case['status'] == 'planned' else 'not_applicable',
                             'classification': 'not_started' if case['status'] == 'planned' else case['classification'],
                             'comparison_key': key, 'quality': manifest['quality'], 'codec': manifest['codec'],
                             'width': manifest['width'], 'height': manifest['height']})
    report = vod.base_report('cdn_strategy_ablation')
    report.update(status='running', runtime_artifacts=artifacts, conditions=conditions, samples=rows,
        source_identity={'reference_release': '5436', 'reference_source_commit': args.reference_source,
                         'runtime_label': args.runtime_label, 'actual_runtime_sha256': artifacts},
        source_quality_policy={'requested_quality_for_acquisition': args.requested_quality,
            'actual_representation_expectations': expected, 'highest_across_all_codecs_verified': False,
            'boundary': 'No acquisition in this tool; explicit actual expectations are checked, not inferred from the requested highest quality.'},
        credentials='Explicit private media manifests only; no Cookie acquisition or account reads; URLs stay in child stdin and memory.',
        boundaries=['Headless software decode/null output, not GUI first frame/audio or subjective acceptance.',
                    'Equal profile isolates modes with mpv60 by default; app H5/proxy60 is a separate strategy reproduction.',
                    'Pre-seek startup segment is the entire observation; initial metric is loadfile to time-pos>=0.1, not first mathematical positive value.',
                    'seek_progress_seconds records the first target+1 second; post_seek_observation_completed_seconds is separate and defaults to target+15 seconds.',
                    'Cache pause unknown/failure/timeout/not-applicable are never zero-success observations.',
                    'Exact cached seekable ranges are optional outer-demuxer evidence; EDL component/OS/CDN caches are not mapped. Cached targets do not exercise uncached recovery.',
                    'CPU is native child threads only; bridge process has separate snapshots; drop/count unsupported remains unknown.',
                    'Fresh local processes cannot guarantee remote cold caches; medians remain separate per BV/cache/timeout/runtime condition.'])
    started = time.monotonic()
    if (args.output / 'report.json').exists():
        raise vod.HarnessError('existing_output_refused')
    def checkpoint():
        report['elapsed_seconds'] = round(time.monotonic() - started, 3)
        report['summary'] = summary_rows(rows)
        atomic_json(args.output / 'report.json', report)
        fields = ('group_id', 'bvid', 'trial', 'mode', 'status', 'classification', 'quality', 'codec',
                  'width', 'height', 'cache_observation_status', 'initial_progress_seconds',
                  'cache_pause_count', 'cache_pause_seconds', 'startup_cache_pause_count',
                  'startup_cache_pause_seconds', 'seek_cache_pause_count', 'seek_cache_pause_seconds',
                  'seek_restart_seconds', 'seek_progress_seconds', 'post_seek_observation_completed_seconds',
                  'bridge_setup_seconds', 'trial_elapsed_seconds')
        content = io.StringIO()
        writer = csv.DictWriter(content, fields, extrasaction='ignore')
        writer.writeheader()
        writer.writerows(rows)
        destination = args.output / 'samples.csv'
        temporary = destination.with_name(destination.name + '.new')
        with temporary.open('w', encoding='utf-8-sig', newline='') as stream:
            stream.write(content.getvalue())
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
    checkpoint()
    for row in rows:
        if row['status'] == 'not_applicable':
            continue
        remaining = args.total_budget_seconds - (time.monotonic() - started)
        if remaining <= 0:
            row['classification'] = 'total_budget_exhausted'
            checkpoint()
            continue
        bridge = None
        condition = conditions[row['group_id']]
        manifest = manifests[row['bvid']]
        began = time.monotonic()
        row.update(status='running', classification='trial_in_flight')
        checkpoint()
        try:
            freeze_check()
            video, audio = manifest['video_urls'][0], manifest['audio_urls'][0]
            if row['mode'] == 'hw-direct':
                video, audio = vod.hw_url(video), vod.hw_url(audio)
            else:
                handshake_before = time.time_ns() // 1_000_000
                bridge = AuditedBridge(executable, mode_payload(row['mode'], manifest, args), min(15, remaining), compiled=bool(args.bridge_executable))
                row['bridge_clock_handshake'] = {'parent_before_unix_ms': handshake_before,
                    'parent_ready_unix_ms': time.time_ns() // 1_000_000,
                    'proxy_clock_origin_unix_ms': bridge.urls.get('clock_origin_unix_ms') if type(bridge.urls.get('clock_origin_unix_ms')) is int else None,
                    'proxy_elapsed_ms_at_ready': bridge.urls.get('elapsed_ms') if type(bridge.urls.get('elapsed_ms')) is int else None,
                    'boundary': 'Handshake bounds scheduling offset; separate relative clocks cannot be overlaid at zero.'}
                if row['mode'].startswith('fixed-h-'):
                    counts = bridge.urls.get('candidate_counts', {})
                    if any(counts.get(track, {}).get('total') != 1 for track in ('video', 'audio')):
                        raise vod.HarnessError('fixed_huawei_resolver_not_strict_singleton')
                video, audio = bridge.urls['video_url'], bridge.urls['audio_url']
                row['bridge_cpu_before'] = bridge_cpu(bridge.process.pid)
            row['bridge_setup_seconds'] = round(time.monotonic() - began, 4) if bridge else 0
            timeout = min(args.trial_deadline_seconds, remaining) - (time.monotonic() - began)
            if timeout <= 0:
                raise vod.HarnessError('trial_budget_exhausted')
            command = [sys.executable, str(Path(__file__)), 'native-child', '--library', args.library,
                '--duration-seconds', str(condition['observation_seconds']), '--timeout-seconds', str(timeout),
                '--network-timeout-seconds', str(condition['mpv_timeouts'][row['mode']]),
                '--buffer-seconds', str(args.buffer_seconds), '--buffer-mib', str(args.buffer_mib),
                '--post-seek-seconds', str(args.post_seek_seconds), '--hardware-decode', args.hardware_decode]
            if condition['seek_seconds'] is not None:
                command += ['--seek-seconds', str(condition['seek_seconds'])]
            response = vod.run_command(command, timeout=timeout, payload=json.dumps({'video_url': video, 'audio_url': audio}) + '\n')
            if response['timed_out']:
                row.update(status='timeout', classification='native_deadline_exceeded')
            else:
                raw = json.loads(response['stdout'])
                row.update(native_safe(raw))
                success = vod.native_measurement_succeeded(row, response['exit_code'], condition['seek_seconds'] is not None)
                if condition['seek_seconds'] is not None:
                    success = success and row.get('post_seek_observation_completed') is True
                row['status'] = 'measured' if success else 'timeout' if row.get('native_status') == 'timeout' else 'failed'
                if row['status'] == 'measured':
                    row.pop('classification', None)
                elif row.get('classification') == 'trial_in_flight':
                    row['classification'] = 'native_measurement_failed'
            row['cache_observation_status'] = 'known' if cache_known(row) else 'unknown'
            observed_key = row.get('playback_progress_seconds')
            first_key = row.get('initial_progress_seconds')
            row['sampled_pause_phase_evidence'] = [
                {'elapsed_seconds': sample.get('elapsed_seconds'), 'position_seconds': sample.get('position_seconds'),
                 'phase': 'seek_observation' if number(observed_key) and sample.get('elapsed_seconds', 0) > observed_key
                          else 'before_initial_0_1s_progress_threshold' if number(first_key) and sample.get('elapsed_seconds', 0) < first_key
                          else 'continuous_pre_seek_progress'}
                for sample in row.get('timeline', []) if sample.get('paused_for_cache') is True]
        except KeyboardInterrupt:
            row.update(status='unknown_interrupted', classification='in_flight_trial_interrupted')
            report.update(status='interrupted', harness_error={'classification': 'operator_interrupted'})
            checkpoint()
            break
        except Exception as error:
            row.update(status='failed', **vod.safe_error(error))
        finally:
            if bridge:
                try:
                    row['bridge_cpu_after'] = bridge_cpu(bridge.process.pid)
                    row['transport'] = bridge.stats()
                except Exception:
                    row['transport_stats_status'] = 'unknown'
                try:
                    bridge.close()
                except Exception:
                    row['bridge_cleanup_status'] = 'unknown'
                    report.update(status='harness_failed', harness_error={'classification': 'bridge_cleanup_failed'})
            row['trial_elapsed_seconds'] = round(time.monotonic() - began, 4)
            checkpoint()
        if report['status'] in ('harness_failed', 'interrupted'):
            break
        try:
            freeze_check()
        except Exception as error:
            report.update(status='harness_failed', harness_error=vod.safe_error(error))
            checkpoint()
            break
        print(json.dumps({key: row.get(key) for key in ('bvid', 'group_id', 'mode', 'trial', 'status', 'initial_progress_seconds', 'cache_pause_count', 'cache_pause_seconds', 'seek_progress_seconds')}), flush=True)
    if report['status'] == 'running':
        report['status'] = 'completed' if all(row['status'] in ('measured', 'not_applicable') for row in rows) else 'completed_with_failures_or_gaps'
    checkpoint()
    return 0 if report['status'] == 'completed' else 1


def parser():
    root = argparse.ArgumentParser(description=__doc__)
    sub = root.add_subparsers(dest='command', required=True)
    run_parser = sub.add_parser('run')
    run_parser.add_argument('--manifest', action='append', required=True, metavar='BV=PRIVATE_JSON')
    run_parser.add_argument('--actual-quality', action='append', required=True, metavar='BV=ACTUAL_CODE')
    run_parser.add_argument('--case', action='append', default=[], metavar='BV=OBSERVE:SEEK_OR_NONE')
    run_parser.add_argument('--library', required=True)
    run_parser.add_argument('--bridge-executable')
    run_parser.add_argument('--dart')
    run_parser.add_argument('--output', required=True, type=Path)
    run_parser.add_argument('--duration-seconds', type=float, default=150)
    run_parser.add_argument('--post-seek-seconds', type=float, default=15)
    run_parser.add_argument('--hardware-decode', choices=('no', 'videotoolbox-copy'), default='no')
    run_parser.add_argument('--timeout-profile', choices=('equal', 'app', 'both'), default='equal')
    run_parser.add_argument('--equal-network-timeout', type=float, default=60)
    run_parser.add_argument('--buffer-seconds', type=float, default=16)
    run_parser.add_argument('--buffer-mib', type=float, default=4)
    run_parser.add_argument('--concurrency', type=int, default=8)
    run_parser.add_argument('--chunk-kib', type=int, default=512)
    run_parser.add_argument('--trial-deadline-seconds', type=float, default=240)
    run_parser.add_argument('--total-budget-seconds', type=float, default=6000)
    run_parser.add_argument('--requested-quality', type=int, default=129)
    run_parser.add_argument('--runtime-label', default='diagnostic')
    run_parser.add_argument('--reference-source', default='f6db39a29db522ef6f97eb7dc2e257c267c07771')
    run_parser.add_argument('--order', default=','.join(DEFAULT_ORDER))
    run_parser.add_argument('--diagnostics', action=argparse.BooleanOptionalAction, default=True)
    child = sub.add_parser('native-child')
    child.add_argument('--library', required=True)
    child.add_argument('--duration-seconds', type=float, required=True)
    child.add_argument('--start-seconds', type=float, default=0)
    child.add_argument('--seek-seconds', type=float)
    child.add_argument('--post-seek-seconds', type=float, default=15)
    child.add_argument('--hardware-decode', choices=('no', 'videotoolbox-copy'), default='no')
    child.add_argument('--timeout-seconds', type=float, required=True)
    child.add_argument('--network-timeout-seconds', type=float, default=60)
    child.add_argument('--buffer-seconds', type=float, default=16)
    child.add_argument('--buffer-mib', type=float, default=4)
    return root


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        for field, low, high in (('post_seek_seconds', 1, 120), ('buffer_seconds', 1, 3600), ('buffer_mib', 1, 2048)):
            if not number(getattr(args, field)) or not low <= getattr(args, field) <= high:
                raise vod.HarnessError('invalid_' + field)
        if args.command == 'run':
            for field, low, high in (('trial_deadline_seconds', 1, 600), ('total_budget_seconds', 1, 18000), ('equal_network_timeout', 1, 60), ('concurrency', 1, 32), ('chunk_kib', 64, 4096)):
                if not number(getattr(args, field)) or not low <= getattr(args, field) <= high:
                    raise vod.HarnessError('invalid_' + field)
            return run(args)
        if args.start_seconds != 0 or not 0 < args.duration_seconds <= 600 or not 0 < args.timeout_seconds <= 600 or not 0 < args.network_timeout_seconds <= 60:
            raise vod.HarnessError('invalid_native_duration_timeout_or_start')
        line = sys.stdin.readline(131073)
        if len(line) > 131072:
            raise vod.HarnessError('invalid_native_input')
        payload = json.loads(line)
        with native.suppress_native_output():
            report = native_run(args, payload)
        print(json.dumps(report, ensure_ascii=True, allow_nan=False, separators=(',', ':')))
        return 0 if report['status'] == 'passed' else 2
    except Exception as error:
        print(json.dumps({'status': 'harness_failed', **vod.safe_error(error)}), flush=True)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())

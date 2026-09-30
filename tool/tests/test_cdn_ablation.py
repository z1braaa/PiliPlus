"""Offline protocol/measurement gates; no library loads, network, or playback."""
import ctypes as C
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('cdn_ablation', Path(__file__).parents[1] / 'cdn_ablation_test.py')
ablation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ablation)


def manifest():
    return ablation.vod.normalize_manifest({
        'video_urls': ['https://upos-sz-mirrorali.bilivideo.com/upgcxcode/1/v.m4s?sign=synthetic-private-v'],
        'audio_urls': ['https://upos-sz-mirrorali.bilivideo.com/upgcxcode/1/a.m4s?sign=synthetic-private-a'],
        'quality': 112, 'codec': 'avc1.640033', 'width': 1440, 'height': 1080,
        'view': {'bvid': 'BV1TEhB6YEpH', 'page_duration': 2345}})


class Conditions(unittest.TestCase):
    def test_source_pool_and_parallel_are_only_ablation_factors(self):
        args = ablation.parser().parse_args(['run', '--manifest', 'BV1TEhB6YEpH=/unused',
            '--actual-quality', 'BV1TEhB6YEpH=112', '--library', '/unused', '--output', '/unused'])
        payloads = {mode: ablation.mode_payload(mode, manifest(), args) for mode in ablation.MODES if mode != 'hw-direct'}
        for payload in payloads.values():
            self.assertIs(payload['auto_select'], True)
            self.assertIs(payload['adaptive'], True)
            self.assertEqual(payload['request_timeout_seconds'], 10)
        for fixed in (False, True):
            pair = [p for p in payloads.values() if p['fixed_huawei'] == fixed]
            self.assertEqual(len(pair), 2)
            self.assertEqual({p['parallel'] for p in pair}, {False, True})
            self.assertEqual({json.dumps({k: v for k, v in p.items() if k != 'parallel'}, sort_keys=True) for p in pair}.__len__(), 1)

    def test_equal_and_application_timeouts_are_distinct(self):
        self.assertEqual({ablation.timed_profile(m, 'equal', 60) for m in ablation.MODES}, {60})
        self.assertEqual(ablation.timed_profile('hw-direct', 'app', 60), 5)
        self.assertEqual(ablation.timed_profile('smart', 'app', 60), 60)

    def test_150_seconds_from_zero_and_no_seek_are_explicit(self):
        plan = ablation.case_plan(manifest(), 150, 'none', 15)
        self.assertEqual(plan['start_seconds'], 0)
        self.assertTrue(plan['covers_90_to_150_seconds_from_zero'])
        self.assertIsNone(plan['seek_seconds'])

    def test_short_media_is_not_silently_claimed_as_90_seconds(self):
        video = manifest()
        video['view']['page_duration'] = 84
        rejected = ablation.case_plan(video, 90, 'auto', 15)
        self.assertEqual(rejected['status'], 'not_applicable')
        short = ablation.case_plan(video, 60, '63', 15)
        self.assertEqual(short['status'], 'planned')
        self.assertFalse(short['covers_90_seconds_from_zero'])

    def test_seek_cannot_end_outside_media_or_near_current_position(self):
        video = manifest()
        video['view']['page_duration'] = 137
        for target in ('130', '35', '-1', 'nan'):
            with self.subTest(target=target):
                self.assertEqual(ablation.case_plan(video, 35, target, 15)['status'], 'not_applicable')

    def test_duration_unknown_is_inapplicable(self):
        video = manifest()
        video['view'] = {}
        self.assertEqual(ablation.case_plan(video, 150, 'none', 15)['classification'], 'page_duration_unknown')

    def test_comparison_identity_includes_cache_timeouts_runtime(self):
        before = ablation.comparison_identity(manifest(), {'timeout': 60, 'buffer': 200}, {'bridge': 'a'})
        for condition, runtime in (({'timeout': 5, 'buffer': 200}, {'bridge': 'a'}),
                                   ({'timeout': 60, 'buffer': 4}, {'bridge': 'a'}),
                                   ({'timeout': 60, 'buffer': 200}, {'bridge': 'b'})):
            self.assertNotEqual(before, ablation.comparison_identity(manifest(), condition, runtime))

    def test_quality_mismatch_stops_before_any_process(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'private.json'
            value = manifest()
            path.write_text(json.dumps(value))
            path.chmod(0o600)
            args = ablation.parser().parse_args(['run', '--manifest', f'BV1TEhB6YEpH={path}',
                '--actual-quality', 'BV1TEhB6YEpH=120', '--library', '/unused', '--output', folder])
            with patch.object(ablation.vod, 'launch') as launch, self.assertRaises(ablation.vod.HarnessError) as caught:
                ablation.run(args)
            self.assertEqual(caught.exception.classification, 'actual_quality_expectation_mismatch')
            launch.assert_not_called()


class EvidenceAndPrivacy(unittest.TestCase):
    def test_missing_cache_is_unknown_not_zero(self):
        self.assertFalse(ablation.cache_known({}))
        self.assertFalse(ablation.cache_known({'cache_pause_count': False, 'cache_pause_seconds': 0}))
        self.assertTrue(ablation.cache_known({'cache_pause_count': 0, 'cache_pause_seconds': 0.0}))

    def test_cache_range_inside_is_not_uncached_recovery(self):
        state = ablation.cache_state_sanitize({'seekable-ranges': [{'start': 0, 'end': 1800}]})
        result = ablation.seek_cache_evidence(state, 1200)
        self.assertIs(result['main_demuxer_target_cached'], True)
        self.assertIs(result['uncached_seek_confirmed'], False)
        self.assertEqual(result['network_recovery_case'], 'not_reproduced_cached_target')

    def test_outside_main_range_does_not_prove_audio_os_or_cdn_uncached(self):
        state = ablation.cache_state_sanitize({'seekable-ranges': [{'start': 0, 'end': 150}]})
        result = ablation.seek_cache_evidence(state, 1200)
        self.assertIs(result['main_demuxer_target_cached'], False)
        self.assertIsNone(result['uncached_seek_confirmed'])

    def test_empty_bad_or_truncated_ranges_stay_unknown(self):
        for values in (None, {}, {'seekable-ranges': []}, {'seekable-ranges': [{'start': 9, 'end': 3}]},
                       {'seekable-ranges': [{'start': 0, 'end': 3}] * 33}):
            with self.subTest(values=values):
                state = ablation.cache_state_sanitize(values)
                self.assertIsNone(ablation.seek_cache_evidence(state, 1200)['main_demuxer_target_cached'])

    def test_raw_negative_memory_values_and_missingness_survive(self):
        safe = ablation.audit_stats({'buffered_payload_bytes': -2, 'active_origin_requests': 0})
        self.assertEqual(safe['buffered_payload_bytes'], -2)
        self.assertTrue(safe['raw_memory_counter_audit']['buffered_payload_bytes']['negative'])
        self.assertFalse(safe['raw_memory_counter_audit']['peak_buffered_payload_bytes']['present'])

    def test_validation_booleans_and_trace_clocks_survive(self):
        safe = ablation.audit_stats({'clock_origin_unix_ms': 1800000000000,
            'diagnostic_upstream_body_bytes': 123, 'track_flushed_body_bytes': {'video': 10, 'audio': 20},
            'request_events': [{'event': 'range_validation', 't_ms': 50, 'etag_equal': False,
                'modified_equal': True, 'validator_checked': True, 'encoding_identity': True}]})
        self.assertEqual(safe['clock_origin_unix_ms'], 1800000000000)
        self.assertIs(safe['request_events'][0]['etag_equal'], False)
        self.assertEqual(safe['track_flushed_body_bytes'], {'video': 10, 'audio': 20})

    def test_diagnostics_and_native_extensions_drop_private_strings(self):
        secret = 'https://upos-sz-mirrorali.bilivideo.com/v.m4s?sign=synthetic-private'
        safe = ablation.audit_stats({'request_events': [{'event': 'headers', 't_ms': 1, 'url': secret,
            'phase': secret, 'etag': 'private-string'}], 'cookie': 'private-cookie'})
        child = ablation.native_safe({'status': 'failed', 'metrics': {}, 'checks': {},
            'native_cache_samples': [{'elapsed_seconds': 1, 'position_seconds': 0,
                'cache_state': {'url': secret, 'seekable_ranges': []}, 'hardware_decode_current': secret}],
            'process_cpu': {'user_cpu_seconds': 1, 'private': secret}, 'clock_alignment': {'private': secret}})
        encoded = json.dumps({'bridge': safe, 'native': child})
        self.assertNotIn('synthetic-private', encoded)
        self.assertNotIn('private-cookie', encoded)
        self.assertNotIn('private-string', encoded)

    def test_failed_unknown_and_interrupted_rows_preserve_denominator(self):
        rows = [{'group_id': 'g', 'mode': 'smart', 'trial': i, 'status': status}
                for i, status in enumerate(('measured', 'failed', 'timeout', 'unknown_interrupted', 'not_run'))]
        stats = ablation.summary_rows(rows)['g']['smart']
        self.assertEqual(stats['planned'], 5)
        self.assertEqual(stats['status_counts']['unknown_interrupted'], 1)
        self.assertEqual(stats['cache_unknown_measured'], 1)
        self.assertIsNone(stats['initial_progress_seconds']['median'])

    def test_unrequested_or_unknown_postseek_is_not_false(self):
        for checks in ({'post_seek_observation_completed': None}, {},
                       {'post_seek_observation_completed': 1}):
            with self.subTest(checks=checks):
                result = ablation.native_safe({'status': 'passed', 'metrics': {}, 'checks': checks})
                self.assertIsNone(result['post_seek_observation_completed'])

    def test_requested_postseek_boolean_result_is_preserved(self):
        for completed in (True, False):
            with self.subTest(completed=completed):
                result = ablation.native_safe({'status': 'passed', 'metrics': {},
                    'checks': {'post_seek_observation_completed': completed}})
                self.assertIs(result['post_seek_observation_completed'], completed)

    def test_cpu_interval_is_distinct_and_can_exceed_one_core(self):
        result = ablation.cpu_delta({'wall': 1, 'user': 0, 'system': 0, 'peak_rss_bytes': 0},
                                   {'wall': 1.5, 'user': 1, 'system': 0.2, 'peak_rss_bytes': 100})
        self.assertEqual(result['cpu_percent'], 240)


class NativeNodeABI(unittest.TestCase):
    def test_integer_and_double_nodes_decode_without_library(self):
        node = ablation.Node()
        node.format = 4
        node.u.int64 = 123
        self.assertEqual(ablation.decode_node(node), 123)
        node.format = 5
        node.u.double = 1.5
        self.assertEqual(ablation.decode_node(node), 1.5)

    def test_unknown_formats_and_strings_are_not_dereferenced(self):
        node = ablation.Node()
        for form in (1, 9, 999):
            node.format = form
            node.u.string = 1
            self.assertIsNone(ablation.decode_node(node))

    def test_invalid_list_counts_are_rejected_without_dereferencing_values(self):
        values = ablation.NodeList()
        values.num = -1
        node = ablation.Node()
        node.format = 7
        node.u.list = C.pointer(values)
        with self.assertRaises(ValueError):
            ablation.decode_node(node)


if __name__ == '__main__':
    unittest.main()

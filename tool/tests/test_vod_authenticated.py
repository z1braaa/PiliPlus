"""Opt-in authentication boundaries with synthetic cookies; no real accounts."""
import argparse
import json
import socket
from pathlib import Path
import tempfile
import unittest
import urllib.request
from unittest.mock import patch

from tool import vod_auto_test as vod, vod_sources as sources, vod_supply_test as supply
from tool.tests.test_vod_sources import BV, VIDEO, AUDIO, FakeSession, view, playinfo


class AuthenticatedAcquisitionTests(unittest.TestCase):
    def test_body_read_timeout_is_a_network_failure_without_private_text(self):
        result = vod.safe_error(socket.timeout('signed-media-private-token'))
        self.assertEqual(result['classification'], 'network_error')
        self.assertNotIn('signed-media', json.dumps(result))

    def cookie_file(self, content):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = Path(directory.name) / 'private.json'
        path.write_text(json.dumps(content), encoding='utf-8')
        return path

    def test_opt_in_cookies_only_reach_exact_official_https_hosts(self):
        path = self.cookie_file({'SESSDATA': 'synthetic%2Ctoken', 'bili_jct': 'synthetic_csrf'})
        session = sources.Session(cookie_file=path)
        self.assertTrue(session.authenticated)
        for host in ('www.bilibili.com', 'api.bilibili.com'):
            request = urllib.request.Request('https://' + host + '/x')
            session.cookie_jar.add_cookie_header(request)
            self.assertIn('SESSDATA=synthetic%2Ctoken', request.get_header('Cookie'))
        for url in ('https://live.bilibili.com/', 'https://upos-sz-mirrorhw.bilivideo.com/',
                    'https://api.bilibili.com.evil.invalid/', 'http://api.bilibili.com/',
                    'https://api.bilibili.com:444/'):
            request = urllib.request.Request(url)
            session.cookie_jar.add_cookie_header(request)
            self.assertIsNone(request.get_header('Cookie'), url)

    def test_anonymous_session_does_not_read_any_cookie_file(self):
        with patch.object(sources, 'load_cookie_file', side_effect=AssertionError('must not read')):
            session = sources.Session()
            self.assertFalse(session.authenticated)
            self.assertEqual(list(session.cookie_jar), [])

    def test_cookie_formats_and_header_injection_fail_without_secret_or_path(self):
        for content in ({'SESSDATA': 'secret\r\nInjected: token'}, {'bad;key': 'secret'},
                        {'SESSDATA': 'secret;other=value'}, {'SESSDATA': 1}, {}, ['secret']):
            path = self.cookie_file(content)
            with self.subTest(content_type=type(content).__name__), self.assertRaises(sources.SourceError) as caught:
                sources.Session(cookie_file=path)
            public = json.dumps(sources.public_error(caught.exception))
            self.assertEqual(str(caught.exception), 'invalid_cookie_file')
            self.assertNotIn('secret', public)
            self.assertNotIn(str(path), public)

    def test_missing_or_oversized_cookie_file_errors_do_not_reveal_private_path(self):
        with self.assertRaises(sources.SourceError) as caught:
            sources.Session(cookie_file='/private/secret-account/not-present.json')
        self.assertEqual(str(caught.exception), 'cookie_file_unavailable')
        self.assertNotIn('secret-account', json.dumps(vod.safe_error(caught.exception)))
        path = self.cookie_file({'SESSDATA': 'synthetic'})
        path.write_bytes(b' ' * 65537)
        with self.assertRaises(sources.SourceError) as caught:
            sources.Session(cookie_file=path)
        self.assertEqual(str(caught.exception), 'invalid_cookie_file')

    def test_external_or_cdn_redirect_is_rejected_before_cookie_can_be_sent(self):
        redirect = sources._OfficialRedirect()
        request = urllib.request.Request('https://api.bilibili.com/x')
        for url in ('https://evil.invalid/', VIDEO, 'http://www.bilibili.com/'):
            with self.subTest(url=url), self.assertRaises(sources.SourceError) as caught:
                redirect.redirect_request(request, None, 302, 'Found', {}, url)
            self.assertNotIn('secret', json.dumps(vod.safe_error(caught.exception)))

    def test_authenticated_lower_html_quality_requests_requested_cid_bound_api(self):
        html = 'window.__INITIAL_STATE__=' + json.dumps({'videoData': view()})
        html += ';window.__playinfo__=' + json.dumps(playinfo(32))
        session = FakeSession(html, [sources.SourceError('anonymous_wbi_unavailable', 'nav'), playinfo(120)])
        session.authenticated = True
        manifest = sources.acquire(BV, quality=120, session=session)
        self.assertEqual(manifest['quality'], 120)
        self.assertEqual(session.calls, ['video_html', 'nav', 'legacy_playurl'])
        self.assertIn('qn=120', session.urls[-1])

    def test_hev_alias_selects_hvc_representation_and_reports_actual_codec(self):
        data = playinfo(120)
        hvc = dict(data['data']['dash']['video'][0], codecs='hvc1.1.6.L153.B0')
        data['data']['dash']['video'].append(hvc)
        for selection in (sources.select_manifest, vod.manifest_from_playurl):
            with self.subTest(selection=selection.__name__):
                manifest = selection(data, 120, 'hev')
                self.assertEqual(manifest['codec'], 'hvc1.1.6.L153.B0')

    def test_cookie_file_path_only_goes_to_private_source_worker_stdin(self):
        manifest = vod.normalize_manifest({'video_urls': [VIDEO], 'audio_urls': [AUDIO],
            'quality': 80, 'codec': 'avc1', 'width': 1920, 'height': 1080})
        captured = {}
        def runner(command, timeout, payload):
            captured.update(command=command, payload=json.loads(payload))
            return {'timed_out': False, 'exit_code': 0, 'stdout': json.dumps({'manifest': manifest})}
        args = argparse.Namespace(bvid=BV, page=1, quality_code=80, codec='avc', cookie_file='/private/synthetic.json')
        with patch.object(vod, 'run_command', runner):
            result = vod.acquire_anonymous_manifest(args, 30)
        self.assertNotIn('/private/synthetic.json', ' '.join(captured['command']))
        self.assertEqual(captured['payload']['cookie_file'], '/private/synthetic.json')
        self.assertNotIn('cookie', result)


class SupplyAndTimelineTests(unittest.TestCase):
    def test_bridge_memory_counters_accept_only_bounded_nonnegative_integers(self):
        keys=('buffered_payload_bytes','peak_buffered_payload_bytes','hedge_buffered_payload_bytes',
              'peak_hedge_buffered_payload_bytes','active_origin_requests')
        for value in (0,12,1_000_000_000_000):
            with self.subTest(value=value):
                self.assertEqual(vod.safe_bridge_stats(dict.fromkeys(keys,value)),dict.fromkeys(keys,value))
        for value in (-1,True,False,'12',12.0,None,1_000_000_000_001,{'path':'private'},['private']):
            with self.subTest(value_type=type(value).__name__):
                self.assertEqual(vod.safe_bridge_stats(dict.fromkeys(keys,value)),{})

    def test_bridge_legacy_diagnostics_remain_compatible_without_arbitrary_new_fields(self):
        original={'observed_upstream_body_bytes':1234,'upstream_requests':4,
                  'selected_hosts':['upos-sz-mirrorhw.bilivideo.com'],
                  'failures':[],'range_failures':[]}
        self.assertEqual(vod.safe_bridge_stats({**original,'private_path':'/private/synthetic',
                                               'cookie':'synthetic_secret','url':VIDEO}),original)
        with self.assertRaises(vod.HarnessError):
            vod.safe_bridge_stats(['invalid'])

    def test_smart_campaign_keeps_correct_plan_summary_and_html_mode(self):
        from tool import vod_catalog as catalog, vod_campaign
        from tool.tests.test_vod_catalog import selected, row
        items = [selected(1), selected(2, 'recent-popular')]
        plan = catalog.plan_batch(items, order=('hw-direct','smart','smart','hw-direct'))
        self.assertEqual(plan['video_plans'][1]['order'], ['smart','hw-direct','hw-direct','smart'])
        samples = [row(1,'hw-direct',2), row(1,'smart',1)]
        summary = catalog.summarize_batch(samples, items[:1], comparison_mode='smart')
        self.assertTrue(summary['videos'][0]['paired'])
        self.assertEqual(summary['videos'][0]['metrics']['file_loaded_seconds']['smart_minus_hw'], -1)
        with tempfile.TemporaryDirectory() as directory:
            report = {'plan': {'comparison_mode': 'smart'}, 'samples': samples,
                'videos': [{'catalog': items[0], 'status': 'completed'}],
                'selection_clock_utc_unix': items[0]['pubdate']+86400, 'summary': summary}
            vod_campaign.write_campaign_html(directory, report)
            page = (Path(directory)/'index.html').read_text()
            self.assertIn('自动选源 + 自适应并发', page)

    def test_supply_offsets_and_configuration_are_used_without_media_cookies(self):
        calls = []
        bridge_payload = {}
        class Bridge:
            def __init__(self, dart, payload, timeout):
                bridge_payload.update(payload)
                self.urls = {'video_url': 'http://127.0.0.1/video', 'audio_url': 'http://127.0.0.1/audio'}
            def stats(self): return {}
            def close(self): pass
        def read(url, size, deadline, offset):
            calls.append((url, size, offset))
            return {'status': 'measured', 'first_64k_seconds': .1, 'elapsed_seconds': .2}
        args = argparse.Namespace(dart='dart', video_mib=16, audio_kib=256, trial_seconds=5,
            video_offset_bytes=32*1048576, audio_offset_bytes=512*1024, concurrency=3, chunk_kib=512,
            cookie_file='/private/synthetic.json')
        with patch.object(vod, 'Bridge', Bridge), patch.object(supply, 'read_supply', read):
            row = supply.trial({'video_urls': [VIDEO], 'audio_urls': [AUDIO]}, 'smart', args)
        self.assertEqual(row['status'], 'measured')
        self.assertEqual(sorted(item[1:] for item in calls), [(256*1024, 512*1024), (16*1048576, 32*1048576)])
        self.assertEqual((bridge_payload['concurrency'], bridge_payload['chunk_kib']), (3, 512))
        self.assertNotIn('cookie', str(bridge_payload))

    def test_fractional_offset_no_longer_silently_tests_zero(self):
        with self.assertRaises(vod.HarnessError):
            supply.trial({}, 'hw-direct', argparse.Namespace(), .5)

    def test_native_timeline_only_preserves_finite_numeric_and_boolean_fields(self):
        result = {'metrics': {}, 'timeline': [{'elapsed_seconds': 1, 'position_seconds': .4,
            'cache_duration_seconds': float('nan'), 'cache_speed_bytes_s': float('inf'),
            'paused_for_cache': True, 'url': VIDEO, 'cookie': 'synthetic_secret'}],
            'conditions': {'hardware_decode': 'no'}}
        safe = vod.sanitize_native_result(result)
        self.assertEqual(safe['timeline'], [{'elapsed_seconds': 1, 'position_seconds': .4, 'paused_for_cache': True}])
        self.assertEqual(safe['hardware_decode'], 'no')
        self.assertNotIn('secret', str(safe))
        self.assertNotIn('private_signature', str(safe))

    def test_playback_parser_supports_authenticated_long_equal_timeout_trials(self):
        args = vod.parser().parse_args(['playback', '--bvid', BV, '--library', 'synthetic',
            '--cookie-file', '/private/synthetic.json', '--quality-code', '120', '--duration-seconds', '180',
            '--deadline-seconds', '240', '--network-timeout-seconds', '5', '--total-budget-seconds', '3600',
            '--buffer-seconds', '360', '--buffer-mib', '200'])
        self.assertEqual((args.quality_code, args.duration_seconds, args.deadline_seconds), (120, 180, 240))
        self.assertEqual(args.network_timeout_seconds, 5)
        self.assertEqual((args.buffer_seconds, args.buffer_mib), (360, 200))

    def test_buffer_profile_changes_comparison_identity(self):
        args = argparse.Namespace(start_seconds=0, duration_seconds=90, seek_seconds=105,
            concurrency=8, chunk_kib=512, buffer_seconds=16, buffer_mib=4)
        manifest = {'manifest_fingerprint': 'same', 'quality': 120, 'codec': 'avc1', 'width': 3840, 'height': 2160}
        original = vod.comparison_key(manifest, args)
        args.buffer_seconds, args.buffer_mib = 360, 200
        self.assertNotEqual(original, vod.comparison_key(manifest, args))

    def test_native_buffer_options_follow_supplied_profile(self):
        from tool.native_mpv_probe import NativePlayer
        options = {}
        class Library:
            def mpv_set_option_string(self, handle, name, value):
                options[name.decode()] = value.decode(); return 0
            def mpv_initialize(self, handle): return 0
            def mpv_observe_property(self, *args): return 0
        player = NativePlayer.__new__(NativePlayer)
        player.lib, player.handle = Library(), 1
        player.initialize(5, 360, 200)
        self.assertEqual(options['cache-secs'], '360.000000')
        self.assertEqual(options['demuxer-max-bytes'], str(200*1048576))
        self.assertEqual(options['demuxer-max-back-bytes'], str(200*1048576))
        self.assertEqual(options['demuxer-hysteresis-secs'], '240.000000')


if __name__ == '__main__':
    unittest.main()

import argparse
import hashlib
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from tool.vod_supply_test import read_supply, summarize, middle_window_args, trial

class SupplyTests(unittest.TestCase):
    def test_exact_ranges_and_truncation(self):
        data=bytes(range(251))*800
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                first,last=map(int,self.headers['Range'][6:].split('-'))
                last=min(last,len(data)-1)
                self.send_response(206)
                self.send_header('Content-Range',f'bytes {first}-{last}/{len(data)}')
                self.send_header('Content-Length',str(last-first+1));self.end_headers()
                self.wfile.write(data[first:last+1] if self.path=='/ok' else data[first:first+100])
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            url=f'http://127.0.0.1:{server.server_port}'
            row=read_supply(url+'/ok',300000,time.monotonic()+3)
            self.assertEqual(row['status'],'measured')
            self.assertEqual(row['bytes'],len(data))
            self.assertEqual(row['sha256'],hashlib.sha256(data).hexdigest())
            self.assertIsNotNone(row['first_64k_seconds'])
            self.assertNotIn(url,str(row))
            row=read_supply(url+'/truncated',65536,time.monotonic()+3)
            self.assertEqual(row['status'],'failed')
            self.assertIsNone(row['sha256'])
        finally: server.shutdown();server.server_close();thread.join()

    def test_budget_and_failed_trials_remain_in_denominator(self):
        row=read_supply('https://example.invalid/private?token=secret',1000,time.monotonic()-1)
        self.assertEqual(row['status'],'failed')
        self.assertNotIn('secret',str(row))
        summary=summarize([dict(row,bvid='BVtest',mode='smart')])
        self.assertEqual(summary['attempted_trials'],1)
        self.assertEqual(summary['measured_trials'],0)

    def test_mismatched_content_is_not_paired_evidence(self):
        rows=[dict(bvid='BVtest',mode=m,status='measured',video={'sha256':str(i)},audio={'sha256':'same'},dual_initial_seconds=1,supply_seconds=2) for i,m in enumerate(('hw-direct','smart'))]
        self.assertFalse(summarize(rows)['pairs'][0]['content_matches'])

    @staticmethod
    def window_row(mode, offset=0, digest='same', **fields):
        return dict(bvid='BVtest',mode=mode,status='measured',video={'sha256':digest},
                    audio={'sha256':'audio_'+digest},video_offset_bytes=offset,audio_offset_bytes=offset//4,
                    quality=120,codec='avc1',manifest_fingerprint='a'*64,
                    dual_initial_seconds=1,supply_seconds=2,**fields)

    def test_same_window_matches_across_modes(self):
        result=summarize([self.window_row('hw-direct',1048576),self.window_row('smart',1048576)])
        self.assertEqual((result['attempted_videos'],result['attempted_windows']), (1,1))
        self.assertTrue(result['pairs'][0]['content_matches'])
        self.assertTrue(result['pairs'][0]['paired_modes'])

    def test_different_windows_keep_independent_hashes_for_same_video(self):
        rows=[self.window_row(mode,offset,digest) for offset,digest in ((0,'start'),(16*1048576,'middle'))
              for mode in ('hw-direct','smart')]
        result=summarize(rows)
        self.assertEqual((result['attempted_videos'],result['attempted_windows'],result['attempted_trials']), (1,2,4))
        self.assertTrue(all(pair['content_matches'] and pair['paired_modes'] for pair in result['pairs']))
        self.assertEqual({pair['video_offset_bytes'] for pair in result['pairs']}, {0,16*1048576})

    def test_content_mismatch_only_invalidates_affected_window(self):
        rows=[self.window_row('hw-direct',0,'start'),self.window_row('smart',0,'start'),
              self.window_row('hw-direct',16*1048576,'middle'),self.window_row('smart',16*1048576,'wrong')]
        result=summarize(rows)
        self.assertTrue(result['pairs'][0]['content_matches'])
        self.assertFalse(result['pairs'][1]['content_matches'])

    def test_representation_or_manifest_or_comparison_change_never_merge(self):
        original=self.window_row('hw-direct')
        for field,value in (('quality',80),('codec','hvc1'),('manifest_fingerprint','b'*64),('comparison_key','other')):
            changed=self.window_row('smart')
            changed[field]=value
            with self.subTest(field=field):
                result=summarize([original,changed])
                self.assertEqual(result['attempted_windows'],2)
                self.assertFalse(any(pair['paired_modes'] for pair in result['pairs']))

    def test_unknown_initial_metric_for_short_window_remains_null(self):
        rows=[self.window_row(mode) for mode in ('hw-direct','smart')]
        for row in rows:row['dual_initial_seconds']=None
        summary=summarize(rows)
        self.assertTrue(summary['pairs'][0]['content_matches'])
        self.assertIsNone(summary['pairs'][0]['modes']['smart']['dual_initial_seconds'])

    def test_pending_trials_remain_planned_without_becoming_attempts(self):
        row={'bvid':'BVtest','mode':'smart','window':'middle','status':'not_run',
             'classification':'campaign_budget_exhausted'}
        summary=summarize([row])
        self.assertEqual((summary['planned_trials'],summary['attempted_trials'],summary['not_run_trials']), (1,0,1))
        self.assertEqual((summary['planned_videos'],summary['attempted_videos']), (1,0))


class MiddleWindowTests(unittest.TestCase):
    @staticmethod
    def initial(video_total,audio_total):
        return [{'video':{'status':'measured','total_bytes':video_total},
                 'audio':{'status':'measured','total_bytes':audio_total}}]

    def test_offsets_are_clipped_for_short_tracks_and_large_windows(self):
        args=argparse.Namespace(video_mib=16,audio_kib=512,video_offset_bytes=0,audio_offset_bytes=0)
        for video_total,audio_total in ((32*1048576,2*1048576),(20*1048576,700*1024),(500*1024,32*1024)):
            with self.subTest(video_total=video_total):
                middle=middle_window_args(args,self.initial(video_total,audio_total))
                self.assertEqual(middle.video_offset_bytes,min(video_total//2,max(0,video_total-16*1048576)))
                self.assertEqual(middle.audio_offset_bytes,min(audio_total//2,max(0,audio_total-512*1024)))
                self.assertLess(middle.video_offset_bytes,video_total)
                self.assertLess(middle.audio_offset_bytes,audio_total)
        self.assertEqual(args.video_offset_bytes,0)

    def test_missing_failed_or_inconsistent_track_lengths_do_not_guess(self):
        args=argparse.Namespace(video_mib=16,audio_kib=512)
        for initial in ([],[{'video':{'status':'failed','total_bytes':10},'audio':{'status':'measured','total_bytes':10}}],
                        self.initial(10,10)+self.initial(20,10)):
            with self.subTest(rows=len(initial)),self.assertRaises(Exception):
                middle_window_args(args,initial)

    def test_known_small_tracks_clip_requested_ranges_before_transfer(self):
        from unittest.mock import patch
        from tool import vod_supply_test as supply
        calls=[]
        def read(url,size,deadline,offset):
            calls.append((size,offset))
            return {'status':'measured','first_64k_seconds':None,'elapsed_seconds':.1}
        args=argparse.Namespace(video_mib=16,audio_kib=512,video_offset_bytes=0,audio_offset_bytes=0,
                               video_total_bytes=500*1024,audio_total_bytes=32*1024,trial_seconds=30)
        video='https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/1/video.m4s'
        audio='https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/1/audio.m4s'
        with patch.object(supply,'read_supply',read):
            result=trial({'video_urls':[video],'audio_urls':[audio]},'hw-direct',args)
        self.assertEqual(result['status'],'measured')
        self.assertEqual(sorted(calls),[(32*1024,0),(500*1024,0)])


class MiddleWindowCliTests(unittest.TestCase):
    def run_campaign(self, *, small=False, exhaust=False, current_views=None):
        import contextlib
        import io
        import json
        from pathlib import Path
        import tempfile
        from unittest.mock import patch
        from tool import vod_supply_test as supply
        from tool.tests.test_vod_catalog import selected
        record=selected(1)
        manifest={'video_urls':['unused-video'],'audio_urls':['unused-audio'],'quality':120,'quality_label':'4K',
                  'codec':'avc1','manifest_fingerprint':'a'*64}
        if current_views is not None:
            manifest['view']={**record,'view':current_views}
        calls=[]
        clock=[0.0]
        def execute(manifest,mode,args):
            calls.append((mode,args.video_offset_bytes,args.audio_offset_bytes))
            if exhaust:clock[0]=31.0
            digest=str(args.video_offset_bytes)
            return {'mode':mode,'status':'measured','video_offset_bytes':args.video_offset_bytes,
                    'audio_offset_bytes':args.audio_offset_bytes,'dual_initial_seconds':None if small else .1,
                    'supply_seconds':.2,'video':{'status':'measured','total_bytes':500*1024 if small else 32*1048576,'sha256':digest},
                    'audio':{'status':'measured','total_bytes':32*1024 if small else 2*1048576,'sha256':digest}}
        with tempfile.TemporaryDirectory() as directory:
            argv=['supply','--catalog','synthetic','--count','1','--output',directory,'--video-mib','16',
                  '--audio-kib','512','--quality-code','120','--middle-window','--modes','hw-direct,smart','--budget-seconds','30']
            with patch.object(supply.sys,'argv',argv),patch.object(supply.vod_campaign,'acquire_catalog',return_value={'candidates':[record]}), \
                 patch.object(supply.vod,'acquire_anonymous_manifest',return_value=manifest) as acquire, \
                 patch.object(supply,'trial',execute),patch.object(supply.time,'monotonic',side_effect=lambda:clock[0]), \
                 patch.object(supply.time,'time',return_value=1800000000), \
                 contextlib.redirect_stdout(io.StringIO()):
                supply.main()
                self.assertEqual(acquire.call_count,1)
            report=json.loads((Path(directory)/'report.json').read_text())
        return report,calls

    def test_middle_cli_keeps_one_manifest_and_four_counterbalanced_trials(self):
        report,calls=self.run_campaign()
        self.assertEqual(len(calls),4)
        self.assertEqual([call[0] for call in calls], ['hw-direct','smart','hw-direct','smart'])
        self.assertEqual({row['window'] for row in report['samples']}, {'initial','middle'})
        self.assertEqual(report['summary']['attempted_trials'],4)
        self.assertEqual(report['summary']['attempted_videos'],1)
        self.assertTrue(all(pair['content_matches'] for pair in report['summary']['pairs']))

    def test_middle_cli_small_file_duplicate_is_not_applicable_not_second_measurement(self):
        report,calls=self.run_campaign(small=True)
        self.assertEqual(len(calls),2)
        self.assertEqual(report['summary']['planned_trials'],4)
        self.assertEqual(report['summary']['not_applicable_trials'],2)
        self.assertEqual(report['summary']['attempted_trials'],2)

    def test_global_budget_retains_three_pending_trials_without_new_requests(self):
        report,calls=self.run_campaign(exhaust=True)
        self.assertEqual(len(calls),1)
        self.assertEqual(report['status'],'incomplete')
        self.assertEqual((report['summary']['planned_trials'],report['summary']['attempted_trials'],report['summary']['not_run_trials']), (4,1,3))
        self.assertTrue(all(row['classification']=='campaign_budget_exhausted' for row in report['samples'] if row['status']=='not_run'))

    def test_acquired_popularity_reclassifies_snapshot_low_video(self):
        report,calls=self.run_campaign(current_views=150000)
        entry=report['videos'][0]
        self.assertEqual(entry['selection_stratum'],'recent-low')
        self.assertEqual(entry['measurement_stratum'],'recent-popular')
        self.assertEqual(entry['metadata_verification_status'],'verified')
        self.assertEqual(report['selection_coverage']['recent-low'],1)
        self.assertEqual(report['acquired_coverage']['recent-low'],0)
        self.assertEqual(report['measurement_coverage']['recent-popular'],1)
        self.assertTrue(all(row['stratum']=='recent-popular' and row['selection_stratum']=='recent-low' for row in report['samples']))

    def test_missing_acquisition_metadata_stays_unknown(self):
        report,calls=self.run_campaign()
        entry=report['videos'][0]
        self.assertEqual(entry['metadata_verification_status'],'unavailable')
        self.assertIsNone(entry['measurement_stratum'])
        self.assertIsNone(entry['actual_metadata'])
        self.assertEqual(report['selection_coverage']['recent-low'],1)
        self.assertEqual(report['measurement_coverage']['recent-low'],0)
        self.assertEqual(report['measurement_coverage']['None'],1)
        self.assertTrue(all(row['stratum'] is None and row['selection_stratum']=='recent-low' for row in report['samples']))

if __name__=='__main__':unittest.main()

class NewSubmissionTests(unittest.TestCase):
    def test_three_pages_bounded_and_returns_only_public_metadata(self):
        from tool.vod_sources import discover_new_submissions
        class Session:
            calls=[]
            def json(self,url,stage):
                self.calls.append(url)
                return {'code':0,'data':{'archives':[{'bvid':'BV1aaaaaaaaa','pubdate':1790000000,'stat':{'view':0},'duration':90,'secret':'private'}]}}
        session=Session()
        result=discover_new_submissions(session=session)
        self.assertEqual(len(session.calls),3)
        self.assertEqual(len(result['candidates']),3)
        self.assertNotIn('secret',str(result))
        self.assertTrue(all('/newlist?' in u for u in session.calls))

    def test_restriction_stops_new_submission_family(self):
        from tool.vod_sources import discover_new_submissions, SourceError
        class Session:
            calls=0
            def json(self,url,stage):
                self.calls+=1
                raise SourceError('access_restricted',stage,http_status=412)
        session=Session()
        result=discover_new_submissions(session=session)
        self.assertEqual(session.calls,1)
        self.assertEqual(result['candidates'],[])

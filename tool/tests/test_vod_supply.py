import hashlib
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from tool.vod_supply_test import read_supply, summarize

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

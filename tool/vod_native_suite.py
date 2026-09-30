#!/usr/bin/env python3
"""Sequential native mpv confirmations of a public metadata catalogue.

Optional --cookie-file is a private JSON name/value map used only for official
source acquisition, never for CDN or native media requests.
"""
import argparse
import json
from pathlib import Path
import statistics
import sys
import time
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from tool import vod_auto_test as vod


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--catalog',required=True)
    p.add_argument('--output',required=True)
    p.add_argument('--library',required=True)
    p.add_argument('--dart',default='/Users/Admin/.cache/piliplus-tools/flutter/bin/dart')
    p.add_argument('--count',type=vod.bounded_number(int,1,40),default=8)
    p.add_argument('--seconds',type=vod.bounded_number(int,5,300),default=15)
    p.add_argument('--quality-code',type=vod.bounded_number(int,1,1000),default=80)
    p.add_argument('--codec',choices=('avc','hevc','hev','av1','av01'),default='avc')
    p.add_argument('--cookie-file',help='opt-in private JSON cookie name/value map, official acquisition only')
    p.add_argument('--require-quality',action='store_true')
    p.add_argument('--concurrency',type=vod.bounded_number(int,1,32),default=8)
    p.add_argument('--chunk-kib',type=vod.bounded_number(int,64,4096),default=1024)
    p.add_argument('--start-seconds',type=vod.bounded_number(float,0,86400),default=0)
    seek=p.add_mutually_exclusive_group()
    seek.add_argument('--seek-seconds',type=vod.bounded_number(float,0,86400))
    seek.add_argument('--no-seek',action='store_true')
    p.add_argument('--order',type=vod.parse_order,help='fixed sequence; default counterbalanced hw-direct/smart ABBA')
    p.add_argument('--budget-seconds',type=vod.bounded_number(int,60,7200),default=1800)
    p.add_argument('--network-timeout-seconds',type=vod.bounded_number(int,1,60),help='Use the same network timeout for all modes; otherwise mirror app defaults.')
    p.add_argument('--buffer-seconds',type=vod.bounded_number(float,.1,3600),default=16)
    p.add_argument('--buffer-mib',type=vod.bounded_number(float,.1,2048),default=4)
    options=p.parse_args()
    data=json.loads(Path(options.catalog).read_text())
    selected=data if isinstance(data,list) else data['selection']
    selected=selected[:options.count]
    report=vod.base_report('native_confirmation_suite')
    if options.cookie_file:
        report['credentials']='explicit local cookie file; official acquisition only; no media cookies'
    seek_seconds=None if options.no_seek else (options.seek_seconds if options.seek_seconds is not None else options.start_seconds+max(30,options.seconds+15))
    modes=list(dict.fromkeys(options.order or ('hw-direct','smart')))
    report.update(selection=selected, samples=[],videos=[],status='running',
        boundary='Same libmpv dual-track startup/cache/seek; no GUI frame or audible-sample evidence.',
        plan={'duration_seconds':options.seconds,'start_seconds':options.start_seconds,'seek_seconds':seek_seconds,'quality_code':options.quality_code,'codec':options.codec,'require_quality':options.require_quality,'concurrency':options.concurrency,'chunk_kib':options.chunk_kib,'buffer_seconds':options.buffer_seconds,'buffer_mib':options.buffer_mib,'budget_seconds':options.budget_seconds,'modes':modes,'network_timeout_override_seconds':options.network_timeout_seconds})
    start=time.monotonic()
    def save():
        report['elapsed_seconds']=round(time.monotonic()-start,3)
        vod.write_report(options.output,report,report['samples'])
    try:
        for i,record in enumerate(selected):
            remaining=options.budget_seconds-(time.monotonic()-start)
            if remaining<=0:break
            bvid=record['bvid']
            print(json.dumps({'video':i+1,'count':len(selected),'bvid':bvid}),flush=True)
            args=argparse.Namespace(bvid=bvid,page=1,manifest=None,quality_code=options.quality_code,codec=options.codec,allow_lower_quality=not options.require_quality,cookie_file=options.cookie_file,
                library=options.library,dart=options.dart,order=options.order or (('hw-direct','smart','smart','hw-direct') if i%2==0 else ('smart','hw-direct','hw-direct','smart')),
                concurrency=options.concurrency,chunk_kib=options.chunk_kib,duration_seconds=options.seconds,start_seconds=options.start_seconds,seek_seconds=seek_seconds,
                deadline_seconds=max(60,options.seconds+90),total_budget_seconds=remaining,network_timeout_seconds=options.network_timeout_seconds,
                buffer_seconds=options.buffer_seconds,buffer_mib=options.buffer_mib)
            entry={'catalog':record,'status':'running'};report['videos'].append(entry)
            def on_sample(subreport,row):
                row.update(bvid=bvid,stratum=record.get('stratum'))
                report['samples'].append(row.copy());save()
                print(json.dumps({'bvid':bvid,'mode':row['mode'],'status':row['status'],'startup':row.get('initial_progress_seconds'),'pause':row.get('cache_pause_seconds')}),flush=True)
            result,rows,_=vod.playback(args,on_sample=on_sample)
            entry.update(status=result['status'],source=result.get('source'),quality_check=result.get('quality_check'),runtime_artifacts=result.get('runtime_artifacts'),error=result.get('error'))
            entry['summary']={}
            for mode in modes:
                good=[r for r in rows if r['mode']==mode and r['status']=='measured']
                entry['summary'][mode]={'measured':len(good),'attempted':sum(r['mode']==mode for r in rows)}
                for key in ('initial_progress_seconds','cache_pause_seconds','seek_progress_seconds'):
                    values=[r[key] for r in good if r.get(key) is not None]
                    entry['summary'][mode][key]=statistics.median(values) if values else None
            save()
        report['status']='completed' if len(report['videos'])==len(selected) and all(v['status']=='completed' for v in report['videos']) else 'incomplete'
    except KeyboardInterrupt:report['status']='interrupted'
    finally:save()
    print(json.dumps({'status':report['status'],'videos':len(report['videos']),'trials':len(report['samples'])}))
if __name__=='__main__':main()

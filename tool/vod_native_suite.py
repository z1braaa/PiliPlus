#!/usr/bin/env python3
"""Sequential native mpv confirmations of a public metadata catalogue."""
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
    p.add_argument('--dart',default='/private/tmp/piliplus-tools/flutter/bin/dart')
    p.add_argument('--count',type=vod.bounded_number(int,1,40),default=8)
    p.add_argument('--seconds',type=vod.bounded_number(int,5,60),default=15)
    p.add_argument('--budget-seconds',type=vod.bounded_number(int,60,7200),default=1800)
    options=p.parse_args()
    data=json.loads(Path(options.catalog).read_text())
    selected=data if isinstance(data,list) else data['selection']
    selected=selected[:options.count]
    report=vod.base_report('native_confirmation_suite')
    report.update(selection=selected, samples=[],videos=[],status='running',
        boundary='Same libmpv dual-track startup/cache/seek; no GUI frame or audible-sample evidence.',
        plan={'duration_seconds':options.seconds,'budget_seconds':options.budget_seconds,'modes':['hw-direct','smart']})
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
            args=argparse.Namespace(bvid=bvid,page=1,manifest=None,quality_code=80,codec='avc',allow_lower_quality=True,
                library=options.library,dart=options.dart,order=('hw-direct','smart','smart','hw-direct') if i%2==0 else ('smart','hw-direct','hw-direct','smart'),
                concurrency=8,chunk_kib=1024,duration_seconds=options.seconds,start_seconds=0,seek_seconds=30,
                deadline_seconds=60,total_budget_seconds=remaining)
            entry={'catalog':record,'status':'running'};report['videos'].append(entry)
            def on_sample(subreport,row):
                row.update(bvid=bvid,stratum=record.get('stratum'))
                report['samples'].append(row.copy());save()
                print(json.dumps({'bvid':bvid,'mode':row['mode'],'status':row['status'],'startup':row.get('initial_progress_seconds'),'pause':row.get('cache_pause_seconds')}),flush=True)
            result,rows,_=vod.playback(args,on_sample=on_sample)
            entry.update(status=result['status'],source=result.get('source'),quality_check=result.get('quality_check'),runtime_artifacts=result.get('runtime_artifacts'),error=result.get('error'))
            entry['summary']={}
            for mode in ('hw-direct','smart'):
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

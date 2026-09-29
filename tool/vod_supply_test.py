#!/usr/bin/env python3
"""Bounded, account-free dual-track byte-supply comparisons (not rendered playback)."""
from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import math
from pathlib import Path
import random
import statistics
import sys
import time
from urllib.request import Request, build_opener, ProxyHandler
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tool import vod_auto_test as vod, vod_catalog as catalog, vod_campaign


def read_supply(url, size, deadline, offset=0):
    """Validate exact range/length; sample useful delivery including HTTP wait.

    No body or signed URL survives the function. Fixed byte windows reflect
    network continuity, not a known media-time buffer or a cache-hit inference.
    """
    start = time.monotonic()
    marks, count, digest, total = [], 0, hashlib.sha256(), None
    result = {"status": "failed", "requested_bytes": size, "offset": offset}
    try:
        if start >= deadline:
            raise vod.HarnessError("trial_budget_exhausted")
        request = Request(url, headers={**vod.HEADERS, "Accept-Encoding": "identity",
                         "Range": f"bytes={offset}-{offset + size - 1}"})
        # DIRECT matches the application's transport. Never use login cookies.
        with build_opener(ProxyHandler({})).open(request, timeout=min(6, deadline-start)) as response:
            import re
            match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", response.headers.get("Content-Range", ""))
            if response.status != 206 or not match or response.headers.get("Content-Encoding", "identity") != "identity":
                raise vod.HarnessError("invalid_range_response")
            first, last, total = map(int, match.groups())
            expected = min(size, total-offset)
            if first != offset or last != offset+expected-1 or expected <= 0:
                raise vod.HarnessError("invalid_range_response")
            if response.headers.get("Content-Length") and int(response.headers['Content-Length']) != expected:
                raise vod.HarnessError("invalid_range_length")
            while count < expected:
                if time.monotonic() >= deadline:
                    raise vod.HarnessError("trial_budget_exhausted")
                block = response.read(min(32768, expected-count))
                if not block:
                    raise vod.HarnessError("truncated_range")
                count += len(block)
                digest.update(block)
                marks.append((time.monotonic()-start, count))
            result['status'] = 'measured'
    except Exception as error:
        result['error'] = vod.safe_error(error)
    elapsed = time.monotonic()-start
    result.update(bytes=count, total_bytes=total, elapsed_seconds=round(elapsed, 4),
                  first_32k_seconds=round(marks[0][0], 4) if marks else None,
                  first_64k_seconds=next((round(t,4) for t,n in marks if n >= 65536), None),
                  mean_mib_s=count/max(elapsed,.001)/1048576,
                  sha256=digest.hexdigest() if result['status']=='measured' else None)
    # Include silence from request dispatch, not just time after first byte.
    previous = 0.0
    gaps=[]
    for timestamp, _ in marks:
        gaps.append(timestamp-previous);previous=timestamp
    result['max_32k_gap_seconds']=round(max(gaps, default=elapsed),4)
    result['delivery']=[[round(t,4), n] for t,n in marks]
    return result


def trial(manifest, mode, args, offset_fraction=0):
    bridge=None
    began=time.monotonic()
    row={'mode':mode, 'offset_fraction':offset_fraction}
    try:
        video,audio=manifest['video_urls'][0],manifest['audio_urls'][0]
        if mode=='hw-direct':video,audio=vod.hw_url(video),vod.hw_url(audio)
        elif mode in ('smart','auto','parallel'):
            bridge=vod.Bridge(args.dart, {'video_urls':manifest['video_urls'], 'audio_urls':manifest['audio_urls'],
                'concurrency':8, 'chunk_kib':1024, 'auto_select':mode!='parallel',
                'adaptive':mode=='smart', 'parallel':mode!='auto',
                'duration_seconds':manifest.get('view',{}).get('page_duration')}, 10)
            video,audio=bridge.urls['video_url'],bridge.urls['audio_url']
        setup=time.monotonic()-began
        deadline=time.monotonic()+args.trial_seconds
        # Tracks run together just as DASH needs simultaneous audio/video supply.
        with ThreadPoolExecutor(max_workers=2) as pool:
            video_future=pool.submit(read_supply,video,args.video_mib*1048576,deadline)
            audio_future=pool.submit(read_supply,audio,128*1024,deadline)
            v,a=video_future.result(),audio_future.result()
        row.update(status='measured' if v['status']==a['status']=='measured' else 'failed',
                   setup_seconds=round(setup,4),video=v,audio=a)
        row['dual_initial_seconds']=max(v['first_64k_seconds'],a['first_64k_seconds']) if v['first_64k_seconds'] is not None and a['first_64k_seconds'] is not None else None
        row['supply_seconds']=max(v['elapsed_seconds'],a['elapsed_seconds'])
        if bridge: row['transport']=bridge.stats()
    except Exception as error:
        row.update(status='failed',error=vod.safe_error(error))
    finally:
        if bridge:bridge.close()
    return row


def summarize(rows):
    groups={}
    for row in rows:groups.setdefault(row['bvid'],[]).append(row)
    pairs=[]
    for bvid,items in groups.items():
        successful=[r for r in items if r['status']=='measured']
        identities={(r['video']['sha256'],r['audio']['sha256']) for r in successful}
        valid=len(identities)==1
        modes={}
        for mode in ('hw-direct','smart','auto','parallel'):
            subset=[r for r in successful if r['mode']==mode]
            if subset:
                modes[mode]={key:statistics.median(r[key] for r in subset) for key in ('dual_initial_seconds','supply_seconds')}
                modes[mode]['trials']=len(subset)
        pairs.append({'bvid':bvid,'content_matches':valid,'modes':modes})
    return {'attempted_videos':len(groups),'attempted_trials':len(rows),
            'measured_trials':sum(r['status']=='measured' for r in rows),'pairs':pairs}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--count',type=vod.bounded_number(int,1,100),default=40)
    parser.add_argument('--dart',default='/private/tmp/piliplus-tools/flutter/bin/dart')
    parser.add_argument('--catalog')
    parser.add_argument('--new-only',action='store_true',help='public life-section new submissions; no search')
    parser.add_argument('--output',required=True)
    parser.add_argument('--video-mib',type=vod.bounded_number(int,1,8),default=2)
    parser.add_argument('--trial-seconds',type=vod.bounded_number(int,5,60),default=18)
    parser.add_argument('--budget-seconds',type=vod.bounded_number(int,30,7200),default=2400)
    parser.add_argument('--seed',type=int,default=29)
    parser.add_argument('--modes',default='hw-direct,smart,auto,hw-direct')
    args=parser.parse_args()
    modes=args.modes.split(',')
    if not 1<=len(modes)<=6 or any(m not in vod.MODES for m in modes):parser.error('invalid modes')
    report=vod.base_report('byte_supply_campaign')
    report.update(boundary='Dual-track byte supply only; not playable buffer, GUI or cache-hit evidence. Anonymous actual quality only.',
        plan={'count':args.count,'modes':modes,'video_mib':args.video_mib,'audio_kib':128,'trial_seconds':args.trial_seconds,'budget_seconds':args.budget_seconds,'seed':args.seed},
        implementation_sha256={p:vod.sha256_file(vod.REPO/p) for p in ('tool/vod_supply_test.py','lib/http/cdn_playback_proxy.dart','lib/http/cdn_origin_policy.dart')},
        samples=[],videos=[])
    rows=report['samples'];start=time.monotonic()
    def checkpoint():
        report.update(elapsed_seconds=round(time.monotonic()-start,3),summary=summarize(rows))
        vod.write_report(args.output,report,rows)
    try:
        args.keywords='游戏,生活,科技';args.request_budget=8;args.old_min_days=30
        if args.catalog:
            found=vod_campaign.acquire_catalog(args,90)
        else:
            from tool.vod_sources import discover_new_submissions
            # Isolate discovery under a process deadline, just like playurl.
            call=vod.run_command([sys.executable,'-c',
                "import json;from tool.vod_sources import discover_new_submissions;print(json.dumps(discover_new_submissions()))"],timeout=45)
            if call['timed_out']:raise vod.HarnessError('discovery_deadline_exceeded')
            fresh=json.loads(call['stdout'])
            if args.new_only:
                found={**fresh,'origin':'public_newlist'}
            else:
                found=vod_campaign.acquire_catalog(args,90)
                found['candidates']=fresh['candidates']+found['candidates']
                found['attempts']=fresh['attempts']+found['attempts']
        report['discovery']={k:v for k,v in found.items() if k!='candidates'}
        records=[];seen=set()
        for raw in found['candidates']:
            try:r=catalog.normalize_video(raw)
            except ValueError:continue
            if r['bvid'] not in seen and r['duration']>=45:
                r['stratum']=catalog.classify_video(r,now=int(time.time()),recent_days=7,older_days=30,low_views=10000,popular_views=100000)
                records.append(r);seen.add(r['bvid'])
        random.Random(args.seed).shuffle(records)
        # Round-robin strata, including intermediate metadata rather than silently
        # claiming a fully stratified sample when low-view discovery was blocked.
        groups={}
        for r in records:groups.setdefault(r['stratum'],[]).append(r)
        selected=[]
        while groups and len(selected)<args.count:
            for key in list(groups):
                if len(selected)<args.count:selected.append(groups[key].pop())
                if not groups[key]:del groups[key]
        report['selection']=selected
        report['coverage']={str(k):sum(r['stratum']==k for r in selected) for k in (*catalog.STRATA,None)}
        report['coverage']['requested_shortfall']=max(0,args.count-len(selected))
        report['status']='running';checkpoint()
        for index,record in enumerate(selected):
            if time.monotonic()-start>=args.budget_seconds:break
            entry={'catalog':record};report['videos'].append(entry)
            print(json.dumps({'video':index+1,'count':len(selected),'bvid':record['bvid'],'stage':'acquire'}),flush=True)
            source=argparse.Namespace(bvid=record['bvid'],page=1,quality_code=80,codec='avc')
            try:
                manifest=vod.acquire_anonymous_manifest(source,min(45,max(1,args.budget_seconds-(time.monotonic()-start))))
                entry.update(status='acquired',actual_quality=manifest['quality'],codec=manifest['codec'],metadata=manifest.get('view'))
                # Rotate direction to distribute CDN warming/order effects.
                rotation=index%len(modes)
                order=modes[rotation:]+modes[:rotation]
                entry['order']=order
                for number,mode in enumerate(order):
                    if time.monotonic()-start>=args.budget_seconds:break
                    trial_args=argparse.Namespace(**vars(args))
                    trial_args.trial_seconds=min(args.trial_seconds,max(1,args.budget_seconds-(time.monotonic()-start)))
                    row=trial(manifest,mode,trial_args)
                    row.update(bvid=record['bvid'],stratum=record['stratum'],trial=number+1,quality=manifest['quality'],codec=manifest['codec'],manifest_fingerprint=manifest['manifest_fingerprint'])
                    rows.append(row);checkpoint()
                    print(json.dumps({'bvid':record['bvid'],'mode':mode,'status':row['status'],'initial':row.get('dual_initial_seconds'),'supply':row.get('supply_seconds')}),flush=True)
            except Exception as error:
                entry.update(status='source_failed',error=vod.safe_error(error));checkpoint()
        report['status']='completed' if len(report['videos'])==len(selected) and len(rows)==len(selected)*len(modes) else 'incomplete'
    except KeyboardInterrupt:report['status']='interrupted'
    except Exception as error:report.update(status='failed',error=vod.safe_error(error))
    checkpoint()
    print(json.dumps({'status':report['status'],'attempted_videos':len(report['videos']),'trials':len(rows)}))

if __name__=='__main__':main()

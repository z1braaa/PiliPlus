#!/usr/bin/env python3
"""Bounded dual-track byte-supply comparisons (not rendered playback).

Optional --cookie-file accepts a private JSON cookie name/value map solely for
official media acquisition. CDN and loopback Range requests never receive it.
"""
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
    if offset_fraction:
        raise vod.HarnessError('unsupported_fractional_offset')
    video_offset = getattr(args, 'video_offset_bytes', 0)
    audio_offset = getattr(args, 'audio_offset_bytes', 0)
    row={'mode':mode, 'video_offset_bytes':video_offset, 'audio_offset_bytes':audio_offset}
    try:
        video,audio=manifest['video_urls'][0],manifest['audio_urls'][0]
        if mode=='hw-direct':video,audio=vod.hw_url(video),vod.hw_url(audio)
        elif mode in ('smart','auto','parallel'):
            bridge=vod.Bridge(args.dart, {'video_urls':manifest['video_urls'], 'audio_urls':manifest['audio_urls'],
                'concurrency':getattr(args,'concurrency',8), 'chunk_kib':getattr(args,'chunk_kib',1024), 'auto_select':mode!='parallel',
                'adaptive':mode=='smart', 'parallel':mode!='auto',
                'duration_seconds':manifest.get('view',{}).get('page_duration')}, min(10,args.trial_seconds))
            video,audio=bridge.urls['video_url'],bridge.urls['audio_url']
        setup=time.monotonic()-began
        deadline=began+args.trial_seconds
        video_size=args.video_mib*1048576
        audio_size=getattr(args,'audio_kib',128)*1024
        for field,offset in (('video_total_bytes',video_offset),('audio_total_bytes',audio_offset)):
            total=getattr(args,field,None)
            if total is not None:
                if type(total) is not int or total <= offset:
                    raise vod.HarnessError('invalid_known_window_length')
                if field=='video_total_bytes':video_size=min(video_size,total-offset)
                else:audio_size=min(audio_size,total-offset)
        # Tracks run together just as DASH needs simultaneous audio/video supply.
        with ThreadPoolExecutor(max_workers=2) as pool:
            video_future=pool.submit(read_supply,video,video_size,deadline,video_offset)
            audio_future=pool.submit(read_supply,audio,audio_size,deadline,audio_offset)
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


def middle_window_args(args, successful_rows):
    """Use verified lengths from the same manifest; byte midpoint is not time."""
    copy=argparse.Namespace(**vars(args))
    for track,size,offset_field,total_field in (
        ('video',args.video_mib*1048576,'video_offset_bytes','video_total_bytes'),
        ('audio',getattr(args,'audio_kib',128)*1024,'audio_offset_bytes','audio_total_bytes')):
        totals={row[track]['total_bytes'] for row in successful_rows
                if isinstance(row.get(track),dict) and row[track].get('status')=='measured'
                and type(row[track].get('total_bytes')) is int and row[track]['total_bytes']>0}
        if len(totals)!=1:
            raise vod.HarnessError('no_verified_window_length' if not totals else 'inconsistent_window_length')
        total=next(iter(totals))
        setattr(copy,total_field,total)
        setattr(copy,offset_field,min(total//2,max(0,total-size)))
    return copy


def verified_measurement_metadata(manifest, selection_clock):
    """Classify current acquisition metadata, never reuse an old layer label."""
    try:
        metadata=catalog.normalize_video(manifest.get('view'))
        stratum=catalog.classify_video(metadata,now=selection_clock,recent_days=7,
                                      older_days=30,low_views=10000,popular_views=100000)
        return metadata,stratum,'verified'
    except (ValueError,TypeError,KeyError):
        return None,None,'unavailable'


def summarize(rows):
    groups={}
    # A BV can have several byte windows or representations. Their hashes are
    # intentionally different; only the same window/source is comparable.
    # Missing identity fields retain compatibility with older reports/tests.
    for row in rows:
        key=(row['bvid'],row.get('video_offset_bytes',0),row.get('audio_offset_bytes',0),
             row.get('actual_quality',row.get('quality')),row.get('codec'),
             row.get('manifest_fingerprint'),row.get('comparison_key'),row.get('window'))
        groups.setdefault(key,[]).append(row)
    pairs=[]
    for identity,items in groups.items():
        bvid,video_offset,audio_offset,quality,codec,fingerprint,comparison_key,window=identity
        successful=[r for r in items if r['status']=='measured']
        identities={(r['video']['sha256'],r['audio']['sha256'],r.get('video_offset_bytes',0),r.get('audio_offset_bytes',0)) for r in successful}
        valid=len(identities)==1
        modes={}
        for mode in ('hw-direct','smart','auto','parallel'):
            subset=[r for r in successful if r['mode']==mode]
            if subset:
                modes[mode]={}
                for key in ('dual_initial_seconds','supply_seconds'):
                    values=[r[key] for r in subset if isinstance(r.get(key),(int,float))
                            and not isinstance(r[key],bool) and math.isfinite(r[key])]
                    modes[mode][key]=statistics.median(values) if values else None
                modes[mode]['trials']=len(subset)
        pair={'bvid':bvid,'video_offset_bytes':video_offset,'audio_offset_bytes':audio_offset,
              'quality':quality,'codec':codec,'content_matches':valid,'modes':modes,
              'paired_modes':len(modes)>1}
        if window in ('initial','middle'):pair['window']=window
        # Fingerprints/key values are grouping inputs, not arbitrary report
        # text. Only safe identifiers may be emitted in the summary.
        import re
        for field,value in (('manifest_fingerprint',fingerprint),('comparison_key',comparison_key)):
            if isinstance(value,str) and re.fullmatch(r'[A-Za-z0-9_.-]{1,128}',value):
                pair[field]=value
        pairs.append(pair)
    attempted=[r for r in rows if r['status'] in ('measured','failed','timeout')]
    return {'planned_videos':len({row['bvid'] for row in rows}),'attempted_videos':len({row['bvid'] for row in attempted}),
            'attempted_windows':sum(any(r['status'] in ('measured','failed','timeout') for r in items) for items in groups.values()),
            'planned_comparison_groups':len(groups),'planned_trials':len(rows),'attempted_trials':len(attempted),
            'measured_trials':sum(r['status']=='measured' for r in rows),
            'not_run_trials':sum(r['status']=='not_run' for r in rows),
            'not_applicable_trials':sum(r['status']=='not_applicable' for r in rows),'pairs':pairs}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--count',type=vod.bounded_number(int,1,100),default=40)
    parser.add_argument('--dart',default='/Users/Admin/.cache/piliplus-tools/flutter/bin/dart')
    parser.add_argument('--catalog')
    parser.add_argument('--new-only',action='store_true',help='public life-section new submissions; no search')
    parser.add_argument('--output',required=True)
    parser.add_argument('--video-mib',type=vod.bounded_number(int,1,128),default=2)
    parser.add_argument('--audio-kib',type=vod.bounded_number(int,64,8192),default=128)
    parser.add_argument('--video-offset-bytes',type=vod.bounded_number(int,0,10**12),default=0)
    parser.add_argument('--audio-offset-bytes',type=vod.bounded_number(int,0,10**12),default=0)
    parser.add_argument('--middle-window',action='store_true',help='after initial order, sample byte midpoint from the same verified track lengths')
    parser.add_argument('--quality-code',type=vod.bounded_number(int,1,1000),default=80)
    parser.add_argument('--codec',choices=('avc','hevc','hev','av1','av01'),default='avc')
    parser.add_argument('--cookie-file',help='opt-in private JSON cookie map, official acquisition only')
    parser.add_argument('--require-quality',action='store_true')
    parser.add_argument('--concurrency',type=vod.bounded_number(int,1,32),default=8)
    parser.add_argument('--chunk-kib',type=vod.bounded_number(int,64,4096),default=1024)
    parser.add_argument('--trial-seconds',type=vod.bounded_number(int,5,600),default=18)
    parser.add_argument('--budget-seconds',type=vod.bounded_number(int,30,7200),default=2400)
    parser.add_argument('--seed',type=int,default=29)
    parser.add_argument('--modes',default='hw-direct,smart,auto,hw-direct')
    args=parser.parse_args()
    modes=args.modes.split(',')
    if not 1<=len(modes)<=6 or any(m not in vod.MODES for m in modes):parser.error('invalid modes')
    report=vod.base_report('byte_supply_campaign')
    if args.cookie_file:
        report['credentials']='explicit local cookie file; official acquisition only; no media cookies'
    report.update(boundary='Dual-track byte supply only; not playable buffer, GUI or cache-hit evidence. Actual quality explicitly recorded.',
        plan={'count':args.count,'modes':modes,'windows':['initial','middle'] if args.middle_window else ['initial'],'video_mib':args.video_mib,'audio_kib':args.audio_kib,'video_offset_bytes':args.video_offset_bytes,'audio_offset_bytes':args.audio_offset_bytes,'quality_code':args.quality_code,'codec':args.codec,'require_quality':args.require_quality,'concurrency':args.concurrency,'chunk_kib':args.chunk_kib,'trial_seconds':args.trial_seconds,'budget_seconds':args.budget_seconds,'seed':args.seed},
        implementation_sha256={p:vod.sha256_file(vod.REPO/p) for p in ('tool/vod_supply_test.py','lib/http/cdn_playback_proxy.dart','lib/http/cdn_origin_policy.dart')},
        samples=[],videos=[])
    rows=report['samples'];start=time.monotonic()
    selection_clock=int(time.time())
    report['selection_clock_utc_unix']=selection_clock
    def checkpoint():
        acquired=[entry for entry in report['videos'] if 'measurement_stratum' in entry]
        report['acquired_coverage']={str(k):sum(entry['measurement_stratum']==k for entry in acquired)
                                     for k in (*catalog.STRATA,None)}
        measured=[entry for entry in acquired if any(row['bvid']==entry['catalog']['bvid']
                  and row['status']=='measured' for row in rows)]
        report['measurement_coverage']={str(k):sum(entry['measurement_stratum']==k for entry in measured)
                                        for k in (*catalog.STRATA,None)}
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
                r['stratum']=catalog.classify_video(r,now=selection_clock,recent_days=7,older_days=30,low_views=10000,popular_views=100000)
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
        report['selection_coverage']=dict(report['coverage'])
        report['plan']['planned_trials']=len(selected)*len(modes)*(2 if args.middle_window else 1)
        report['status']='running';checkpoint()
        for index,record in enumerate(selected):
            entry={'catalog':record,'selection_stratum':record['stratum']};report['videos'].append(entry)
            rotation=index%len(modes)
            order=modes[rotation:]+modes[:rotation]
            entry['order']=order
            windows=report['plan']['windows']
            def decorated(row,window,number,manifest=None,check=None):
                row.update(bvid=record['bvid'],stratum=entry.get('measurement_stratum'),
                           selection_stratum=record['stratum'],trial=number,window=window,
                           quality=manifest['quality'] if manifest else None,requested_quality=args.quality_code,
                           requested_quality_reproduced=check['requested_quality_reproduced'] if check else False,
                           codec=manifest['codec'] if manifest else None,
                           manifest_fingerprint=manifest['manifest_fingerprint'] if manifest else None)
                return row
            def pending(window,classification,status='not_run',manifest=None,check=None,window_args=None):
                window_args=window_args or args
                for number,mode in enumerate(order,1):
                    row={'mode':mode,'status':status,'classification':classification,
                         'video_offset_bytes':getattr(window_args,'video_offset_bytes',0),
                         'audio_offset_bytes':getattr(window_args,'audio_offset_bytes',0)}
                    rows.append(decorated(row,window,number,manifest,check))
            if time.monotonic()-start>=args.budget_seconds:
                entry.update(status='not_run',error={'classification':'campaign_budget_exhausted'})
                for window in windows:pending(window,'campaign_budget_exhausted')
                checkpoint();continue
            print(json.dumps({'video':index+1,'count':len(selected),'bvid':record['bvid'],'stage':'acquire'}),flush=True)
            source=argparse.Namespace(bvid=record['bvid'],page=1,quality_code=args.quality_code,codec=args.codec,cookie_file=args.cookie_file)
            try:
                manifest=vod.acquire_anonymous_manifest(source,min(45,max(1,args.budget_seconds-(time.monotonic()-start))))
                check=vod.quality_policy(manifest,args.quality_code,not args.require_quality)
                entry.update(status='acquired',actual_quality=manifest['quality'],codec=manifest['codec'],metadata=manifest.get('view'),quality_check=check)
                actual_metadata,actual_stratum,metadata_status=verified_measurement_metadata(manifest,selection_clock)
                entry.update(actual_metadata=actual_metadata,actual_stratum=actual_stratum,
                             measurement_stratum=actual_stratum,metadata_verification_status=metadata_status)
                if not check['benchmark_allowed']:
                    raise vod.HarnessError('requested_quality_not_reproduced',requested_quality=args.quality_code,actual_quality=manifest['quality'])
                initial_rows=[]
                for window in windows:
                    window_args=argparse.Namespace(**vars(args))
                    if window=='middle':
                        try:window_args=middle_window_args(args,initial_rows)
                        except Exception as error:
                            pending(window,vod.safe_error(error)['classification'],manifest=manifest,check=check)
                            checkpoint();continue
                        if (window_args.video_offset_bytes==args.video_offset_bytes
                                and window_args.audio_offset_bytes==args.audio_offset_bytes):
                            pending(window,'window_duplicates_initial','not_applicable',manifest,check,window_args)
                            checkpoint();continue
                    for number,mode in enumerate(order,1):
                        remaining=args.budget_seconds-(time.monotonic()-start)
                        if remaining<=0:
                            row={'mode':mode,'status':'not_run','classification':'campaign_budget_exhausted',
                                 'video_offset_bytes':window_args.video_offset_bytes,
                                 'audio_offset_bytes':window_args.audio_offset_bytes}
                        else:
                            trial_args=argparse.Namespace(**vars(window_args))
                            trial_args.trial_seconds=min(args.trial_seconds,remaining)
                            row=trial(manifest,mode,trial_args)
                        decorated(row,window,number,manifest,check)
                        rows.append(row)
                        if window=='initial':initial_rows.append(row)
                        checkpoint()
                        print(json.dumps({'bvid':record['bvid'],'mode':mode,'window':window,'status':row['status'],'initial':row.get('dual_initial_seconds'),'supply':row.get('supply_seconds')}),flush=True)
            except Exception as error:
                entry.update(status='source_failed',error=vod.safe_error(error))
                for window in windows:
                    if not any(row.get('bvid')==record['bvid'] and row.get('window')==window for row in rows):
                        pending(window,entry['error']['classification'])
                checkpoint()
        report['status']='completed' if len(rows)==report['plan']['planned_trials'] and not any(row['status']=='not_run' for row in rows) else 'incomplete'
    except KeyboardInterrupt:report['status']='interrupted'
    except Exception as error:report.update(status='failed',error=vod.safe_error(error))
    checkpoint()
    print(json.dumps({'status':report['status'],'attempted_videos':len(report['videos']),'trials':len(rows)}))

if __name__=='__main__':main()

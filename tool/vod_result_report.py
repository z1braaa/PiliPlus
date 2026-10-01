#!/usr/bin/env python3
"""Render public test reports into a standalone read-only Chinese HTML report."""
import argparse
import hashlib
import html
import json
from pathlib import Path
import statistics


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reports',nargs='+')
    parser.add_argument('--output',required=True)
    args=parser.parse_args()
    sections=[]
    e=lambda v:html.escape(str(v))
    number=lambda v:'—' if v is None else f'{v:.3f}'
    for path in args.reports:
        source=Path(path);data=json.loads(source.read_text())
        rows=data.get('samples',[])
        native=data.get('kind') in ('native_confirmation_suite','native_playback_comparison')
        start_key='initial_progress_seconds' if native else 'dual_initial_seconds'
        other_key='cache_pause_seconds' if native else 'supply_seconds'
        groups={}
        for row in rows:groups.setdefault(row.get('bvid',data.get('source',{}).get('bvid','unknown')),[]).append(row)
        table=[]
        for bvid,items in groups.items():
            for mode in dict.fromkeys(r['mode'] for r in items):
                candidates=[r for r in items if r['mode']==mode]
                good=[r for r in candidates if r['status']=='measured']
                def median(key):
                    vals=[r[key] for r in good if r.get(key) is not None]
                    return statistics.median(vals) if vals else None
                table.append('<tr>'+''.join('<td>'+e(v)+'</td>' for v in [bvid,mode,f'{len(good)}/{len(candidates)}',','.join(str(q) for q in sorted({r.get('quality') for r in candidates if r.get('quality') is not None})),number(median(start_key)),number(median(other_key))])+'</tr>')
        sections.append(f'<section><h2>{e(source.parent.name)}</h2><p>状态：{e(data.get("status"))}；视频 {len(groups)}，试验 {len(rows)}。耗时 {e(data.get("elapsed_seconds","—"))} 秒。</p><p>{e(data.get("boundary",data.get("measurement_boundary","")))}</p><p>发现覆盖：{e(data.get("coverage",{}))}</p><p>取源/画质结果：{e(data.get("error",{}))}</p><table><thead><tr><th>视频</th><th>模式</th><th>完成/尝试</th><th>实际画质代码</th><th>{"原生起播" if native else "两轨首64KiB"}（秒）</th><th>{"原生缓存暂停" if native else "两轨完整供给"}（秒）</th></tr></thead><tbody>{"".join(table)}</tbody></table><details><summary>复核信息</summary><p>报告 SHA-256：{hashlib.sha256(source.read_bytes()).hexdigest()}</p><pre>{e(json.dumps(data.get("plan",{}),ensure_ascii=False,indent=2))}</pre></details></section>')
    output=Path(args.output);output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text('''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>PiliPlus 自动测试报告</title><style>body{font:16px/1.65 system-ui,sans-serif;color:#183047;background:#f4f7fa;max-width:1200px;margin:36px auto;padding:0 24px}section{background:white;padding:24px;margin:24px 0;border-radius:12px}table{border-collapse:collapse;width:100%;font-size:14px}th,td{border-bottom:1px solid #ddd;text-align:left;padding:8px}th{background:#eaf1f7;position:sticky;top:0}pre{white-space:pre-wrap}h1{line-height:1.3}</style><h1>PiliPlus：电池显示与 CDN 实测</h1><p>hw-direct＝手选华为云；smart＝自动选源＋自适应并发；auto＝仅自动选源；parallel＝旧固定并发对照。</p><p>画质代码 16＝360p，32＝480p，80＝1080p。失败/超时没有作为成功秒数参与中位数。下载供给不是实际播放卡顿；原生起播也不是 GUI 首帧。各阶段修改过传输实现，不能跨阶段混算提升比例。新旧、热度只是抽样标签，不能证明缓存状态。</p>'''+''.join(sections)+'</html>',encoding='utf-8')

if __name__=='__main__':main()

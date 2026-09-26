"""Bounded public-video discovery, stratified comparisons and a local report."""
from __future__ import annotations

from argparse import Namespace
import hashlib
import html
import json
import math
from pathlib import Path
import re
import time

from tool import vod_auto_test as vod
from tool import vod_catalog as catalog


def policy(args):
    if args.old_min_days <= args.recent_days or args.popular_min_views <= args.max_views:
        raise vod.HarnessError("overlapping_strata_thresholds")
    return {"recent_days": args.recent_days, "older_days": args.old_min_days,
            "low_views": args.max_views, "popular_views": args.popular_min_views}


def acquire_catalog(args, timeout):
    if timeout <= 0:
        raise vod.HarnessError("campaign_budget_exhausted")
    if args.catalog:
        path = Path(args.catalog)
        if path.stat().st_size > 1_048_576:
            raise vod.HarnessError("catalog_too_large")
        data = json.loads(path.read_text(encoding="utf-8"))
        records = data if isinstance(data, list) else data.get("candidates")
        if not isinstance(records, list) or len(records) > 200:
            raise vod.HarnessError("invalid_catalog")
        return {"candidates": catalog.extract_candidates(records, source="provided_catalog"),
                "attempts": [], "origin": "provided_metadata_catalog"}
    terms = [part.strip() for part in args.keywords.split(",") if part.strip()]
    if not 1 <= len(terms) <= 3 or any(len(term) > 40 or any(ord(c) < 32 for c in term) for term in terms):
        raise vod.HarnessError("invalid_discovery_terms")
    worker = (
        "import json,sys\n"
        "from tool.vod_sources import discover_candidates\n"
        "from tool.vod_catalog import extract_candidates\n"
        "from tool.vod_auto_test import safe_error\n"
        "try:\n"
        " p=json.load(sys.stdin)\n"
        " r=discover_candidates(keywords=p['keywords'],request_budget=p['request_budget'],max_candidates=200,older_days=p['older_days'])\n"
        " print(json.dumps({'candidates':extract_candidates(r['candidates']), 'attempts':r.get('attempts',[]), 'sampling_strategy':r.get('sampling_strategy',{})}))\n"
        "except Exception as e:\n"
        " print(json.dumps({'error':safe_error(e)}));sys.exit(1)\n"
    )
    call = vod.run_command([vod.sys.executable, "-c", worker], timeout=timeout,
                           payload=json.dumps({"keywords": ",".join(terms), "request_budget": args.request_budget,
                                               "older_days": args.old_min_days}))
    if call["timed_out"]:
        raise vod.HarnessError("discovery_deadline_exceeded")
    data = json.loads(call["stdout"])
    if call["exit_code"] != 0:
        error = vod.public_source_attempt(data.get("error", {}))
        raise vod.HarnessError(error.pop("classification", "discovery_failed"), **error)
    records = data.get("candidates")
    if not isinstance(records, list) or len(records) > 200:
        raise vod.HarnessError("invalid_discovery_result")
    return {"candidates": catalog.extract_candidates(records),
            "attempts": [vod.public_source_attempt(x) for x in data.get("attempts", [])[:16] if isinstance(x, dict)],
            "sampling_strategy": data.get("sampling_strategy", {}),
            "origin": "anonymous_public_sources"}


def missing_rows(record, order, classification, *, error=None):
    # An unknown-source identity exists only for unmeasured failures. It cannot
    # participate in successful playback statistics.
    identity = hashlib.sha256(("unmeasured:" + record["bvid"]).encode()).hexdigest()
    rows = []
    for number, mode in enumerate(order, 1):
        rows.append({"bvid": record["bvid"], "stratum": record["stratum"],
                     "pubdate": record["pubdate"], "view": record["view"],
                     "trial": number, "mode": mode, "comparison_key": identity,
                     "quality": None, "codec": None, "start_seconds": None,
                     "status": "not_run", "classification": classification})
    return rows


def summarize(rows, selected):
    # Source failures have no actual quality/codec: retain their trial status,
    # while only real measurements enter within-video statistical comparisons.
    summary = catalog.summarize_batch(rows, catalog=selected)
    summary["planned_trials"] = len(rows)
    summary["measured_trials"] = sum(row.get("status") == "measured" for row in rows)
    summary["unmeasured_trials"] = len(rows) - summary["measured_trials"]
    return summary


def campaign(args):
    report = vod.base_report("stratified_vod_campaign")
    rows, videos, selected = [], [], []
    began, locked_now = time.monotonic(), int(time.time())
    report["selection_clock_utc_unix"] = locked_now
    report["measurement_boundary"] = (
        "An observational convenience sample of public videos. Recency/view count do not prove CDN cache state. "
        "Headless mpv progress/cache/seek signals are not GUI first frame or first audible sample. "
        "Only within-video actual-quality/codec/position/runtime-matched comparisons are aggregated.")
    report["plan"] = {"count": args.count, "requested_quality": args.quality_code,
                      "accept_available_anonymous_quality": not args.require_quality,
                      "order": list(args.order), "concurrency": args.concurrency, "chunk_kib": args.chunk_kib,
                      "duration_seconds": args.duration_seconds, "start_seconds": args.start_seconds,
                      "seek_seconds": args.seek_seconds, "total_budget_seconds": args.campaign_budget_seconds,
                      "discovery_request_budget": args.request_budget, "seed": args.seed}
    report["videos"], report["samples"] = videos, rows

    def remaining():
        return max(0, args.campaign_budget_seconds - (time.monotonic() - began))

    def checkpoint():
        report["elapsed_seconds"] = round(time.monotonic() - began, 3)
        report["summary"] = summarize(rows, selected)
        planned = report.get("batch_plan", {}).get("planned_trial_count", len(rows))
        report["summary"]["planned_trials"] = planned
        report["summary"]["unmeasured_trials"] = planned - report["summary"]["measured_trials"]
        vod.write_report(args.output, report, rows)

    def fill_remainder(record, order, classification):
        existing = [row for row in rows if row["bvid"] == record["bvid"]]
        for pending in missing_rows(record, order, classification):
            if not any(row["trial"] == pending["trial"] for row in existing):
                if existing:
                    for field in ("comparison_key", "quality", "codec", "width", "height", "start_seconds"):
                        pending[field] = existing[0].get(field)
                rows.append(pending)

    try:
        thresholds = policy(args)
        if args.order.count("hw-direct") < 1 or args.order.count("parallel") < 1:
            raise vod.HarnessError("comparison_modes_required")
        # Fail early on missing native tools rather than consuming discovery
        # requests and misclassifying dependency errors as network failures.
        if not Path(args.library).is_file():
            raise vod.HarnessError("dependency_missing", dependency="libmpv")
        vod.resolve_executable(args.dart, "dart")
        print(json.dumps({"progress": "discovering_public_videos"}), flush=True)
        discovered = acquire_catalog(args, min(args.discovery_deadline_seconds, remaining()))
        min_duration = math.ceil(max(30, args.start_seconds + args.duration_seconds + 2, (args.seek_seconds or 0) + 2))
        selection = catalog.select_catalog(discovered["candidates"], now=locked_now, **thresholds,
                                           quota_per_stratum=math.ceil(args.count / 4), max_videos=args.count,
                                           min_duration_seconds=min_duration, seed=args.seed)
        selected = selection["selected"]
        report["discovery"] = {key: value for key, value in discovered.items() if key != "candidates"}
        report["selection"] = selection
        plan = catalog.plan_batch(selected, order=args.order, seed=args.seed)
        report["batch_plan"] = plan
        if not selected:
            raise vod.HarnessError("no_eligible_public_videos")
        report["status"] = "running"
        checkpoint()
        for video_index, record in enumerate(selected, 1):
            order = tuple(next(item["order"] for item in plan["video_plans"] if item["bvid"] == record["bvid"]))
            entry = {"catalog": record, "status": "not_run"}
            videos.append(entry)
            if remaining() <= 0:
                entry["error"] = {"classification": "campaign_budget_exhausted"}
                rows.extend(missing_rows(record, order, "campaign_budget_exhausted"))
                checkpoint()
                continue
            print(json.dumps({"progress": "acquiring_video", "video": record["bvid"],
                              "stratum": record["stratum"], "index": video_index, "count": len(selected)}), flush=True)
            video_args = Namespace(**vars(args))
            video_args.bvid, video_args.page, video_args.manifest = record["bvid"], 1, None
            video_args.allow_lower_quality = not args.require_quality
            video_args.order = order
            try:
                manifest = vod.acquire_anonymous_manifest(video_args, min(60, remaining()))
                view = manifest.get("view", {})
                if view.get("bvid") != record["bvid"]:
                    raise vod.HarnessError("video_identity_not_verified")
                actual_stratum = catalog.classify_video(view, now=locked_now, **thresholds)
                if actual_stratum != record["stratum"]:
                    raise vod.HarnessError("catalog_metadata_changed")
                actual_view = catalog.normalize_video(view)
                entry["verified_metadata"] = actual_view
                page_duration = view.get("page_duration")
                entry["page_duration"] = page_duration
                if not isinstance(page_duration, (int, float)) or isinstance(page_duration, bool) or not math.isfinite(page_duration):
                    raise vod.HarnessError("page_duration_not_verified")
                if page_duration < min_duration:
                    raise vod.HarnessError("video_too_short_for_fixed_positions")
                video_args.total_budget_seconds = remaining()
                print(json.dumps({"progress": "playing_matched_trials", "video": record["bvid"],
                                  "actual_quality": manifest["quality"], "requested_quality": args.quality_code}), flush=True)
                def completed_sample(subreport, row):
                    row.update(bvid=record["bvid"], stratum=record["stratum"], pubdate=actual_view["pubdate"],
                               view=actual_view["view"], page_duration=page_duration)
                    rows.append(row)
                    entry.update(source=subreport.get("source"), quality_check=subreport.get("quality_check"),
                                 runtime_artifacts=subreport.get("runtime_artifacts"))
                    checkpoint()
                    print(json.dumps({"progress": "trial_saved", "video": record["bvid"],
                                      "trial": row["trial"], "mode": row["mode"], "status": row["status"]}), flush=True)
                subreport, measured_rows, _ = vod.playback(video_args, acquired_manifest=manifest, baseline=report,
                                                          on_sample=completed_sample)
                entry.update({"status": subreport["status"],
                              "source": subreport.get("source"), "quality_check": subreport.get("quality_check"),
                              "runtime_artifacts": subreport.get("runtime_artifacts"),
                              "summary": subreport.get("summary"), "error": subreport.get("error")})
                fill_remainder(record, order, (subreport.get("error") or {}).get("classification", "trial_not_completed"))
            except Exception as error:
                entry.update(status="not_reproduced", error=vod.safe_error(error))
                fill_remainder(record, order, entry["error"]["classification"])
            checkpoint()
        report["coverage_complete"] = len(selected) == args.count and not any(selection["shortages"].values())
        all_measured = (len(rows) == plan["planned_trial_count"] and rows
                        and all(row["status"] == "measured" for row in rows)
                        and all(video["status"] == "completed" for video in videos))
        report["status"] = ("completed" if report["coverage_complete"] else "completed_with_gaps") if all_measured else "incomplete"
    except KeyboardInterrupt:
        report.update(status="interrupted", error={"classification": "user_interrupted"})
        # Completed trials were already checkpointed. Preserve their comparison
        # identity for the interrupted/unstarted remainder of the same video.
        for record in selected:
            order = next(item["order"] for item in report["batch_plan"]["video_plans"] if item["bvid"] == record["bvid"])
            fill_remainder(record, order, "user_interrupted")
            entry = next((item for item in videos if item["catalog"]["bvid"] == record["bvid"]), None)
            if entry is None:
                videos.append({"catalog": record, "status": "not_run", "error": {"classification": "user_interrupted"}})
            elif entry["status"] != "completed":
                entry.update(status="interrupted", error={"classification": "user_interrupted"})
    except Exception as error:
        report.update(status="not_reproduced", error=vod.safe_error(error))
    checkpoint()
    return report, rows, 0 if report["status"] in ("completed", "completed_with_gaps") else (130 if report["status"] == "interrupted" else 1)


STRATUM_NAMES = {"recent-low": "近期 · 低播放", "recent-popular": "近期 · 热门",
                 "older-low": "较旧 · 低播放", "older-popular": "较旧 · 热门"}


def write_campaign_html(directory, report):
    esc = lambda value: html.escape(str(value), quote=True)
    def seconds(value):
        if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value):
            return f"{value:.2f} 秒"
        return "未测得"
    def median_metric(samples, mode, metric):
        import statistics
        values = [row[metric] for row in samples if row.get("mode") == mode and row.get("status") == "measured"
                  and isinstance(row.get(metric), (int, float)) and not isinstance(row[metric], bool) and math.isfinite(row[metric])]
        return statistics.median(values) if values else None
    table = []
    samples = report.get("samples", [])
    for video in report.get("videos", []):
        meta = {**video["catalog"], **(video.get("verified_metadata") or {})}
        trials = [row for row in samples if row.get("bvid") == meta["bvid"]]
        q = (video.get("source") or {}).get("quality_label", "未取得")
        source = video.get("source") or {}
        if source.get("codec"):
            q += " / " + source["codec"]
        hw, parallel = [median_metric(trials, mode, "initial_progress_seconds") for mode in ("hw-direct", "parallel")]
        difference = (parallel - hw) if hw is not None and parallel is not None else None
        bridge = median_metric(trials, "parallel", "bridge_setup_seconds")
        seek = " / ".join(seconds(median_metric(trials, mode, "seek_progress_seconds")) for mode in ("hw-direct", "parallel"))
        pauses = " / ".join(seconds(median_metric(trials, mode, "cache_pause_seconds")) for mode in ("hw-direct", "parallel"))
        error = video.get("error") or {}
        status = ("测量完成" if video["status"] == "completed" else "未完成")
        if error:
            status += " · " + str(error.get("classification", "unknown"))
            if error.get("http_status"):
                status += " (HTTP " + str(error["http_status"]) + ")"
        status += " · 华为 " + str(sum(row.get("status") == "measured" and row.get("mode") == "hw-direct" for row in trials))
        status += "/" + str(sum(row.get("mode") == "hw-direct" for row in trials))
        status += "，并发 " + str(sum(row.get("status") == "measured" and row.get("mode") == "parallel" for row in trials))
        status += "/" + str(sum(row.get("mode") == "parallel" for row in trials))
        name = STRATUM_NAMES.get(meta["stratum"], meta["stratum"])
        # Metadata remains plain text; the only link is a validated BV identifier.
        bvid = meta["bvid"]
        link = f'<a href="https://www.bilibili.com/video/{esc(bvid)}/" rel="noreferrer">{esc(bvid)}</a>'
        age = (report["selection_clock_utc_unix"] - meta["pubdate"]) / 86400
        cells = [link, esc(name), esc(f"{age:.1f} 天 / {meta['view']:,} 次"), esc(q),
                 esc(seconds(hw)), esc(seconds(parallel)), esc(seconds(difference)), esc(seconds(bridge)),
                 esc(seek), esc(pauses), esc(status)]
        table.append('<tr data-group="' + esc(meta["stratum"]) + '"><td>' + '</td><td>'.join(cells) + '</td></tr>')
    state = {"completed": "已完成", "completed_with_gaps": "已测完可取得的视频，部分分组缺样本", "incomplete": "部分完成", "not_reproduced": "未取得可测样本",
             "interrupted": "已停止", "running": "正在测试"}.get(report.get("status"), "待测试")
    summary = report.get("summary", {})
    shortage = (report.get("selection") or {}).get("shortages", {})
    detail = esc(json.dumps({"error": report.get("error"), "missing_groups": shortage,
                            "discovery": report.get("discovery"), "summary": summary}, ensure_ascii=False, indent=2))
    page = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>PiliPlus 点播自动测试</title><style>body{font:16px/1.55 system-ui,sans-serif;background:#f7f8fb;color:#19243b;margin:0}main{max-width:1280px;margin:32px auto;padding:0 24px}h1{margin-bottom:8px}section{background:white;padding:24px;border-radius:14px;margin:20px 0}table{border-collapse:collapse;min-width:1050px;width:100%;font-size:14px}th,td{padding:13px 10px;border-bottom:1px solid #e2e7ef;text-align:left}th{background:#f3f6fa}a{color:#255bb0}select{font:inherit;margin:10px;padding:6px}pre{white-space:pre-wrap;overflow-wrap:anywhere}.scroll{overflow:auto}.muted{color:#526176}</style>
<main><h1>PiliPlus 点播自动测试</h1><p class="muted">近期发布、低播放量与卡顿的关系：分组观察与同视频对照</p>
<section><strong>''' + esc(state) + '</strong><p>计划记录 ' + esc(summary.get("planned_trials", 0)) + ' 次，已测量 ' + esc(summary.get("measured_trials", 0)) + ' 次；用时 ' + esc(seconds(report.get("elapsed_seconds"))) + '''。</p>
<p>实际画质以取得的轨道为准。匿名取得的低画质不能当成 4K 问题已复现；缺失指标显示“未测得”，不作为零秒成功。</p></section>
<section><label>显示分组<select id="group"><option value="all">所有分组</option>''' + ''.join('<option value="'+esc(key)+'">'+esc(value)+'</option>' for key,value in STRATUM_NAMES.items()) + '''</select></label>
<div class="scroll"><table><thead><tr><th>视频</th><th>分组</th><th>发布距今 / 播放量</th><th>实际画质 / 编码</th><th>华为起播中位数</th><th>并发起播中位数</th><th>并发 − 华为</th><th>并发额外准备</th><th>拖动恢复（华为 / 并发）</th><th>观察段缓存暂停（华为 / 并发）</th><th>成功 / 计划</th></tr></thead><tbody>''' + ''.join(table) + '''</tbody></table></div>
<p class="muted">起播表示原生播放器位置开始推进，不是界面首帧或首声音。起播计时不包含单列的并发额外准备；差值为正表示并发较慢。恢复、暂停均显示同视频两种模式的中位数，未取得信号不填零。只对相同视频、实际画质、编码与位置计算。短片段和少量样本不能证明因果关系或 CDN 未缓存。</p></section>
<section><a href="report.json">完整 JSON</a> · <a href="samples.csv">逐次 CSV</a><details><summary>分组缺口与诊断信息</summary><pre>''' + detail + '''</pre></details></section>
</main><script>document.getElementById('group').addEventListener('change',function(){document.querySelectorAll('tbody tr').forEach(r=>r.hidden=this.value!=='all'&&r.dataset.group!==this.value);});</script></html>'''
    (Path(directory) / "index.html").write_text(page, encoding="utf-8")

"""Stratum membership and paired comparisons must survive hostile/missing data."""

import importlib.util
import json
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location("vod_catalog", Path(__file__).parents[1] / "vod_catalog.py")
catalog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(catalog)
NOW = 1_800_000_000


def video(number=1, age_days=1, views=1000, **extra):
    return {"bvid": f"BV{number:010d}", "pubdate": NOW - age_days * 86400,
            "view": views, "duration": 180, "title": "Public title", **extra}


def selected(number=1, stratum="recent-low"):
    return {**catalog.normalize_video(video(number)), "stratum": stratum}


def row(number, mode, seconds, key=None, **extra):
    return {"bvid": f"BV{number:010d}", "mode": mode, "status": "measured",
            "comparison_key": key or f"baseline-{number}", "quality": 80, "codec": "avc1.640028",
            "width": 1920, "height": 1080, "start_seconds": 0,
            "file_loaded_seconds": seconds, **extra}


class SelectionTests(unittest.TestCase):
    def test_exact_age_and_view_boundaries_define_four_distinct_strata(self):
        self.assertEqual(catalog.classify_video(video(age_days=7, views=9999), now=NOW), "recent-low")
        self.assertEqual(catalog.classify_video(video(age_days=7, views=10000), now=NOW), "recent-low")
        self.assertIsNone(catalog.classify_video(video(age_days=7, views=10001), now=NOW))
        self.assertEqual(catalog.classify_video(video(age_days=7, views=100000), now=NOW), "recent-popular")
        self.assertEqual(catalog.classify_video(video(age_days=30, views=9999), now=NOW), "older-low")
        self.assertEqual(catalog.classify_video(video(age_days=30, views=100000), now=NOW), "older-popular")
        self.assertIsNone(catalog.classify_video(video(age_days=29, views=10), now=NOW))

    def test_configured_maximum_view_count_includes_exact_limit(self):
        self.assertEqual(catalog.classify_video(video(views="10000"), now=NOW), "recent-low")
        self.assertEqual(catalog.classify_video(video(age_days=40, views=10000), now=NOW), "older-low")
        self.assertEqual(catalog.classify_video(video(views=20), now=NOW, low_views=20), "recent-low")
        self.assertIsNone(catalog.classify_video(video(views=21), now=NOW, low_views=20))

    def test_thresholds_can_change_without_using_playback_measurements(self):
        self.assertEqual(catalog.classify_video(video(age_days=3, views=15), now=NOW,
                                                recent_days=3, older_days=10, low_views=20, popular_views=50), "recent-low")
        with self.assertRaises(catalog.CatalogError):
            catalog.classify_video(video(), now=NOW, recent_days=30, older_days=7)

    def test_future_missing_and_rounded_counts_do_not_enter_a_stratum(self):
        invalid = [video(1, pubdate=NOW + 1), video(2, view="1.2万"), video(3, pubdate=None),
                   video(4, view=True), video(5, duration=0)]
        result = catalog.select_catalog(invalid, now=NOW)
        self.assertEqual(result["selected"], [])
        self.assertEqual(result["rejected_counts"]["future_publication"], 1)
        self.assertEqual(result["rejected_counts"]["unknown_view"], 2)
        self.assertEqual(result["shortages"], dict.fromkeys(catalog.STRATA, 1))

    def test_duplicate_conflicts_are_excluded_instead_of_choosing_lower_counts(self):
        original = video(1)
        result = catalog.select_catalog([original, dict(original), video(2), video(2, views=100000)], now=NOW)
        self.assertEqual([item["bvid"] for item in result["selected"]], [original["bvid"]])
        self.assertEqual(result["rejected_counts"], {"conflicting_duplicate": 1, "duplicate": 1})

    def test_fixed_seed_selection_ignores_input_order_and_slowness_fields(self):
        originals = [video(number) for number in range(1, 7)]
        first = catalog.select_catalog(originals, now=NOW, quota_per_stratum=2, seed=9)
        altered = [{**item, "file_loaded_seconds": 99999 - index} for index, item in enumerate(reversed(originals))]
        second = catalog.select_catalog(altered, now=NOW, quota_per_stratum=2, seed=9)
        self.assertEqual(first["selected"], second["selected"])

    def test_quota_shortages_never_borrow_videos_from_another_stratum(self):
        records = [video(1), video(2), video(3, views=200000), video(4, age_days=40, views=200000)]
        result = catalog.select_catalog(records, now=NOW, quota_per_stratum=1)
        self.assertEqual(len(result["selected"]), 3)
        self.assertEqual(result["shortages"]["older-low"], 1)
        self.assertEqual([item["stratum"] for item in result["selected"]], ["recent-low", "recent-popular", "older-popular"])

    def test_total_limit_and_round_allocation_are_bounded_and_balanced(self):
        records = []
        for number in range(1, 5):
            records.extend([video(number), video(number + 10, views=100000),
                            video(number + 20, age_days=40), video(number + 30, age_days=40, views=100000)])
        result = catalog.select_catalog(records, now=NOW, quota_per_stratum=3, max_videos=5)
        self.assertEqual(len(result["selected"]), 5)
        self.assertEqual([item["stratum"] for item in result["selected"][:4]], list(catalog.STRATA))
        with self.assertRaises(catalog.CatalogError):
            catalog.select_catalog(records, now=NOW, max_videos=13)


class DiscoveryTests(unittest.TestCase):
    def test_recommendation_dynamic_search_payloads_are_whitelisted_leads(self):
        for payload in ({"data": {"item": [video(1)]}},
                        {"data": {"archives": [video(1)]}},
                        {"data": {"result": [{"bvid": video(1)["bvid"], "pubdate": str(NOW - 86400),
                                                "play": "1000", "duration": "02:03", "title": "<em>Title</em>"}]}}):
            result = catalog.extract_candidates(payload)
            self.assertEqual(len(result), 1)
            self.assertEqual(result[0]["view"], 1000)
            self.assertNotIn("title", result[0])
        self.assertEqual(result[0]["duration"], 123)

    def test_initial_state_json_is_parsed_without_evaluating_trailing_code(self):
        secret = "https://cdn.example/video?sign=never-report"
        payload = "<script>window.__INITIAL_STATE__=" + json.dumps({"videoData": video(1, title=secret)}) + ";throw new Error('not executed')</script>"
        result = catalog.extract_candidates(payload)
        self.assertEqual(result[0]["bvid"], video(1)["bvid"])
        self.assertNotIn("never-report", json.dumps(result))
        self.assertEqual(catalog.extract_candidates("<html>no initial data</html>"), [])

    def test_candidate_unknown_values_become_none_and_never_copy_url_text(self):
        result = catalog.extract_candidates({"data": [video(1, pubdate="https://private?sign=x", view="2.1万", duration="https://private")]})
        self.assertIsNone(result[0]["pubdate"])
        self.assertIsNone(result[0]["view"])
        self.assertIsNone(result[0]["duration"])
        self.assertNotIn("https://", json.dumps(result))

    def test_reextracting_normalized_records_preserves_actual_title_fingerprint(self):
        normalized = catalog.normalize_video(video(1, title="测试标题 &amp; provenance"))
        once = catalog.extract_candidates([normalized])
        twice = catalog.extract_candidates(once)
        self.assertEqual(once, [normalized])
        self.assertEqual(twice, once)
        self.assertNotEqual(once[0]["title_fingerprint"], catalog.hashlib.sha256(b"").hexdigest())
        uppercase = {**normalized, "title_fingerprint": normalized["title_fingerprint"].upper()}
        self.assertEqual(catalog.extract_candidates([uppercase]), [normalized])

    def test_invalid_existing_fingerprint_is_not_trusted_or_propagated(self):
        title = "Verified public title"
        expected = catalog.hashlib.sha256(title.encode()).hexdigest()
        for fingerprint in ("x" * 64, "a" * 63, "https://private?sign=secret", 123, {"secret": "token"}):
            with self.subTest(fingerprint=fingerprint):
                original = video(1, title=title, title_fingerprint=fingerprint)
                candidate = catalog.extract_candidates([original])[0]
                self.assertEqual(candidate["title_fingerprint"], expected)
                self.assertNotIn("secret", json.dumps(candidate))
                self.assertEqual(catalog.normalize_video(original)["title_fingerprint"], expected)


class PlanningTests(unittest.TestCase):
    def test_each_video_keeps_contiguous_trials_with_seeded_mirrored_order(self):
        items = [selected(1), selected(2, "recent-popular")]
        plan = catalog.plan_batch(items, seed=0)
        self.assertEqual(plan["video_plans"][0]["order"], ["hw-direct", "parallel", "parallel", "hw-direct"])
        self.assertEqual(plan["video_plans"][1]["order"], ["parallel", "hw-direct", "hw-direct", "parallel"])
        self.assertEqual([trial["bvid"] for trial in plan["trials"][:4]], [items[0]["bvid"]] * 4)
        self.assertEqual(plan["planned_trial_count"], 8)
        self.assertEqual(catalog.plan_batch(items, seed=1)["video_plans"][0]["order"], plan["video_plans"][1]["order"])
        with self.assertRaises(catalog.CatalogError):
            catalog.plan_batch([items[0], items[0]])


class SummaryTests(unittest.TestCase):
    def test_different_videos_have_independent_valid_comparison_keys(self):
        result = catalog.summarize_batch([row(1, "hw-direct", 1), row(1, "parallel", 3),
                                           row(2, "hw-direct", 8), row(2, "parallel", 6)],
                                          [selected(1), selected(2, "older-popular")])
        self.assertTrue(all(video["paired"] for video in result["videos"]))
        self.assertEqual(result["strata"]["recent-low"]["metrics"]["file_loaded_seconds"]["median_parallel_minus_hw"], 2)
        self.assertEqual(result["strata"]["older-popular"]["metrics"]["file_loaded_seconds"]["median_parallel_minus_hw"], -2)

    def test_failure_and_unknown_are_not_zero_or_successful_timing(self):
        rows = [row(1, "hw-direct", 2), row(1, "parallel", 3), row(1, "parallel", 99, status="timeout"),
                row(1, "parallel", None), row(1, "hw-direct", 0, status="not_run")]
        result = catalog.summarize_batch(rows, [selected(1)])["videos"][0]
        self.assertEqual(result["metrics"]["file_loaded_seconds"]["parallel_median"], 3)
        self.assertEqual(result["metrics"]["file_loaded_seconds"]["hw_median"], 2)
        self.assertEqual(result["modes"]["parallel"]["failed_or_timeout"], 1)
        self.assertEqual(result["modes"]["hw-direct"]["not_run"], 1)

    def test_per_video_key_quality_or_position_drift_rejects_mixed_statistics(self):
        for changed in ({"key": "another"}, {"quality": 64}, {"start_seconds": 70}, {"codec": "hev1.1.6"}):
            with self.subTest(changed=changed), self.assertRaises(catalog.CatalogError) as caught:
                catalog.summarize_batch([row(1, "hw-direct", 2), row(1, "parallel", 3, **changed)], [selected(1)])
            self.assertEqual(caught.exception.classification, "mixed_video_baselines")

    def test_layer_summary_gives_each_video_one_vote_not_each_trial(self):
        rows = [row(1, "hw-direct", 5), row(1, "parallel", 4)]
        rows.extend([row(2, "hw-direct", 5), row(2, "parallel", 10)] * 5)
        result = catalog.summarize_batch(rows, [selected(1), selected(2)])
        metric = result["strata"]["recent-low"]["metrics"]["file_loaded_seconds"]
        self.assertEqual(metric["median_parallel_minus_hw"], 2)
        self.assertEqual(metric["paired_videos"], 2)
        self.assertNotIn("p95", metric)

    def test_success_without_quality_codec_or_actual_resolution_cannot_be_paired(self):
        for missing in ("comparison_key", "quality", "codec", "width", "height", "start_seconds"):
            measured = row(1, "parallel", 3)
            del measured[missing]
            with self.subTest(missing=missing), self.assertRaises(catalog.CatalogError):
                catalog.summarize_batch([row(1, "hw-direct", 2), measured], [selected(1)])

    def test_unplanned_samples_are_not_posthoc_added_to_selected_catalog(self):
        with self.assertRaises(catalog.CatalogError):
            catalog.summarize_batch([row(2, "hw-direct", 2)], [selected(1)])
        result = catalog.summarize_batch([row(1, "hw-direct", 2, private_url="https://cdn?sign=secret"),
                                         row(1, "parallel", 3)], [selected(1)])
        self.assertNotIn("secret", json.dumps(result))
        self.assertNotIn("https://", json.dumps(result))


if __name__ == "__main__":
    unittest.main()

import gzip
import json
import unittest
import urllib.parse
from unittest.mock import patch

from tool import vod_sources as sources


BV = "BV1234567890"
VIDEO = "https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/1/video.m4s?private_signature=secret"
AUDIO = "https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/1/audio.m4s?private_signature=secret"


def view():
    return {"bvid": BV, "cid": 100, "pubdate": 1700000000, "stat": {"view": 25000}, "duration": 200,
            "pages": [{"page": 1, "cid": 100, "duration": 200}]}


def playinfo(quality=32):
    return {"code": 0, "data": {"quality": 120, "dash": {
        "video": [{"id": quality, "codecs": "avc1.64001f", "width": 852,
                   "height": 480, "baseUrl": VIDEO}],
        "audio": [{"id": 30280, "codecs": "mp4a.40.2", "bandwidth": 1000,
                   "baseUrl": AUDIO}]}}}


class FakeSession:
    def __init__(self, html="", replies=None):
        self.html_value = html
        self.replies = list(replies or [])
        self.calls = []
        self.urls = []

    def html(self, url, stage):
        self.calls.append(stage)
        return self.html_value

    def json(self, url, stage):
        self.calls.append(stage)
        self.urls.append(url)
        value = self.replies.pop(0)
        if isinstance(value, Exception):
            raise value
        return value


class SourceTests(unittest.TestCase):
    def test_gzip_official_html_is_decoded_before_global_parsing(self):
        html = "window.__INITIAL_STATE__=" + json.dumps({"videoData": view()})
        text = sources._decode_body(gzip.compress(html.encode()), "gzip", "video_html")
        self.assertEqual(sources.embedded_json(text, "__INITIAL_STATE__")["videoData"]["bvid"], BV)

    def test_global_decoder_handles_braces_and_semicolon_inside_string(self):
        text = 'window.__INITIAL_STATE__ = {"title":"a }; b { c"}; trailing();'
        self.assertEqual(sources.embedded_json(text, "__INITIAL_STATE__"), {"title": "a }; b { c"})

    def test_html_acquisition_returns_actual_lower_quality_without_api_request(self):
        html = "window.__INITIAL_STATE__=" + json.dumps({"videoData": view()})
        html += ";window.__playinfo__=" + json.dumps(playinfo())
        session = FakeSession(html)
        result = sources.acquire(BV, quality=120, session=session)
        self.assertEqual(session.calls, ["video_html"])
        self.assertEqual((result["quality"], result["width"], result["height"]), (32, 852, 480))
        self.assertEqual(result["source_route"], "official_video_html")
        self.assertEqual(result["view"]["stat"]["view"], 25000)

    def test_codec_preference_uses_actual_representation(self):
        info = playinfo()
        info["data"]["dash"]["video"].insert(0, {"id": 32, "codecs": "av01.0.08M.08",
                                                    "width": 852, "height": 480, "baseUrl": VIDEO})
        self.assertTrue(sources.select_manifest(info, 120, "avc")["codec"].startswith("avc"))
        self.assertTrue(sources.select_manifest(info, 120, "av1")["codec"].startswith("av01"))

    def test_embedded_stream_without_page_identity_requires_cid_bound_api_source(self):
        metadata = view()
        del metadata["cid"]
        metadata["pages"].append({"page": 2, "cid": 200, "duration": 100})
        state = "window.__INITIAL_STATE__=" + json.dumps({"videoData": metadata})
        session = FakeSession(state + ";window.__playinfo__=" + json.dumps(playinfo()),
                              [sources.SourceError("anonymous_wbi_unavailable", "nav"), playinfo(64)])
        result = sources.acquire(BV, page=2, session=session)
        self.assertEqual(session.calls, ["video_html", "nav", "legacy_playurl"])
        self.assertEqual(result["source_route"], "official_legacy_playurl")
        self.assertEqual(result["quality"], 64)
        self.assertEqual(urllib.parse.parse_qs(urllib.parse.urlsplit(session.urls[-1]).query)["cid"], ["200"])

    def test_login_required_search_stops_search_family_without_changing_keywords(self):
        session = FakeSession(replies=[{"code": 0, "data": {"list": []}},
                                      {"code": -101, "message": "login required"},
                                      {"code": 0, "data": {"list": [view()]}}])
        result = sources.discover_candidates(keywords="游戏,生活,科技", request_budget=8, session=session)
        self.assertEqual(session.calls, ["popular", "search_recent", "precious"])
        self.assertEqual(result["attempts"][1]["classification"], "login_required")
        self.assertEqual(result["attempts"][1]["api_code"], -101)

    def test_missing_metadata_stays_unknown_not_zero(self):
        meta = sources.view_metadata({"bvid": BV})
        self.assertIsNone(meta["stat"]["view"])
        self.assertIsNone(meta["pubdate"])
        self.assertIsNone(meta["duration"])

    def test_restriction_stops_without_fallback_or_retry(self):
        session = FakeSession(replies=[sources.SourceError("access_restricted", "view", http_status=412)])
        with self.assertRaises(sources.SourceError) as caught:
            sources.acquire(BV, session=session)
        self.assertEqual(session.calls, ["video_html", "view"])
        self.assertEqual(sources.public_error(caught.exception),
                         {"classification": "access_restricted", "stage": "view", "http_status": 412,
                          "attempts": [{"stage": "video_html", "status": "ok"},
                                       {"classification": "access_restricted", "stage": "view", "http_status": 412}]})

    def test_explicit_challenge_not_normal_page_library_string_is_terminal(self):
        session = FakeSession('window._riskdata_={"v_voucher":"challenge"};')
        with self.assertRaises(sources.SourceError):
            sources.acquire(BV, session=session)
        self.assertEqual(session.calls, ["video_html"])

    def test_exception_payload_does_not_include_signed_addresses(self):
        error = sources.SourceError("official_http_error", "playurl", http_status=500)
        payload = json.dumps(sources.public_error(error))
        self.assertNotIn(VIDEO, payload)
        self.assertNotIn("private_signature", payload)
        self.assertEqual(str(error), "official_http_error")

    def test_public_errors_reject_unknown_text_and_addresses(self):
        error = sources.SourceError(VIDEO, VIDEO)
        self.assertEqual(sources.public_error(error), {"classification": "source_unavailable", "stage": "source"})

    def test_failed_acquisition_retains_html_embedded_nav_and_restricted_api_order(self):
        state = "window.__INITIAL_STATE__=" + json.dumps({"videoData": view()})
        state += ';window.__playinfo__={"code":0,"data":{}};'
        nav = {"data": {"wbi_img": {"img_url": "https://i0.hdslb.com/" + "a" * 32 + ".png",
                                    "sub_url": "https://i0.hdslb.com/" + "b" * 32 + ".png"}}}
        session = FakeSession(state, [nav, sources.SourceError("access_restricted", "wbi_playurl", http_status=412)])
        with self.assertRaises(sources.SourceError) as caught:
            sources.acquire(BV, session=session)
        error = sources.public_error(caught.exception)
        self.assertEqual([a["stage"] for a in error["attempts"]],
                         ["video_html", "embedded_playurl", "nav", "wbi_playurl"])
        self.assertEqual(error["attempts"][-1]["http_status"], 412)
        self.assertEqual(session.calls, ["video_html", "nav", "wbi_playurl"])

    def test_history_is_flat_bounded_and_enum_whitelisted(self):
        recursive = {"stage": "nav", "classification": "official_api_unavailable", "api_code": -404}
        recursive["attempts"] = [recursive]
        history = [{"stage": VIDEO, "status": "ok"},
                   {"stage": "nav", "status": VIDEO, "classification": VIDEO, "http_status": 999,
                    "api_code": 10 ** 20, "message": VIDEO}, recursive]
        history += [{"stage": "nav", "status": "ok", "url": VIDEO}] * 20
        error = sources.SourceError("official_api_unavailable", "nav", history=history)
        # Revalidate even if a caller mutates the exception after construction.
        error.history.append({"stage": "nav", "status": VIDEO, "url": VIDEO})
        payload = sources.public_error(error)
        self.assertLessEqual(len(payload["attempts"]), 16)
        encoded = json.dumps(payload)
        self.assertNotIn("private_signature", encoded)
        self.assertNotIn("message", encoded)
        self.assertNotIn("url", encoded)
        self.assertEqual(payload["attempts"][0],
                         {"stage": "nav", "classification": "official_api_unavailable", "api_code": -404})
        self.assertTrue(all("attempts" not in attempt for attempt in payload["attempts"]))

    def test_request_budget_failure_retains_current_stage_and_no_extra_fallback(self):
        session = FakeSession()
        session.html = lambda url, stage: (_ for _ in ()).throw(sources.SourceError("request_budget_exhausted", stage))
        with self.assertRaises(sources.SourceError) as caught:
            sources.acquire(BV, session=session)
        self.assertEqual(sources.public_error(caught.exception)["attempts"],
                         [{"classification": "request_budget_exhausted", "stage": "video_html"}])
        self.assertEqual(session.calls, [])

    def test_malformed_manifest_is_a_redacted_source_error(self):
        with self.assertRaises(sources.SourceError):
            sources.select_manifest(None)

    def test_wrong_html_page_cid_cannot_supply_requested_page_track(self):
        state = "window.__INITIAL_STATE__=" + json.dumps({"videoData": view(), "cid": 999})
        state += ";window.__playinfo__=" + json.dumps(playinfo())
        session = FakeSession(state, [{"data": {}}, playinfo()])
        result = sources.acquire(BV, session=session)
        self.assertEqual(result["source_route"], "official_legacy_playurl")
        self.assertEqual(session.calls, ["video_html", "nav", "legacy_playurl"])

    def test_multi_page_total_does_not_replace_requested_page_duration(self):
        metadata = {**view(), "duration": 120,
                    "pages": [{"page": 1, "cid": 100, "duration": 10},
                              {"page": 2, "cid": 200, "duration": 110}]}
        state = "window.__INITIAL_STATE__=" + json.dumps({"videoData": metadata, "cid": 100})
        cases = [(FakeSession(state + ";window.__playinfo__=" + json.dumps(playinfo())),
                  "official_video_html"),
                 (FakeSession(state, [{"data": {}}, playinfo()]), "official_legacy_playurl")]
        for session, route in cases:
            with self.subTest(route=route):
                result = sources.acquire(BV, page=1, session=session)
                self.assertEqual(result["source_route"], route)
                self.assertEqual(result["view"]["duration"], 120)
                self.assertEqual(result["view"]["page_duration"], 10)

    def test_missing_page_duration_stays_unknown_despite_total_duration(self):
        metadata = {**view(), "duration": 120, "pages": [{"page": 1, "cid": 100}]}
        state = "window.__INITIAL_STATE__=" + json.dumps({"videoData": metadata})
        result = sources.acquire(BV, session=FakeSession(state + ";window.__playinfo__=" + json.dumps(playinfo())))
        self.assertEqual(result["view"]["duration"], 120)
        self.assertIsNone(result["view"]["page_duration"])

    def test_official_host_allowlist_rejects_external_redirects(self):
        with self.assertRaises(sources.SourceError):
            sources._official_url("https://example.com/challenge", "redirect")

    def test_media_urls_reject_userinfo_external_host_and_mixed_path(self):
        stream = {"baseUrl": VIDEO, "backupUrl": ["https://other.example/upgcxcode/1/video.m4s",
                                                   "https://u:p@bilivideo.com/upgcxcode/1/video.m4s",
                                                   AUDIO]}
        self.assertEqual(sources._stream_urls(stream), [VIDEO])

    def test_request_budget_exhaustion_prevents_network_call(self):
        session = sources.Session(max_requests=1)
        session.requests = 1
        with patch.object(session.opener, "open") as opener:
            with self.assertRaises(sources.SourceError):
                session.json("https://api.bilibili.com/x/web-interface/nav", "nav")
        opener.assert_not_called()

    def test_discovery_has_finite_paths_and_keeps_unknowns(self):
        session = FakeSession(replies=[{"code": 0, "data": {"list": [view()]}},
                                       sources.SourceError("access_restricted", "search_recent", http_status=412)])
        result = sources.discover_candidates(request_budget=2, session=session)
        self.assertEqual(len(session.calls), 2)
        self.assertEqual(len(result["candidates"]), 1)
        self.assertEqual(result["attempts"][1]["http_status"], 412)

    def test_precious_is_a_normal_public_source_and_regional_is_not_retried(self):
        older = {**view(), "bvid": "BV0234567890", "pubdate": 1500000000}
        session = FakeSession(replies=[{"code": 0, "data": {"list": [view()]}},
                                       {"code": 0, "data": {"result": []}},
                                       {"code": 0, "data": {"list": [older]}}])
        result = sources.discover_candidates(request_budget=3, session=session)
        self.assertEqual(session.calls, ["popular", "search_recent", "precious"])
        self.assertEqual(result["candidates"][1]["discovery_source"], "precious")
        self.assertEqual(result["candidates"][1]["pubdate"], 1500000000)

    def test_older_age_is_configurable_and_recorded_in_sampling_strategy(self):
        session = FakeSession(replies=[{"code": 0, "data": {"list": []}},
                                       {"code": 0, "data": {"result": []}},
                                       {"code": 0, "data": {"list": []}},
                                       {"code": 0, "data": {"result": []}}])
        with patch.object(sources.time, "time", return_value=2000000000):
            result = sources.discover_candidates(request_budget=4, session=session, older_days=90)
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(session.urls[-1]).query)
        self.assertEqual(int(query["pubtime_end"][0]), 2000000000 - 90 * 86400)
        self.assertEqual(result["sampling_strategy"]["older_days"], 90)

    def test_restricted_older_search_stops_all_remaining_search_keywords(self):
        session = FakeSession(replies=[{"code": 0, "data": {"list": []}},
                                       {"code": 0, "data": {"result": []}},
                                       {"code": 0, "data": {"list": []}},
                                       sources.SourceError("access_restricted", "search_older", http_status=412)])
        result = sources.discover_candidates(request_budget=12, session=session)
        self.assertEqual(session.calls, ["popular", "search_recent", "precious", "search_older"])
        self.assertEqual(len(result["attempts"]), 4)

    def test_restricted_recent_search_still_allows_distinct_precious_source(self):
        session = FakeSession(replies=[{"code": 0, "data": {"list": []}},
                                       sources.SourceError("access_restricted", "search_recent", http_status=412),
                                       {"code": 0, "data": {"list": [view()]}}])
        result = sources.discover_candidates(request_budget=8, session=session)
        self.assertEqual(session.calls, ["popular", "search_recent", "precious"])
        self.assertEqual(result["candidates"][0]["discovery_source"], "precious")

    def test_all_play_info_fallbacks_are_finite(self):
        state = "window.__INITIAL_STATE__=" + json.dumps({"videoData": view()})
        session = FakeSession(state, [{"data": {}}, {"code": 0, "data": {}}])
        with self.assertRaises(sources.SourceError) as caught:
            sources.acquire(BV, session=session)
        self.assertEqual(session.calls, ["video_html", "nav", "legacy_playurl"])
        self.assertEqual([a["stage"] for a in sources.public_error(caught.exception)["attempts"]],
                         ["video_html", "nav", "legacy_playurl", "playurl"])


if __name__ == "__main__":
    unittest.main()

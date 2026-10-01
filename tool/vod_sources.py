"""Bounded anonymous official-web VOD acquisition.

Only normal official HTTPS requests are made. By default a new in-memory
CookieJar accepts anonymous response cookies. An explicitly supplied private
cookie file may authenticate acquisition; browser/application stores are never
read automatically. Cookies are restricted to the exact official host allowlist
and are never used for media CDN requests.
Signed media addresses are returned in memory, never printed or logged here.
The HTML globals and DASH selection follow the public website approach used by
yt-dlp's BiliBiliIE, not its optional login or fingerprint-generation helpers.
"""

import hashlib
import http.cookiejar
import json
from pathlib import Path
import re
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib


OFFICIAL_HOSTS = frozenset(("www.bilibili.com", "api.bilibili.com"))
MEDIA_DOMAINS = ("bilivideo.com", "bilivideo.cn", "bilivideo.net", "akamaized.net")
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                  "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
    "Referer": "https://www.bilibili.com/",
    "Accept-Encoding": "gzip, deflate",
}
MAX_BODY = 4 * 1024 * 1024
WBI_MIX = (46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
           27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13)
QUALITY_NAMES = {6: "240P", 16: "360P", 32: "480P", 64: "720P", 74: "720P60",
                 80: "1080P", 112: "1080P+", 116: "1080P60", 120: "4K",
                 125: "HDR", 126: "Dolby Vision", 127: "8K"}
PUBLIC_STAGES = frozenset(("source", "input", "redirect", "video_html", "view", "metadata",
                           "embedded_playurl", "nav", "wbi_playurl", "legacy_playurl", "playurl",
                           "official_api", "popular", "precious", "search_recent", "search_older"))
PUBLIC_CLASSIFICATIONS = frozenset((
    "source_unavailable", "unsupported_official_address", "response_too_large_or_truncated",
    "unsupported_content_encoding", "response_too_large", "invalid_official_response",
    "request_budget_exhausted", "access_restricted", "official_http_error",
    "official_request_timeout", "official_network_unavailable", "invalid_official_json",
    "official_api_unavailable", "login_required", "video_metadata_unavailable",
    "anonymous_dash_unavailable", "unsupported_media_address", "invalid_dash_metadata",
    "anonymous_wbi_unavailable", "invalid_bvid", "invalid_source_parameters",
    "access_challenge", "video_identity_mismatch", "video_page_unavailable",
    "invalid_cookie_file", "cookie_file_unavailable"))


def _public_fields(classification, stage, http_status=None, api_code=None):
    result = {"classification": classification if isinstance(classification, str)
              and classification in PUBLIC_CLASSIFICATIONS else "source_unavailable",
              "stage": stage if isinstance(stage, str) and stage in PUBLIC_STAGES else "source"}
    if type(http_status) is int and 100 <= http_status <= 599:
        result["http_status"] = http_status
    if type(api_code) is int and abs(api_code) < 1_000_000:
        result["api_code"] = api_code
    return result


def _public_history(history):
    """Flat enum-only attempts; never retain nested history, messages or URLs."""
    if not isinstance(history, (list, tuple)):
        return []
    result = []
    for item in history[:16]:
        if not isinstance(item, dict):
            continue
        stage = item.get("stage")
        if not isinstance(stage, str) or stage not in PUBLIC_STAGES:
            continue
        clean = {"stage": stage}
        if item.get("status") == "ok":
            clean["status"] = "ok"
        category = item.get("classification")
        if isinstance(category, str) and category in PUBLIC_CLASSIFICATIONS:
            clean.update(_public_fields(category, stage, item.get("http_status"), item.get("api_code")))
        if len(clean) > 1:
            result.append(clean)
    return result


class SourceError(Exception):
    """An exception whose message and public fields never contain addresses."""

    def __init__(self, classification, stage, http_status=None, api_code=None, *, history=None):
        fields = _public_fields(classification, stage, http_status, api_code)
        self.classification = fields["classification"]
        self.stage = fields["stage"]
        self.http_status = fields.get("http_status")
        self.api_code = fields.get("api_code")
        self.history = _public_history(history)
        super().__init__(self.classification)


def public_error(error):
    if not isinstance(error, SourceError):
        return {"classification": "source_unavailable", "stage": "source"}
    result = _public_fields(error.classification, error.stage, error.http_status, error.api_code)
    attempts = _public_history(error.history)
    if attempts:
        result["attempts"] = attempts
    return result


def _official_url(value, stage):
    try:
        uri = urllib.parse.urlsplit(value)
        valid = (uri.scheme == "https" and uri.hostname in OFFICIAL_HOSTS
                 and not uri.username and not uri.password and uri.port in (None, 443))
    except (TypeError, ValueError):
        valid = False
    if not valid:
        raise SourceError("unsupported_official_address", stage)


class _OfficialRedirect(urllib.request.HTTPRedirectHandler):
    max_redirections = 3
    max_repeats = 1

    def redirect_request(self, request, response, code, message, headers, new_url):
        _official_url(new_url, "redirect")
        return super().redirect_request(request, response, code, message, headers, new_url)


class _OfficialCookiePolicy(http.cookiejar.DefaultCookiePolicy):
    """Even a broad .bilibili.com cookie is sent only to approved API/HTML hosts."""

    def return_ok(self, cookie, request):
        try:
            _official_url(request.full_url, "redirect")
        except SourceError:
            return False
        return super().return_ok(cookie, request)


def load_cookie_file(path):
    """Read an opt-in JSON name/value map; never include its path/value in errors.

    Accepted format: {"SESSDATA": "...", "bili_jct": "...", ...}.
    This function does not access application or browser storage. Callers should
    keep the supplied file outside the repository with owner-only permissions.
    """
    try:
        with Path(path).open("rb") as handle:
            payload = handle.read(65537)
    except (OSError, ValueError, TypeError):
        raise SourceError("cookie_file_unavailable", "input") from None
    try:
        data = json.loads(payload) if len(payload) <= 65536 else None
        if not isinstance(data, dict) or not 1 <= len(data) <= 64:
            raise ValueError()
        for name, value in data.items():
            if (not isinstance(name, str) or not re.fullmatch(r"[!#$%&'*+.^_`|~A-Za-z0-9-]{1,128}", name)
                    or not isinstance(value, str) or not 0 < len(value) <= 16384
                    or any(ord(c) < 33 or ord(c) > 126 or c in ';,"\\' for c in value)):
                raise ValueError()
        return data
    except (ValueError, TypeError, UnicodeError):
        raise SourceError("invalid_cookie_file", "input") from None


def _decode_body(payload, encoding, stage):
    try:
        # Some official video responses are gzip even when identity is requested.
        if encoding == "gzip" or payload[:2] == b"\x1f\x8b":
            inflater = zlib.decompressobj(16 + zlib.MAX_WBITS)
            payload = inflater.decompress(payload, MAX_BODY + 1)
            if not inflater.eof or inflater.unconsumed_tail:
                raise SourceError("response_too_large_or_truncated", stage)
        elif encoding == "deflate":
            inflater = zlib.decompressobj()
            payload = inflater.decompress(payload, MAX_BODY + 1)
            if not inflater.eof or inflater.unconsumed_tail:
                raise SourceError("response_too_large_or_truncated", stage)
        elif encoding not in (None, "", "identity"):
            raise SourceError("unsupported_content_encoding", stage)
        if len(payload) > MAX_BODY:
            raise SourceError("response_too_large", stage)
        return payload.decode("utf-8-sig")
    except (UnicodeDecodeError, zlib.error):
        raise SourceError("invalid_official_response", stage) from None


class Session:
    def __init__(self, request_timeout=15, max_requests=12, *, cookie_file=None):
        if not 0 < request_timeout <= 15 or not 1 <= max_requests <= 40:
            raise ValueError("invalid anonymous request budget")
        self.request_timeout = request_timeout
        self.max_requests = max_requests
        self.requests = 0
        self.authenticated = cookie_file is not None
        self.cookie_jar = http.cookiejar.CookieJar(policy=_OfficialCookiePolicy())
        if cookie_file is not None:
            for name, value in load_cookie_file(cookie_file).items():
                self.cookie_jar.set_cookie(http.cookiejar.Cookie(
                    version=0, name=name, value=value, port=None, port_specified=False,
                    domain=".bilibili.com", domain_specified=True, domain_initial_dot=True,
                    path="/", path_specified=True, secure=True, expires=None,
                    discard=True, comment=None, comment_url=None, rest={}))
        self.opener = urllib.request.build_opener(
            _OfficialRedirect(), urllib.request.HTTPCookieProcessor(self.cookie_jar))

    def _text(self, url, stage):
        _official_url(url, stage)
        if self.requests >= self.max_requests:
            raise SourceError("request_budget_exhausted", stage)
        self.requests += 1
        try:
            with self.opener.open(urllib.request.Request(url, headers=HEADERS),
                                  timeout=self.request_timeout) as response:
                payload = response.read(MAX_BODY + 1)
                encoding = response.headers.get("Content-Encoding", "").lower()
            if len(payload) > MAX_BODY:
                raise SourceError("response_too_large", stage)
            return _decode_body(payload, encoding, stage)
        except SourceError:
            raise
        except urllib.error.HTTPError as error:
            category = "access_restricted" if error.code in (401, 403, 412, 429) else "official_http_error"
            raise SourceError(category, stage, http_status=error.code) from None
        except (TimeoutError, socket.timeout):
            raise SourceError("official_request_timeout", stage) from None
        except (urllib.error.URLError, OSError):
            raise SourceError("official_network_unavailable", stage) from None

    def html(self, url, stage="video_html"):
        return self._text(url, stage)

    def json(self, url, stage="official_api"):
        try:
            value = json.loads(self._text(url, stage))
        except (json.JSONDecodeError, ValueError):
            raise SourceError("invalid_official_json", stage) from None
        if not isinstance(value, dict):
            raise SourceError("invalid_official_json", stage)
        return value

    def acquire(self, bvid, page=1, quality=80, codec="avc"):
        return acquire(bvid, page, quality, codec, session=self)


def _api_data(response, stage):
    code = response.get("code") if isinstance(response, dict) else None
    if type(code) is not int or code != 0 or not isinstance(response.get("data"), (dict, list)):
        category = "access_restricted" if code in (-352, -401, -412, -403) else "official_api_unavailable"
        if code == -101:
            category = "login_required"
        raise SourceError(category, stage, api_code=code)
    return response["data"]


def embedded_json(html, name):
    """Parse a JSON assignment with a decoder, including braces inside strings."""
    match = re.search(r"(?:\bwindow\s*\.\s*)?" + re.escape(name) + r"\s*=\s*", html)
    if not match:
        return None
    try:
        result, _ = json.JSONDecoder().raw_decode(html, match.end())
        return result if isinstance(result, dict) else None
    except (json.JSONDecodeError, ValueError):
        return None


def _nonnegative(value):
    return value if type(value) is int and value >= 0 else None


def view_metadata(data, bvid=None):
    if not isinstance(data, dict):
        raise SourceError("video_metadata_unavailable", "metadata")
    actual_bvid = data.get("bvid") or bvid
    if not isinstance(actual_bvid, str) or not re.fullmatch(r"BV[A-Za-z0-9]{10}", actual_bvid):
        raise SourceError("video_metadata_unavailable", "metadata")
    pages = []
    for item in data.get("pages") or []:
        if not isinstance(item, dict) or type(item.get("cid")) is not int:
            continue
        pages.append({"page": _nonnegative(item.get("page")), "cid": item["cid"],
                      "duration": _nonnegative(item.get("duration"))})
    stat = data.get("stat") if isinstance(data.get("stat"), dict) else {}
    return {"bvid": actual_bvid, "pubdate": _nonnegative(data.get("pubdate")),
            "stat": {"view": _nonnegative(stat.get("view"))},
            "duration": _nonnegative(data.get("duration")), "pages": pages}


def _stream_urls(stream):
    base = stream.get("baseUrl") or stream.get("base_url")
    backups = stream.get("backupUrl") or stream.get("backup_url") or []
    if not isinstance(backups, list):
        backups = []
    candidates = [base, *backups] if base else []
    result = []
    for url in candidates:
        if not isinstance(url, str):
            continue
        try:
            uri = urllib.parse.urlsplit(url)
            valid = (uri.scheme in ("http", "https") and not uri.username and not uri.password
                     and uri.port in (None, 80, 443)
                     and any(uri.hostname == host or (uri.hostname or "").endswith("." + host)
                             for host in MEDIA_DOMAINS)
                     and uri.path.startswith("/upgcxcode/") and uri.path.endswith((".m4s", ".mp4")))
        except ValueError:
            valid = False
        if valid and url not in result and (not result or uri.path == urllib.parse.urlsplit(result[0]).path):
            result.append(url)
        if len(result) == 4:
            break
    return result


def select_manifest(response, requested_quality=80, preferred_codec="avc", *, stage="playurl"):
    """Use actual DASH representation metadata, never the requested qn label."""
    if not isinstance(response, dict):
        raise SourceError("anonymous_dash_unavailable", stage)
    data = _api_data(response, stage) if "code" in response else response
    if not isinstance(data, dict):
        raise SourceError("anonymous_dash_unavailable", stage)
    dash = data.get("dash") if isinstance(data.get("dash"), dict) else {}
    videos = [v for v in dash.get("video") or [] if isinstance(v, dict)
              and type(v.get("id")) is int and v["id"] <= requested_quality]
    audios = [a for a in dash.get("audio") or [] if isinstance(a, dict)]
    if not videos or not audios:
        raise SourceError("anonymous_dash_unavailable", stage)
    actual_quality = max(v["id"] for v in videos)
    exact = [v for v in videos if v["id"] == actual_quality]
    prefixes = {"avc": ("avc",), "hevc": ("hev", "hvc"), "hev": ("hev", "hvc"),
                "av1": ("av01",), "av01": ("av01",)}.get(
        preferred_codec, (preferred_codec,))
    video = next((v for v in exact if isinstance(v.get("codecs"), str)
                  and v["codecs"].startswith(prefixes)), exact[0])
    audio = max(audios, key=lambda a: a.get("bandwidth") if type(a.get("bandwidth")) is int else 0)
    video_urls, audio_urls = _stream_urls(video), _stream_urls(audio)
    if not video_urls or not audio_urls:
        raise SourceError("unsupported_media_address", stage)
    if (not isinstance(video.get("codecs"), str) or not re.fullmatch(r"[A-Za-z0-9_. -]{1,80}", video["codecs"])
            or any(type(video.get(k)) is not int or video[k] <= 0 for k in ("width", "height"))):
        raise SourceError("invalid_dash_metadata", stage)
    result = {"video_urls": video_urls, "audio_urls": audio_urls, "quality": actual_quality,
              "codec": video["codecs"], "width": video["width"], "height": video["height"],
              "quality_label": QUALITY_NAMES.get(actual_quality, "unknown")}
    if isinstance(audio.get("codecs"), str) and re.fullmatch(r"[A-Za-z0-9_. -]{1,80}", audio["codecs"]):
        result["audio_codec"] = audio["codecs"]
    return result


def _signed_query(params, nav):
    images = nav.get("data", {}).get("wbi_img", {})
    try:
        source = "".join(urllib.parse.urlsplit(images[k]).path.rsplit("/", 1)[-1].split(".")[0]
                         for k in ("img_url", "sub_url"))
        if len(source) < 64:
            raise ValueError()
        key = "".join(source[i] for i in WBI_MIX)
    except (KeyError, TypeError, ValueError):
        raise SourceError("anonymous_wbi_unavailable", "nav") from None
    cleaned = {k: "".join(c for c in str(v) if c not in "!'()*") for k, v in params.items()}
    query = urllib.parse.urlencode(sorted(cleaned.items()), quote_via=urllib.parse.quote)
    return query + "&w_rid=" + hashlib.md5((query + key).encode()).hexdigest()


def _attempt(stage, error=None):
    if not error:
        return {"stage": stage, "status": "ok"}
    fields = public_error(error)
    fields.pop("attempts", None)
    return fields


def _source_failure(error, attempts):
    current = _attempt(error.stage, error)
    history = list(attempts)
    if not history or history[-1] != current:
        history.append(current)
    return SourceError(error.classification, error.stage, error.http_status, error.api_code, history=history)


def acquire(bvid, page=1, quality=80, codec="avc", *, session=None):
    if not isinstance(bvid, str) or not re.fullmatch(r"BV[A-Za-z0-9]{10}", bvid):
        raise _source_failure(SourceError("invalid_bvid", "input"), [])
    if type(page) is not int or not 1 <= page <= 1000 or type(quality) is not int or not 1 <= quality <= 1000:
        raise _source_failure(SourceError("invalid_source_parameters", "input"), [])
    session = session or Session()
    attempts, metadata, embedded, html_cid = [], None, None, None
    lower_manifest = None
    try:
        html = session.html("https://www.bilibili.com/video/" + bvid + "/?p=" + str(page), "video_html")
        state = embedded_json(html, "__INITIAL_STATE__")
        risk = embedded_json(html, "_riskdata_")
        if not state and risk and risk.get("v_voucher"):
            raise SourceError("access_challenge", "video_html")
        if state and isinstance(state.get("videoData"), dict):
            metadata = view_metadata(state["videoData"], bvid)
            html_cid = state.get("cid") or state["videoData"].get("cid")
        embedded = embedded_json(html, "__playinfo__")
        attempts.append(_attempt("video_html"))
    except SourceError as error:
        if error.classification in ("access_restricted", "access_challenge", "request_budget_exhausted"):
            raise _source_failure(error, attempts) from None
        attempts.append(_attempt("video_html", error))
    if metadata is None:
        try:
            data = _api_data(session.json("https://api.bilibili.com/x/web-interface/view?" +
                                         urllib.parse.urlencode({"bvid": bvid}), "view"), "view")
            metadata = view_metadata(data, bvid)
            attempts.append(_attempt("view"))
        except SourceError as error:
            raise _source_failure(error, attempts) from None
    if metadata["bvid"] != bvid:
        raise _source_failure(SourceError("video_identity_mismatch", "metadata"), attempts)
    selected = next((p for p in metadata["pages"] if p["page"] == page), None)
    if selected is None:
        raise _source_failure(SourceError("video_page_unavailable", "metadata"), attempts)
    # videoData.duration can be the aggregate across all P pages. Measurement
    # and seek limits must use the requested page's reported duration only.
    metadata["page_duration"] = selected["duration"]
    # A page query and a matching BV do not identify the embedded DASH's CID.
    # Unknown page identity must use the CID-bound API instead of guessing.
    if embedded and html_cid == selected["cid"]:
        try:
            manifest = select_manifest(embedded, quality, codec, stage="embedded_playurl")
            result = {**manifest, "bvid": bvid, "page": page, "view": metadata,
                      "source_route": "official_video_html", "acquisition_attempts": attempts}
            if not getattr(session, "authenticated", False) or manifest["quality"] == quality:
                return result
            # A logged-in page may embed its default lower quality. Ask the
            # CID-bound official API for the requested representation first.
            lower_manifest = result
        except SourceError as error:
            if error.classification in ("access_restricted", "login_required"):
                raise _source_failure(error, attempts) from None
            attempts.append(_attempt("embedded_playurl", error))
    # At most two additional public play-info routes. No retries on restrictions.
    params = {"bvid": bvid, "cid": selected["cid"], "qn": quality, "fnval": 4048,
              "fnver": 0, "fourk": 1, "wts": int(time.time())}
    routes = ("wbi_playurl", "legacy_playurl")
    for route in routes:
        try:
            if route == "wbi_playurl":
                nav = session.json("https://api.bilibili.com/x/web-interface/nav", "nav")
                query = _signed_query(params, nav)
                attempts.append(_attempt("nav"))
                address = "https://api.bilibili.com/x/player/wbi/playurl?" + query
            else:
                address = "https://api.bilibili.com/x/player/playurl?" + urllib.parse.urlencode(params)
            manifest = select_manifest(session.json(address, route), quality, codec, stage=route)
            attempts.append(_attempt(route))
            return {**manifest, "bvid": bvid, "page": page, "view": metadata,
                    "source_route": "official_" + route, "acquisition_attempts": attempts}
        except SourceError as error:
            attempts.append(_attempt(route, error))
            if error.classification in ("access_restricted", "access_challenge", "login_required",
                                        "request_budget_exhausted"):
                raise _source_failure(error, attempts) from None
    if lower_manifest is not None:
        return {**lower_manifest, "acquisition_attempts": attempts}
    raise _source_failure(SourceError("anonymous_dash_unavailable", "playurl"), attempts)


def anonymous_manifest(bvid, page, quality, preferred_codec="avc"):
    return acquire(bvid, page, quality, preferred_codec)


def discover_candidates(keywords="游戏,生活,科技", request_budget=3, max_candidates=80, *,
                        session=None, older_days=30):
    """Public convenience sample, never a random or complete-site sample.

    Metadata is returned as reported. Missing dates/views stay unknown; callers
    must filter strata explicitly. A restriction ends the whole search family,
    without trying different keywords against the same restricted endpoint.
    """
    if type(request_budget) is not int or not 1 <= request_budget <= 12:
        raise ValueError("invalid discovery request budget")
    if type(max_candidates) is not int or not 1 <= max_candidates <= 200:
        raise ValueError("invalid candidate count")
    if type(older_days) is not int or not 1 <= older_days <= 3650:
        raise ValueError("invalid older-video age")
    session = session or Session(max_requests=request_budget)
    words = [w.strip()[:80] for w in keywords.split(",") if w.strip()][:3] if isinstance(keywords, str) else list(keywords)[:3]
    cutoff = int(time.time()) - older_days * 86400

    def search_spec(word, old):
        params = {"search_type": "video", "keyword": word, "order": "pubdate", "page": 1}
        if old:
            params["pubtime_end"] = cutoff
        return ("search_older" if old else "search_recent",
                "https://api.bilibili.com/x/web-interface/search/type?" + urllib.parse.urlencode(params))

    specs = [("popular", "https://api.bilibili.com/x/web-interface/popular?pn=1&ps=50")]
    if words:
        specs.append(search_spec(words[0], False))
    # This normal public list was verified locally. Its older/high-view entries
    # are still classified from actual publication dates and counts by callers.
    specs.append(("precious", "https://api.bilibili.com/x/web-interface/popular/precious?page_size=50&page=1"))
    if words:
        specs.append(search_spec(words[0], True))
    for word in words[1:]:
        specs.extend((search_spec(word, False), search_spec(word, True)))
    candidates, attempts, seen = [], [], set()
    search_blocked = False
    for stage, url in specs:
        if len(attempts) >= request_budget:
            break
        if len(candidates) >= max_candidates:
            break
        if search_blocked and stage.startswith("search"):
            continue
        try:
            data = _api_data(session.json(url, stage), stage)
            items = data.get("list", data.get("archives", data.get("result", []))) if isinstance(data, dict) else []
            accepted = 0
            for item in items:
                if not isinstance(item, dict):
                    continue
                if item.get("bvid") in seen:
                    continue
                try:
                    meta = view_metadata(item)
                except SourceError:
                    continue
                if stage.startswith("search"):
                    play = item.get("play")
                    meta["stat"]["view"] = _nonnegative(play)
                    length = item.get("duration")
                    if isinstance(length, str) and re.fullmatch(r"\d+:\d{1,2}", length):
                        minutes, seconds = map(int, length.split(":"))
                        meta["duration"] = minutes * 60 + seconds if seconds < 60 else None
                meta["discovery_source"] = stage
                candidates.append(meta)
                seen.add(meta["bvid"])
                accepted += 1
                if len(candidates) >= max_candidates:
                    break
            attempts.append({"stage": stage, "status": "ok", "candidates": accepted})
        except SourceError as error:
            attempts.append(public_error(error))
            if stage.startswith("search") and error.classification in ("access_restricted", "access_challenge", "login_required"):
                search_blocked = True
    return {"candidates": candidates, "attempts": attempts,
            "sampling_boundary": "public convenience sample; missing metadata is unknown",
            "sampling_strategy": {"older_days": older_days, "older_pubtime_end": cutoff,
                                  "keyword_count": len(words),
                                  "search_policy": "stop_search_family_on_access_restriction",
                                  "requested_source_order": [stage for stage, _ in specs]}}


def discover_new_submissions(*, session=None, request_budget=3):
    """Normal public new-submission list; no search restriction circumvention.

    This is a different official catalogue, not a complete/random-site sample.
    Stop this family on a restriction, use at most three ordinary list pages.
    """
    from tool.vod_catalog import extract_candidates
    if type(request_budget) is not int or not 1 <= request_budget <= 3:
        raise ValueError('invalid new-submission budget')
    session = session or Session(max_requests=request_budget)
    candidates, attempts = [], []
    for page in range(1, request_budget + 1):
        try:
            data = _api_data(session.json(
                f'https://api.bilibili.com/x/web-interface/newlist?rid=160&pn={page}&ps=40',
                'official_api'), 'official_api')
            records = extract_candidates(data, source='public_newlist')
            candidates.extend(records)
            attempts.append({'stage': 'official_api', 'source': 'public_newlist',
                             'page': page, 'status': 'ok', 'candidates': len(records)})
            if not records:
                break
        except SourceError as error:
            attempts.append(public_error(error))
            if error.classification in ('access_restricted', 'access_challenge', 'login_required'):
                break
    return {'candidates': candidates, 'attempts': attempts}

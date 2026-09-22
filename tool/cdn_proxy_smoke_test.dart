// Standalone transport checks: dart tool/cdn_proxy_smoke_test.dart
// Uses only local HTTP servers and the Dart SDK; no Bilibili account is needed.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// Standalone execution must also work before Flutter package resolution.
// ignore: avoid_relative_lib_imports
import '../lib/http/cdn_playback_proxy.dart';

const _chunkSize = 65536;
const _concurrency = 3;
const _timeout = Duration(seconds: 15);

Future<void> main() async {
  final tests = <String, Future<void> Function()>{
    'production URL allowlist and opaque tokens': _allowlist,
    'parallel full download preserves byte order and headers':
        _parallelDownload,
    'simultaneous player requests share the concurrency limit':
        _sharedConcurrency,
    'closed, open, suffix and clamped byte ranges': _ranges,
    'HEAD metadata and invalid ranges': _metadataAndInvalidRanges,
    'methods and unregistered tokens cannot fetch arbitrary origins': _routing,
    'redirects stay within the registered origin policy': _redirects,
    'range-ignoring origins fall back without duplicate bytes': _fallback,
    'unknown-length fallback streams until the connection closes':
        _unknownLength,
    'malformed first partial response falls back before output':
        _malformedFirst,
    'late corrupt partial response truncates with a valid prefix': _lateFailure,
    'downstream cancellation stops speculative fetching': _cancellation,
    'cancellation before response headers stops upstream work':
        _earlyCancellation,
    'closing proxy aborts transfers and closes the listener': _close,
  };
  var failures = 0;
  for (final entry in tests.entries) {
    final watch = Stopwatch()..start();
    try {
      await entry.value().timeout(_timeout);
      stdout.writeln('PASS ${entry.key} (${watch.elapsedMilliseconds} ms)');
    } catch (error, stack) {
      failures++;
      stderr.writeln('FAIL ${entry.key}: $error\n$stack');
    }
  }
  stdout.writeln('${tests.length - failures}/${tests.length} checks passed.');
  if (failures > 0) exitCode = 1;
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

HttpClient _client() => HttpClient()
  ..findProxy = ((_) => 'DIRECT')
  ..autoUncompress = false
  ..connectionTimeout = const Duration(seconds: 3);

Future<void> _allowlist() async {
  final proxy = await CdnPlaybackProxy.start();
  try {
    const accepted = <String>[
      'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/10/20/300/300.m4s?deadline=123&sign=secret',
      'https://cn-test.bilivideo.cn/upgcxcode/10/20/300/300.mp4',
      'https://cn-test.bilivideo.net/upgcxcode/10/20/300/300.m4s',
      'https://upos-hz-mirrorakam.akamaized.net/upgcxcode/10/20/300/300.m4s',
    ];
    for (final source in accepted) {
      final local = proxy.register(source);
      final uri = Uri.parse(local);
      _expect(
        local != source,
        'Supported video URL was not registered: $source',
      );
      _expect(uri.scheme == 'http', 'Local playback must use HTTP');
      _expect(
        InternetAddress.tryParse(uri.host)?.isLoopback ?? false,
        'Listener URL is not loopback: $uri',
      );
      _expect(uri.port > 0, 'Missing local listener port');
      _expect(
        !local.contains('bilivideo') &&
            !local.contains('akamaized') &&
            !local.contains('secret') &&
            !local.contains('upgcxcode'),
        'The local playback URL exposed source URL or signature',
      );
    }
    const rejected = <String>[
      'https://example.com/upgcxcode/1.m4s',
      'https://evilbilivideo.com/upgcxcode/1.m4s',
      'https://bilivideo.com.evil.example/upgcxcode/1.m4s',
      'https://127.0.0.1/upgcxcode/1.m4s',
      'http://localhost/upgcxcode/1.m4s',
      'https://upos.bilivideo.com/live-bvc/1.m4s',
      'https://upos.bilivideo.com/upgcxcode/1.m3u8',
      'ftp://upos.bilivideo.com/upgcxcode/1.m4s',
      'file:///upgcxcode/1.m4s',
      'not a valid absolute URL',
    ];
    for (final source in rejected) {
      _expect(
        proxy.register(source) == source,
        'Unsupported URL should retain the original playback route: $source',
      );
    }
  } finally {
    await proxy.close();
  }
}

Future<void> _parallelDownload() => _withFixture((fixture) async {
  final local = fixture.register(
    '/parallel.m4s',
    headers: {
      'Referer': 'https://www.bilibili.com/',
      'User-Agent': 'PiliPlus-cdn-test/1.0',
    },
  );
  final response = await _fetch(local);
  _expect(
    response.status == HttpStatus.ok,
    'Full GET status ${response.status}',
  );
  _expect(
    response.contentLength == fixture.origin.bytes.length,
    'Full GET Content-Length did not describe the complete video',
  );
  _expect(
    response.contentRange == null,
    'Full GET included partial Content-Range',
  );
  _expect(response.contentType == 'video/mp4', 'Video Content-Type was lost');
  _expect(
    response.acceptRanges == 'bytes',
    'Byte-range support was not advertised',
  );
  _expect(response.error == null, 'Full GET stream failed: ${response.error}');
  _expectBytes(response.body, fixture.origin.bytes, 'full download');
  _expect(
    fixture.origin.maxActive > 1,
    'The origin saw no concurrent data requests',
  );
  _expect(
    fixture.origin.maxActive <= _concurrency,
    'Origin concurrency ${fixture.origin.maxActive} exceeded $_concurrency',
  );
  _expect(
    fixture.origin.completedStarts.asMap().entries.any(
      (entry) =>
          entry.key > 0 &&
          entry.value < fixture.origin.completedStarts[entry.key - 1],
    ),
    'Origin fixture did not exercise out-of-order completion',
  );
  for (final request in fixture.origin.requests) {
    _expect(request.referer == 'https://www.bilibili.com/', 'Referer was lost');
    _expect(
      request.userAgent == 'PiliPlus-cdn-test/1.0',
      'User-Agent was lost',
    );
    _expect(
      request.acceptEncoding == 'identity',
      'Upstream must request identity encoding for byte offsets',
    );
    if (request.method == 'GET' && request.range != null) {
      _expect(
        RegExp(r'^bytes=\d+-\d+$').hasMatch(request.range!),
        'Parallel fetch was not a bounded byte range: ${request.range}',
      );
    }
  }
});

Future<void> _sharedConcurrency() => _withFixture((fixture) async {
  final responses = await Future.wait([
    _fetch(fixture.register('/parallel.m4s')),
    _fetch(fixture.register('/parallel.m4s')),
  ]);
  for (final response in responses) {
    _expect(response.status == HttpStatus.ok, 'Simultaneous request failed');
    _expect(
      response.error == null,
      'Simultaneous stream failed: ${response.error}',
    );
    _expectBytes(response.body, fixture.origin.bytes, 'simultaneous download');
  }
  _expect(
    fixture.origin.maxActive > 1,
    'Simultaneous requests were serialized',
  );
  _expect(
    fixture.origin.maxActive <= _concurrency,
    'Simultaneous requests exceeded the shared limit: ${fixture.origin.maxActive}',
  );
});

Future<void> _ranges() => _withFixture((fixture) async {
  final local = fixture.register('/ranges.m4s');
  final total = fixture.origin.bytes.length;
  final cases = <(String, int, int)>[
    ('bytes=17-200123', 17, 200123),
    ('bytes=100003-', 100003, total - 1),
    ('bytes=-70001', total - 70001, total - 1),
    ('bytes=${total - 25}-${total + 1000}', total - 25, total - 1),
    ('bytes=-${total + 1000}', 0, total - 1),
    ('bytes=0-0', 0, 0),
    ('bytes=${total - 1}-${total - 1}', total - 1, total - 1),
  ];
  for (final (range, start, end) in cases) {
    final response = await _fetch(local, range: range);
    _expect(
      response.status == HttpStatus.partialContent,
      '$range status ${response.status}',
    );
    _expect(
      response.contentRange == 'bytes $start-$end/$total',
      '$range unexpected Content-Range ${response.contentRange}',
    );
    _expect(
      response.contentLength == end - start + 1,
      '$range unexpected Content-Length ${response.contentLength}',
    );
    _expect(response.error == null, '$range stream failed: ${response.error}');
    _expectBytes(
      response.body,
      fixture.origin.bytes.sublist(start, end + 1),
      range,
    );
  }
});

Future<void> _metadataAndInvalidRanges() => _withFixture((fixture) async {
  final local = fixture.register('/metadata.m4s');
  final total = fixture.origin.bytes.length;
  final head = await _fetch(local, method: 'HEAD');
  _expect(head.status == HttpStatus.ok, 'HEAD status ${head.status}');
  _expect(head.contentLength == total, 'HEAD lost the source Content-Length');
  _expect(head.contentType == 'video/mp4', 'HEAD lost Content-Type');
  _expect(head.body.isEmpty, 'HEAD returned a body');
  _expect(head.acceptRanges == 'bytes', 'HEAD lost byte-range capability');
  for (final range in <String>[
    'bytes=$total-',
    'bytes=${total + 99}-${total + 120}',
    'bytes=100-99',
    'bytes=-0',
    'bytes=0-10,20-30',
    'bytes=abc-def',
  ]) {
    final response = await _fetch(local, range: range);
    _expect(
      response.status == HttpStatus.requestedRangeNotSatisfiable,
      'Invalid range $range returned ${response.status}',
    );
    if (range == 'bytes=$total-') {
      _expect(
        response.contentRange == 'bytes */$total',
        'Unsatisfiable range omitted the known object size',
      );
    }
  }
});

Future<void> _routing() => _withFixture((fixture) async {
  final local = fixture.register('/routing.m4s');
  final before = fixture.origin.requests.length;
  final post = await _fetch(local, method: 'POST');
  _expect(post.status == HttpStatus.methodNotAllowed, 'POST was not rejected');
  _expect(fixture.origin.requests.length == before, 'POST contacted upstream');
  final unknown = local.replace(path: '${local.path}-unknown');
  final response = await _fetch(unknown);
  _expect(
    response.status == HttpStatus.notFound,
    'Unregistered token returned ${response.status}',
  );
  final arbitrary = local.replace(
    path: '/proxy',
    queryParameters: {'url': fixture.origin.url('/arbitrary.m4s').toString()},
  );
  final arbitraryResponse = await _fetch(arbitrary);
  _expect(arbitraryResponse.status >= 400, 'Arbitrary URL was accepted');
  _expect(
    fixture.origin.requests.length == before,
    'Unknown token or arbitrary URL caused an upstream request',
  );
  for (final headers in <Map<String, String>>[
    {'Origin': 'https://example.com'},
    {'Host': 'example.com'},
  ]) {
    final response = await _fetch(local, headers: headers);
    _expect(
      response.status >= 400,
      'Unexpected browser authority was accepted',
    );
    _expect(
      fixture.origin.requests.length == before,
      'Rejected browser authority fetched upstream',
    );
  }
  final second = await CdnPlaybackProxy.start(
    allowOrigin: (uri) => uri.host == '127.0.0.1',
  );
  try {
    final secondLocal = Uri.parse(
      second.register(fixture.origin.url('/second.m4s').toString()),
    );
    final foreignToken = secondLocal.replace(
      path: local.path,
      query: local.query,
    );
    final foreign = await _fetch(foreignToken);
    _expect(
      foreign.status == HttpStatus.notFound,
      'A token from another proxy instance was accepted',
    );
    _expect(
      fixture.origin.requests.length == before,
      'Foreign token fetched upstream',
    );
  } finally {
    await second.close();
  }
});

Future<void> _redirects() => _withFixture((fixture) async {
  final allowed = await _fetch(fixture.register('/redirect.m4s'));
  _expect(allowed.status == HttpStatus.ok, 'Same-origin redirect failed');
  _expect(allowed.error == null, 'Redirect stream failed: ${allowed.error}');
  _expectBytes(allowed.body, fixture.origin.bytes, 'same-origin redirect');
  final deniedOrigin = await _Origin.start(chunks: 1);
  try {
    fixture.origin.deniedRedirect = deniedOrigin.url('/never-fetch.m4s');
    final denied = await _fetch(fixture.register('/redirect-denied.m4s'));
    _expect(denied.status >= 400, 'Out-of-policy redirect was accepted');
    _expect(
      deniedOrigin.requests.isEmpty,
      'Out-of-policy redirect was fetched',
    );
  } finally {
    await deniedOrigin.close();
  }
});

Future<void> _fallback() => _withFixture((fixture) async {
  final local = fixture.register('/ignore-range.m4s');
  for (final range in <String?>[null, 'bytes=200-900']) {
    final response = await _fetch(local, range: range);
    _expect(
      response.status == HttpStatus.ok,
      'An origin ignoring Range must preserve its 200 status',
    );
    _expect(response.contentRange == null, 'Fallback claimed partial content');
    _expect(response.error == null, 'Fallback failed: ${response.error}');
    _expectBytes(
      response.body,
      fixture.origin.bytes,
      'range-ignoring fallback',
    );
  }
});

Future<void> _unknownLength() => _withFixture((fixture) async {
  final response = await _fetch(fixture.register('/unknown-length.m4s'));
  _expect(
    response.status == HttpStatus.ok,
    'Unknown-length fallback status ${response.status}',
  );
  _expect(
    response.contentLength == -1,
    'Unknown-length fallback invented a length',
  );
  _expect(
    response.error == null,
    'Unknown-length fallback failed: ${response.error}',
  );
  _expectBytes(response.body, fixture.origin.bytes, 'unknown-length fallback');
});

Future<void> _malformedFirst() => _withFixture((fixture) async {
  for (final path in <String>['/malformed-probe.m4s', '/malformed-first.m4s']) {
    final response = await _fetch(fixture.register(path));
    _expect(
      response.status == HttpStatus.ok,
      '$path did not fall back to a full GET',
    );
    _expect(response.error == null, '$path fallback failed: ${response.error}');
    _expectBytes(response.body, fixture.origin.bytes, path);
  }
});

Future<void> _lateFailure() => _withFixture((fixture) async {
  for (final path in <String>[
    '/late-wrong-range.m4s',
    '/late-short-body.m4s',
    '/late-total.m4s',
    '/late-etag.m4s',
  ]) {
    final response = await _fetch(fixture.register(path));
    _expect(
      response.status == HttpStatus.ok,
      '$path lost the initial full response',
    );
    _expect(
      response.body.isNotEmpty,
      '$path did not exercise failure after data',
    );
    _expect(
      response.body.length < fixture.origin.bytes.length,
      '$path silently returned a complete response after upstream corruption',
    );
    _expect(
      response.error != null,
      '$path was not signaled as a truncated response',
    );
    _expect(
      response.error is! TimeoutException,
      '$path left the downstream connection hanging instead of truncating',
    );
    _expectBytes(
      response.body,
      fixture.origin.bytes.sublist(0, response.body.length),
      '$path valid prefix',
    );
  }
});

Future<void> _cancellation() => _withFixture((fixture) async {
  final local = fixture.register('/slow.m4s');
  final client = _client();
  try {
    final request = await client.getUrl(local);
    final response = await request.close();
    final firstBytes = Completer<void>();
    final subscription = response.listen((bytes) {
      if (bytes.isNotEmpty && !firstBytes.isCompleted) firstBytes.complete();
    }, onError: (Object _) {});
    await firstBytes.future.timeout(const Duration(seconds: 5));
    client.close(force: true);
    await subscription.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final settledCount = fixture.origin.requests.length;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _expect(
      fixture.origin.requests.length == settledCount,
      'Upstream requests continued after downstream cancellation '
      '($settledCount -> ${fixture.origin.requests.length})',
    );
    _expect(
      settledCount < fixture.origin.bytes.length ~/ _chunkSize ~/ 2,
      'Cancellation downloaded too much of the remaining video ($settledCount requests)',
    );
  } finally {
    client.close(force: true);
  }
}, chunks: 80);

Future<void> _earlyCancellation() => _withFixture((fixture) async {
  final local = fixture.register('/slow-probe.m4s');
  final client = _client();
  try {
    final request = await client.getUrl(local);
    final pending = request.close().then<void>((response) async {
      await response.listen((_) {}, onError: (Object _) {}).cancel();
    }, onError: (Object _) {});
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (fixture.origin.requests.isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    _expect(fixture.origin.requests.isNotEmpty, 'Probe never reached origin');
    client.close(force: true);
    await pending.timeout(const Duration(seconds: 3));
    await Future<void>.delayed(const Duration(milliseconds: 700));
    _expect(
      fixture.origin.requests.length == 1,
      'Cancelled probe started more upstream requests: ${fixture.origin.requests.length}',
    );
  } finally {
    client.close(force: true);
  }
});

Future<void> _close() => _withFixture((fixture) async {
  final local = fixture.register('/slow.m4s');
  final client = _client();
  try {
    final request = await client.getUrl(local);
    final response = await request.close();
    final firstBytes = Completer<void>();
    final stopped = Completer<void>();
    var received = 0;
    response.listen(
      (bytes) {
        received += bytes.length;
        if (!firstBytes.isCompleted) firstBytes.complete();
      },
      onError: (Object _) {
        if (!stopped.isCompleted) stopped.complete();
      },
      onDone: () {
        if (!stopped.isCompleted) stopped.complete();
      },
    );
    await firstBytes.future.timeout(const Duration(seconds: 5));
    await fixture.proxy.close().timeout(const Duration(seconds: 3));
    await stopped.future.timeout(const Duration(seconds: 3));
    _expect(
      received < fixture.origin.bytes.length,
      'close() allowed the entire transfer to run',
    );
    final check = _client();
    var connected = false;
    try {
      final request = await check.getUrl(local);
      await request.close();
      connected = true;
    } on SocketException {
      // A closed listener must reject new connections.
    } on HttpException {
      // Also valid when connection races listener shutdown.
    } finally {
      check.close(force: true);
    }
    _expect(!connected, 'close() left the listener reachable');
    await fixture.proxy
        .close(); // Closing twice must be safe during player teardown.
  } finally {
    client.close(force: true);
  }
}, chunks: 80);

void _expectBytes(List<int> actual, List<int> expected, String label) {
  _expect(
    actual.length == expected.length,
    '$label: ${actual.length} bytes, expected ${expected.length}',
  );
  for (var index = 0; index < actual.length; index++) {
    if (actual[index] != expected[index]) {
      throw StateError(
        '$label: byte $index was ${actual[index]}, expected ${expected[index]}',
      );
    }
  }
}

Future<void> _withFixture(
  Future<void> Function(_Fixture) action, {
  int chunks = 20,
}) async {
  final origin = await _Origin.start(chunks: chunks);
  CdnPlaybackProxy? proxy;
  try {
    proxy = await CdnPlaybackProxy.start(
      concurrency: _concurrency,
      chunkSize: _chunkSize,
      timeout: const Duration(seconds: 3),
      allowOrigin: (uri) =>
          uri.scheme == 'http' &&
          uri.host == '127.0.0.1' &&
          uri.port == origin.server.port,
    );
    await action(_Fixture(origin, proxy));
  } finally {
    await proxy?.close();
    await origin.close();
  }
}

class _Fixture {
  _Fixture(this.origin, this.proxy);
  final _Origin origin;
  final CdnPlaybackProxy proxy;

  Uri register(String path, {Map<String, String> headers = const {}}) {
    final source = origin.url(path).toString();
    final local = proxy.register(source, headers: headers);
    _expect(local != source, 'allowOrigin seam did not register $source');
    return Uri.parse(local);
  }
}

class _Response {
  _Response(HttpClientResponse response, this.body, this.error)
    : status = response.statusCode,
      contentLength = response.contentLength,
      contentRange = response.headers.value(HttpHeaders.contentRangeHeader),
      contentType = response.headers.contentType?.mimeType,
      acceptRanges = response.headers.value(HttpHeaders.acceptRangesHeader);
  final int status;
  final int contentLength;
  final String? contentRange;
  final String? contentType;
  final String? acceptRanges;
  final Uint8List body;
  final Object? error;
}

Future<_Response> _fetch(
  Uri uri, {
  String method = 'GET',
  String? range,
  Map<String, String> headers = const {},
}) async {
  final client = _client();
  try {
    final request = await client.openUrl(method, uri);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(const Duration(seconds: 5));
    final bytes = BytesBuilder(copy: false);
    Object? error;
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 5))) {
        bytes.add(chunk);
      }
    } catch (caught) {
      error = caught;
    }
    return _Response(response, bytes.takeBytes(), error);
  } finally {
    client.close(force: true);
  }
}

class _OriginRequest {
  _OriginRequest(HttpRequest request)
    : method = request.method,
      range = request.headers.value(HttpHeaders.rangeHeader),
      referer = request.headers.value(HttpHeaders.refererHeader),
      userAgent = request.headers.value(HttpHeaders.userAgentHeader),
      acceptEncoding = request.headers.value(HttpHeaders.acceptEncodingHeader);
  final String method;
  final String? range;
  final String? referer;
  final String? userAgent;
  final String? acceptEncoding;
}

class _Origin {
  _Origin(this.server, this.bytes) {
    server.listen((request) => unawaited(_serve(request)));
  }
  final HttpServer server;
  final Uint8List bytes;
  final requests = <_OriginRequest>[];
  final completedStarts = <int>[];
  int active = 0;
  int maxActive = 0;
  Uri? deniedRedirect;

  static Future<_Origin> start({required int chunks}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final data = Uint8List(_chunkSize * chunks + 137);
    for (var index = 0; index < data.length; index++) {
      data[index] = (index * 31 + (index >> 8) * 17 + (index >> 16) * 11) & 255;
    }
    return _Origin(server, data);
  }

  Uri url(String path) =>
      Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: path);

  Future<void> _serve(HttpRequest request) async {
    requests.add(_OriginRequest(request));
    active++;
    maxActive = math.max(maxActive, active);
    final response = request.response;
    unawaited(response.done.then<void>((_) {}, onError: (Object _) {}));
    try {
      if (request.uri.path == '/redirect.m4s' ||
          request.uri.path == '/redirect-denied.m4s') {
        response.statusCode = HttpStatus.found;
        response.headers.set(
          HttpHeaders.locationHeader,
          request.uri.path == '/redirect.m4s'
              ? url('/redirect-target.m4s')
              : deniedRedirect!,
        );
        response.contentLength = 0;
        await response.close();
        return;
      }
      response.headers.contentType = ContentType('video', 'mp4');
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final match = range == null
          ? null
          : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
      final ignoreRange =
          request.uri.path == '/ignore-range.m4s' ||
          request.uri.path == '/unknown-length.m4s';
      var start = 0;
      var end = bytes.length - 1;
      final partial = !ignoreRange && match != null;
      if (partial) {
        start = int.parse(match.group(1)!);
        end = match.group(2)!.isEmpty
            ? bytes.length - 1
            : math.min(int.parse(match.group(2)!), bytes.length - 1);
      }
      if (start >= bytes.length || start > end) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${bytes.length}',
        );
        response.contentLength = 0;
        await response.close();
        return;
      }
      response
        ..statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok
        ..contentLength = request.uri.path == '/unknown-length.m4s'
            ? -1
            : end - start + 1;
      response.headers.set(
        HttpHeaders.etagHeader,
        request.uri.path == '/late-etag.m4s' && start >= _chunkSize
            ? '"fixture-v2"'
            : '"fixture-v1"',
      );
      if (partial) {
        var reportedStart = start;
        final probe = start == 0 && end == 0;
        if (request.uri.path == '/malformed-probe.m4s' ||
            request.uri.path == '/malformed-first.m4s' && !probe ||
            request.uri.path == '/late-wrong-range.m4s' &&
                start >= _chunkSize) {
          reportedStart++;
        }
        final reportedTotal =
            bytes.length +
            (request.uri.path == '/late-total.m4s' && start >= _chunkSize
                ? 1
                : 0);
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $reportedStart-$end/$reportedTotal',
        );
      }
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      if (request.uri.path == '/parallel.m4s' && end > start) {
        // Later chunks intentionally complete first; output must stay ordered.
        final delay = <int>[65, 100, 8, 25][(start ~/ _chunkSize) % 4];
        await Future<void>.delayed(Duration(milliseconds: delay));
      }
      if (request.uri.path == '/slow.m4s' && end > start) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (request.uri.path == '/slow-probe.m4s') {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      if (request.uri.path == '/late-short-body.m4s' && start >= _chunkSize) {
        response.add(
          Uint8List.sublistView(bytes, start, start + (end - start + 1) ~/ 2),
        );
        await response.flush();
        response.deadline = Duration.zero;
        return;
      }
      response.add(Uint8List.sublistView(bytes, start, end + 1));
      await response.close();
      completedStarts.add(start);
    } on Object {
      // Client cancellation and intentionally truncated fixtures close sockets.
      try {
        response.deadline = Duration.zero;
      } on Object {
        // Already closed by the client or server.
      }
    } finally {
      active--;
    }
  }

  Future<void> close() async {
    await server.close(force: true);
  }
}

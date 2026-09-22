// Standalone V2 transport checks: dart tool/cdn_multi_origin_test.dart
// Every transfer stays on deterministic loopback origins; no account is used.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// ignore: avoid_relative_lib_imports
import '../lib/http/cdn_origin_policy.dart';
// ignore: avoid_relative_lib_imports
import '../lib/http/cdn_playback_proxy.dart';

const _chunkSize = 64 * 1024;
const _total = 12 * _chunkSize + 123;

Future<void> main() async {
  final tests = <String, Future<void> Function()>{
    'V2 limits accept configurable concurrency and chunk size': _limits,
    'geographic policy uses the explicit mainland list and same asset only':
        _geographicPolicy,
    'multiple signed donors interleave mainland hosts before later signatures':
        _donorInterleaving,
    'different mainland origins serve pieces; fast overseas stays unused':
        _multiOrigin,
    'different CDN validators remain origin-local': _originValidators,
    'simultaneous multi-CDN streams share the concurrency limit':
        _sharedConcurrency,
    'a failed mainland piece retries on another mainland origin': _retryPiece,
    'all mainland origins are tried before original-route fallback': _fallback,
    'equal-length alternate with matching prefix but wrong middle is rejected':
        _mismatchedInterior,
    'a changed validator on the same origin cannot corrupt emitted bytes':
        _changedValidator,
    'sliding window schedules ahead of a slow piece from the previous batch':
        _slidingWindow,
    'queued payload reservations remain globally bounded at 64 MiB':
        _bufferBudget,
    'unavailable mainland probes overlap instead of delaying startup serially':
        _parallelProbeFailures,
    'failed anchor identity sample can be replaced by a healthy mainland peer':
        _anchorSampleFailure,
    'speculative metadata cannot starve a healthy first anchor at low concurrency':
        _metadataDoesNotStarveAnchor,
  };
  var failures = 0;
  for (final test in tests.entries) {
    try {
      await test.value().timeout(const Duration(seconds: 20));
      stdout.writeln('PASS ${test.key}');
    } catch (error, stack) {
      failures++;
      stderr.writeln('FAIL ${test.key}: $error\n$stack');
    }
  }
  stdout.writeln('${tests.length - failures}/${tests.length} checks passed.');
  if (failures != 0) exitCode = 1;
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void _expectBytes(List<int> actual, List<int> expected, String label) {
  _expect(actual.length == expected.length, '$label: wrong byte count');
  for (var i = 0; i < actual.length; i++) {
    _expect(actual[i] == expected[i], '$label: incorrect byte at $i');
  }
}

Future<void> _limits() async {
  final defaultProxy = await CdnPlaybackProxy.start();
  try {
    _expect(defaultProxy.concurrency == 8, 'V2 default must be 8 connections');
    _expect(defaultProxy.chunkSize == 1024 * 1024, 'V2 default must be 1 MiB');
  } finally {
    await defaultProxy.close();
  }
  for (final values in [(1, 64 * 1024), (32, 4 * 1024 * 1024)]) {
    final proxy = await CdnPlaybackProxy.start(
      concurrency: values.$1,
      chunkSize: values.$2,
    );
    await proxy.close();
  }
  for (final values in [
    (0, _chunkSize),
    (33, _chunkSize),
    (8, 64 * 1024 - 1),
    (8, 4 * 1024 * 1024 + 1),
  ]) {
    var rejected = false;
    try {
      final proxy = await CdnPlaybackProxy.start(
        concurrency: values.$1,
        chunkSize: values.$2,
      );
      await proxy.close();
    } on ArgumentError {
      rejected = true;
    }
    _expect(rejected, 'Unsafe transport limits were accepted: $values');
  }
}

Future<void> _geographicPolicy() async {
  final original = Uri.parse(
    'https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/1/2/3/asset.m4s'
    '?deadline=123&sign=local-test-only',
  );
  final wrongPath = original.replace(path: '/upgcxcode/1/2/3/other.m4s');
  final result = CdnOriginPolicy.resolve([original, wrongPath]);
  const expectedHosts = {
    'upos-sz-mirrorali.bilivideo.com',
    'upos-sz-mirrorhw.bilivideo.com',
    'upos-sz-mirrorbos.bilivideo.com',
    'upos-sz-mirror08c.bilivideo.com',
    'upos-sz-mirrorbd.bilivideo.com',
    'upos-sz-mirror14b.bilivideo.com',
    'upos-sz-estgoss.bilivideo.com',
    'upos-sz-mirrorcos.bilivideo.com',
  };
  final mainlandHosts = result
      .where((origin) => origin.mainland)
      .map((origin) => origin.uri.host)
      .toSet();
  _expect(
    mainlandHosts.length == expectedHosts.length &&
        mainlandHosts.containsAll(expectedHosts),
    'Mainland candidates must come from the explicit geographic list',
  );
  _expect(
    result.every((origin) => origin.uri.path == original.path),
    'An alternative for another asset entered the media pool',
  );
  _expect(
    result.any((origin) => origin.uri == original && !origin.mainland),
    'The original overseas route was not retained as fallback',
  );
  _expect(
    result
        .where((origin) => origin.mainland)
        .every(
          (origin) => origin.uri.query == original.query,
        ),
    'The signed asset query changed while constructing mainland routes',
  );
  for (final host in [
    'upos-sz-mirroralio1.bilivideo.com',
    'upos-sz-mirrorcoso1.bilivideo.com',
    'upos-tf-all-hw.bilivideo.com',
    'cn-hk-eq-01-01.bilivideo.com',
    'upos-sz-mirroraliov.bilivideo.com',
  ]) {
    final candidate = original.replace(host: host);
    final classified = CdnOriginPolicy.resolve([candidate]);
    _expect(
      classified.any((origin) => origin.uri == candidate && !origin.mainland),
      'Provider or prefix was mistaken for mainland geography: $host',
    );
  }
  final peer = Uri.parse(
    'https://peer.mcdn.bilivideo.cn/v1/resource/media.m4s',
  );
  _expect(
    CdnOriginPolicy.resolve([peer]).every(
      (origin) => origin.uri == peer && !origin.mainland,
    ),
    'A peer-resource path was rewritten onto ordinary mirrors',
  );
}

Future<void> _donorInterleaving() async {
  final first = Uri.parse(
    'https://upos-sz-mirrorcosov.bilivideo.com/upgcxcode/1/2/3/asset.m4s'
    '?deadline=123&sign=first-signature',
  );
  final second = first.replace(
    host: 'upos-hz-mirrorakam.akamaized.net',
    query: 'deadline=456&sign=second-signature',
  );
  for (final sources in [
    [first, second],
    [
      first.replace(host: 'upos-sz-mirrorcos.bilivideo.com'),
      second.replace(host: 'upos-sz-mirrorhw.bilivideo.com'),
    ],
    [
      first.replace(host: 'upos-sz-mirrorcos.bilivideo.com'),
      second.replace(host: 'upos-sz-mirrorcos.bilivideo.com'),
    ],
  ]) {
    final candidates = CdnOriginPolicy.resolve(sources);
    final mainland = candidates.where((origin) => origin.mainland).toList();
    _expect(
      mainland.length == 16,
      'A signed donor was discarded or duplicated',
    );
    for (var round = 0; round < 2; round++) {
      final roundHosts = mainland
          .skip(round * 8)
          .take(8)
          .map((origin) => origin.uri.host)
          .toSet();
      _expect(
        roundHosts.length == 8 &&
            roundHosts.containsAll(CdnOriginPolicy.mainlandHosts),
        'Multiple signatures repeated a CDN before completing host round $round',
      );
    }
    for (final host in CdnOriginPolicy.mainlandHosts) {
      final queries = mainland
          .where((origin) => origin.uri.host == host)
          .map((origin) => origin.uri.query)
          .toSet();
      _expect(
        queries.contains(first.query) && queries.contains(second.query),
        'The alternate signed address was lost for $host',
      );
    }
    if (CdnOriginPolicy.mainlandHosts.contains(sources.first.host)) {
      _expect(
        mainland.first.uri == sources.first,
        'An API-provided mainland address lost its initial host priority',
      );
    }
    final repeated = CdnOriginPolicy.resolve(sources);
    _expect(
      repeated.map((origin) => origin.uri).join('\n') ==
          candidates.map((origin) => origin.uri).join('\n'),
      'Candidate ordering changed without any input change',
    );
  }
}

Future<void> _multiOrigin() => _withFixture((fixture) async {
  fixture.origins[0].delay = const Duration(milliseconds: 18);
  fixture.origins[1].delay = const Duration(milliseconds: 4);
  fixture.origins[2].delay = const Duration(milliseconds: 11);
  final response = await _fetch(fixture.localUrl);
  _expect(response.error == null, 'Multi-origin response failed');
  _expectBytes(response.bytes, fixture.bytes, 'multi-origin order');
  for (final origin in fixture.mainland) {
    _expect(
      origin.pieces.isNotEmpty,
      'A healthy mainland origin served no piece',
    );
  }
  _expect(
    fixture.fallback.requests.isEmpty,
    'The faster overseas route was used while mainland origins were healthy',
  );
  _expect(
    fixture.maxActive > 1,
    'Independent origins were downloaded serially',
  );
  _expect(fixture.maxActive <= 4, 'Configured concurrency was exceeded');
});

Future<void> _originValidators() => _withFixture((fixture) async {
  final response = await _fetch(fixture.localUrl);
  _expectBytes(response.bytes, fixture.bytes, 'different origin validators');
  for (final origin in fixture.mainland) {
    _expect(
      origin.pieces.isNotEmpty,
      'Different ETag incorrectly excluded a CDN',
    );
    _expect(
      origin.foreignValidators == 0,
      'A validator from a different origin was sent to this CDN',
    );
  }
});

Future<void> _sharedConcurrency() => _withFixture((fixture) async {
  final responses = await Future.wait([
    _fetch(fixture.localUrl),
    _fetch(fixture.localUrl),
  ]);
  for (final response in responses) {
    _expect(response.error == null, 'Concurrent player response failed');
    _expectBytes(response.bytes, fixture.bytes, 'concurrent playback requests');
  }
  _expect(fixture.maxActive > 1, 'Concurrent streams were fully serialized');
  _expect(
    fixture.maxActive <= 4,
    'Multiple transfers escaped the global connection limit: ${fixture.maxActive}',
  );
});

Future<void> _retryPiece() => _withFixture((fixture) async {
  fixture.origins[0].failOnePiece = true;
  final response = await _fetch(fixture.localUrl);
  _expectBytes(response.bytes, fixture.bytes, 'piece retry');
  final failed = fixture.origins[0].failedPiece;
  _expect(failed != null, 'Fixture did not exercise an actual piece failure');
  _expect(
    fixture.mainland
        .skip(1)
        .any(
          (origin) => origin.pieces.any(
            (request) =>
                request.start == failed!.$1 && request.end == failed.$2,
          ),
        ),
    'The failed byte interval was not retried on a mainland peer',
  );
  _expect(
    fixture.fallback.requests.isEmpty,
    'Retry unnecessarily left mainland',
  );
});

Future<void> _fallback() => _withFixture((fixture) async {
  for (final origin in fixture.mainland) {
    origin.rejectAll = true;
  }
  final response = await _fetch(fixture.localUrl);
  _expectBytes(
    response.bytes,
    fixture.bytes,
    'all-mainland unavailable fallback',
  );
  _expect(
    fixture.fallback.pieces.isNotEmpty,
    'Original-route fallback was unused',
  );
  final firstFallback = fixture.fallback.requests.first.sequence;
  for (final origin in fixture.mainland) {
    _expect(
      origin.requests.any((request) => request.sequence < firstFallback),
      'Fallback began before trying every mainland candidate',
    );
  }
});

Future<void> _mismatchedInterior() => _withFixture((fixture) async {
  fixture.origins[1].wrongInterior = true;
  final response = await _fetch(fixture.localUrl);
  _expectBytes(response.bytes, fixture.bytes, 'alternate identity mismatch');
  final rejected = fixture.origins[1];
  _expect(
    rejected.requests.any((request) => request.start >= _chunkSize),
    'The alternate was never sampled beyond its matching prefix',
  );
  _expect(
    rejected.pieces.isEmpty,
    'A mismatched CDN was admitted for data pieces',
  );
  _expect(
    fixture.fallback.requests.isEmpty,
    'Healthy mainland peer was skipped',
  );
});

Future<void> _changedValidator() => _withFixture(
  (fixture) async {
    fixture.origins[0].changeValidator = true;
    final response = await _fetch(fixture.localUrl);
    _expect(
      response.bytes.length < fixture.bytes.length,
      'A representation that changed during the transfer was fully accepted',
    );
    _expectBytes(
      response.bytes,
      fixture.bytes.sublist(0, response.bytes.length),
      'valid prefix before a same-origin version change',
    );
  },
  mainlandCount: 1,
  includeFallback: false,
);

Future<void> _slidingWindow() => _withFixture(
  (fixture) async {
    final origin = fixture.origins.single;
    final release = Completer<void>();
    final ahead = Completer<void>();
    origin.blockers[4 * _chunkSize] = release;
    origin.observedStarts[5 * _chunkSize] = ahead;
    final download = _fetch(fixture.localUrl);
    try {
      // Chunks 1, 2 and 3 can be consumed while chunk 4 is blocked. The next
      // window must already schedule chunk 5 instead of waiting for a batch.
      await ahead.future.timeout(const Duration(seconds: 2));
    } finally {
      release.complete();
      final response = await download;
      _expectBytes(response.bytes, fixture.bytes, 'sliding-window byte order');
    }
  },
  mainlandCount: 1,
  includeFallback: false,
);

Future<void> _parallelProbeFailures() => _withFixture(
  (fixture) async {
    for (final origin in fixture.mainland) {
      origin.rejectProbeAfter = const Duration(milliseconds: 200);
    }
    final watch = Stopwatch()..start();
    final response = await _fetch(fixture.localUrl);
    watch.stop();
    _expectBytes(response.bytes, fixture.bytes, 'parallel unavailable probes');
    _expect(
      watch.elapsedMilliseconds < 650,
      'Four 200 ms failed metadata probes serialized startup: '
      '${watch.elapsedMilliseconds} ms',
    );
    final firstFallback = fixture.fallback.requests.first.sequence;
    for (final origin in fixture.mainland) {
      _expect(
        origin.requests.any(
          (request) =>
              request.start == 0 &&
              request.end == 0 &&
              request.sequence < firstFallback,
        ),
        'An unavailable mainland probe was skipped before fallback',
      );
    }
  },
  mainlandCount: 4,
);

Future<void> _anchorSampleFailure() => _withFixture((fixture) async {
  fixture.origins[0].rejectMiddleSample = true;
  final response = await _fetch(fixture.localUrl);
  _expectBytes(
    response.bytes,
    fixture.bytes,
    'anchor identity-sample recovery',
  );
  final rejected = fixture.origins[0];
  _expect(
    rejected.requests.any(
      (request) => request.start == fixture.bytes.length ~/ 2,
    ),
    'The first anchor did not reach the failing middle sample',
  );
  _expect(rejected.pieces.isEmpty, 'Failed anchor emitted a data piece');
  for (final healthy in fixture.mainland.skip(1)) {
    _expect(healthy.pieces.isNotEmpty, 'Failed anchor poisoned a healthy peer');
  }
  _expect(
    fixture.fallback.requests.isEmpty,
    'Anchor failure skipped mainland peers',
  );
});

Future<void> _metadataDoesNotStarveAnchor() async {
  for (final concurrency in [1, 2]) {
    await _withFixture(
      (fixture) async {
        final release = Completer<void>();
        for (final origin in fixture.mainland.skip(1)) {
          origin.metadataBlocker = release;
        }
        final download = _fetch(
          fixture.localUrl,
          range: 'bytes=0-${_chunkSize - 1}',
        );
        try {
          // Seven unused metadata candidates must not consume every slot ahead
          // of the healthy first origin's identity samples and playback bytes.
          final response = await download.timeout(
            const Duration(milliseconds: 500),
          );
          _expectBytes(
            response.bytes,
            fixture.bytes.sublist(0, _chunkSize),
            'healthy startup with concurrency $concurrency',
          );
          _expect(
            fixture.origins.first.pieces.isNotEmpty,
            'The healthy first origin did not serve the requested playback range',
          );
        } finally {
          release.complete();
          await download;
        }
      },
      mainlandCount: 8,
      includeFallback: false,
      concurrency: concurrency,
    );
  }
}

Future<void> _bufferBudget() async {
  const chunkSize = 4 * 1024 * 1024;
  const total = 40 * chunkSize;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final origin = Uri.parse(
    'http://127.0.0.1:${server.port}/upgcxcode/large/media.m4s',
  );
  final releaseHead = Completer<void>();
  final exercised = Completer<void>();
  var queuedPieces = 0;
  server.listen((request) {
    unawaited(() async {
      try {
        final range = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(
          request.headers.value(HttpHeaders.rangeHeader) ?? '',
        )!;
        final start = int.parse(range[1]!);
        final end = int.parse(range[2]!);
        if (start >= chunkSize && end - start + 1 == chunkSize) {
          queuedPieces++;
          if (queuedPieces >= 8 && !exercised.isCompleted) exercised.complete();
        }
        if (start == chunkSize) await releaseHead.future;
        final response = request.response
          ..statusCode = HttpStatus.partialContent
          ..contentLength = end - start + 1;
        response.headers
          ..set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total')
          ..set(HttpHeaders.etagHeader, '"unchanging-large-object"');
        // No entire 160 MiB file is allocated; each deterministic piece is zero.
        response.add(Uint8List(end - start + 1));
        await response.close();
      } on Object {
        request.response.deadline = Duration.zero;
      }
    }());
  });
  final proxy = await CdnPlaybackProxy.start(
    concurrency: 32,
    chunkSize: chunkSize,
    timeout: const Duration(seconds: 5),
    allowOrigin: (uri) => uri.origin == origin.origin,
    originResolver: (_) => [CdnOrigin(origin, mainland: true)],
  );
  final local = proxy.register(origin.toString());
  final downloads = [_fetch(local), _fetch(local)];
  try {
    await exercised.future.timeout(const Duration(seconds: 3));
    // Both player streams stop at the held 4 MiB piece. Later responses can
    // finish but cannot be consumed, so all queued reservations remain live.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    _expect(
      queuedPieces <= 16,
      'Queued $queuedPieces x 4 MiB across players, exceeding 64 MiB globally',
    );
  } finally {
    await proxy.close();
    releaseHead.complete();
    await Future.wait(downloads);
    await server.close(force: true);
  }
}

Future<void> _withFixture(
  Future<void> Function(_Fixture) action, {
  int mainlandCount = 3,
  bool includeFallback = true,
  int concurrency = 4,
}) async {
  final fixture = await _Fixture.start(
    mainlandCount,
    includeFallback,
    concurrency,
  );
  try {
    await action(fixture);
  } finally {
    await fixture.close();
  }
}

final class _Fixture {
  final Uint8List bytes = Uint8List(_total);
  final List<_Origin> origins = [];
  late CdnPlaybackProxy proxy;
  late String localUrl;
  var active = 0;
  var maxActive = 0;
  var sequence = 0;

  Iterable<_Origin> get mainland => origins.where((origin) => origin.mainland);
  _Origin get fallback => origins.last;

  static Future<_Fixture> start(
    int mainlandCount,
    bool includeFallback,
    int concurrency,
  ) async {
    final fixture = _Fixture();
    var state = 0x15abcd;
    for (var i = 0; i < fixture.bytes.length; i++) {
      state = (state * 1664525 + 1013904223) & 0xffffffff;
      fixture.bytes[i] = state >> 24;
    }
    final count = mainlandCount + (includeFallback ? 1 : 0);
    for (var i = 0; i < count; i++) {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = _Origin(fixture, server, i, i < mainlandCount);
      fixture.origins.add(origin);
      server.listen((request) {
        unawaited(origin.handle(request));
      });
    }
    fixture.proxy = await CdnPlaybackProxy.start(
      concurrency: concurrency,
      chunkSize: _chunkSize,
      timeout: const Duration(seconds: 2),
      allowOrigin: (uri) => fixture.origins.any(
        (origin) => uri.origin == origin.uri.origin,
      ),
      originResolver: (_) => fixture.origins
          .map((origin) => CdnOrigin(origin.uri, mainland: origin.mainland))
          .toList(),
    );
    fixture.localUrl = fixture.proxy.register(
      fixture.origins.last.uri.toString(),
      alternatives: fixture.origins.map((origin) => origin.uri.toString()),
    );
    return fixture;
  }

  Future<void> close() async {
    await proxy.close();
    for (final origin in origins) {
      final metadataBlocker = origin.metadataBlocker;
      if (metadataBlocker != null && !metadataBlocker.isCompleted) {
        metadataBlocker.complete();
      }
      for (final blocker in origin.blockers.values) {
        if (!blocker.isCompleted) blocker.complete();
      }
    }
    await Future.wait(
      origins.map((origin) => origin.server.close(force: true)),
    );
  }
}

final class _Origin {
  _Origin(this.fixture, this.server, this.id, this.mainland);
  final _Fixture fixture;
  final HttpServer server;
  final int id;
  final bool mainland;
  final List<_Request> requests = [];
  final Map<int, Completer<void>> blockers = {};
  final Map<int, Completer<void>> observedStarts = {};
  Completer<void>? metadataBlocker;
  Duration delay = const Duration(milliseconds: 8);
  bool rejectAll = false;
  bool failOnePiece = false;
  bool wrongInterior = false;
  bool changeValidator = false;
  Duration? rejectProbeAfter;
  bool rejectMiddleSample = false;
  (int, int)? failedPiece;
  int foreignValidators = 0;

  Uri get uri => Uri.parse(
    'http://127.0.0.1:${server.port}/upgcxcode/test/media.m4s',
  );
  String get etag => '"origin-$id-unique-validator"';
  String get modified => HttpDate.format(DateTime.utc(2026, 1, id + 1));
  Iterable<_Request> get pieces => requests.where(
    (request) => request.end - request.start + 1 >= _chunkSize,
  );

  Future<void> handle(HttpRequest request) async {
    fixture.active++;
    fixture.maxActive = math.max(fixture.maxActive, fixture.active);
    try {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final match = range == null
          ? null
          : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
      final start = match == null ? 0 : int.parse(match[1]!);
      final end = match == null || match[2]!.isEmpty
          ? fixture.bytes.length - 1
          : math.min(int.parse(match[2]!), fixture.bytes.length - 1);
      final record = _Request(++fixture.sequence, start, end);
      requests.add(record);
      if (start == 0 && end == 0 && metadataBlocker != null) {
        await metadataBlocker!.future;
      }
      if (start == 0 && end == 0 && rejectProbeAfter != null) {
        await Future<void>.delayed(rejectProbeAfter!);
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
      if (end - start + 1 >= _chunkSize) {
        final observed = observedStarts[start];
        if (observed != null && !observed.isCompleted) observed.complete();
        final blocked = blockers[start];
        if (blocked != null) await blocked.future;
      }
      if (rejectAll ||
          (rejectMiddleSample &&
              start == fixture.bytes.length ~/ 2 &&
              end - start + 1 == 4096) ||
          (failOnePiece &&
              failedPiece == null &&
              start >= _chunkSize &&
              end - start + 1 >= _chunkSize)) {
        if (!rejectAll) failedPiece = (start, end);
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
      await Future<void>.delayed(delay);
      final changed =
          changeValidator &&
          start >= _chunkSize &&
          end - start + 1 >= _chunkSize;
      final responseEtag = changed ? '"origin-$id-new-version"' : etag;
      final conditional = request.headers.value(HttpHeaders.ifRangeHeader);
      // RFC If-Range semantics: a nonmatching origin-local validator yields a
      // full representation, which the proxy must never append as a byte piece.
      final conditionalMismatch =
          conditional != null &&
          conditional != responseEtag &&
          conditional != modified;
      if (conditionalMismatch && !changed) foreignValidators++;
      final isPartial = match != null && !conditionalMismatch;
      final bodyStart = isPartial ? start : 0;
      final bodyEnd = isPartial ? end : fixture.bytes.length - 1;
      final body = Uint8List.fromList(
        fixture.bytes.sublist(bodyStart, bodyEnd + 1),
      );
      if (wrongInterior || changed) {
        for (var i = 0; i < body.length; i++) {
          if (bodyStart + i >= _chunkSize) body[i] ^= 0xff;
        }
      }
      final response = request.response
        ..statusCode = isPartial ? HttpStatus.partialContent : HttpStatus.ok
        ..contentLength = body.length;
      response.headers
        ..set(HttpHeaders.contentTypeHeader, 'video/mp4')
        ..set(HttpHeaders.etagHeader, responseEtag)
        ..set(HttpHeaders.lastModifiedHeader, modified)
        ..set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (isPartial) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${fixture.bytes.length}',
        );
      }
      if (request.method != 'HEAD') response.add(body);
      await response.close();
    } on Object {
      // Closing a failed/cancelled transfer may abort a deterministic origin.
      request.response.deadline = Duration.zero;
    } finally {
      fixture.active--;
    }
  }
}

final class _Request {
  const _Request(this.sequence, this.start, this.end);
  final int sequence;
  final int start;
  final int end;
}

final class _Response {
  const _Response(this.bytes, this.error);
  final Uint8List bytes;
  final Object? error;
}

Future<_Response> _fetch(String url, {String? range}) async {
  final client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..autoUncompress = false;
  final bytes = BytesBuilder(copy: false);
  Object? failure;
  try {
    final request = await client.getUrl(Uri.parse(url));
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    final response = await request.close();
    _expect(
      response.statusCode ==
          (range == null ? HttpStatus.ok : HttpStatus.partialContent),
      'Unexpected playback status',
    );
    try {
      await for (final chunk in response) {
        bytes.add(chunk);
      }
    } on Object catch (error) {
      failure = error;
    }
  } finally {
    client.close(force: true);
  }
  return _Response(bytes.takeBytes(), failure);
}

// Bounded transport diagnostics checks. Only synthetic loopback media is used.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

// ignore: avoid_relative_lib_imports
import '../lib/http/cdn_origin_policy.dart';
// ignore: avoid_relative_lib_imports
import '../lib/http/cdn_playback_proxy.dart';
// ignore: avoid_relative_lib_imports
import '../lib/utils/cdn_startup_trace.dart';
import 'cdn_benchmark_bridge.dart' as bridge;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

final class Fixture {
  Fixture(
    this.server,
    this.bytes,
    this.headerDelay,
    this.bodyDelay,
    this.change,
  );
  final HttpServer server;
  final Uint8List bytes;
  final Duration headerDelay;
  final Duration bodyDelay;
  final bool change;
  int requests = 0;

  static Future<Fixture> start({
    Duration headerDelay = Duration.zero,
    Duration bodyDelay = Duration.zero,
    bool change = false,
  }) async {
    final bytes = Uint8List.fromList(
      List.generate(512 * 1024, (index) => index % 251),
    )..setRange(0, 23, utf8.encode('diagnostic-secret-body!'));
    final fixture = Fixture(
      await HttpServer.bind('127.0.0.1', 0),
      bytes,
      headerDelay,
      bodyDelay,
      change,
    );
    fixture.server.listen((request) async {
      final number = ++fixture.requests;
      try {
        if (headerDelay > Duration.zero) {
          await Future<void>.delayed(headerDelay);
        }
        final raw = request.headers.value('range');
        final match = raw == null
            ? null
            : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(raw);
        final start = match == null ? 0 : int.parse(match[1]!);
        final end = match == null || match[2]!.isEmpty
            ? bytes.length - 1
            : min(bytes.length - 1, int.parse(match[2]!));
        final response = request.response..statusCode = raw == null ? 200 : 206;
        if (raw != null) {
          response.headers.set(
            'content-range',
            'bytes $start-$end/${bytes.length}',
          );
        }
        response.headers.set(
          'etag',
          change && number > 1
              ? '"changed-diagnostic-secret"'
              : '"diagnostic-secret"',
        );
        response.headers.set(
          'last-modified',
          change && number > 1
              ? 'Tue, 29 Sep 2026 00:00:00 GMT'
              : 'Mon, 28 Sep 2026 00:00:00 GMT',
        );
        response.contentLength = end - start + 1;
        for (var offset = start; offset <= end; offset += 32 * 1024) {
          response.add(bytes.sublist(offset, min(end + 1, offset + 32 * 1024)));
          if (bodyDelay > Duration.zero) {
            await response.flush();
            await Future<void>.delayed(bodyDelay);
          }
        }
        await response.close();
      } catch (_) {
        // Client cancellation is intentional in several checks.
      }
    });
    return fixture;
  }

  Uri get uri => Uri.parse(
    'http://127.0.0.1:${server.port}/upgcxcode/test/video.m4s?upsig=diagnostic-secret-query',
  );
  Future<void> close() => server.close(force: true);
}

Future<CdnPlaybackProxy> proxyFor(
  Fixture fixture, {
  bool diagnostics = true,
  int eventLimit = 12000,
  int concurrency = 2,
  bool stream = false,
  Duration timeout = const Duration(seconds: 2),
}) => CdnPlaybackProxy.start(
  enableDiagnostics: diagnostics,
  diagnosticEventLimit: eventLimit,
  concurrency: concurrency,
  chunkSize: 64 * 1024,
  timeout: timeout,
  autoSelect: stream,
  parallel: !stream,
  allowOrigin: (uri) =>
      uri.host == '127.0.0.1' && uri.port == fixture.server.port,
  originResolver: (uris) => [CdnOrigin(uris.first, mainland: true)],
  isBaselineOrigin: (_) => true,
);

Future<Uint8List> fetch(String url) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close();
    check(response.statusCode == 200, 'unexpected media status');
    final result = BytesBuilder(copy: false);
    await for (final bytes in response) {
      result.add(bytes);
    }
    return result.takeBytes();
  } finally {
    client.close(force: true);
  }
}

bool sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

List<Map<String, Object>> events(CdnPlaybackProxy proxy) =>
    (proxy.diagnostics['request_events'] as List).cast<Map<String, Object>>();

String register(CdnPlaybackProxy proxy, Fixture fixture) => proxy.register(
  fixture.uri.toString(),
  headers: const {
    'Referer': 'https://www.bilibili.com/?private=diagnostic-secret-header',
  },
  track: CdnStartupTrack.video,
);

Future<void> disabledAndByteIdentity() async {
  final fixture = await Fixture.start();
  final disabled = await proxyFor(fixture, diagnostics: false);
  final enabled = await proxyFor(fixture);
  try {
    final off = await fetch(register(disabled, fixture));
    final on = await fetch(register(enabled, fixture));
    check(
      sameBytes(off, fixture.bytes) && sameBytes(on, off),
      'observation changed bytes',
    );
    check(
      disabled.diagnostics['diagnostics_enabled'] == false,
      'default-off flag',
    );
    check(
      !disabled.diagnostics.containsKey('request_events'),
      'disabled retained events',
    );
    final rows = events(enabled);
    check(
      rows.any((row) => row['event'] == 'headers' && row['http'] == 206),
      'no HTTP headers',
    );
    check(
      rows.any((row) => row['event'] == 'body_first'),
      'no first-byte observation',
    );
    check(
      rows.any((row) => row['event'] == 'output_complete'),
      'no completed output',
    );
    var previous = -1;
    for (final row in rows) {
      check((row['t_ms'] as int) >= previous, 'nonmonotonic request clock');
      previous = row['t_ms'] as int;
      check(row['track'] == 'video', 'lost track');
      check(
        (row['parent_id'] as int) > 0 && (row['transfer_id'] as int) > 0,
        'lost lineage',
      );
    }
    final text = jsonEncode(enabled.diagnostics);
    check(
      !text.contains('diagnostic-secret') && !text.contains('/upgcxcode/'),
      'private data escaped',
    );
    final flushed = enabled.diagnostics['track_flushed_body_bytes'] as Map;
    check(
      flushed['video'] == fixture.bytes.length,
      'ordered flush counter mismatch',
    );
    check(
      enabled.diagnostics['diagnostic_upstream_body_bytes'] ==
          fixture.bytes.length + 1,
      'upstream counter mismatch',
    );
  } finally {
    await disabled.close();
    await enabled.close();
    await fixture.close();
  }
}

Future<void> boundedEvents() async {
  final fixture = await Fixture.start();
  final proxy = await proxyFor(fixture, eventLimit: 8);
  try {
    check(
      sameBytes(await fetch(register(proxy, fixture)), fixture.bytes),
      'bounded logging altered bytes',
    );
    check(events(proxy).length == 8, 'event limit failed');
    check(
      (proxy.diagnostics['request_events_dropped'] as int) > 0,
      'missing truncation signal',
    );
    check(
      (proxy.diagnostics['host_request_counts'] as Map).length <= 128,
      'host count limit failed',
    );
    check(
      (proxy.diagnostics['diagnostic_upstream_body_bytes'] as int) > 0,
      'capped trace stopped counters',
    );
  } finally {
    await proxy.close();
    await fixture.close();
  }
}

Future<void> queueAndRelease() async {
  final fixture = await Fixture.start(
    headerDelay: const Duration(milliseconds: 30),
  );
  final proxy = await proxyFor(fixture, concurrency: 1);
  try {
    final url = register(proxy, fixture);
    final received = await Future.wait([fetch(url), fetch(url)]);
    check(
      received.every((value) => sameBytes(value, fixture.bytes)),
      'queued media bytes',
    );
    final rows = events(proxy);
    check(
      rows.any((row) => row['event'] == 'queued'),
      'queue was not observed',
    );
    final complete = rows.where((row) => row['event'] == 'body_complete');
    check(complete.isNotEmpty, 'no completed request');
    for (final row in complete) {
      check(
        rows.any(
          (later) =>
              later['event'] == 'request_released' &&
              later['request_id'] == row['request_id'] &&
              (later['t_ms'] as int) >= (row['t_ms'] as int),
        ),
        'completion suppressed slot release',
      );
    }
  } finally {
    await proxy.close();
    check(proxy.diagnostics['active_origin_requests'] == 0, 'slots leaked');
    await fixture.close();
  }
}

Future<void> validatorMismatch() async {
  final fixture = await Fixture.start(change: true);
  final proxy = await proxyFor(fixture);
  try {
    check(
      sameBytes(await fetch(register(proxy, fixture)), fixture.bytes),
      'fallback changed content',
    );
    final rows = events(proxy);
    check(
      rows.any(
        (row) =>
            row['event'] == 'range_validation' &&
            row['accepted'] == false &&
            row['validator_checked'] == true &&
            row['etag_equal'] == false &&
            row['modified_equal'] == false,
      ),
      'missing safe validator mismatch evidence',
    );
    check(
      rows.any(
        (row) => row['event'] == 'failure' && row['kind'] == 'range_metadata',
      ),
      'missing failure classification',
    );
    check(
      !jsonEncode(proxy.diagnostics).contains('diagnostic-secret'),
      'validator or fallback URL escaped',
    );
  } finally {
    await proxy.close();
    await fixture.close();
  }
}

Future<void> continuousStream() async {
  final fixture = await Fixture.start(
    bodyDelay: const Duration(milliseconds: 10),
  );
  final proxy = await proxyFor(fixture, stream: true);
  try {
    check(
      sameBytes(await fetch(register(proxy, fixture)), fixture.bytes),
      'stream content changed',
    );
    final rows = events(proxy);
    check(
      rows.any((row) => row['event'] == 'selected' && row['phase'] == 'stream'),
      'missing stream selection',
    );
    check(
      rows.any(
        (row) => row['event'] == 'body_complete' && row['phase'] == 'stream',
      ),
      'missing stream completion',
    );
    check(
      !rows.any((row) => row['event'] == 'stream_to_chunks'),
      'healthy stream spuriously split',
    );
  } finally {
    await proxy.close();
    await fixture.close();
  }
}

Future<void> cancellationAndTimeout() async {
  final fixture = await Fixture.start(
    bodyDelay: const Duration(milliseconds: 50),
  );
  final proxy = await proxyFor(fixture, stream: true);
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(
      Uri.parse(register(proxy, fixture)),
    )).close();
    final first = Completer<void>();
    final sub = response.listen((_) {
      if (!first.isCompleted) first.complete();
    }, onError: (Object _) {});
    await first.future.timeout(const Duration(seconds: 2));
    client.close(force: true);
    await sub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await proxy.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    check(
      events(proxy).any((row) => row['event'] == 'cancel'),
      'cancel was not observed',
    );
    check(
      proxy.diagnostics['active_origin_requests'] == 0,
      'cancel leaked slot',
    );
  } finally {
    client.close(force: true);
    await proxy.close();
    await fixture.close();
  }
  final slow = await Fixture.start(
    headerDelay: const Duration(milliseconds: 200),
  );
  final failing = await proxyFor(
    slow,
    timeout: const Duration(milliseconds: 50),
  );
  try {
    try {
      await fetch(register(failing, slow));
    } catch (_) {}
    check(
      events(failing)
          .any((row) => row['event'] == 'failure' && row['kind'] == 'timeout'),
      'timeout classification missing',
    );
  } finally {
    await failing.close();
    await slow.close();
  }
}

Future<void> fixedHuaweiControl() async {
  const source =
      'https://example.akamaized.net/upgcxcode/test/video.m4s?upsig=private';
  final rewritten = bridge.benchmarkFixedHuaweiUrls([source]);
  final uri = Uri.parse(rewritten.single);
  final candidates = bridge.benchmarkFixedHuaweiOrigins([uri]);
  check(
    uri.host == bridge.benchmarkHuaweiHost,
    'fallback base not fixed Huawei',
  );
  check(
    uri.path == Uri.parse(source).path && uri.query == Uri.parse(source).query,
    'signed resource altered',
  );
  check(
    candidates.length == 1 &&
        candidates.single.uri == uri &&
        candidates.single.mainland,
    'singleton resolver expanded',
  );
  check(bridge.benchmarkAllowFixedHuawei(uri), 'Huawei denied');
  check(
    !bridge.benchmarkAllowFixedHuawei(Uri.parse(source)),
    'foreign redirect allowed',
  );
  check(
    bridge.benchmarkFixedHuaweiOrigins([Uri.parse(source)]).isEmpty,
    'foreign base admitted',
  );
}

Future<void> main() async {
  final cases = <String, Future<void> Function()>{
    'disabled_byte_identity_and_privacy': disabledAndByteIdentity,
    'bounded_trace_and_counters': boundedEvents,
    'queue_and_release_timeline': queueAndRelease,
    'validator_mismatch_and_fallback': validatorMismatch,
    'healthy_continuous_stream': continuousStream,
    'cancellation_and_timeout': cancellationAndTimeout,
    'fixed_huawei_pool_fallback_redirect': fixedHuaweiControl,
  };
  var passed = 0;
  for (final entry in cases.entries) {
    await entry.value();
    passed++;
    stdout.writeln(jsonEncode({'case': entry.key, 'status': 'passed'}));
  }
  stdout.writeln(jsonEncode({'passed': passed, 'total': cases.length}));
}

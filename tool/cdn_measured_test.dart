// Deterministic transport checks: no public network or accounts.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

// ignore: avoid_relative_lib_imports
import '../lib/http/cdn_origin_policy.dart';
// ignore: avoid_relative_lib_imports
import '../lib/http/cdn_playback_proxy.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

class Origin {
  Origin(this.server, this.bytes, this.delay, this.stalled);
  final HttpServer server;
  final Uint8List bytes;
  final Duration delay;
  final bool stalled;
  int requests = 0, active = 0, peak = 0;
  final ranges = <String>[];
  static Future<Origin> start(
    Uint8List bytes, {
    Duration delay = Duration.zero,
    bool stalled = false,
  }) async {
    final origin = Origin(
      await HttpServer.bind('127.0.0.1', 0),
      bytes,
      delay,
      stalled,
    );
    origin.server.listen((req) async {
      origin.requests++;
      final raw = req.headers.value('range')!;
      origin.ranges.add(raw);
      origin.active++;
      origin.peak = max(origin.peak, origin.active);
      try {
        if (stalled && origin.requests == 1) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(raw)!;
        final start = int.parse(m[1]!);
        final end = (m[2]!.isEmpty
            ? bytes.length - 1
            : min(int.parse(m[2]!), bytes.length - 1));
        if (start > 0 && end - start > 4096) await Future<void>.delayed(delay);
        req.response.statusCode = 206;
        req.response.headers.set(
          'content-range',
          'bytes $start-$end/${bytes.length}',
        );
        req.response.headers.set('etag', '"stable"');
        req.response.contentLength = end - start + 1;
        if (start == 0 && delay > Duration.zero && end > 65536) {
          for (var offset = 0; offset <= end; offset += 65536) {
            req.response.add(
              bytes.sublist(offset, min(end + 1, offset + 65536)),
            );
            await req.response.flush();
            await Future<void>.delayed(delay);
          }
        } else {
          req.response.add(bytes.sublist(start, end + 1));
        }
        await req.response.close();
      } catch (_) {
      } finally {
        origin.active--;
      }
    });
    return origin;
  }

  Uri get uri =>
      Uri.parse('http://127.0.0.1:${server.port}/upgcxcode/test/video.m4s');
  Future<void> close() => server.close(force: true);
}

Future<Uint8List> fetch(String url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    check(res.statusCode == 200, 'bad proxy status');
    final builder = BytesBuilder();
    await for (final bytes in res) {
      builder.add(bytes);
    }
    return builder.takeBytes();
  } finally {
    client.close(force: true);
  }
}

Future<void> scenario({
  bool stalled = false,
  bool adaptive = true,
  bool parallel = true,
  int size = 6 * 1024 * 1024,
  Duration delay = Duration.zero,
}) async {
  final bytes = Uint8List.fromList(List.generate(size, (i) => (i * 13) % 251));
  final first = await Origin.start(bytes, stalled: stalled, delay: delay);
  final second = await Origin.start(bytes);
  final proxy = await CdnPlaybackProxy.start(
    autoSelect: true,
    adaptive: adaptive,
    parallel: parallel,
    concurrency: 8,
    allowOrigin: (u) => u.host == '127.0.0.1',
    originResolver: (_) => [CdnOrigin(first.uri), CdnOrigin(second.uri)],
  );
  final watch = Stopwatch()..start();
  try {
    final result = await fetch(proxy.register(first.uri.toString()))
        .timeout(const Duration(seconds: 15));
    check(result.length == bytes.length, 'truncated body');
    for (var i = 0; i < bytes.length; i++) {
      check(result[i] == bytes[i], 'corruption at $i');
    }
    if (stalled) {
      check(
        watch.elapsedMilliseconds < 1900,
        'healthy backup blocked by slow first origin',
      );
      check(second.requests > 0, 'backup unused');
    } else if (delay == Duration.zero) {
      check(second.requests == 0, 'healthy source triggered unnecessary hedge');
      check(first.peak == 1, 'healthy source needlessly increased concurrency');
    } else if (parallel) {
      check(
        first.peak > 1 && first.peak <= 8,
        'adaptive window never grew or exceeded bound',
      );
    } else {
      check(first.peak == 1, 'auto-only started parallel data');
    }
    if (!stalled && delay == Duration.zero) {
      check(
        first.requests == 1,
        'healthy stream was split into repeated requests',
      );
    }
  } finally {
    await proxy.close();
    await first.close();
    await second.close();
  }
}

Future<void> raceLoserRecovery() async {
  final bytes = Uint8List.fromList(List.generate(1024 * 1024, (i) => i % 251));
  final fallback = await Origin.start(bytes, stalled: true);
  final quickPrefix = await Origin.start(
    bytes,
    delay: const Duration(seconds: 4),
  );
  final proxy = await CdnPlaybackProxy.start(
    autoSelect: true,
    adaptive: true,
    concurrency: 8,
    allowOrigin: (u) => u.host == '127.0.0.1',
    originResolver: (_) => [
      CdnOrigin(fallback.uri),
      CdnOrigin(quickPrefix.uri),
    ],
  );
  try {
    final result = await fetch(proxy.register(fallback.uri.toString()))
        .timeout(const Duration(seconds: 12));
    check(
      result.length == bytes.length,
      'race loser was incorrectly excluded from failover',
    );
    for (var i = 0; i < bytes.length; i++) {
      check(result[i] == bytes[i], 'recovery byte mismatch');
    }
    check(
      fallback.requests > 1,
      'fallback was not retried after race cancellation',
    );
  } finally {
    await proxy.close();
    await fallback.close();
    await quickPrefix.close();
  }
}

Future<void> main() async {
  final tests = <String, Future<void> Function()>{
    'healthy stream keeps one connection and reuses initial data': scenario,
    'race cancellation does not blacklist a healthy fallback':
        raceLoserRecovery,
    'slow first candidate cannot block a healthy backup': () =>
        scenario(stalled: true),
    'auto-only stays sequential': () => scenario(
      parallel: false,
      size: 1024 * 1024,
      delay: const Duration(milliseconds: 180),
    ),
    'adaptive expands on slow range supply': () =>
        scenario(delay: const Duration(milliseconds: 180)),
    'small media accepts server-clamped initial range': () =>
        scenario(size: 1024),
  };
  var passed = 0;
  for (final test in tests.entries) {
    try {
      await test.value();
      passed++;
      stdout.writeln('PASS ${test.key}');
    } catch (e, s) {
      stderr.writeln('FAIL ${test.key}: $e\n$s');
    }
  }
  stdout.writeln('$passed/${tests.length} checks passed.');
  if (passed != tests.length) exitCode = 1;
}

// Deterministic transport checks: no public network or accounts.
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

Future<void> queuedRangesAreNotOriginTimeouts() async {
  // Each independent Range is a valid two-second request, comfortably inside
  // the three-second origin idle bound. Eight speculative pieces share seven
  // normal slots, so the last piece waits locally before doing any network I/O.
  // Timing that wait as origin silence truncated the old response at ~11 MiB.
  final bytes = Uint8List.fromList(
    List.generate(16 * 1024 * 1024 + 127, (i) => (i * 17) % 251),
  );
  final origin = await Origin.start(
    bytes,
    delay: const Duration(seconds: 2),
  );
  final proxy = await CdnPlaybackProxy.start(
    autoSelect: true,
    adaptive: true,
    concurrency: 8,
    // A deliberately high media demand exercises every bounded adaptive level.
    // This is a scheduling stress fixture, not a real-video bitrate claim.
    durationSeconds: 1,
    allowOrigin: (u) => u.host == '127.0.0.1',
    originResolver: (_) => [CdnOrigin(origin.uri)],
  );
  try {
    final result = await fetch(proxy.register(origin.uri.toString()))
        .timeout(const Duration(seconds: 40));
    check(result.length == bytes.length, 'queued Range response was truncated');
    for (var i = 0; i < bytes.length; i++) {
      check(result[i] == bytes[i], 'queued Range corrupted byte $i');
    }
    check(origin.peak >= 7, 'fixture did not fill the normal request slots');
    check(origin.peak <= 8, 'fixture exceeded the shared connection bound');
    check(
      (proxy.diagnostics['failures'] as List).isEmpty,
      'local queue delay was recorded as an origin failure',
    );
  } finally {
    await proxy.close();
    await origin.close();
  }
}

Future<void> actualOriginSilenceStillTimesOut() async {
  final bytes = Uint8List(1024 * 1024);
  final origin = await Origin.start(
    bytes,
    delay: const Duration(seconds: 4),
  );
  final proxy = await CdnPlaybackProxy.start(
    autoSelect: true,
    adaptive: true,
    concurrency: 8,
    allowOrigin: (u) => u.host == '127.0.0.1',
    originResolver: (_) => [CdnOrigin(origin.uri)],
  );
  var rejected = false;
  try {
    try {
      await fetch(proxy.register(origin.uri.toString()))
          .timeout(const Duration(seconds: 12));
    } on HttpException {
      rejected = true;
    }
    check(rejected, 'a genuinely silent origin escaped its idle deadline');
    check(
      (proxy.diagnostics['failures'] as List).any(
        (failure) => failure['phase'] == 'chunk_or_admission',
      ),
      'genuine origin silence was not classified as a transfer failure',
    );
  } finally {
    await proxy.close();
    await origin.close();
  }
}

class SupplyOrigin {
  SupplyOrigin(
    this.server,
    this.bytes, {
    required this.slow,
    required this.burst,
    required this.transition,
    required this.corrupt,
    required this.blockSize,
    required this.slowLarge,
    required this.headerDelay,
    this.continuousBytesPerSecond,
  });
  final HttpServer server;
  final Uint8List bytes;
  final bool slow, burst, transition, corrupt, slowLarge;
  final int blockSize;
  final Duration headerDelay;
  final int? continuousBytesPerSecond;
  bool closed = false, heldLarge = false;
  final largeStarted = Completer<void>();
  final ranges = <(int, int)>[];
  final metadata = <String>[];
  Uri get uri =>
      Uri.parse('http://127.0.0.1:${server.port}/upgcxcode/test/video.m4s');
  static Future<SupplyOrigin> start(
    Uint8List bytes, {
    bool slow = false,
    bool burst = false,
    bool transition = false,
    bool corrupt = false,
    int blockSize = 16384,
    bool slowLarge = false,
    Duration headerDelay = const Duration(milliseconds: 350),
    int? continuousBytesPerSecond,
  }) async {
    final origin = SupplyOrigin(
      await HttpServer.bind('127.0.0.1', 0),
      bytes,
      slow: slow,
      burst: burst,
      transition: transition,
      corrupt: corrupt,
      blockSize: blockSize,
      slowLarge: slowLarge,
      headerDelay: headerDelay,
      continuousBytesPerSecond: continuousBytesPerSecond,
    );
    origin.server.listen((req) async {
      final raw = req.headers.value('range') ?? 'bytes=0-';
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(raw);
      final suffix = RegExp(r'^bytes=-(\d+)$').firstMatch(raw);
      final start = suffix == null
          ? int.parse(m![1]!)
          : max(0, bytes.length - int.parse(suffix[1]!));
      final end = suffix != null || m![2]!.isEmpty
          ? bytes.length - 1
          : min(bytes.length - 1, int.parse(m[2]!));
      final length = end - start + 1;
      final open = suffix == null && m![2]!.isEmpty;
      final index = origin.ranges.length;
      origin.ranges.add((start, length));
      final version = transition && index > 0 ? 'new' : 'old';
      origin.metadata.add(version);
      req.response.statusCode = 206;
      req.response.contentLength = length;
      req.response.headers.set(
        'content-range',
        'bytes $start-$end/${bytes.length}',
      );
      req.response.headers.set('etag', '"$version"');
      req.response.headers.set(
        'last-modified',
        version == 'old'
            ? 'Mon, 28 Sep 2026 00:00:00 GMT'
            : 'Tue, 29 Sep 2026 00:00:00 GMT',
      );
      try {
        if (!slow) {
          await Future<void>.delayed(headerDelay);
        }
        if (slowLarge && !open && length >= 512 * 1024 && !origin.heldLarge) {
          origin.heldLarge = true;
          if (!origin.largeStarted.isCompleted) origin.largeStarted.complete();
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        for (var offset = start; offset <= end && !origin.closed;) {
          final initialBurst = burst && open && offset - start < 256 * 1024;
          final step = min(
            slow && !initialBurst ? blockSize : 65536,
            end - offset + 1,
          );
          final data = Uint8List.fromList(bytes.sublist(offset, offset + step));
          if (corrupt &&
              offset <= bytes.length ~/ 2 &&
              offset + step > bytes.length ~/ 2) {
            data[bytes.length ~/ 2 - offset] ^= 1;
          }
          req.response.add(data);
          await req.response.flush();
          offset += step;
          final delay = open && continuousBytesPerSecond != null
              ? (step * 1000 / continuousBytesPerSecond).round()
              : initialBurst
              ? 0
              : slow
              ? 250 * blockSize ~/ 16384
              : 16;
          await Future<void>.delayed(Duration(milliseconds: delay));
        }
        await req.response.close();
      } catch (_) {}
    });
    return origin;
  }

  Future<void> close() async {
    closed = true;
    await server.close(force: true);
  }
}

Future<Map<String, Object>> observeSupply(
  String url,
  Uint8List expected, {
  Duration? pause,
}) async {
  final client = HttpClient();
  final watch = Stopwatch()..start();
  var count = 0;
  var last = 0.0;
  var gap = 0.0;
  var paused = false;
  final metrics = <String, Object>{};
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close();
    await for (final data in response.timeout(const Duration(seconds: 30))) {
      final now = watch.elapsedMicroseconds / 1e6;
      gap = max(gap, now - last);
      last = now;
      check(count + data.length <= expected.length, 'excess supply bytes');
      for (var i = 0; i < data.length; i++) {
        check(
          data[i] == expected[count + i],
          'supply byte changed at ${count + i}',
        );
      }
      count += data.length;
      if (count >= 1024 * 1024) {
        metrics.putIfAbsent('first_1mib_seconds', () => now);
      }
      if (count >= 8 * 1024 * 1024) {
        metrics.putIfAbsent('first_8mib_seconds', () => now);
      }
      if (pause != null && !paused && count >= 65536) {
        paused = true;
        await Future<void>.delayed(pause);
      }
    }
    check(count == expected.length, 'supply response truncated');
    return metrics..addAll({
      'bytes': count,
      'elapsed_seconds': watch.elapsedMicroseconds / 1e6,
      'max_gap_seconds': gap,
    });
  } finally {
    client.close(force: true);
  }
}

Future<void> sustainedSupply({
  bool burst = false,
  int blockSize = 16384,
  bool transition = false,
  bool corrupt = false,
  bool hedge = false,
}) async {
  final bytes = Uint8List.fromList(
    List.generate(
      (corrupt ? 512 * 1024 : 8 * 1024 * 1024) + 127,
      (i) => (i * 17) % 251,
    ),
  );
  final slow = await SupplyOrigin.start(
    bytes,
    slow: true,
    burst: burst,
    blockSize: blockSize,
  );
  final fast = await SupplyOrigin.start(
    bytes,
    transition: transition,
    corrupt: corrupt,
    slowLarge: hedge,
  );
  final second = hedge ? await SupplyOrigin.start(bytes) : null;
  final proxy = await CdnPlaybackProxy.start(
    autoSelect: true,
    adaptive: true,
    concurrency: 8,
    durationSeconds: 12,
    allowOrigin: (u) => u.host == '127.0.0.1',
    originResolver: (_) => [
      CdnOrigin(slow.uri),
      CdnOrigin(fast.uri),
      if (second != null) CdnOrigin(second.uri),
    ],
  );
  try {
    final metrics = await observeSupply(
      proxy.register(slow.uri.toString()),
      bytes,
    );
    if (!corrupt) {
      check(
        (metrics['first_1mib_seconds'] as double) < 8,
        'backup entered too late',
      );
      check(
        (metrics['max_gap_seconds'] as double) < 3,
        'ordered supply waited for a large slow block',
      );
      check(
        fast.ranges.any((r) => r.$2 > 4096),
        'validated backup served no media',
      );
    } else {
      check(
        fast.ranges.every((r) => r.$2 <= 4096),
        'changed payload was admitted',
      );
    }
    if (transition) {
      check(
        fast.metadata.take(4).join(',') == 'old,new,new,new',
        'metadata transition did not retry a complete strict sample pair',
      );
    }
    if (hedge) {
      check(fast.heldLarge, 'fixture never blocked the current ordered block');
      check(
        second!.ranges.any((r) => r.$2 >= 512 * 1024),
        'verified hedge did not serve a large block',
      );
      check(
        (proxy.diagnostics['peak_hedge_buffered_payload_bytes'] as int) > 0,
        'hedge payload was not accounted for',
      );
    }
    await proxy.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    check(
      proxy.diagnostics['buffered_payload_bytes'] == 0,
      'payload reservation leaked',
    );
    check(
      proxy.diagnostics['hedge_buffered_payload_bytes'] == 0,
      'hedge reservation leaked',
    );
    check(
      (proxy.diagnostics['peak_buffered_payload_bytes'] as int) <=
          64 * 1024 * 1024,
      'hedged payload exceeded the shared memory bound',
    );
    check(
      (proxy.diagnostics['failures'] as List).isEmpty,
      'cancelled hedge loser was marked unavailable',
    );
    stdout.writeln(
      'METRIC ${jsonEncode({'burst': burst, 'block_size': blockSize, 'transition': transition, 'corrupt': corrupt, 'hedge': hedge, 'supply': metrics, 'slow_requests': slow.ranges.length, 'backup_requests': fast.ranges.length, 'second_requests': second?.ranges.length})}',
    );
  } finally {
    await proxy.close();
    await slow.close();
    await fast.close();
    await second?.close();
  }
}

Future<void> healthyConsumerPause() async {
  final bytes = Uint8List.fromList(
    List.generate(12 * 1024 * 1024 + 127, (i) => (i * 17) % 251),
  );
  final origin = await SupplyOrigin.start(bytes);
  final proxy = await CdnPlaybackProxy.start(
    autoSelect: true,
    adaptive: true,
    concurrency: 8,
    durationSeconds: 18,
    allowOrigin: (u) => u.host == '127.0.0.1',
    originResolver: (_) => [CdnOrigin(origin.uri)],
  );
  try {
    final metrics = await observeSupply(
      proxy.register(origin.uri.toString()),
      bytes,
      pause: const Duration(seconds: 5),
    );
    check(
      origin.ranges.length == 1,
      'consumer pause caused healthy stream to split',
    );
    check(
      (proxy.diagnostics['failures'] as List).isEmpty,
      'consumer pause marked origin failed',
    );
    stdout.writeln(
      'METRIC ${jsonEncode({'pause_seconds': 5, 'supply': metrics, 'requests': origin.ranges.length})}',
    );
  } finally {
    await proxy.close();
    await origin.close();
  }
}

Future<void> cancellationDuringHedge() async {
  final bytes = Uint8List.fromList(
    List.generate(8 * 1024 * 1024 + 127, (i) => (i * 17) % 251),
  );
  final slow = await SupplyOrigin.start(bytes, slow: true);
  final first = await SupplyOrigin.start(bytes, slowLarge: true);
  final second = await SupplyOrigin.start(bytes, slowLarge: true);
  final proxy = await CdnPlaybackProxy.start(
    autoSelect: true,
    adaptive: true,
    concurrency: 8,
    durationSeconds: 12,
    allowOrigin: (u) => u.host == '127.0.0.1',
    originResolver: (_) => [
      CdnOrigin(slow.uri),
      CdnOrigin(first.uri),
      CdnOrigin(second.uri),
    ],
  );
  try {
    final fetchResult = observeSupply(
      proxy.register(slow.uri.toString()),
      bytes,
    ).then((_) => false, onError: (Object _) => true);
    await first.largeStarted.future.timeout(const Duration(seconds: 12));
    await second.largeStarted.future.timeout(const Duration(seconds: 12));
    await proxy.close();
    check(
      await fetchResult,
      'closing the active session did not abort its body',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    check(
      proxy.diagnostics['buffered_payload_bytes'] == 0,
      'cancelled primary retained its payload reservation',
    );
    check(
      proxy.diagnostics['hedge_buffered_payload_bytes'] == 0,
      'cancelled hedge retained its payload reservation',
    );
    check(
      proxy.diagnostics['active_origin_requests'] == 0,
      'cancelled hedge retained an origin slot',
    );
    check(
      (proxy.diagnostics['failures'] as List).isEmpty,
      'session cancellation was recorded as a CDN failure',
    );
    check(
      (proxy.diagnostics['peak_hedge_buffered_payload_bytes'] as int) > 0,
      'fixture did not reserve a hedge payload',
    );
  } finally {
    await proxy.close();
    await slow.close();
    await first.close();
    await second.close();
  }
}

Future<void> qualifiedVideoSelection({
  bool slowPrefix = false,
  bool fastForeign = false,
  bool baselineLowSupply = false,
}) async {
  final bytes = Uint8List.fromList(
    List.generate(8 * 1024 * 1024 + 127, (i) => (i * 17) % 251),
  );
  final baseline = await SupplyOrigin.start(
    bytes,
    slow: baselineLowSupply,
    burst: baselineLowSupply,
    headerDelay: fastForeign
        ? const Duration(seconds: 2)
        : slowPrefix
        ? const Duration(milliseconds: 700)
        : Duration.zero,
  );
  final foreign = await SupplyOrigin.start(
    bytes,
    slow: slowPrefix,
    burst: slowPrefix,
  );
  final proxy = await CdnPlaybackProxy.start(
    autoSelect: true,
    adaptive: true,
    concurrency: 8,
    durationSeconds: 24,
    allowOrigin: (u) => u.host == '127.0.0.1',
    isBaselineOrigin: (u) => u.port == baseline.server.port,
    // Resolver's first entry deliberately disagrees with baseline order.
    originResolver: (_) => [CdnOrigin(foreign.uri), CdnOrigin(baseline.uri)],
  );
  try {
    final metrics = await observeSupply(
      proxy.register(foreign.uri.toString(), track: CdnStartupTrack.video),
      bytes,
    );
    check(
      (metrics['first_1mib_seconds'] as double) < 6,
      'video chose cached prefix without sustained supply',
    );
    if (!fastForeign && !baselineLowSupply) {
      check(
        baseline.ranges.length == 1,
        'healthy baseline was split or needlessly qualified',
      );
      check(
        foreign.ranges.every((r) => r.$2 <= 256 * 1024),
        'unqualified foreign won over healthy baseline',
      );
      if (!slowPrefix) {
        check(
          foreign.ranges.isEmpty,
          'ready baseline triggered needless qualification',
        );
      }
    }
    if (fastForeign) {
      check(
        foreign.ranges.any((r) => r.$2 == bytes.length),
        'qualified foreign could not win over delayed baseline',
      );
      check(
        foreign.ranges.length == 3,
        'qualified healthy foreign did not keep one original body',
      );
    }
    if (baselineLowSupply) {
      check(
        foreign.ranges.any((r) => r.$2 > 4096),
        'low sustained baseline supply never recovered',
      );
    }
    await proxy.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    check(
      proxy.diagnostics['buffered_payload_bytes'] == 0,
      'qualification reservation leaked',
    );
    check(
      proxy.diagnostics['active_origin_requests'] == 0,
      'winning baseline did not cancel losing qualification',
    );
    check(
      (proxy.diagnostics['failures'] as List).isEmpty,
      'cancelled qualification was treated as origin failure',
    );
    stdout.writeln(
      'METRIC ${jsonEncode({
        'p3_video': true,
        'slow_prefix': slowPrefix,
        'fast_foreign': fastForeign,
        'baseline_low': baselineLowSupply,
        'supply': metrics,
        'baseline_ranges': baseline.ranges.map((r) => [r.$1, r.$2]).toList(),
        'foreign_ranges': foreign.ranges.map((r) => [r.$1, r.$2]).toList(),
        'diagnostics': proxy.diagnostics,
      })}',
    );
  } finally {
    await proxy.close();
    await baseline.close();
    await foreign.close();
  }
}

Future<void> qualifiedSeekUsesCurrentRange() async {
  final bytes = Uint8List.fromList(
    List.generate(8 * 1024 * 1024 + 127, (i) => (i * 17) % 251),
  );
  final first = await SupplyOrigin.start(bytes, headerDelay: Duration.zero);
  final second = await SupplyOrigin.start(bytes);
  final proxy = await CdnPlaybackProxy.start(
    autoSelect: true,
    adaptive: true,
    concurrency: 1,
    durationSeconds: 24,
    allowOrigin: (u) => u.host == '127.0.0.1',
    originResolver: (_) => [CdnOrigin(first.uri), CdnOrigin(second.uri)],
  );
  final client = HttpClient();
  const start = 6 * 1024 * 1024;
  const length = 1024 * 1024;
  try {
    final req = await client.getUrl(
      Uri.parse(
        proxy.register(first.uri.toString(), track: CdnStartupTrack.video),
      ),
    );
    req.headers.set('range', 'bytes=$start-${start + length - 1}');
    final response = await req.close().timeout(const Duration(seconds: 3));
    final result = await response.fold<BytesBuilder>(
      BytesBuilder(),
      (b, d) => b..add(d),
    );
    check(response.statusCode == 206, 'seek response was not partial');
    final actual = result.takeBytes();
    check(actual.length == length, 'qualified seek truncated');
    for (var i = 0; i < actual.length; i++) {
      check(
        actual[i] == bytes[start + i],
        'seek scratch bytes leaked into body',
      );
    }
    check(
      first.ranges.length == 3,
      'one-slot qualification deadlocked or split',
    );
    final sample = first.ranges[1];
    check(
      sample.$1 >= start && sample.$1 + sample.$2 <= start + length,
      'seek qualified unrelated fixed object midpoint',
    );
    check(
      first.ranges.last == (start, length),
      'seek did not use an independent unchanged original Range',
    );
  } finally {
    client.close(force: true);
    await proxy.close();
    await first.close();
    await second.close();
  }
}

Future<void> weakVideoFallbackKeepsOriginalBody() async {
  final bytes = Uint8List.fromList(
    List.generate(2 * 1024 * 1024 + 127, (i) => (i * 17) % 251),
  );
  final origin = await SupplyOrigin.start(
    bytes,
    transition: true,
    headerDelay: Duration.zero,
  );
  final alternate = await Origin.start(
    bytes,
    stalled: true,
    delay: const Duration(seconds: 4),
  );
  final proxy = await CdnPlaybackProxy.start(
    autoSelect: true,
    adaptive: true,
    concurrency: 8,
    durationSeconds: 12,
    allowOrigin: (u) => u.host == '127.0.0.1',
    originResolver: (_) => [CdnOrigin(origin.uri), CdnOrigin(alternate.uri)],
  );
  try {
    final metrics = await observeSupply(
      proxy.register(origin.uri.toString(), track: CdnStartupTrack.video),
      bytes,
    );
    check(
      (metrics['first_1mib_seconds'] as double) >= 2.5 &&
          (metrics['first_1mib_seconds'] as double) < 5,
      'weak-source fallback was unbounded or raced qualified candidates',
    );
    check(
      origin.ranges.last == (0, bytes.length),
      'weak-source fallback did not use its own original body',
    );
    check(
      origin.ranges.length == 3,
      'independent weak-source body was needlessly split',
    );
    check(
      origin.metadata.join(',') == 'old,new,new',
      'fixture did not fail its strict qualification metadata pair',
    );
    stdout.writeln(
      'METRIC ${jsonEncode({'weak_qualification_fallback': metrics, 'requests': origin.ranges.length})}',
    );
  } finally {
    await proxy.close();
    await origin.close();
    await alternate.close();
  }
}

Future<void> knownSlowRanksBehindUnmeasurable() async {
  final bytes = Uint8List.fromList(
    List.generate(2 * 1024 * 1024 + 127, (i) => (i * 17) % 251),
  );
  final slow = await SupplyOrigin.start(bytes, slow: true, burst: true);
  final healthy = await SupplyOrigin.start(
    bytes,
    transition: true,
    headerDelay: Duration.zero,
  );
  final proxy = await CdnPlaybackProxy.start(
    autoSelect: true,
    adaptive: true,
    concurrency: 8,
    durationSeconds: 12,
    allowOrigin: (u) => u.host == '127.0.0.1',
    originResolver: (_) => [CdnOrigin(slow.uri), CdnOrigin(healthy.uri)],
  );
  try {
    final metrics = await observeSupply(
      proxy.register(slow.uri.toString(), track: CdnStartupTrack.video),
      bytes,
    );
    check(
      (metrics['first_1mib_seconds'] as double) < 4,
      'known inadequate supply outranked metadata-only uncertainty',
    );
    check(
      healthy.ranges.length == 3 && healthy.ranges.last == (0, bytes.length),
      'healthy uncertain source did not retain independent original body',
    );
    check(
      slow.ranges.every((r) => r.$2 <= 256 * 1024),
      'known slow cached prefix won again at weak fallback',
    );
    check(
      (proxy.diagnostics['range_failures'] as List).isNotEmpty,
      'strict metadata guard was bypassed to select weak source',
    );
    stdout.writeln(
      'METRIC ${jsonEncode({'known_slow_vs_metadata': metrics, 'slow_requests': slow.ranges.length, 'healthy_requests': healthy.ranges.length})}',
    );
  } finally {
    await proxy.close();
    await slow.close();
    await healthy.close();
  }
}

Future<void> qualifiedSteadySupplyKeepsOriginalBody() async {
  final bytes = Uint8List.fromList(
    List.generate(8 * 1024 * 1024 + 127, (i) => (i * 17) % 251),
  );
  final baseline = await SupplyOrigin.start(
    bytes,
    headerDelay: const Duration(milliseconds: 2600),
  );
  // Small middle samples are 4MiB/s, original response supplies 600KiB/s.
  // Average media demand is ~342KiB/s. This is adequate original-response
  // supply; it must not be split merely because it no longer meets probe score.
  final foreign = await SupplyOrigin.start(
    bytes,
    continuousBytesPerSecond: 600 * 1024,
  );
  final proxy = await CdnPlaybackProxy.start(
    autoSelect: true,
    adaptive: true,
    concurrency: 8,
    durationSeconds: 24,
    allowOrigin: (u) => u.host == '127.0.0.1',
    isBaselineOrigin: (u) => u.port == baseline.server.port,
    originResolver: (_) => [CdnOrigin(baseline.uri), CdnOrigin(foreign.uri)],
  );
  try {
    final metrics = await observeSupply(
      proxy.register(foreign.uri.toString(), track: CdnStartupTrack.video),
      bytes,
    );
    stdout.writeln(
      'METRIC ${jsonEncode({'qualified_steady_supply': metrics, 'foreign_requests': foreign.ranges.length, 'baseline_requests': baseline.ranges.length, 'diagnostics': proxy.diagnostics})}',
    );
    check(
      foreign.ranges.length == 3,
      'adequate original-body supply was judged by qualification threshold',
    );
    check(
      baseline.ranges.length == 1,
      'adequate original-body supply triggered peer sampling',
    );
    check(
      (proxy.diagnostics['failures'] as List).isEmpty,
      'adequate original response recorded a false origin failure',
    );
  } finally {
    await proxy.close();
    await baseline.close();
    await foreign.close();
  }
}

Future<void> smallVideoRange({required String kind}) async {
  final bytes = Uint8List.fromList(
    List.generate(2 * 1024 * 1024 + 127, (i) => (i * 17) % 251),
  );
  final first = await SupplyOrigin.start(bytes, headerDelay: Duration.zero);
  final second = await SupplyOrigin.start(bytes);
  final proxy = await CdnPlaybackProxy.start(
    autoSelect: true,
    adaptive: true,
    concurrency: 1,
    durationSeconds: 12,
    allowOrigin: (u) => u.host == '127.0.0.1',
    originResolver: (_) => [CdnOrigin(first.uri), CdnOrigin(second.uri)],
  );
  final client = HttpClient();
  final watch = Stopwatch()..start();
  final size = kind == 'suffix' ? 100 : 8192;
  final start = kind == 'metadata' ? 0 : bytes.length - size;
  final raw = switch (kind) {
    'metadata' => 'bytes=0-8191',
    'suffix' => 'bytes=-100',
    _ => 'bytes=$start-',
  };
  try {
    final request = await client.getUrl(
      Uri.parse(
        proxy.register(first.uri.toString(), track: CdnStartupTrack.video),
      ),
    );
    request.headers.set('range', raw);
    final response = await request.close().timeout(const Duration(seconds: 2));
    final result = await response.fold<BytesBuilder>(
      BytesBuilder(),
      (b, d) => b..add(d),
    );
    final actual = result.takeBytes();
    check(
      response.statusCode == 206 && actual.length == size,
      'small video Range lost its native HTTP shape',
    );
    for (var i = 0; i < actual.length; i++) {
      check(actual[i] == bytes[start + i], 'small Range byte mismatch');
    }
    check(
      watch.elapsedMilliseconds < 1000,
      'small video Range waited for a throughput qualification gate',
    );
    check(
      first.ranges.length == (kind == 'tail' ? 2 : 1),
      'small Range fetched unnecessary sustained supply samples',
    );
    check(
      first.ranges.last == (start, size),
      'small Range was replaced by probe bytes',
    );
    stdout.writeln(
      'METRIC ${jsonEncode({'small_range': kind, 'elapsed_seconds': watch.elapsedMicroseconds / 1e6, 'requests': first.ranges.length, 'bytes': size})}',
    );
  } finally {
    client.close(force: true);
    await proxy.close();
    await first.close();
    await second.close();
  }
}

Future<void> longConsumerPause({bool cancel = false}) async {
  final bytes = Uint8List.fromList(
    List.generate(16 * 1024 * 1024 + 127, (i) => (i * 17) % 251),
  );
  final origin = await Origin.start(bytes);
  final proxy = await CdnPlaybackProxy.start(
    autoSelect: true,
    adaptive: true,
    concurrency: 8,
    timeout: const Duration(milliseconds: 500),
    durationSeconds: 24,
    allowOrigin: (u) => u.host == '127.0.0.1',
    originResolver: (_) => [CdnOrigin(origin.uri)],
  );
  final client = HttpClient();
  try {
    if (!cancel) {
      final metrics = await observeSupply(
        proxy.register(origin.uri.toString(), track: CdnStartupTrack.video),
        bytes,
        pause: const Duration(seconds: 2),
      );
      check(origin.requests == 1, 'long player pause split/truncated origin');
      stdout.writeln(
        'METRIC ${jsonEncode({'long_consumer_pause': metrics, 'timeout_milliseconds': 500, 'pause_milliseconds': 2000, 'requests': origin.requests})}',
      );
    } else {
      final response = await (await client.getUrl(
        Uri.parse(
          proxy.register(origin.uri.toString(), track: CdnStartupTrack.video),
        ),
      )).close();
      final body = StreamIterator(response);
      check(await body.moveNext(), 'missing initial body');
      // Enough payload to fill local socket buffers; leave consumer paused.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      check(
        proxy.diagnostics['active_origin_requests'] == 1,
        'fixture did not keep the backpressured origin alive',
      );
      final watch = Stopwatch()..start();
      await proxy.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      check(
        watch.elapsedMilliseconds < 500,
        'blocked downstream did not cancel promptly',
      );
      check(
        proxy.diagnostics['active_origin_requests'] == 0,
        'blocked downstream retained a slot after cancellation',
      );
      await body.cancel();
    }
    check(
      (proxy.diagnostics['failures'] as List).isEmpty,
      'player backpressure/cancellation was recorded as CDN silence',
    );
  } finally {
    client.close(force: true);
    await proxy.close();
    await origin.close();
  }
}

Future<void> main(List<String> args) async {
  final tests = <String, Future<void> Function()>{
    'healthy Huawei baseline starts without qualification or duplicate body':
        qualifiedVideoSelection,
    'cached foreign prefix cannot win without sustained current-object supply':
        () => qualifiedVideoSelection(slowPrefix: true),
    'qualified fast foreign wins over delayed Huawei': () =>
        qualifiedVideoSelection(fastForeign: true),
    'a fast Huawei prefix still recovers from sustained low supply': () =>
        qualifiedVideoSelection(baselineLowSupply: true),
    'nonzero seek qualifies its current Range without one-slot deadlock':
        qualifiedSeekUsesCurrentRange,
    'weak qualification uses a bounded independent original-body fallback':
        weakVideoFallbackKeepsOriginalBody,
    'known inadequate supply ranks behind metadata-only uncertainty':
        knownSlowRanksBehindUnmeasurable,
    'qualified adequate steady supply keeps its original body':
        qualifiedSteadySupplyKeepsOriginalBody,
    '8KiB video metadata Range skips sustained supply qualification': () =>
        smallVideoRange(kind: 'metadata'),
    '100-byte video suffix Range skips sustained supply qualification': () =>
        smallVideoRange(kind: 'suffix'),
    'initial open-ended near-tail seek skips throughput ranking': () =>
        smallVideoRange(kind: 'tail'),
    'consumer pause beyond upstream timeout preserves whole body':
        longConsumerPause,
    'closing a backpressured consumer releases its stream promptly': () =>
        longConsumerPause(cancel: true),
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
    'locally queued ranges preserve the full body and do not blacklist an origin':
        queuedRangesAreNotOriginTimeouts,
    'a granted but silent origin still obeys its idle deadline':
        actualOriginSilenceStillTimesOut,
    'fast first packet cannot monopolize sustained supply': sustainedSupply,
    'a fast initial burst cannot monopolize sustained supply': () =>
        sustainedSupply(burst: true),
    '4 KiB TCP fragments still detect sustained low supply': () =>
        sustainedSupply(blockSize: 4096),
    'a paused healthy consumer keeps one continuous origin response':
        healthyConsumerPause,
    'transient peer metadata requires a new complete matching sample pair':
        () => sustainedSupply(transition: true),
    'changed peer bytes are still rejected after metadata retry': () =>
        sustainedSupply(transition: true, corrupt: true),
    'a blocked ordered piece permits only a verified bounded hedge': () =>
        sustainedSupply(hedge: true),
    'session cancellation releases hedged payloads and origin slots':
        cancellationDuringHedge,
  };
  final selected = tests.entries
      .where(
        (test) =>
            args.isEmpty || args.any((filter) => test.key.contains(filter)),
      )
      .toList();
  var passed = 0;
  for (final test in selected) {
    try {
      await test.value();
      passed++;
      stdout.writeln('PASS ${test.key}');
    } catch (e, s) {
      stderr.writeln('FAIL ${test.key}: $e\n$s');
    }
  }
  stdout.writeln('$passed/${selected.length} checks passed.');
  if (passed != selected.length || selected.isEmpty) exitCode = 1;
}

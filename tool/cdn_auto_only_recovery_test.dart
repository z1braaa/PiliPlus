// Deterministic recovery checks: loopback only, no public network or account.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Standalone Dart checks also run outside Flutter package resolution.
// ignore: avoid_relative_lib_imports
import '../lib/http/cdn_origin_policy.dart';
// ignore: avoid_relative_lib_imports
import '../lib/http/cdn_playback_proxy.dart';
// ignore: avoid_relative_lib_imports
import '../lib/utils/cdn_startup_trace.dart';
import 'cdn_measured_test.dart' as fixture;

bool sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

Future<void> run(
  String name, {
  required bool slow,
  required bool mismatch,
}) async {
  final bytes = Uint8List.fromList(
    List.generate(4 * 1024 * 1024, (index) => index % 251),
  );
  final peerBytes = Uint8List.fromList(bytes);
  if (mismatch) peerBytes[0] ^= 255;
  final baseline = await fixture.Origin.start(
    bytes,
    delay: slow ? const Duration(milliseconds: 150) : Duration.zero,
  );
  final peer = await fixture.Origin.start(peerBytes);
  final proxy = await CdnPlaybackProxy.start(
    concurrency: 2,
    chunkSize: 512 * 1024,
    autoSelect: true,
    adaptive: true,
    parallel: false,
    durationSeconds: 5,
    enableDiagnostics: true,
    allowOrigin: (uri) => uri.host == '127.0.0.1',
    originResolver: (_) => [
      CdnOrigin(baseline.uri, mainland: true),
      CdnOrigin(peer.uri, mainland: true),
    ],
    isBaselineOrigin: (uri) => uri.port == baseline.server.port,
  );
  try {
    final url = proxy.register(
      baseline.uri.toString(),
      track: CdnStartupTrack.video,
    );
    final watch = Stopwatch()..start();
    final received = await fixture.fetch(url);
    fixture.check(
      sameBytes(received, bytes),
      'mismatched peer contributed bytes',
    );
    final events = proxy.diagnostics['request_events'] as List;
    if (slow) {
      fixture.check(
        events.any(
          (e) => e['event'] == 'stream_to_chunks' && e['kind'] == 'low_supply',
        ),
        'auto-only failed to detect low supply',
      );
      if (!mismatch) {
        fixture.check(
          watch.elapsedMilliseconds < 6000,
          'auto-only did not recover before complete slow stream',
        );
      }
    } else {
      fixture.check(
        !events.any((e) => e['event'] == 'stream_to_chunks'),
        'healthy auto-only stream split',
      );
      fixture.check(
        peer.requests == 0,
        'healthy source unnecessarily loaded peers',
      );
    }
    fixture.check(
      events
          .where((e) => e['event'] == 'window')
          .every((e) => e['window'] == 1),
      'auto-only forced concurrent chunk window',
    );
    fixture.check(
      proxy.diagnostics['peak_hedge_buffered_payload_bytes'] == 0,
      'auto-only launched duplicate body hedge',
    );
    if (mismatch) {
      fixture.check(
        events.any(
          (e) => e['event'] == 'origin_invalidated' && e['kind'] == 'identity',
        ),
        'inconsistent peer not rejected',
      );
      fixture.check(
        peer.ranges.every((range) => range == 'bytes=0-4095'),
        'inconsistent peer served unverified bulk range',
      );
    }
    stdout.writeln(
      jsonEncode({
        'case': name,
        'status': 'passed',
        'elapsed_ms': watch.elapsedMilliseconds,
      }),
    );
  } finally {
    await proxy.close();
    await baseline.close();
    await peer.close();
  }
}

Future<void> healthyLowBitrateAudio() async {
  final bytes = Uint8List.fromList(
    List.generate(512 * 1024, (index) => index % 251),
  );
  // 64KiB every 1.6s is approximately 40KiB/s: ample for this track's 17KiB/s
  // mean requirement, below the legacy audio supply threshold of 128KiB/s.
  final baseline = await fixture.Origin.start(
    bytes,
    delay: const Duration(milliseconds: 1600),
  );
  final peer = await fixture.Origin.start(bytes);
  final proxy = await CdnPlaybackProxy.start(
    concurrency: 2,
    chunkSize: 512 * 1024,
    autoSelect: true,
    adaptive: true,
    parallel: false,
    durationSeconds: 30,
    enableDiagnostics: true,
    allowOrigin: (uri) => uri.host == '127.0.0.1',
    originResolver: (_) => [
      CdnOrigin(baseline.uri, mainland: true),
      CdnOrigin(peer.uri, mainland: true),
    ],
    isBaselineOrigin: (uri) => uri.port == baseline.server.port,
  );
  try {
    final received = await fixture.fetch(
      proxy.register(baseline.uri.toString(), track: CdnStartupTrack.audio),
    );
    fixture.check(sameBytes(received, bytes), 'healthy audio content changed');
    final events = proxy.diagnostics['request_events'] as List;
    fixture.check(
      !events.any((e) => e['event'] == 'stream_to_chunks'),
      'healthy low bitrate audio spuriously split',
    );
    fixture.check(
      peer.requests == 0,
      'healthy low bitrate audio unnecessarily warmed peer',
    );
    fixture.check(
      proxy.diagnostics['peak_hedge_buffered_payload_bytes'] == 0,
      'auto-only audio launched hedge',
    );
    stdout.writeln(
      jsonEncode({
        'case': 'auto_only_healthy_40KiB_audio_keeps_stream',
        'status': 'passed',
      }),
    );
  } finally {
    await proxy.close();
    await baseline.close();
    await peer.close();
  }
}

Future<void> main() async {
  await run(
    'auto_only_fast_prefix_slow_body_recovers',
    slow: true,
    mismatch: false,
  );
  await run('auto_only_healthy_stream_not_split', slow: false, mismatch: false);
  await run('auto_only_mismatched_peer_rejected', slow: true, mismatch: true);
  await healthyLowBitrateAudio();
  stdout.writeln(jsonEncode({'passed': 4, 'total': 4}));
}

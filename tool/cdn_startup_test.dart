// Deterministic P0 startup checks: dart tool/cdn_startup_test.dart
// All media and origins live on loopback; no account or signed URL is needed.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// Keep this runnable before Flutter package resolution.
// ignore: avoid_relative_lib_imports
import '../lib/http/cdn_origin_policy.dart';
// ignore: avoid_relative_lib_imports
import '../lib/http/cdn_playback_proxy.dart';
// ignore: avoid_relative_lib_imports
import '../lib/utils/cdn_startup_trace.dart';

const _kiB = 1024;
const _miB = 1024 * _kiB;
const _smallChunk = 64 * _kiB;
const _testTimeout = Duration(seconds: 12);

Future<void> main() async {
  final tests = <String, Future<void> Function()>{
    'NET-02: 4 MiB steady chunks do not delay the first playback bytes':
        _earlyFirstBytes,
    'NET-03: a blocked and mismatched peer cannot delay or corrupt playback':
        _peerAdmission,
    'NET-03: blocked peer validation cannot hold the second anchor piece':
        _peerCannotHoldSecondPiece,
    'NET-03: two connections still let a healthy peer serve later pieces':
        _twoConnectionPeer,
    'NET-04: adjacent ranges reuse identity samples; new token invalidates':
        _sessionReuse,
    'NET-04: changed strong ETag invalidates cached cross-origin identity':
        _changedIdentity,
    'NET-04: delayed old peer validation cannot overwrite a new version':
        _overlappingIdentityEpoch,
    'NET-04: sequential ranges on one token reuse an upstream TCP connection':
        _connectionReuse,
    'NET-05: audio startup uses capacity reserved from video prefetch':
        _audioPriority,
    'NET-05: audio continuation outruns blocked video prefetch':
        _audioContinuation,
    'NET-05: audio first bytes bypass blocked video peer admission at two connections':
        _audioDuringPeerValidation,
    'NET-07: cancelling a stream stops its background work': _cancellation,
    'NET-07: cancelling a non-head waiter frees its transfer immediately':
        _cancelNonHeadWaiter,
  };
  var failed = 0;
  for (final test in tests.entries) {
    final watch = Stopwatch()..start();
    try {
      await test.value().timeout(_testTimeout);
      stdout.writeln('PASS ${test.key} (${watch.elapsedMilliseconds} ms)');
    } catch (error, stack) {
      failed++;
      stderr.writeln('FAIL ${test.key}: $error\n$stack');
    }
  }
  stdout.writeln('${tests.length - failed}/${tests.length} checks passed.');
  if (failed != 0) exitCode = 1;
}

void _expect(bool condition, String detail) {
  if (!condition) throw StateError(detail);
}

void _expectBytes(List<int> actual, List<int> expected, String detail) {
  _expect(actual.length == expected.length, '$detail: wrong byte count');
  for (var index = 0; index < actual.length; index++) {
    if (actual[index] != expected[index]) {
      throw StateError('$detail: byte $index differs');
    }
  }
}

Future<void> _earlyFirstBytes() async {
  // The origin can immediately finish a 64 KiB request, but deliberately holds
  // the rest of any 4 MiB request. This checks delivery, not a timing guess.
  final fixture = await _Fixture.start(
    originCount: 1,
    chunkSize: 4 * _miB,
    totalBytes: 5 * _miB + 127,
  );
  final origin = fixture.origins.single;
  final releaseLarge = Completer<void>();
  origin
    ..beforeBody = (request) async {
      if (request.start >= _smallChunk && request.length > _smallChunk) {
        await releaseLarge.future;
      }
    }
    ..afterPrefix = (request) async {
      if (request.start == 0 && request.length > _smallChunk) {
        await releaseLarge.future;
      }
    };
  final run = _FetchRun.start(
    fixture.register(),
    range: 'bytes=0-${5 * _miB - 1}',
  );
  try {
    // The first body must arrive while a large steady request is still held.
    // A full-block-before-output implementation times out here.
    _expect(
      await run.firstBody.timeout(const Duration(seconds: 2)),
      'No playback body arrived while the large request was held',
    );
    _expect(!releaseLarge.isCompleted, 'Large transfer was released too soon');
    releaseLarge.complete();
    final result = await run.done;
    _expect(result.error == null, 'Playback stream failed: ${result.error}');
    _expect(result.status == HttpStatus.partialContent, 'Wrong Range status');
    _expect(
      result.contentRange == 'bytes 0-${5 * _miB - 1}/${fixture.bytes.length}',
      'Wrong Content-Range',
    );
    _expect(result.contentLength == 5 * _miB, 'Wrong Content-Length');
    _expectBytes(
      result.bytes,
      fixture.bytes.sublist(0, 5 * _miB),
      'early delivery still preserves the full Range',
    );
  } finally {
    if (!releaseLarge.isCompleted) releaseLarge.complete();
    run.cancel();
    await fixture.close();
  }
}

Future<void> _peerAdmission() async {
  final fixture = await _Fixture.start(originCount: 2);
  final anchor = fixture.origins.first;
  final peer = fixture.origins.last;
  final peerSampleStarted = Completer<void>();
  final releasePeerSample = Completer<void>();
  peer
    ..corruptMiddle = true
    ..beforeBody = (request) async {
      if (request.start == fixture.bytes.length ~/ 2 &&
          request.length == 4096) {
        if (!peerSampleStarted.isCompleted) peerSampleStarted.complete();
        await releasePeerSample.future;
      }
    };
  final run = _FetchRun.start(fixture.register());
  try {
    _expect(
      await run.firstBody.timeout(const Duration(seconds: 2)),
      'No playback body arrived while peer validation was held',
    );
    // The first qualified mainland source can serve before the second source
    // has passed identity checks. A peer with different middle bytes must not
    // join the payload pool after its validation is released.
    await peerSampleStarted.future.timeout(const Duration(seconds: 2));
    _expect(
      !releasePeerSample.isCompleted,
      'Peer identity check finished before the first playback body',
    );
    releasePeerSample.complete();
    final result = await run.done;
    _expect(result.error == null, 'Playback stream failed: ${result.error}');
    _expectBytes(result.bytes, fixture.bytes, 'mismatched peer rejected');
    _expect(
      peer.requests.every((request) => request.length < _smallChunk),
      'Unverified peer served a media payload',
    );
    _expect(
      anchor.requests.any((request) => request.length >= _smallChunk),
      'Qualified anchor served no payload',
    );
  } finally {
    if (!releasePeerSample.isCompleted) releasePeerSample.complete();
    run.cancel();
    await fixture.close();
  }
}

Future<void> _peerCannotHoldSecondPiece() async {
  final fixture = await _Fixture.start(originCount: 2);
  final anchor = fixture.origins.first;
  final peer = fixture.origins.last;
  final peerSampleStarted = Completer<void>();
  final releasePeerSample = Completer<void>();
  final secondPieceArrived = Completer<void>();
  var received = 0;
  peer.beforeBody = (request) async {
    if (request.start == fixture.bytes.length ~/ 2 && request.length == 4096) {
      if (!peerSampleStarted.isCompleted) peerSampleStarted.complete();
      await releasePeerSample.future;
    }
  };
  final run = _FetchRun.start(
    fixture.register(),
    onBytes: (count) {
      received += count;
      if (received >= 2 * _smallChunk && !secondPieceArrived.isCompleted) {
        secondPieceArrived.complete();
      }
    },
  );
  try {
    _expect(
      await run.firstBody.timeout(const Duration(seconds: 2)),
      'Anchor supplied no first piece',
    );
    await peerSampleStarted.future.timeout(const Duration(seconds: 2));
    // A peer may validate in the background; the next ordered piece can still
    // be fetched from the healthy anchor without waiting for that peer.
    await secondPieceArrived.future.timeout(const Duration(seconds: 1));
    _expect(
      !releasePeerSample.isCompleted,
      'Peer validation was released before the second piece arrived',
    );
    _expect(
      anchor.requests.any(
        (request) =>
            request.start >= _smallChunk && request.length >= _smallChunk,
      ),
      'Second piece was not served by the validated anchor',
    );
    releasePeerSample.complete();
    final result = await run.done;
    _expect(result.error == null, 'Playback stream failed: ${result.error}');
    _expectBytes(
      result.bytes,
      fixture.bytes,
      'peer validation held in background',
    );
  } finally {
    if (!releasePeerSample.isCompleted) releasePeerSample.complete();
    run.cancel();
    await fixture.close();
  }
}

Future<void> _twoConnectionPeer() async {
  final fixture = await _Fixture.start(
    originCount: 2,
    concurrency: 2,
    totalBytes: 40 * _smallChunk + 127,
  );
  final anchor = fixture.origins.first;
  final peer = fixture.origins.last;
  anchor.beforeBody = (request) async {
    if (request.start > 0 && request.length >= _smallChunk) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  };
  try {
    final result = await _FetchRun.start(
      fixture.register(),
      range: 'bytes=0-${24 * _smallChunk - 1}',
    ).done;
    _expect(
      result.error == null,
      'Two-connection stream failed: ${result.error}',
    );
    _expectBytes(
      result.bytes,
      fixture.bytes.sublist(0, 24 * _smallChunk),
      'two-connection multi-source byte order',
    );
    _expect(
      anchor.requests.any((request) => request.length >= _smallChunk),
      'Anchor served no media data',
    );
    _expect(
      peer.sampleCount('sign=first') > 0 &&
          peer.requests.any((request) => request.length >= _smallChunk),
      'Healthy peer never joined payload at concurrency two',
    );
  } finally {
    await fixture.close();
  }
}

Future<void> _sessionReuse() async {
  final fixture = await _Fixture.start(
    originCount: 2,
    totalBytes: 80 * _smallChunk + 127,
  );
  fixture.origins.first.beforeBody = (request) async {
    if (request.start > 0 && request.length >= _smallChunk) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  };
  try {
    final firstToken = fixture.register(query: 'sign=first');
    Future<void> range(String url, int start) async {
      // More than the four-piece prefetch window lets a validated peer join
      // after background admission without holding the first few pieces.
      final end = start + 24 * _smallChunk - 1;
      final result = await _FetchRun.start(
        url,
        range: 'bytes=$start-$end',
      ).done;
      _expect(result.error == null, 'Range failed: ${result.error}');
      _expect(result.status == HttpStatus.partialContent, 'Wrong Range status');
      _expectBytes(
        result.bytes,
        fixture.bytes.sublist(start, end + 1),
        'adjacent Range',
      );
    }

    await range(firstToken, 0);
    _expect(
      fixture.origins.last.requests.any(
        (request) => request.length >= _smallChunk,
      ),
      'Validated peer never joined the first media stream',
    );
    final peerPiecesBeforeSeek = fixture.origins.last.requests
        .where((request) => request.length >= _smallChunk)
        .length;
    final samplesOnce = fixture.origins
        .map((origin) => origin.sampleCount('sign=first'))
        .toList();
    _expect(
      samplesOnce.every((count) => count > 0),
      'Fixture did not observe both origins passing identity checks',
    );
    final probesOnce = fixture.origins
        .map((origin) => origin.probeCount('sign=first'))
        .toList();
    await range(firstToken, 26 * _smallChunk);
    _expect(
      fixture.origins.last.requests
              .where((request) => request.length >= _smallChunk)
              .length >
          peerPiecesBeforeSeek,
      'Validated peer was not reused for payload after seek',
    );
    final samplesAfterSeek = fixture.origins
        .map((origin) => origin.sampleCount('sign=first'))
        .toList();
    final probesAfterSeek = fixture.origins
        .map((origin) => origin.probeCount('sign=first'))
        .toList();
    _expect(
      _equalCounts(samplesAfterSeek, samplesOnce),
      'The same token repeated full identity samples on seek: '
      '$samplesOnce -> $samplesAfterSeek',
    );
    _expect(
      probesAfterSeek.every((count) => count > 0) &&
          probesAfterSeek[0] > probesOnce[0],
      'Seek did not refresh anchor metadata before reusing cached samples',
    );

    // A changed signed address receives a different registration token. The
    // session cache must not silently inherit the first token's validation.
    final secondToken = fixture.register(query: 'sign=second');
    await range(secondToken, 52 * _smallChunk);
    _expect(
      fixture.origins.any(
        (origin) => origin.sampleCount('sign=second') > 0,
      ),
      'New signed resource reused stale preparation',
    );
  } finally {
    await fixture.close();
  }
}

Future<void> _changedIdentity() async {
  final fixture = await _Fixture.start(
    originCount: 2,
    totalBytes: 80 * _smallChunk + 127,
  );
  final anchor = fixture.origins.first;
  final peer = fixture.origins.last;
  anchor.beforeBody = (request) async {
    if (request.start > 0 && request.length >= _smallChunk) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  };
  final token = fixture.register();
  Future<_FetchResult> range(int start) => _FetchRun.start(
    token,
    range: 'bytes=$start-${start + 24 * _smallChunk - 1}',
  ).done;
  void expectVersion(_FetchResult response, int start, int generation) {
    _expect(
      response.error == null,
      'Versioned Range failed: ${response.error}',
    );
    _expect(
      response.status == HttpStatus.partialContent,
      'Versioned Range returned wrong status',
    );
    final expected = fixture.bytes.sublist(start, start + 24 * _smallChunk);
    final mask = _Origin.versionMask(generation);
    if (mask != 0) {
      for (var index = 0; index < expected.length; index++) {
        expected[index] ^= mask;
      }
    }
    _expectBytes(response.bytes, expected, 'resource generation $generation');
  }

  try {
    // A long Range allows admission of both mainland origins and populates the
    // strong-ETag identity cache before the resource changes.
    expectVersion(await range(0), 0, 0);
    _expect(
      peer.sampleCount('sign=first') > 0,
      'Peer identity was never checked in the original generation',
    );
    final anchorSamples = anchor.sampleCount('sign=first');
    final peerSamples = peer.sampleCount('sign=first');
    _expect(
      anchorSamples > 0 && peerSamples > 0,
      'Initial identity was not sampled',
    );

    // Both origins now serve a new representation at the same URL and length.
    // Fresh 0-0 probes must reject the cached anchor and require new samples.
    anchor.generation = 1;
    peer.generation = 1;
    expectVersion(await range(26 * _smallChunk), 26 * _smallChunk, 1);
    _expect(
      anchor.sampleCount('sign=first') > anchorSamples &&
          peer.sampleCount('sign=first') > peerSamples,
      'Changed strong ETags reused old anchor or peer identity samples',
    );

    // Only the peer changes again. Its cached admission is invalid although
    // the anchor's generation remains valid; no peer-v2 bytes may be spliced
    // into the anchor-v1 response.
    peer.generation = 2;
    expectVersion(await range(52 * _smallChunk), 52 * _smallChunk, 1);
    _expect(
      peer.requests.any((request) => request.generation == 2),
      'Changed peer was not rechecked',
    );
    _expect(
      peer.requests.every(
        (request) => request.generation != 2 || request.length < _smallChunk,
      ),
      'Changed peer served a media payload without matching anchor identity',
    );
  } finally {
    await fixture.close();
  }
}

Future<void> _overlappingIdentityEpoch() async {
  final fixture = await _Fixture.start(
    originCount: 2,
    concurrency: 2,
    totalBytes: 64 * _smallChunk + 127,
  );
  final anchor = fixture.origins.first;
  final peer = fixture.origins.last;
  final oldPeerSampleStarted = Completer<void>();
  final releaseOldPeerSample = Completer<void>();
  anchor.beforeBody = (request) async {
    if (request.start > 0 && request.length >= _smallChunk) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  };
  peer.beforeBody = (request) async {
    if (request.generation == 0 &&
        request.start == fixture.bytes.length ~/ 2 &&
        request.length == 4096) {
      if (!oldPeerSampleStarted.isCompleted) oldPeerSampleStarted.complete();
      await releaseOldPeerSample.future;
    }
  };
  final token = fixture.register();
  final old = _FetchRun.start(
    token,
    range: 'bytes=0-${8 * _smallChunk - 1}',
  );
  try {
    _expect(
      await old.firstBody.timeout(const Duration(seconds: 2)),
      'Old generation did not emit its initial piece',
    );
    await oldPeerSampleStarted.future.timeout(const Duration(seconds: 2));
    // This changes the resource while a generation-0 peer response is held in
    // the fixture. The next Range's fresh strong ETag must advance the epoch.
    anchor.generation = 1;
    peer.generation = 1;

    Future<void> newRange(int start) async {
      const length = 24 * _smallChunk;
      final result = await _FetchRun.start(
        token,
        range: 'bytes=$start-${start + length - 1}',
      ).done.timeout(const Duration(seconds: 4));
      _expect(
        result.error == null,
        'New-version Range failed: ${result.error}',
      );
      final expected = fixture.bytes.sublist(start, start + length);
      for (var index = 0; index < expected.length; index++) {
        expected[index] ^= _Origin.versionMask(1);
      }
      _expectBytes(
        result.bytes,
        expected,
        'new version after old background job',
      );
    }

    await newRange(10 * _smallChunk);
    final anchorSamples = anchor.sampleCount('sign=first', generation: 1);
    final peerSamples = peer.sampleCount('sign=first', generation: 1);
    _expect(
      anchorSamples > 0 && peerSamples > 0,
      'New version did not establish its own cross-origin identity',
    );
    releaseOldPeerSample.complete();
    final oldResult = await old.done.timeout(const Duration(seconds: 2));
    _expect(
      oldResult.bytes.isNotEmpty && oldResult.bytes.length < 8 * _smallChunk,
      'Old generation was not stopped after the version changed',
    );
    _expectBytes(
      oldResult.bytes,
      fixture.bytes.sublist(0, oldResult.bytes.length),
      'old response remains a valid old-version prefix',
    );

    await newRange(36 * _smallChunk);
    _expect(
      anchor.sampleCount('sign=first', generation: 1) == anchorSamples &&
          peer.sampleCount('sign=first', generation: 1) == peerSamples,
      'Late old-version validation overwrote the new-version identity cache',
    );
  } finally {
    if (!releaseOldPeerSample.isCompleted) releaseOldPeerSample.complete();
    old.cancel();
    await fixture.close();
  }
}

Future<void> _connectionReuse() async {
  final fixture = await _Fixture.start(originCount: 1, concurrency: 1);
  final origin = fixture.origins.single;
  final token = fixture.register();
  Future<void> range(int start) async {
    final result = await _FetchRun.start(
      token,
      range: 'bytes=$start-${start + _smallChunk - 1}',
    ).done;
    _expect(result.error == null, 'Sequential Range failed: ${result.error}');
    _expect(result.status == HttpStatus.partialContent, 'Wrong Range status');
    _expectBytes(
      result.bytes,
      fixture.bytes.sublist(start, start + _smallChunk),
      'sequential Range',
    );
  }

  try {
    await range(0);
    final firstCount = origin.requests.length;
    final firstPorts = origin.requests
        .map((request) => request.remotePort)
        .whereType<int>()
        .toSet();
    _expect(firstPorts.isNotEmpty, 'The origin did not expose TCP peer ports');
    // Allow the loopback writer to finish and return its HttpClient to this
    // token's small idle pool before the second player request begins.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await range(2 * _smallChunk);
    final secondPorts = origin.requests
        .skip(firstCount)
        .map((request) => request.remotePort)
        .whereType<int>()
        .toSet();
    _expect(secondPorts.isNotEmpty, 'Second Range never reached the origin');
    _expect(
      firstPorts.intersection(secondPorts).isNotEmpty,
      'Adjacent Ranges used disjoint upstream TCP connections: '
      '$firstPorts -> $secondPorts',
    );
  } finally {
    await fixture.close();
  }
}

bool _equalCounts(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Future<void> _audioPriority() async {
  const videoPath = '/upgcxcode/test/video.m4s';
  const audioPath = '/upgcxcode/test/audio.m4s';
  final fixture = await _Fixture.start(originCount: 1, concurrency: 2);
  final origin = fixture.origins.single;
  final releaseOneVideo = Completer<void>();
  final releaseOtherVideo = Completer<void>();
  final oneVideoRequestBlocked = Completer<void>();
  var blockedVideoRequests = 0;
  origin.beforeBody = (request) async {
    if (request.path != videoPath ||
        request.start == 0 ||
        request.length < _smallChunk) {
      return;
    }
    blockedVideoRequests++;
    if (blockedVideoRequests == 1 && !oneVideoRequestBlocked.isCompleted) {
      oneVideoRequestBlocked.complete();
    }
    if (blockedVideoRequests == 1) {
      await releaseOneVideo.future;
    } else {
      await releaseOtherVideo.future;
    }
  };
  final video = _FetchRun.start(
    fixture.register(path: videoPath, track: CdnStartupTrack.video),
  );
  _FetchRun? audio;
  try {
    _expect(
      await video.firstBody.timeout(const Duration(seconds: 2)),
      'Video never reached its first playback body',
    );
    await oneVideoRequestBlocked.future.timeout(const Duration(seconds: 2));
    audio = _FetchRun.start(
      fixture.register(path: audioPath, track: CdnStartupTrack.audio),
      range: 'bytes=0-${_smallChunk - 1}',
    );
    // At concurrency two, video prefetch can occupy one slot. Audio startup
    // must use the reserved urgent slot without releasing the slow prefetch.
    _expect(
      await audio.firstBody.timeout(const Duration(seconds: 2)),
      'Audio startup waited for a blocked video prefetch',
    );
    final result = await audio.done;
    _expect(result.error == null, 'Audio Range failed: ${result.error}');
    _expectBytes(
      result.bytes,
      fixture.bytes.sublist(0, _smallChunk),
      'audio startup',
    );
    final requests = origin.requests;
    final firstAudio = requests.indexWhere(
      (request) => request.path == audioPath,
    );
    var videoPrefetchCount = 0;
    var laterVideo = -1;
    for (var index = 0; index < requests.length; index++) {
      final request = requests[index];
      if (request.path == videoPath &&
          request.start > 0 &&
          request.length >= _smallChunk) {
        videoPrefetchCount++;
        if (videoPrefetchCount == 2) {
          laterVideo = index;
          break;
        }
      }
    }
    _expect(firstAudio >= 0, 'Audio never contacted the origin');
    _expect(
      laterVideo < 0 || firstAudio < laterVideo,
      'A second video prefetch occupied the reserved audio slot',
    );
  } finally {
    if (!releaseOneVideo.isCompleted) releaseOneVideo.complete();
    if (!releaseOtherVideo.isCompleted) releaseOtherVideo.complete();
    audio?.cancel();
    video.cancel();
    await video.done;
    await fixture.close();
  }
}

Future<void> _audioContinuation() async {
  const videoPath = '/upgcxcode/test/video.m4s';
  const audioPath = '/upgcxcode/test/audio.m4s';
  final fixture = await _Fixture.start(originCount: 1, concurrency: 2);
  final releaseVideo = Completer<void>();
  final blockedVideo = Completer<void>();
  fixture.origins.single.beforeBody = (request) async {
    if (request.path == videoPath &&
        request.start > 0 &&
        request.length >= _smallChunk) {
      if (!blockedVideo.isCompleted) blockedVideo.complete();
      await releaseVideo.future;
    }
  };
  final video = _FetchRun.start(
    fixture.register(path: videoPath, track: CdnStartupTrack.video),
  );
  _FetchRun? audio;
  try {
    _expect(
      await video.firstBody.timeout(const Duration(seconds: 2)),
      'Video never supplied its first piece',
    );
    await blockedVideo.future.timeout(const Duration(seconds: 2));
    audio = _FetchRun.start(
      fixture.register(path: audioPath, track: CdnStartupTrack.audio),
      range: 'bytes=0-${2 * _smallChunk - 1}',
    );
    _expect(
      await audio.firstBody.timeout(const Duration(seconds: 2)),
      'Audio never supplied its first piece',
    );
    // The second audio piece is still startup data. It should not be treated
    // as speculative work blocked by the unrelated video prefetch.
    final result = await audio.done.timeout(const Duration(seconds: 1));
    _expect(result.error == null, 'Audio continuation failed: ${result.error}');
    _expectBytes(
      result.bytes,
      fixture.bytes.sublist(0, 2 * _smallChunk),
      'audio continuation',
    );
    _expect(!releaseVideo.isCompleted, 'Video prefetch was released too soon');
  } finally {
    if (!releaseVideo.isCompleted) releaseVideo.complete();
    audio?.cancel();
    video.cancel();
    await video.done;
    await fixture.close();
  }
}

Future<void> _audioDuringPeerValidation() async {
  const videoPath = '/upgcxcode/test/video.m4s';
  const audioPath = '/upgcxcode/test/audio.m4s';
  final fixture = await _Fixture.start(
    originCount: 2,
    concurrency: 2,
    totalBytes: 24 * _smallChunk + 127,
  );
  final anchor = fixture.origins.first;
  final peer = fixture.origins.last;
  final peerSampleStarted = Completer<void>();
  final releasePeerSample = Completer<void>();
  anchor.beforeBody = (request) async {
    if (request.path == videoPath &&
        request.start > 0 &&
        request.length >= _smallChunk) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  };
  peer.beforeBody = (request) async {
    if (request.path == videoPath &&
        request.start == fixture.bytes.length ~/ 2 &&
        request.length == 4096) {
      if (!peerSampleStarted.isCompleted) peerSampleStarted.complete();
      await releasePeerSample.future;
    }
  };
  final video = _FetchRun.start(
    fixture.register(path: videoPath, track: CdnStartupTrack.video),
    range: 'bytes=0-${20 * _smallChunk - 1}',
  );
  _FetchRun? audio;
  try {
    _expect(
      await video.firstBody.timeout(const Duration(seconds: 2)),
      'Video anchor supplied no first body',
    );
    await peerSampleStarted.future.timeout(const Duration(seconds: 2));
    audio = _FetchRun.start(
      fixture.register(path: audioPath, track: CdnStartupTrack.audio),
      range: 'bytes=0-${_smallChunk - 1}',
    );
    _expect(
      await audio.firstBody.timeout(const Duration(seconds: 2)),
      'Audio first bytes waited for unrelated video peer validation',
    );
    final result = await audio.done.timeout(const Duration(seconds: 2));
    _expect(result.error == null, 'Audio Range failed: ${result.error}');
    _expectBytes(
      result.bytes,
      fixture.bytes.sublist(0, _smallChunk),
      'audio while video peer is blocked',
    );
    _expect(
      !releasePeerSample.isCompleted,
      'Peer validation was released before audio completed',
    );
  } finally {
    if (!releasePeerSample.isCompleted) releasePeerSample.complete();
    audio?.cancel();
    video.cancel();
    await video.done;
    await fixture.close();
  }
}

Future<void> _cancellation() async {
  final fixture = await _Fixture.start(originCount: 2);
  final anchor = fixture.origins.first;
  final peer = fixture.origins.last;
  final peerSampleStarted = Completer<void>();
  final releasePeerSample = Completer<void>();
  final releaseAnchorPiece = Completer<void>();
  anchor.beforeBody = (request) async {
    if (request.start == _smallChunk && request.length >= _smallChunk) {
      await releaseAnchorPiece.future;
    }
  };
  peer.beforeBody = (request) async {
    if (request.start == fixture.bytes.length ~/ 2 && request.length == 4096) {
      if (!peerSampleStarted.isCompleted) peerSampleStarted.complete();
      await releasePeerSample.future;
    }
  };
  final token = fixture.register();
  final run = _FetchRun.start(token);
  try {
    _expect(
      await run.firstBody.timeout(const Duration(seconds: 2)),
      'No playback body arrived before cancellation',
    );
    await peerSampleStarted.future.timeout(const Duration(seconds: 2));
    run.cancel();
    releasePeerSample.complete();
    releaseAnchorPiece.complete();
    await run.done.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final countAfterClose = fixture.requestCount;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    _expect(
      fixture.requestCount == countAfterClose,
      'Cancelled playback continued scheduling upstream requests '
      '($countAfterClose -> ${fixture.requestCount}): '
      '${fixture.origins.expand((origin) => origin.requests).map((request) => '${request.start}-${request.end}').join(',')}',
    );

    // Seek/new player request must not inherit a cancelled transfer's slot or
    // failed state. The request is intentionally small to avoid background work.
    final result = await _FetchRun.start(
      token,
      range: 'bytes=${3 * _smallChunk}-${4 * _smallChunk - 1}',
    ).done.timeout(const Duration(seconds: 2));
    _expect(result.error == null, 'Seek after cancellation failed');
    _expectBytes(
      result.bytes,
      fixture.bytes.sublist(3 * _smallChunk, 4 * _smallChunk),
      'seek after cancellation',
    );
  } finally {
    if (!releasePeerSample.isCompleted) releasePeerSample.complete();
    if (!releaseAnchorPiece.isCompleted) releaseAnchorPiece.complete();
    run.cancel();
    await fixture.close();
  }
}

Future<void> _cancelNonHeadWaiter() async {
  final fixture = await _Fixture.start(originCount: 1, concurrency: 1);
  final firstProbeStarted = Completer<void>();
  final releaseFirstProbe = Completer<void>();
  var held = false;
  fixture.origins.single.beforeBody = (request) async {
    if (!held && request.start == 0 && request.end == 0) {
      held = true;
      firstProbeStarted.complete();
      await releaseFirstProbe.future;
    }
  };
  final token = fixture.register();
  final runs = <_FetchRun>[
    _FetchRun.start(token, range: 'bytes=0-0'),
  ];
  _FetchRun? ninth;
  try {
    await firstProbeStarted.future.timeout(const Duration(seconds: 2));
    // Fill the eight active-transfer positions. B is the queue head; C is
    // cancelled while it is behind B, with D-H still waiting afterwards.
    for (var index = 0; index < 7; index++) {
      final run = _FetchRun.start(token, range: 'bytes=0-0');
      runs.add(run);
      await run.sent.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    runs[2].cancel();
    await runs[2].done.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // With C removed immediately, there is room for I. If it remains stuck
    // behind B in the waiter queue, the proxy rejects I at its transfer cap.
    ninth = _FetchRun.start(token, range: 'bytes=0-0');
    await ninth.sent.timeout(const Duration(seconds: 2));
    final early = await Future.any<_FetchResult?>([
      ninth.done.then<_FetchResult?>((result) => result),
      Future<_FetchResult?>.delayed(
        const Duration(milliseconds: 100),
        () => null,
      ),
    ]);
    _expect(
      early == null || early.status != HttpStatus.serviceUnavailable,
      'Non-head cancellation kept a transfer slot occupied (HTTP 503)',
    );
    releaseFirstProbe.complete();
    final result = await ninth.done.timeout(const Duration(seconds: 2));
    _expect(result.error == null, 'Replacement Range failed: ${result.error}');
    _expect(
      result.status == HttpStatus.partialContent,
      'Replacement was rejected',
    );
    _expectBytes(
      result.bytes,
      fixture.bytes.sublist(0, 1),
      'replacement Range',
    );
  } finally {
    if (!releaseFirstProbe.isCompleted) releaseFirstProbe.complete();
    ninth?.cancel();
    for (final run in runs) {
      run.cancel();
    }
    await fixture.close();
  }
}

final class _Fixture {
  _Fixture(this.bytes, this.origins, this.chunkSize);

  final Uint8List bytes;
  final List<_Origin> origins;
  final int chunkSize;
  late CdnPlaybackProxy proxy;

  static Future<_Fixture> start({
    required int originCount,
    int chunkSize = _smallChunk,
    int concurrency = 4,
    int? totalBytes,
  }) async {
    final length =
        totalBytes ?? math.max(10 * chunkSize + 127, 12 * _smallChunk);
    final bytes = Uint8List(length);
    var state = 0x75ac1d;
    for (var index = 0; index < length; index++) {
      state = (state * 1664525 + 1013904223) & 0xffffffff;
      bytes[index] = state >> 24;
    }
    final origins = <_Origin>[];
    for (var index = 0; index < originCount; index++) {
      final origin = await _Origin.start(bytes, index);
      origins.add(origin);
    }
    final fixture = _Fixture(bytes, origins, chunkSize)
      ..proxy = await CdnPlaybackProxy.start(
        concurrency: concurrency,
        chunkSize: chunkSize,
        timeout: const Duration(seconds: 4),
        allowOrigin: (uri) => origins.any(
          (origin) => uri.origin == origin.uri.origin,
        ),
        originResolver: (originals) => origins
            .map(
              (origin) => CdnOrigin(
                // The same deterministic origin serves a video and an audio
                // path, but each registration remains its own media resource.
                origin.uri.replace(
                  path: originals.first.path,
                  query: originals.first.query,
                ),
                mainland: true,
              ),
            )
            .toList(),
      );
    return fixture;
  }

  int get requestCount => origins.fold<int>(
    0,
    (count, origin) => count + origin.requests.length,
  );

  String register({
    String query = 'sign=first',
    String? path,
    CdnStartupTrack track = CdnStartupTrack.unknown,
  }) => proxy.register(
    origins.first.uri.replace(query: query, path: path).toString(),
    track: track,
  );

  Future<void> close() async {
    await proxy.close();
    await Future.wait(origins.map((origin) => origin.close()));
  }
}

final class _Origin {
  _Origin(this.bytes, this.server, this.index);

  final Uint8List bytes;
  final HttpServer server;
  final int index;
  final List<_OriginRequest> requests = [];
  Future<void> Function(_OriginRequest)? beforeBody;
  Future<void> Function(_OriginRequest)? afterPrefix;
  bool corruptMiddle = false;
  int generation = 0;

  static int versionMask(int generation) => switch (generation) {
    0 => 0,
    1 => 0x5a,
    2 => 0xa5,
    _ => throw ArgumentError.value(generation, 'generation'),
  };

  static Future<_Origin> start(Uint8List bytes, int index) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = _Origin(bytes, server, index);
    server.listen((request) => unawaited(origin._handle(request)));
    return origin;
  }

  Uri get uri => Uri.parse(
    'http://127.0.0.1:${server.port}/upgcxcode/test/media.m4s',
  );

  int probeCount(String query) => requests.where((request) {
    if (request.query != query) return false;
    return request.start == 0 && request.end == 0;
  }).length;

  int sampleCount(String query, {int? generation}) => requests.where((request) {
    if (request.query != query ||
        (generation != null && request.generation != generation)) {
      return false;
    }
    return (request.start == 0 && request.end == 4095) ||
        (request.start == bytes.length ~/ 2 && request.length == 4096);
  }).length;

  Future<void> _handle(HttpRequest request) async {
    try {
      final value = request.headers.value(HttpHeaders.rangeHeader);
      final match = value == null
          ? null
          : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(value);
      final start = match == null ? 0 : int.parse(match[1]!);
      final end = match == null || match[2]!.isEmpty
          ? bytes.length - 1
          : math.min(int.parse(match[2]!), bytes.length - 1);
      if (start < 0 || end < start || end >= bytes.length) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await request.response.close();
        return;
      }
      final record = _OriginRequest(
        request.uri.path,
        request.uri.query,
        start,
        end,
        generation,
        request.connectionInfo?.remotePort,
      );
      requests.add(record);
      await beforeBody?.call(record);

      final response = request.response
        ..statusCode = HttpStatus.partialContent
        ..contentLength = record.length;
      response.headers
        ..set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${bytes.length}',
        )
        ..set(HttpHeaders.contentTypeHeader, 'video/mp4')
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.etagHeader, '"origin-$index-v${record.generation}"');
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      final body = Uint8List.fromList(bytes.sublist(start, end + 1));
      final mask = versionMask(record.generation);
      if (mask != 0) {
        for (var offset = 0; offset < body.length; offset++) {
          body[offset] ^= mask;
        }
      }
      if (corruptMiddle) {
        for (var offset = 0; offset < body.length; offset++) {
          if (start + offset >= bytes.length ~/ 2) body[offset] ^= 0xff;
        }
      }
      if (afterPrefix != null && body.length > _smallChunk) {
        response.add(body.sublist(0, _smallChunk));
        await response.flush();
        await afterPrefix!(record);
        response.add(body.sublist(_smallChunk));
      } else {
        response.add(body);
      }
      await response.close();
    } on Object {
      // A cancelled proxy request can close its upstream socket mid-response.
      request.response.deadline = Duration.zero;
    }
  }

  Future<void> close() => server.close(force: true);
}

final class _OriginRequest {
  const _OriginRequest(
    this.path,
    this.query,
    this.start,
    this.end,
    this.generation,
    this.remotePort,
  );
  final String path;
  final String query;
  final int start;
  final int end;
  final int generation;
  final int? remotePort;
  int get length => end - start + 1;
}

final class _FetchRun {
  _FetchRun(this.client, this.sent, this.firstBody, this.done);

  final HttpClient client;
  final Future<void> sent;
  final Future<bool> firstBody;
  final Future<_FetchResult> done;

  static _FetchRun start(
    String url, {
    String? range,
    void Function(int)? onBytes,
  }) {
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..autoUncompress = false;
    final sent = Completer<void>();
    final first = Completer<bool>();
    final done = () async {
      final bytes = BytesBuilder(copy: false);
      var status = 0;
      String? contentRange;
      var contentLength = -1;
      Object? error;
      try {
        final request = await client.getUrl(Uri.parse(url));
        if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
        final pending = request.close();
        if (!sent.isCompleted) sent.complete();
        final response = await pending;
        status = response.statusCode;
        contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
        contentLength = response.contentLength;
        await for (final chunk in response) {
          if (chunk.isNotEmpty && !first.isCompleted) first.complete(true);
          bytes.add(chunk);
          onBytes?.call(chunk.length);
        }
      } on Object catch (caught) {
        error = caught;
      } finally {
        if (!sent.isCompleted) sent.complete();
        if (!first.isCompleted) {
          first.complete(false);
        }
        client.close(force: true);
      }
      return _FetchResult(
        bytes.takeBytes(),
        status,
        contentRange,
        contentLength,
        error,
      );
    }();
    return _FetchRun(client, sent.future, first.future, done);
  }

  void cancel() => client.close(force: true);
}

final class _FetchResult {
  const _FetchResult(
    this.bytes,
    this.status,
    this.contentRange,
    this.contentLength,
    this.error,
  );
  final Uint8List bytes;
  final int status;
  final String? contentRange;
  final int contentLength;
  final Object? error;
}

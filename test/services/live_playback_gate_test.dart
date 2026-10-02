import 'dart:async';

import 'package:PiliPlus/services/live_playback_gate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synchronized/synchronized.dart';

void main() {
  test('late A response cannot replace B, including a return to A', () {
    final gate = LivePlaybackGate();
    final ownerA = Object();
    final ownerB = Object();
    final oldA = gate.claim(ownerA);
    final b = gate.claim(ownerB);
    gate
      ..confirmRoom(oldA, live: true)
      ..sourceOpened();
    expect(gate.allowed, isFalse);
    gate.confirmRoom(b, live: true);
    expect(gate.allowed, isTrue);
    final newA = gate.claim(ownerA);
    expect(gate.accepts(oldA), isFalse);
    gate
      ..confirmRoom(oldA, live: true)
      ..sourceOpened();
    expect(gate.allowed, isFalse);
    gate.confirmRoom(newA, live: true);
    expect(gate.allowed, isTrue);
  });

  test('source events cannot resurrect a server-ended room', () {
    final gate = LivePlaybackGate();
    final lease = gate.claim(Object());
    gate
      ..confirmRoom(lease, live: true)
      ..sourceOpened();
    expect(gate.allowed, isTrue);
    gate
      ..roomEnded()
      ..sourceOpened();
    expect(gate.allowed, isFalse);
    gate.confirmRoom(lease, live: true);
    expect(gate.allowed, isTrue);
  });

  test('source error stays stopped until an open succeeds', () {
    final gate = LivePlaybackGate();
    final lease = gate.claim(Object());
    gate
      ..confirmRoom(lease, live: true)
      ..sourceOpened()
      ..sourceFailed();
    expect(gate.allowed, isFalse);
    // Repeated room information and buffering notifications do not open media.
    gate.confirmRoom(lease, live: true);
    expect(gate.allowed, isFalse);
    gate.sourceOpened();
    expect(gate.allowed, isTrue);
    gate.sourceChanging();
    expect(gate.allowed, isFalse);
  });

  test('mini adoption preserves source but invalidates old page requests', () {
    final gate = LivePlaybackGate();
    final pageLease = gate.claim(Object());
    gate
      ..confirmRoom(pageLease, live: true)
      ..sourceOpened();
    final restored = gate.claim(Object(), preserveSource: true);
    expect(gate.allowed, isTrue);
    expect(gate.accepts(pageLease), isFalse);
    expect(gate.accepts(restored), isTrue);
    gate.clear();
    expect(gate.allowed, isFalse);
    expect(gate.accepts(restored), isFalse);
  });

  test('mini adoption during recovery requires a fresh lease to resume', () {
    final gate = LivePlaybackGate();
    final oldLease = gate.claim(Object());
    gate
      ..confirmRoom(oldLease, live: true)
      ..sourceOpened()
      ..sourceFailed();
    final newLease = gate.claim(Object(), preserveSource: true);
    expect(gate.roomLive, isTrue);
    expect(gate.allowed, isFalse);
    expect(gate.accepts(oldLease), isFalse);
    expect(gate.accepts(newLease), isTrue);
    gate.sourceOpened();
    expect(gate.allowed, isTrue);
    gate.roomEnded();
    expect(gate.roomLive, isFalse);
  });

  test('handoff queues a new recovery behind the old paused open', () async {
    final gate = LivePlaybackGate();
    final lock = Lock();
    final oldLease = gate.claim(Object());
    gate.confirmRoom(oldLease, live: true);
    final oldOpenStarted = Completer<void>();
    final finishOldOpen = Completer<void>();
    final calls = <String>[];
    final oldRecovery = lock.synchronized(
      () => recoverLivePlayback(
        stillAllowed: () => gate.accepts(oldLease) && gate.roomLive,
        openPaused: () async {
          calls.add('old open');
          oldOpenStarted.complete();
          await finishOldOpen.future;
        },
        play: () async => calls.add('old play'),
        onRecovered: () {
          calls.add('old recovered');
          gate.sourceOpened();
        },
      ),
    );
    await oldOpenStarted.future;
    final newLease = gate.claim(Object(), preserveSource: true);
    final newRecovery = lock.synchronized(
      () => recoverLivePlayback(
        stillAllowed: () => gate.accepts(newLease) && gate.roomLive,
        openPaused: () async => calls.add('new open'),
        play: () async => calls.add('new play'),
        onRecovered: () {
          calls.add('new recovered');
          gate.sourceOpened();
        },
      ),
    );
    expect(calls, ['old open']);
    expect(gate.allowed, isFalse);
    finishOldOpen.complete();
    await Future.wait([oldRecovery, newRecovery]);
    expect(calls, ['old open', 'new open', 'new play', 'new recovered']);
    expect(gate.allowed, isTrue);
  });

  for (final endRoom in [false, true]) {
    test(
      'queued recovery is cancelled by ${endRoom ? 'room ending' : 'pause'}',
      () async {
        final gate = LivePlaybackGate();
        final lease = gate.claim(Object());
        gate.confirmRoom(lease, live: true);
        final lock = Lock();
        final lockAcquired = Completer<void>();
        final releaseLock = Completer<void>();
        final blocker = lock.synchronized(() async {
          lockAcquired.complete();
          await releaseLock.future;
        });
        await lockAcquired.future;
        var requestedPlaying = true;
        final calls = <String>[];
        final recovery = lock.synchronized(
          () => recoverLivePlayback(
            stillAllowed: () =>
                gate.accepts(lease) && gate.roomLive && requestedPlaying,
            openPaused: () async => calls.add('open'),
            play: () async => calls.add('play'),
            onRecovered: () {
              calls.add('recovered');
              gate.sourceOpened();
            },
          ),
        );
        if (endRoom) {
          gate.roomEnded();
        } else {
          requestedPlaying = false;
        }
        releaseLock.complete();
        await Future.wait([blocker, recovery]);
        expect(calls, isEmpty);
        expect(gate.allowed, isFalse);
      },
    );
  }

  test('pause during paused open prevents the delayed play command', () async {
    final openStarted = Completer<void>();
    final finishOpen = Completer<void>();
    var requestedPlaying = true;
    final calls = <String>[];
    final recovery = recoverLivePlayback(
      stillAllowed: () => requestedPlaying,
      openPaused: () async {
        calls.add('open');
        openStarted.complete();
        await finishOpen.future;
      },
      play: () async => calls.add('play'),
      onRecovered: () => calls.add('recovered'),
    );
    await openStarted.future;
    requestedPlaying = false;
    finishOpen.complete();
    await recovery;
    expect(calls, ['open']);
  });

  test('pause during play prevents marking the source recovered', () async {
    final playStarted = Completer<void>();
    final finishPlay = Completer<void>();
    var requestedPlaying = true;
    final calls = <String>[];
    final recovery = recoverLivePlayback(
      stillAllowed: () => requestedPlaying,
      openPaused: () async => calls.add('open'),
      play: () async {
        calls.add('play');
        playStarted.complete();
        await finishPlay.future;
      },
      onRecovered: () => calls.add('recovered'),
    );
    await playStarted.future;
    requestedPlaying = false;
    finishPlay.complete();
    await recovery;
    expect(calls, ['open', 'play']);
  });
}

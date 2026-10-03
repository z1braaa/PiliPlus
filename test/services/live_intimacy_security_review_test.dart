import 'dart:async';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/live_room/live_danmaku_send_gate.dart';
import 'package:PiliPlus/services/live_automation_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

// Mirrors LoginAccount equality without importing or creating real accounts.
class _EqualAccountIdentity {
  _EqualAccountIdentity(this.uid);
  final int uid;
  @override
  bool operator ==(Object other) =>
      other is _EqualAccountIdentity && other.uid == uid;
  @override
  int get hashCode => uid.hashCode;
}

void main() {
  test('replacement foreground waits for every retiring watch packet', () async {
    final coordinator = LiveAutomationCoordinator();
    final firstPacket = Completer<void>();
    final secondPacket = Completer<void>();
    coordinator
      ..retireForeground(firstPacket.future)
      ..retireForeground(secondPacket.future);
    var frontendStarted = 0;
    var frontendReporting = false;
    // This models the admission predicate of a newly constructed view session.
    void applyReplacementForeground() {
      final allowed =
          !coordinator.foregroundWatchDraining &&
          !coordinator.foregroundWatchSuspended &&
          !coordinator.backgroundWatchClaimed;
      if (allowed && !frontendReporting) frontendStarted++;
      frontendReporting = allowed;
    }

    coordinator.addListener(applyReplacementForeground);
    applyReplacementForeground();
    expect(frontendStarted, 0);
    expect(coordinator.foregroundWatchDraining, isTrue);
    firstPacket.complete();
    await Future<void>.delayed(Duration.zero);
    expect(coordinator.foregroundWatchDraining, isTrue);
    expect(frontendStarted, 0);
    secondPacket.complete();
    await Future<void>.delayed(Duration.zero);
    expect(coordinator.foregroundWatchDraining, isFalse);
    expect(frontendReporting, isTrue);
    expect(frontendStarted, 1);
    coordinator
      ..removeListener(applyReplacementForeground)
      ..dispose();
  });

  test(
    'background claim waits for retired and currently registered foregrounds',
    () async {
      final coordinator = LiveAutomationCoordinator();
      final retiredPacket = Completer<void>();
      final registeredPacket = Completer<void>();
      coordinator
        ..retireForeground(retiredPacket.future)
        ..registerForeground(() => registeredPacket.future);
      final owner = Object();
      var claimed = false;
      final claim = coordinator.claim(owner, 10).then((value) {
        claimed = value;
        return value;
      });
      expect(coordinator.backgroundWatchClaimed, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(claimed, isFalse);
      retiredPacket.complete();
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.foregroundWatchDraining, isFalse);
      expect(claimed, isFalse);
      registeredPacket.complete();
      expect(await claim, isTrue);
      expect(claimed, isTrue);
      await coordinator.release(owner);
      coordinator.dispose();
    },
  );

  test('a stale same-owner claim cannot approve a newly started claim epoch', () async {
    final coordinator = LiveAutomationCoordinator();
    final owner = Object();
    expect(await coordinator.claim(owner, 10), isTrue);
    final newDrain = Completer<void>();
    coordinator.registerForeground(() => newDrain.future);
    final repeatedOldClaim = coordinator.claim(owner, 10);
    // release() changes ownership synchronously before its returned future is
    // awaited. Reusing the owner object must still create a distinct epoch.
    final released = coordinator.release(owner);
    final newClaim = coordinator.claim(owner, 10);
    await released;
    expect(
      await repeatedOldClaim,
      isFalse,
      reason:
          'The old settled claim is not evidence for the new foreground drain.',
    );
    newDrain.complete();
    expect(await newClaim, isTrue);
    await coordinator.release(owner);
    coordinator.dispose();
  });

  test(
    'a repeated claim cannot bypass an outstanding foreground drain',
    () async {
      final coordinator = LiveAutomationCoordinator();
      final owner = Object();
      final drain = Completer<void>();
      coordinator.registerForeground(() => drain.future);
      final first = coordinator.claim(owner, 10);
      expect(coordinator.backgroundWatchClaimed, isTrue);
      var repeatFinished = false;
      final repeated = coordinator.claim(owner, 10).then((value) {
        repeatFinished = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        repeatFinished,
        isFalse,
        reason:
            'A same-owner request must also await foreground E/X settlement.',
      );
      expect(await coordinator.claim(Object(), 10), isFalse);
      drain.complete();
      expect(await first, isTrue);
      expect(await repeated, isTrue);
      await coordinator.release(owner);
      coordinator.dispose();
    },
  );

  test(
    'late claim completion and old release cannot replace a newer owner',
    () async {
      final coordinator = LiveAutomationCoordinator();
      final oldOwner = Object();
      final newOwner = Object();
      final drain = Completer<void>();
      Future<void> surrender() => drain.future;
      coordinator.registerForeground(surrender);
      final oldClaim = coordinator.claim(oldOwner, 10);
      await coordinator.release(oldOwner);
      coordinator.unregisterForeground(surrender);
      expect(await coordinator.claim(newOwner, 20), isTrue);
      drain.complete();
      expect(await oldClaim, isFalse);
      await coordinator.release(oldOwner);
      expect(coordinator.owns(newOwner), isTrue);
      expect(coordinator.backgroundWatchClaimed, isTrue);
      await coordinator.release(newOwner);
      coordinator.dispose();
    },
  );

  test(
    'foreground surrender failure never grants background watch ownership',
    () async {
      final coordinator = LiveAutomationCoordinator();
      final owner = Object();
      coordinator.registerForeground(
        () async => throw StateError('offline fixture failure'),
      );
      expect(await coordinator.claim(owner, 10), isFalse);
      expect(coordinator.backgroundWatchClaimed, isFalse);
      expect(coordinator.owns(owner), isFalse);
      coordinator.dispose();
    },
  );

  test('equal UID login objects keep separate gates while the same identity shares one', () async {
    final coordinator = LiveAutomationCoordinator();
    final identity1 = _EqualAccountIdentity(10);
    final identity2 = _EqualAccountIdentity(10);
    expect(identity1 == identity2, isTrue);
    expect(identical(identity1, identity2), isFalse);
    final first = coordinator.acquireDanmakuGate(identity1, 10, 30);
    final same = coordinator.acquireDanmakuGate(identity1, 10, 30);
    final reauthenticated = coordinator.acquireDanmakuGate(identity2, 10, 30);
    final otherRoom = coordinator.acquireDanmakuGate(identity1, 10, 40);
    expect(identical(first.gate, same.gate), isTrue);
    expect(identical(first.gate, reauthenticated.gate), isFalse);
    expect(identical(first.gate, otherRoom.gate), isFalse);
    first.release();
    same.release();
    reauthenticated.release();
    otherRoom.release();
    await Future<void>.delayed(Duration.zero);
    coordinator.dispose();
  });

  test(
    'pending send keeps its lock across final lease release and reacquisition',
    () async {
      final coordinator = LiveAutomationCoordinator();
      final identity = Object();
      final old = coordinator.acquireDanmakuGate(identity, 10, 30);
      final response = Completer<LoadingState<void>>();
      final request = old.gate.trySend(
        () => response.future,
        clearDraftOnSuccess: false,
      );
      expect(old.gate.pending, isTrue);
      old
        ..release()
        ..release(); // Idempotency must not corrupt the reference count.
      await Future<void>.delayed(Duration.zero);
      final replacement = coordinator.acquireDanmakuGate(identity, 10, 30);
      expect(identical(old.gate, replacement.gate), isTrue);
      var duplicateWrites = 0;
      expect(
        await replacement.gate.trySend(() async {
          duplicateWrites++;
          return const Success(null);
        }, clearDraftOnSuccess: false),
        isNull,
      );
      expect(duplicateWrites, 0);
      response.complete(const Success(null));
      expect(await request, isNotNull);
      await Future<void>.delayed(Duration.zero);
      final retained = coordinator.acquireDanmakuGate(identity, 10, 30);
      expect(identical(replacement.gate, retained.gate), isTrue);
      replacement.release();
      retained.release();
      await Future<void>.delayed(Duration.zero);
      final fresh = coordinator.acquireDanmakuGate(identity, 10, 30);
      expect(identical(fresh.gate, old.gate), isFalse);
      fresh.release();
      await Future<void>.delayed(Duration.zero);
      coordinator.dispose();
    },
  );

  test('late success after identity cancellation cannot clear a newly edited draft', () async {
    final gate = LiveDanmakuSendGate();
    var current = true;
    var cleared = 0;
    final response = Completer<LoadingState<void>>();
    final request = gate.trySend(
      () => response.future,
      clearDraftOnSuccess: true,
      stillCurrent: () => current,
      onDraftSuccess: (_) => cleared++,
    );
    gate.markDraftChanged();
    current = false;
    response.complete(const Success(null));
    await request;
    expect(cleared, 0);
    expect(gate.successSerial, 0);
    expect(gate.successfulRevision, isNull);
    gate.dispose();
  });

  test(
    'cancelled admission does not call a sender or consume the cooldown',
    () async {
      final gate = LiveDanmakuSendGate();
      var writes = 0;
      expect(
        await gate.trySend(
          () async {
            writes++;
            return const Success(null);
          },
          clearDraftOnSuccess: false,
          stillCurrent: () => false,
        ),
        isNull,
      );
      expect(writes, 0);
      expect(gate.lastAttemptAt, isNull);
      gate.dispose();
    },
  );

  test(
    'manual activity postpones automatic sends across a shared gate',
    () async {
      var now = DateTime.utc(2026, 10, 3);
      final gate = LiveDanmakuSendGate(now: () => now);
      var writes = 0;
      Future<LoadingState<void>> send() async {
        writes++;
        return const Success(null);
      }

      await gate.trySend(send, clearDraftOnSuccess: true);
      now = now.add(const Duration(seconds: 29));
      expect(
        await gate.trySend(
          send,
          clearDraftOnSuccess: false,
          minimumInterval: const Duration(seconds: 30),
        ),
        isNull,
      );
      expect(writes, 1);
      now = now.add(const Duration(seconds: 1));
      expect(
        await gate.trySend(
          send,
          clearDraftOnSuccess: false,
          minimumInterval: const Duration(seconds: 30),
        ),
        isNotNull,
      );
      expect(writes, 2);
      gate.dispose();
    },
  );

  test(
    'synchronous pending listeners can cancel before the sender runs',
    () async {
      final gate = LiveDanmakuSendGate();
      var current = true;
      var writes = 0;
      gate.addListener(() {
        if (gate.pending) current = false;
      });
      final result = await gate.trySend(
        () async {
          writes++;
          return const Success(null);
        },
        clearDraftOnSuccess: true,
        stillCurrent: () => current,
      );
      expect(result, isNull);
      expect(writes, 0);
      expect(gate.pending, isFalse);
      gate.dispose();
    },
  );
}

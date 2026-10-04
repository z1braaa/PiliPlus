import 'dart:async';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/live_room/live_danmaku_send_gate.dart';
import 'package:PiliPlus/services/live_automation_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cross room account lock preserves individual drafts and manual two-second cadence', () async {
    var now = DateTime(2026, 10, 3);
    final account = LiveDanmakuAccountGate();
    final a = LiveDanmakuSendGate(now: () => now, accountGate: account);
    final b = LiveDanmakuSendGate(now: () => now, accountGate: account);
    a.markDraftChanged();
    b
      ..markDraftChanged()
      ..markDraftChanged();
    final wait = Completer<LoadingState<void>>();
    final first = a.trySend(
      () => wait.future,
      clearDraftOnSuccess: true,
      minimumInterval: const Duration(seconds: 2),
    );
    expect(
      await b.trySend(
        () async => const Success(null),
        clearDraftOnSuccess: true,
      ),
      isNull,
    );
    wait.complete(const Success(null));
    await first;
    expect(a.successfulRevision, 1);
    expect(b.draftRevision, 2);
    now = now.add(const Duration(seconds: 2));
    expect(
      await b.trySend(
        () async => const Success(null),
        clearDraftOnSuccess: false,
        minimumInterval: const Duration(seconds: 30),
      ),
      isNull,
    );
    expect(
      await b.trySend(
        () async => const Success(null),
        clearDraftOnSuccess: true,
        minimumInterval: const Duration(seconds: 2),
      ),
      isNotNull,
    );
    expect(b.successfulRevision, 2);
    a.dispose();
    b.dispose();
  });

  test(
    'releasing every room lease does not reset account attempt clock',
    () async {
      final coordinator = LiveAutomationCoordinator();
      final identity = Object();
      final first = coordinator.acquireDanmakuGate(identity, 5, 10);
      await first.gate.trySend(
        () async => const Success(null),
        clearDraftOnSuccess: false,
      );
      final at = coordinator.lastDanmakuAttemptAt(identity, 5);
      first.release();
      await Future<void>.delayed(Duration.zero);
      final second = coordinator.acquireDanmakuGate(identity, 5, 20);
      expect(coordinator.lastDanmakuAttemptAt(identity, 5), at);
      expect(
        await second.gate.trySend(
          () async => const Success(null),
          clearDraftOnSuccess: false,
          minimumInterval: const Duration(seconds: 30),
        ),
        isNull,
      );
      expect(coordinator.lastDanmakuAttemptAt(Object(), 6), isNull);
      second.release();
      coordinator.dispose();
    },
  );
}

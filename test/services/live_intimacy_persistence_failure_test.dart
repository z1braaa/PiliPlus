import 'dart:async';

import 'package:PiliPlus/services/live_intimacy_record_store.dart';
import 'package:PiliPlus/services/live_intimacy_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'live_intimacy_dual_queue_records_test.dart' show Interaction;
import 'live_intimacy_scheduler_test.dart' as fixture;

class _FailingStore extends MemoryLiveIntimacyRecordStore {
  bool fail = false;
  bool flushFailure = false;
  int attemptedWrites = 0;
  @override
  Future<void> write(
    int uid,
    int anchorUid,
    int roomId,
    Map<String, dynamic> data,
  ) async {
    ++attemptedWrites;
    if (fail) {
      throw StateError(flushFailure ? 'flush failed' : 'write failed');
    }
    await super.write(uid, anchorUid, roomId, data);
  }
}

class _BlockingClearStore extends _FailingStore {
  final clearEntered = Completer<void>();
  final allowClear = Completer<void>();
  @override
  Future<void> clearAccount(int uid) async {
    clearEntered.complete();
    await allowClear.future;
    await super.clearAccount(uid);
  }
}

class _FailingReadStore extends MemoryLiveIntimacyRecordStore {
  bool failRead = true;
  int writes = 0;
  @override
  Future<Map<String, dynamic>?> read(int uid, int anchorUid, int roomId) {
    if (failRead) throw StateError('synchronous open or read failed');
    return super.read(uid, anchorUid, roomId);
  }

  @override
  Future<void> write(
    int uid,
    int anchorUid,
    int roomId,
    Map<String, dynamic> data,
  ) async {
    ++writes;
    await super.write(uid, anchorUid, roomId, data);
  }
}

void main() {
  test('account clear immediately prevents dispatch while preferences are being saved', () async {
    final h = fixture.Harness([fixture.room(1)]);
    await h.tick();
    final notifiedStatuses = <String>[];
    h.scheduler.addListener(() {
      notifiedStatuses.add(h.scheduler.statusText);
    });
    final old = h.sessions.single;
    final preferenceEntered = Completer<void>();
    final allowPreferenceWrite = Completer<void>();
    h.beforeWritePreferences = (_, _) async {
      preferenceEntered.complete();
      await allowPreferenceWrite.future;
    };
    final clearing = h.scheduler.clearAccountData(1);
    expect(old.allowed(), isFalse);
    await preferenceEntered.future;
    await h.tick();
    await h.scheduler.interactionTickForTesting();
    expect(h.sessions, hasLength(1));
    expect(old.closed, isTrue);
    expect(h.coordinator.backgroundWatchClaimed, isFalse);
    allowPreferenceWrite.complete();
    await clearing;
    expect(h.scheduler.statusText, '后台亲密度任务已关闭');
    expect(notifiedStatuses.last, h.scheduler.statusText);
    await h.close();
  });

  test(
    'unreadable ledger pauses without async errors or overwriting old data',
    () async {
      final store = _FailingReadStore();
      store.records['1:1:10'] = {
        'watch': {'schema': 1, 'effective_ms': 7000, 'reported_seconds': 3},
      };
      final h = fixture.Harness([fixture.room(1)], records: store);
      await h.tick();
      final state = h.scheduler.stateFor(10, 1)!;
      expect(state.recordRestoreError, contains('读取失败'));
      expect(h.scheduler.persistenceError, contains('尚未恢复'));
      expect(h.sessions, isEmpty);
      expect(store.writes, 0);
      expect((store.records['1:1:10']!['watch'] as Map)['effective_ms'], 7000);
      store.failRead = false;
      await h.scheduler.retryRecordSaves();
      expect(state.recordRestoreError, isNull);
      expect(state.watchProgress.effectiveDuration.inSeconds, 7);
      await h.tick();
      expect(h.sessions, hasLength(1));
      expect(state.watchProgress.effectiveDuration.inSeconds, 7);
      await h.close();
    },
  );

  test(
    'clearing an account prevents concurrent retry from resurrecting records',
    () async {
      final store = _BlockingClearStore();
      final h = fixture.Harness([fixture.room(1)], records: store);
      await h.tick();
      store.fail = true;
      h.account = const LiveIntimacyAccount(
        uid: 2,
        identity: 'other',
        generation: 1,
        loggedIn: true,
      );
      await h.tick();
      final clearing = h.scheduler.clearAccountData(1);
      final sameClear = h.scheduler.clearAccountData(1);
      expect(identical(clearing, sameClear), isTrue);
      await store.clearEntered.future;
      final beforeRetry = store.attemptedWrites;
      store.fail = false;
      await h.scheduler.retryRecordSaves();
      expect(store.attemptedWrites, beforeRetry);
      store.allowClear.complete();
      await clearing;
      await h.scheduler.retryRecordSaves();
      expect(await store.read(1, 1, 10), isNull);
      await h.close();
    },
  );

  for (final flushFailure in [false, true]) {
    test(
      'failed ${flushFailure ? "flush" : "write"} releases watch on disable and retries exact ledger',
      () async {
        final store = _FailingStore()..flushFailure = flushFailure;
        final events = <(int, bool, bool)>[];
        final h = fixture.Harness(
          [fixture.room(1)],
          records: store,
          interactions: (configuration, read, allowed) =>
              Interaction(configuration, read, allowed, events),
        );
        await h.tick();
        await h.scheduler.interactionTickForTesting();
        final state = h.scheduler.currentRoom!;
        state.watchProgress.effectiveDuration = const Duration(seconds: 12);
        final oldSession = h.sessions.single;
        final foregroundAllowed = <bool>[];
        h.coordinator.addListener(() {
          foregroundAllowed.add(!h.coordinator.backgroundWatchClaimed);
        });
        store.fail = true;
        await h.scheduler.savePreferences(
          h.scheduler.preferences.copyWith(enabled: false),
        );
        expect(oldSession.closed, isTrue);
        expect(h.coordinator.backgroundWatchClaimed, isFalse);
        expect(foregroundAllowed, contains(true));
        expect(h.scheduler.currentRoom, isNull);
        expect(h.scheduler.persistenceError, contains('尚未保存'));
        expect(h.scheduler.pendingRecordSaveCount, 1);
        expect(state.recordSaveError, contains('保存失败'));
        // An independent successful official read must not clear local failure.
        state.watchProgress.synchronize(fixture.taskSet(), h.now);
        expect(state.recordSaveError, isNotNull);
        store.fail = false;
        await h.scheduler.retryRecordSaves();
        expect(h.scheduler.persistenceError, isNull);
        expect(state.recordSaveError, isNull);
        expect(h.scheduler.pendingRecordSaveCount, 0);
        final saved = await store.read(1, 1, 10);
        expect((saved!['watch'] as Map)['effective_ms'], 12000);
        expect(h.coordinator.backgroundWatchClaimed, isFalse);
        await h.close();
      },
    );
  }

  test('record failure during preemption releases old owner and another room can claim', () async {
    final store = _FailingStore();
    final h = fixture.Harness([
      fixture.room(1),
      fixture.room(2),
    ], records: store);
    await h.tick();
    final old = h.sessions.single;
    expect(h.scheduler.currentRoom!.anchorUid, 2);
    store.fail = true;
    h.scheduler.updateForeground(roomId: 10, anchorUid: 1);
    await h.tick();
    expect(old.closed, isTrue);
    expect(h.scheduler.currentRoom!.anchorUid, 1);
    expect(h.sessions.length, 2);
    expect(h.coordinator.backgroundWatchClaimed, isTrue);
    expect(h.scheduler.persistenceError, isNotNull);
    await h.scheduler.suspend();
    expect(h.sessions.last.closed, isTrue);
    expect(h.coordinator.backgroundWatchClaimed, isFalse);
    store.fail = false;
    await h.scheduler.retryRecordSaves();
    await h.close();
  });

  test(
    'record failure during account change keeps old UID retry and stops media',
    () async {
      final store = _FailingStore();
      final events = <(int, bool, bool)>[];
      final h = fixture.Harness(
        [fixture.room(1)],
        records: store,
        interactions: (configuration, read, allowed) =>
            Interaction(configuration, read, allowed, events),
      );
      await h.tick();
      await h.scheduler.interactionTickForTesting();
      h.scheduler.currentRoom!.watchProgress.effectiveDuration = const Duration(
        seconds: 9,
      );
      store.fail = true;
      h.account = const LiveIntimacyAccount(
        uid: 2,
        identity: 'other',
        generation: 1,
        loggedIn: true,
      );
      await h.tick();
      expect(h.sessions.single.closed, isTrue);
      expect(h.coordinator.backgroundWatchClaimed, isFalse);
      expect(h.scheduler.accountUid, 2);
      expect(h.scheduler.persistenceError, isNull);
      h.account = LiveIntimacyAccount(
        uid: 1,
        identity: h.identity,
        generation: 2,
        loggedIn: true,
      );
      await h.tick();
      final restored = h.scheduler.currentRoom!;
      expect(restored.watchProgress.effectiveDuration.inSeconds, 9);
      expect(restored.recordSaveError, isNotNull);
      store.fail = false;
      await h.scheduler.retryRecordSaves();
      expect(restored.recordSaveError, isNull);
      final old = await store.read(1, 1, 10);
      expect((old!['watch'] as Map)['effective_ms'], 9000);
      expect(await store.read(2, 1, 10), isNull);
      await h.close();
    },
  );

  test(
    'record failure cannot stop shutdown or explicit account clearing cleanup',
    () async {
      for (final clear in [false, true]) {
        final store = _FailingStore();
        final events = <(int, bool, bool)>[];
        final h = fixture.Harness(
          [fixture.room(1)],
          records: store,
          interactions: (configuration, read, allowed) =>
              Interaction(configuration, read, allowed, events),
        );
        await h.tick();
        await h.scheduler.interactionTickForTesting();
        store.fail = true;
        if (clear) {
          await h.scheduler.clearAccountData(1);
          expect(h.scheduler.pendingRecordSaveCount, 0);
        } else {
          await h.close();
        }
        expect(h.sessions.single.closed, isTrue);
        expect(h.coordinator.backgroundWatchClaimed, isFalse);
        store.fail = false;
        if (clear) await h.close();
      }
    },
  );

  test(
    'preference write failure still waits for detached media cleanup',
    () async {
      final h = fixture.Harness([fixture.room(1)]);
      await h.tick();
      final session = h.sessions.single..holdClose = Completer<void>();
      h.beforeWritePreferences = (_, _) async =>
          throw StateError('preference write failed');
      var settled = false;
      final operation = h.scheduler.savePreferences(
        h.scheduler.preferences.copyWith(enabled: false),
      );
      final assertion = expectLater(
        operation.whenComplete(() {
          settled = true;
        }),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
      expect(h.coordinator.backgroundWatchClaimed, isTrue);
      session.holdClose!.complete();
      await assertion;
      expect(session.closed, isTrue);
      expect(h.coordinator.backgroundWatchClaimed, isFalse);
      await h.close();
    },
  );
}

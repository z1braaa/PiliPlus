import 'dart:async';

import 'package:PiliPlus/services/live_intimacy_discovery.dart';
import 'package:PiliPlus/services/live_intimacy_interaction_session.dart';
import 'package:PiliPlus/services/live_intimacy_record_store.dart';
import 'package:PiliPlus/services/live_intimacy_scheduler.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:PiliPlus/utils/live_viewer_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'live_intimacy_scheduler_test.dart' as fixture;

List<LiveFanTask> reliableTasks({bool done = false}) => [
  for (final task in fixture.taskSet(done: done))
    if (task.jumpType == 'watchLive')
      task
    else
      LiveFanTask(
        name: task.name,
        description: task.description,
        jumpType: task.jumpType,
        completed: task.completed,
        currentCount: task.currentCount,
        targetCount: task.targetCount,
        actionsPerProgress: task.jumpType == 'like' ? 30 : 1,
      ),
];

class Interaction extends LiveIntimacyInteractionSession {
  Interaction(this.configuration, this.read, this.allowed, this.events);
  final LiveIntimacyRoomPreferences configuration;
  final Future<LiveFanTaskSnapshot> Function() read;
  final bool Function() allowed;
  final List<(int, bool, bool)> events;
  @override
  List<LiveFanTask> tasks = const [];
  @override
  String? pauseReason;
  @override
  bool get pending => false;
  @override
  String get statusText => pauseReason ?? 'interaction waiting';
  bool closed = false;
  @override
  Future<void> tick({bool like = false, bool danmaku = false}) async {
    tasks = (await read()).tasks;
    if (!allowed()) return;
    events.add((configuration.anchorUid, like, danmaku));
    notifyListeners();
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  List<LiveFanTask> dailyTasks(int count, {String period = ''}) => [
    for (final type in ['like', 'sendDanmu', 'watchLive'])
      LiveFanTask(
        name: type == 'watchLive' ? '观看直播满15分钟' : type,
        description: '',
        jumpType: type,
        completed: count == 10,
        currentCount: count,
        targetCount: 10,
        dailyRewardProgress: true,
        actionsPerProgress: type == 'like' ? 30 : 1,
        period: period,
      ),
  ];

  test('two successful independent reads reset only the confirmed room ledger and journal cycle', () async {
    final store = MemoryLiveIntimacyRecordStore();
    final h = fixture.Harness(
      [fixture.room(1), fixture.room(2)],
      enabled: false,
      records: store,
    );
    h.taskStates[1] = dailyTasks(10);
    h.taskStates[2] = dailyTasks(10);
    await h.tick();
    await h.scheduler.refresh();
    final a = h.scheduler.stateFor(10, 1)!;
    final b = h.scheduler.stateFor(20, 2)!;
    a.watchProgress
      ..effectiveDuration = const Duration(seconds: 123)
      ..reportedSeconds = 120;
    b.watchProgress
      ..effectiveDuration = const Duration(seconds: 42)
      ..reportedSeconds = 30;
    h.taskStates[1] = dailyTasks(0);
    await h.scheduler.refresh();
    expect(a.periodConfirmed, isFalse);
    expect(a.watchProgress.effectiveDuration.inSeconds, 123);
    expect(a.watchProgress.reportedSeconds, 120);
    await h.scheduler.refresh();
    expect(a.periodConfirmed, isTrue);
    expect(a.officialCycle.confirmedLocalCycles, {
      'like': 1,
      'sendDanmu': 1,
      'watchLive': 1,
    });
    expect(a.watchProgress.effectiveDuration, Duration.zero);
    expect(a.watchProgress.reportedSeconds, 0);
    expect(a.watchProgress.currentRoundEstimateSeconds, isNull);
    expect(b.watchProgress.effectiveDuration.inSeconds, 42);
    expect(b.watchProgress.reportedSeconds, 30);
    expect((store.records['1:1:10']!['cycle'] as Map)['local_cycles'], {
      'like': 1,
      'sendDanmu': 1,
      'watchLive': 1,
    });
    a.watchProgress
      ..effectiveDuration = const Duration(seconds: 7)
      ..reportedSeconds = 6;
    await h.scheduler.refresh();
    expect(a.watchProgress.effectiveDuration.inSeconds, 7);
    expect(a.watchProgress.reportedSeconds, 6);
    expect(h.sessions, isEmpty);
    await h.close();
  });

  test('merged refreshes count as one reset observation', () async {
    final h = fixture.Harness([fixture.room(1)], enabled: false);
    h.taskStates[1] = dailyTasks(10);
    await h.tick();
    await h.scheduler.refresh();
    h.taskStates[1] = dailyTasks(0);
    final started = Completer<void>();
    final gate = Completer<void>();
    h.beforeRead = (_) {
      started.complete();
      return gate.future;
    };
    final first = h.scheduler.refresh();
    await started.future;
    final second = h.scheduler.refresh();
    expect(identical(first, second), isTrue);
    gate.complete();
    await first;
    final state = h.scheduler.stateFor(10, 1)!;
    expect(state.periodConfirmed, isFalse);
    expect(state.officialCycle.confirmedLocalCycles, isEmpty);
    h.beforeRead = null;
    await h.scheduler.refresh();
    expect(state.periodConfirmed, isTrue);
    expect(state.officialCycle.confirmedLocalCycles['watchLive'], 1);
    await h.close();
  });

  test(
    'failed official read preserves ledger and restarts two-read confirmation',
    () async {
      final h = fixture.Harness([fixture.room(1)], enabled: false);
      h.taskStates[1] = dailyTasks(10);
      await h.tick();
      await h.scheduler.refresh();
      final state = h.scheduler.stateFor(10, 1)!;
      state.watchProgress.effectiveDuration = const Duration(seconds: 99);
      h.taskStates[1] = dailyTasks(0);
      await h.scheduler.refresh();
      h.beforeRead = (_) =>
          Future<void>.error(StateError('network unavailable'));
      await h.scheduler.refresh();
      h.beforeRead = null;
      h.now = h.now.add(const Duration(seconds: 30));
      await h.scheduler.refresh();
      expect(state.periodConfirmed, isFalse);
      expect(state.watchProgress.effectiveDuration.inSeconds, 99);
      await h.scheduler.refresh();
      expect(state.periodConfirmed, isTrue);
      expect(state.watchProgress.effectiveDuration, Duration.zero);
      await h.close();
    },
  );

  test(
    'same named official period never resets ledger after repeated lower reads',
    () async {
      final h = fixture.Harness([fixture.room(1)], enabled: false);
      h.taskStates[1] = dailyTasks(10, period: 'same-day');
      await h.tick();
      await h.scheduler.refresh();
      final state = h.scheduler.stateFor(10, 1)!;
      state.watchProgress
        ..effectiveDuration = const Duration(seconds: 123)
        ..reportedSeconds = 120;
      h.taskStates[1] = dailyTasks(0, period: 'same-day');
      for (var i = 0; i < 3; i++) {
        await h.scheduler.refresh();
      }
      expect(state.periodConfirmed, isFalse);
      expect(state.officialCycle.confirmedLocalCycles, isEmpty);
      expect(state.watchProgress.effectiveDuration.inSeconds, 123);
      expect(state.watchProgress.reportedSeconds, 120);
      await h.close();
    },
  );

  test('manual refresh with master off reads every authorized known room without executing', () async {
    final events = <(int, bool, bool)>[];
    final incomplete = fixture
        .room(2)
        .copyWith(
          automation: const LiveTaskAutomationPreferences(),
        );
    final h = fixture.Harness(
      [fixture.room(1), incomplete, fixture.room(3, authorized: false)],
      enabled: false,
      interactions: (configuration, read, allowed) =>
          Interaction(configuration, read, allowed, events),
    );
    h.discovery.candidates[1] = const LiveIntimacyCandidate(
      roomId: 10,
      anchorUid: 1,
      medalLevel: 1,
      followed: true,
      medalOwned: true,
      live: false,
    );
    h.taskStates[1] = fixture.taskSet(done: true, watchDone: true);
    await h.tick();
    expect(h.reads, isEmpty);
    await h.scheduler.refresh();
    expect(h.reads, {1: 1, 2: 1});
    final offline = h.scheduler.stateFor(10, 1)!;
    expect(offline.authorizedTasksCompleted, isTrue);
    expect(offline.pauseReason, '主播尚未开播');
    expect(offline.watchProgress.lastSynchronizedAt, h.now);
    expect(h.scheduler.stateFor(20, 2)!.pauseReason, '请先开启自动点赞');
    expect(h.scheduler.preferences.enabled, isFalse);
    expect(h.scheduler.statusText, '后台亲密度任务已关闭');
    expect(h.scheduler.currentRoom, isNull);
    expect(h.sessions, isEmpty);
    expect(events, isEmpty);
    expect(h.coordinator.backgroundWatchClaimed, isFalse);
    h.now = h.now.add(const Duration(minutes: 6));
    await h.tick();
    await h.scheduler.interactionTickForTesting();
    expect(h.reads, {1: 1, 2: 1});
    expect(events, isEmpty);
    await h.close();
  });

  test(
    'manual refresh rechecks authorized rooms omitted from partial discovery',
    () async {
      final h = fixture.Harness([fixture.room(1)], enabled: false);
      h.discovery.omittedFromDiscovery.add(1);
      h.taskStates[1] = fixture.taskSet(done: true, watchDone: true);
      await h.tick();
      await h.scheduler.refresh();
      expect(h.reads, {1: 1});
      expect(h.scheduler.stateFor(10, 1)!.authorizedTasksCompleted, isTrue);
      expect(h.sessions, isEmpty);
      await h.close();
    },
  );

  for (final reason in ['匿名观看', '暂停记录观看', '身份冲突', '未登录']) {
    test('manual read cannot bypass $reason', () async {
      final h = fixture.Harness([fixture.room(1)], enabled: false);
      h.account = LiveIntimacyAccount(
        uid: 1,
        identity: h.identity,
        generation: 0,
        loggedIn: reason != '未登录',
        privacyReason: reason == '未登录' ? null : reason,
      );
      await h.tick();
      await h.scheduler.refresh();
      expect(h.reads, isEmpty);
      expect(h.sessions, isEmpty);
      expect(h.scheduler.currentRoom, isNull);
      await h.close();
    });
  }

  test('concurrent manual refreshes share one read-only operation', () async {
    final h = fixture.Harness([fixture.room(1)], enabled: false);
    await h.tick();
    final gate = Completer<void>();
    final started = Completer<void>();
    h.beforeRead = (_) {
      if (!started.isCompleted) started.complete();
      return gate.future;
    };
    final first = h.scheduler.refresh();
    await started.future;
    final second = h.scheduler.refresh();
    expect(identical(first, second), isTrue);
    expect(h.reads, {1: 1});
    gate.complete();
    await Future.wait([first, second]);
    expect(h.reads, {1: 1});
    expect(h.sessions, isEmpty);
    await h.close();
  });

  test('manual refresh respects failed official-read backoff without refreshing stale data', () async {
    final h = fixture.Harness([fixture.room(1)], enabled: false);
    await h.tick();
    h.beforeRead = (_) async =>
        throw const LiveInteractionException('官方任务暂时无法核对');
    await h.scheduler.refresh();
    final state = h.scheduler.stateFor(10, 1)!;
    expect(state.officialFresh, isFalse);
    expect(state.watchProgress.lastSynchronizedAt, isNull);
    await h.scheduler.refresh();
    expect(h.reads, {1: 1});
    expect(state.officialFresh, isFalse);
    h.now = h.now.add(const Duration(seconds: 30));
    h.beforeRead = null;
    await h.scheduler.refresh();
    expect(h.reads, {1: 2});
    expect(state.officialFresh, isTrue);
    expect(state.watchProgress.lastSynchronizedAt, h.now);
    await h.close();
  });

  test(
    'manual refresh after identity changes rejects old account results',
    () async {
      final h = fixture.Harness([fixture.room(1)], enabled: false);
      await h.tick();
      final gate = Completer<void>();
      final started = Completer<void>();
      h.beforeRead = (_) {
        if (!started.isCompleted) started.complete();
        return gate.future;
      };
      final pending = h.scheduler.refresh();
      await started.future;
      h.account = const LiveIntimacyAccount(
        uid: 2,
        identity: Object(),
        generation: 1,
        loggedIn: true,
      );
      h.stored[2] = LiveIntimacyPreferences(
        rooms: [fixture.room(1)],
      );
      await h.tick();
      gate.complete();
      await pending;
      expect(h.scheduler.accountUid, 2);
      expect(h.scheduler.stateFor(10, 1)!.tasks, isEmpty);
      expect(h.scheduler.stateFor(10, 1)!.officialFresh, isFalse);
      expect(h.sessions, isEmpty);
      await h.close();
    },
  );

  for (final old in LiveIntimacyRoomMode.values) {
    test(
      'changing ${old.name} room mode revokes consent in either direction',
      () async {
        final configured = fixture.room(1).copyWith(mode: old);
        final h = fixture.Harness([configured]);
        await h.tick();
        final next = old == LiveIntimacyRoomMode.full
            ? LiveIntimacyRoomMode.likeOnly
            : LiveIntimacyRoomMode.full;
        await h.scheduler.saveRoomPreferences(
          configured.copyWith(mode: next, authorized: false),
        );
        expect(h.scheduler.preferences.roomFor(10, 1)!.authorized, isFalse);
        await h.close();
      },
    );
  }

  test(
    'like only completion is not current when the like period is unconfirmed',
    () async {
      final only = fixture
          .room(1)
          .copyWith(mode: LiveIntimacyRoomMode.likeOnly);
      final h = fixture.Harness([only]);
      h.taskStates[1] = [
        const LiveFanTask(
          name: 'like',
          description: '',
          jumpType: 'like',
          completed: true,
          currentCount: 10,
          targetCount: 10,
        ),
      ];
      await h.tick();
      final state = h.scheduler.stateFor(10, 1)!;
      expect(state.authorizedTasksCompleted, isTrue);
      expect(state.watchProgress.syncError, isNull);
      h.taskStates[1] = [
        const LiveFanTask(
          name: 'like',
          description: '',
          jumpType: 'like',
          completed: true,
          currentCount: 5,
          targetCount: 10,
        ),
      ];
      await h.scheduler.refresh();
      expect(state.periodConfirmed, isFalse);
      expect(state.authorizedTasksCompleted, isFalse);
      expect(state.pauseReason, contains('周期待核对'));
      await h.close();
    },
  );

  test('one official source polls active watch at thirty seconds and others at five minutes', () async {
    final h = fixture.Harness([fixture.room(1), fixture.room(2)]);
    await h.tick();
    expect(h.reads, {1: 1, 2: 1});
    h.now = h.now.add(const Duration(seconds: 29));
    await h.tick();
    expect(h.reads, {1: 1, 2: 1});
    h.now = h.now.add(const Duration(seconds: 1));
    await h.tick();
    expect(h.reads, {1: 1, 2: 2});
    h.now = h.now.add(const Duration(seconds: 270));
    await h.tick();
    expect(h.reads, {1: 2, 2: 3});
    await h.close();
  });

  test('simultaneous panel and interaction reads merge rather than racing progress', () async {
    final events = <(int, bool, bool)>[];
    final h = fixture.Harness(
      [fixture.room(1)],
      interactions: (configuration, read, allowed) =>
          Interaction(configuration, read, allowed, events),
    );
    await h.tick();
    await h.scheduler.interactionTickForTesting();
    final wait = Completer<void>();
    h.beforeRead = (_) => wait.future;
    h.now = h.now.add(const Duration(seconds: 30));
    final refresh = h.scheduler.refresh();
    await Future<void>.delayed(Duration.zero);
    final interaction = h.scheduler.interactionTickForTesting();
    await Future<void>.delayed(Duration.zero);
    expect(h.reads[1], 2);
    wait.complete();
    await Future.wait([refresh, interaction]);
    // A subsequent dispatch can legitimately request another fresh snapshot.
    expect(h.reads[1], lessThanOrEqualTo(3));
    await h.close();
  });

  test(
    'failed synchronization keeps original time and makes completion stale',
    () async {
      final h = fixture.Harness([fixture.room(1)]);
      h.taskStates[1] = fixture.taskSet(done: true, watchDone: true);
      await h.tick();
      final state = h.scheduler.stateFor(10, 1)!;
      final at = state.watchProgress.lastSynchronizedAt;
      expect(state.authorizedTasksCompleted, isTrue);
      h.beforeRead = (_) async =>
          throw const LiveInteractionException('network failed');
      await h.scheduler.refresh();
      expect(state.watchProgress.lastSynchronizedAt, at);
      expect(state.watchProgress.syncState, LiveIntimacySyncState.failed);
      expect(state.authorizedTasksCompleted, isFalse);
      await h.close();
    },
  );

  test(
    'interactions rotate globally while only one other room owns audio',
    () async {
      final events = <(int, bool, bool)>[];
      final h = fixture.Harness(
        [fixture.room(1), fixture.room(2)],
        interactions: (configuration, read, allowed) =>
            Interaction(configuration, read, allowed, events),
      );
      h.taskStates[1] = reliableTasks();
      h.taskStates[2] = reliableTasks();
      await h.tick();
      expect(h.scheduler.currentRoom!.anchorUid, 2);
      await h.scheduler.interactionTickForTesting();
      h.now = h.now.add(const Duration(seconds: 30));
      await h.scheduler.interactionTickForTesting();
      h.now = h.now.add(const Duration(seconds: 30));
      await h.scheduler.interactionTickForTesting();
      expect(events.where((e) => e.$3).map((e) => e.$1), [2, 1]);
      expect(h.sessions.length, 1);
      expect(h.scheduler.ownsWatchReporter, isTrue);
      expect(h.scheduler.currentInteractionRoom!.anchorUid, 1);
      await h.close();
    },
  );

  test('official interaction completion clears the active target while audio continues', () async {
    final events = <(int, bool, bool)>[];
    final h = fixture.Harness(
      [fixture.room(1)],
      interactions: (configuration, read, allowed) =>
          Interaction(configuration, read, allowed, events),
    );
    h.taskStates[1] = reliableTasks();
    await h.tick();
    await h.scheduler.interactionTickForTesting();
    h.now = h.now.add(const Duration(seconds: 30));
    await h.scheduler.interactionTickForTesting();
    expect(h.scheduler.currentInteractionRoom?.anchorUid, 1);
    h.taskStates[1] = reliableTasks(done: true);
    await h.scheduler.refresh();
    await h.scheduler.interactionTickForTesting();
    expect(h.scheduler.currentInteractionRoom, isNull);
    expect(h.scheduler.stateFor(10, 1)!.interactionRunning, isFalse);
    expect(h.scheduler.currentRoom?.anchorUid, 1);
    expect(h.scheduler.stateFor(10, 1)!.watchRunning, isTrue);
    await h.close();
  });

  test(
    'audio failure does not pause that room interaction authorization',
    () async {
      final events = <(int, bool, bool)>[];
      final h = fixture.Harness(
        [fixture.room(1), fixture.room(2)],
        interactions: (configuration, read, allowed) =>
            Interaction(configuration, read, allowed, events),
      );
      await h.tick();
      h.sessions.single.pauseReason = 'audio unavailable';
      h.sessions.single.notifyListeners();
      await h.tick();
      expect(h.scheduler.currentRoom!.anchorUid, 1);
      expect(h.scheduler.stateFor(20, 2)!.pauseReason, isNull);
      expect(
        h.scheduler.stateFor(20, 2)!.watchPauseReason,
        'audio unavailable',
      );
      await h.scheduler.interactionTickForTesting();
      h.now = h.now.add(const Duration(seconds: 30));
      await h.scheduler.interactionTickForTesting();
      expect(events.any((e) => e.$1 == 2), isTrue);
      await h.close();
    },
  );

  test(
    'like only needs no message, never allocates audio or emits danmaku',
    () async {
      final only = fixture
          .room(1)
          .copyWith(
            mode: LiveIntimacyRoomMode.likeOnly,
            automation: const LiveTaskAutomationPreferences(autoLike: true),
          );
      expect(only.configurationIssue(), isNull);
      final events = <(int, bool, bool)>[];
      final h = fixture.Harness(
        [only],
        interactions: (configuration, read, allowed) =>
            Interaction(configuration, read, allowed, events),
      );
      h.taskStates[1] = reliableTasks();
      await h.tick();
      await h.scheduler.interactionTickForTesting();
      h.now = h.now.add(const Duration(seconds: 30));
      await h.scheduler.interactionTickForTesting();
      expect(h.sessions, isEmpty);
      expect(h.coordinator.backgroundWatchClaimed, isFalse);
      expect(events, [(1, true, false)]);
      expect(h.scheduler.statusText, contains('正在执行互动任务'));
      expect(h.scheduler.statusText, contains('没有运行中的观时任务'));
      await h.close();
    },
  );

  test(
    'watch completion hands off before unfinished interactions complete',
    () async {
      final h = fixture.Harness([fixture.room(1), fixture.room(2)]);
      h.taskStates[2] = fixture.taskSet(watchDone: true);
      await h.tick();
      expect(h.scheduler.currentRoom!.anchorUid, 1);
      expect(h.scheduler.stateFor(20, 2)!.completed, isFalse);
      expect(h.scheduler.stateFor(20, 2)!.authorizedTasksCompleted, isFalse);
      await h.close();
    },
  );

  test('ledger persists cumulative and accepted seconds without counting restart gap', () async {
    final store = MemoryLiveIntimacyRecordStore();
    final h = fixture.Harness([fixture.room(1)], records: store);
    await h.tick();
    h.scheduler.stateFor(10, 1)!.watchProgress
      ..sample(
        position: Duration.zero,
        monotonicClock: Duration.zero,
        validPlayback: true,
      )
      ..sample(
        position: const Duration(seconds: 1),
        monotonicClock: const Duration(seconds: 1),
        validPlayback: true,
      )
      ..reportedSeconds = 60;
    await h.close();
    final resumed = fixture.Harness([fixture.room(1)], records: store);
    await resumed.tick();
    final recovered = resumed.scheduler.stateFor(10, 1)!.watchProgress;
    expect(recovered.effectiveDuration, const Duration(seconds: 1));
    expect(recovered.reportedSeconds, 60);
    recovered.sample(
      position: const Duration(hours: 1),
      monotonicClock: Duration.zero,
      validPlayback: true,
    );
    expect(recovered.effectiveDuration, const Duration(seconds: 1));
    await resumed.close();
  });

  test('disabled master displays cached data but never marks it current completion', () async {
    final store = MemoryLiveIntimacyRecordStore();
    final h = fixture.Harness([fixture.room(1)], records: store);
    h.taskStates[1] = fixture.taskSet(done: true, watchDone: true);
    await h.tick();
    await h.close();
    final off = fixture.Harness(
      [fixture.room(1)],
      enabled: false,
      records: store,
    );
    await off.tick();
    await Future<void>.delayed(Duration.zero);
    final state = off.scheduler.stateFor(10, 1)!;
    expect(state.tasks, isNotEmpty);
    expect(state.watchProgress.restoredFromCache, isTrue);
    expect(state.authorizedTasksCompleted, isFalse);
    expect(off.sessions, isEmpty);
    await off.close();
  });

  test(
    'clearing one account never removes another account room ledger',
    () async {
      final store = MemoryLiveIntimacyRecordStore();
      await store.write(1, 1, 10, {
        'watch': {'schema': 1, 'reported_seconds': 20},
      });
      await store.write(2, 1, 10, {
        'watch': {'schema': 1, 'reported_seconds': 30},
      });
      final h = fixture.Harness([fixture.room(1)], records: store);
      await h.tick();
      await h.scheduler.clearAccountData(1);
      expect(await store.read(1, 1, 10), isNull);
      expect((await store.read(2, 1, 10))!['watch']['reported_seconds'], 30);
      expect(h.scheduler.preferences.enabled, isFalse);
      expect(h.scheduler.rooms, isEmpty);
      await h.close();
    },
  );
}

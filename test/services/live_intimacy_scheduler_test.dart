import 'dart:async';

import 'package:PiliPlus/services/live_automation_coordinator.dart';
import 'package:PiliPlus/services/live_intimacy_audio_session.dart';
import 'package:PiliPlus/services/live_intimacy_discovery.dart';
import 'package:PiliPlus/services/live_intimacy_scheduler.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:PiliPlus/utils/live_viewer_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

LiveIntimacyRoomPreferences room(int uid, {bool authorized = true}) =>
    LiveIntimacyRoomPreferences(
      anchorUid: uid,
      roomId: uid * 10,
      authorized: authorized,
      automation: const LiveTaskAutomationPreferences(
        autoLike: true,
        autoDanmaku: true,
        defaultMessage: 'configured',
      ),
    );
List<LiveFanTask> taskSet({bool done = false, bool watchDone = false}) => [
  for (final type in ['like', 'sendDanmu', 'watchLive'])
    LiveFanTask(
      name: type == 'watchLive' ? '观看直播满15分钟' : type,
      description: '',
      jumpType: type,
      completed: type == 'watchLive' ? watchDone : done,
      currentCount: done ? 10 : 0,
      targetCount: 10,
    ),
];

class Discovery implements LiveIntimacyDiscoverySource {
  final candidates = <int, LiveIntimacyCandidate>{};
  final failures = <int>{};
  Completer<void>? pending;
  Completer<void>? pendingRecheck;
  int cancels = 0;
  @override
  Future<List<LiveIntimacyCandidate>> discover(
    List<LiveIntimacyRoomPreferences> rooms,
  ) async {
    if (pending != null) await pending!.future;
    return [
      for (final room in rooms)
        if (candidates[room.anchorUid] != null) candidates[room.anchorUid]!,
    ];
  }

  @override
  Future<LiveIntimacyCandidate> recheck(
    LiveIntimacyRoomPreferences room,
  ) async {
    if (pendingRecheck != null) await pendingRecheck!.future;
    if (failures.contains(room.anchorUid)) {
      throw const LiveInteractionException('资格暂时未知');
    }
    return candidates[room.anchorUid]!;
  }

  @override
  void cancel() {
    cancels++;
  }
}

class Session extends LiveIntimacyTaskSession {
  Session(this.tasks, this.watchProgress, this.allowed);
  @override
  List<LiveFanTask> tasks;
  @override
  final LiveIntimacyWatchProgress watchProgress;
  final bool Function() allowed;
  @override
  String? pauseReason;
  @override
  String get statusText => pauseReason ?? 'running';
  @override
  bool get actualPlayback => !closed;
  bool started = false;
  bool closed = false;
  Completer<void>? holdClose;
  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> refresh() async {}
  @override
  Future<void> close() async {
    if (holdClose != null) await holdClose!.future;
    closed = true;
  }

  void changeTasks(List<LiveFanTask> value) {
    tasks = value;
    notifyListeners();
  }
}

class Harness {
  final identity = Object();
  late LiveIntimacyAccount account = LiveIntimacyAccount(
    uid: 1,
    identity: identity,
    generation: 0,
    loggedIn: true,
  );
  final discovery = Discovery();
  final coordinator = LiveAutomationCoordinator();
  final stored = <int, LiveIntimacyPreferences>{};
  final taskStates = <int, List<LiveFanTask>>{};
  final sessions = <Session>[];
  Completer<List<LiveTaskEmoticonOption>>? pendingEmoticons;
  final sessionUids = <int>[];
  late final LiveIntimacyScheduler scheduler;
  DateTime now = DateTime(2026, 10, 3);
  Harness(List<LiveIntimacyRoomPreferences> rooms, {bool enabled = true}) {
    stored[1] = LiveIntimacyPreferences(enabled: enabled, rooms: rooms);
    for (final configuration in rooms) {
      final uid = configuration.anchorUid;
      discovery.candidates[uid] = LiveIntimacyCandidate(
        roomId: configuration.roomId,
        anchorUid: uid,
        medalLevel: uid,
        followed: true,
        medalOwned: true,
        live: true,
        areaId: 1,
        parentAreaId: 2,
      );
      taskStates[uid] = taskSet();
    }
    scheduler = LiveIntimacyScheduler.testing(
      account: () => account,
      readPreferences: (uid) => stored[uid] ?? const LiveIntimacyPreferences(),
      writePreferences: (uid, value) async {
        stored[uid] = value;
      },
      discovery: discovery,
      coordinator: coordinator,
      automaticTimers: false,
      now: () => now,
      loadEmoticons: (_) async => pendingEmoticons != null
          ? await pendingEmoticons!.future
          : const [
              LiveTaskEmoticonOption(
                unique: 'selected',
                label: 'selected',
                available: true,
              ),
            ],
      readTasks: (room) async => LiveFanTaskSnapshot(
        roomId: room.roomId,
        anchorUid: room.anchorUid,
        accountUid: account.uid,
        accountIdentity: account.identity,
        tasks: taskStates[room.anchorUid]!,
        joined: true,
      ),
      createSession: (configuration, candidate, progress, allowed) {
        final session = Session(
          taskStates[configuration.anchorUid]!,
          progress,
          allowed,
        );
        sessions.add(session);
        sessionUids.add(configuration.anchorUid);
        return session;
      },
    );
  }
  Future<void> tick() => scheduler.tickForTesting();
  Future<void> close() => scheduler.shutdown();
}

void main() {
  test('global and room switches independently prevent execution', () async {
    final off = Harness([room(1)], enabled: false);
    await off.tick();
    expect(off.sessions, isEmpty);
    await off.close();
    final unauthorized = Harness([room(1, authorized: false)]);
    await unauthorized.tick();
    expect(unauthorized.sessions, isEmpty);
    expect(unauthorized.coordinator.backgroundWatchClaimed, isFalse);
    await unauthorized.close();
  });

  test(
    'high and low sorting are stable, authorized foreground preempts',
    () async {
      final harness = Harness([room(1), room(3), room(2)]);
      await harness.tick();
      expect(harness.sessionUids, [3]);
      harness.scheduler.updateForeground(roomId: 10, anchorUid: 1);
      await harness.tick();
      expect(harness.sessionUids, [3, 1]);
      expect(harness.sessions.first.closed, isTrue);
      expect(harness.sessions.first.allowed(), isFalse);
      harness.scheduler.updateForeground();
      await harness.scheduler.savePreferences(
        harness.scheduler.preferences.copyWith(
          sort: LiveIntimacySort.medalLowToHigh,
        ),
      );
      await harness.tick();
      expect(harness.sessionUids.last, 1);
      await harness.close();
    },
  );

  test('unopened unauthorized foreground cannot take the task owner', () async {
    final harness = Harness([room(1, authorized: false), room(2)]);
    harness.scheduler.updateForeground(roomId: 10, anchorUid: 1);
    await harness.tick();
    expect(harness.sessionUids, [2]);
    await harness.scheduler.saveRoomPreferences(room(1));
    expect(harness.scheduler.preferences.roomFor(10, 1)!.authorized, isFalse);
    await harness.close();
  });

  test('all three official flags required, completed rooms are checked for new cycles', () async {
    final harness = Harness([room(1), room(2)]);
    harness.taskStates[2] = taskSet(done: true, watchDone: false);
    await harness.tick();
    expect(harness.sessionUids, [2]);
    harness.taskStates[2] = taskSet(done: true, watchDone: true);
    harness.sessions.last.changeTasks(harness.taskStates[2]!);
    await harness.tick();
    expect(harness.sessionUids, [2, 1]);
    harness.taskStates[2] = taskSet();
    await harness.tick();
    expect(harness.sessionUids, [2, 1, 2]);
    expect(harness.scheduler.stateFor(20, 2)!.completed, isFalse);
    await harness.close();
  });

  test(
    'known already complete room does not start a background player',
    () async {
      final harness = Harness([room(1)]);
      harness.taskStates[1] = taskSet(done: true, watchDone: true);
      await harness.tick();
      expect(harness.sessions, isEmpty);
      expect(harness.coordinator.backgroundWatchClaimed, isFalse);
      await harness.close();
    },
  );

  test('empty task response pauses without declaring completion or allocating media', () async {
    final harness = Harness([room(1)]);
    harness.taskStates[1] = const [];
    await harness.tick();
    expect(harness.sessions, isEmpty);
    final state = harness.scheduler.stateFor(10, 1)!;
    expect(state.completed, isFalse);
    expect(state.pauseReason, contains('为空'));
    await harness.close();
  });

  test(
    'a failed room is skipped and does not block another candidate',
    () async {
      final harness = Harness([room(1), room(2)]);
      harness.discovery.failures.add(2);
      await harness.tick();
      await harness.tick();
      expect(harness.sessionUids, [1]);
      expect(harness.scheduler.stateFor(20, 2)!.pauseReason, contains('资格'));
      await harness.close();
    },
  );

  test(
    'privacy and persistent switch changes cancel pending dispatch immediately',
    () async {
      final harness = Harness([room(1)]);
      await harness.tick();
      final session = harness.sessions.single;
      expect(session.allowed(), isTrue);
      harness.stored[1] = harness.stored[1]!.copyWith(enabled: false);
      expect(session.allowed(), isFalse);
      harness.stored[1] = harness.stored[1]!.copyWith(enabled: true);
      harness.account = LiveIntimacyAccount(
        uid: 1,
        identity: harness.identity,
        generation: 0,
        loggedIn: true,
        privacyReason: '匿名观看',
      );
      expect(session.allowed(), isFalse);
      await harness.tick();
      expect(session.closed, isTrue);
      expect(harness.coordinator.backgroundWatchClaimed, isFalse);
      await harness.close();
    },
  );

  test('late discovery from another account never starts a session', () async {
    final harness = Harness([room(1)]);
    final pending = Completer<void>();
    harness.discovery.pending = pending;
    final tick = harness.tick();
    await Future<void>.delayed(Duration.zero);
    harness.account = const LiveIntimacyAccount(
      uid: 2,
      identity: Object(),
      generation: 1,
      loggedIn: true,
    );
    pending.complete();
    await tick;
    expect(harness.sessions, isEmpty);
    expect(harness.coordinator.backgroundWatchClaimed, isFalse);
    await harness.close();
  });

  test(
    'explicit foreground authorization checks configuration and permissions',
    () async {
      final harness = Harness([room(1, authorized: false)], enabled: false);
      await harness.tick();
      expect(
        await harness.scheduler.authorizeRoom(room(1), true),
        contains('手动'),
      );
      harness.scheduler.updateForeground(roomId: 10, anchorUid: 1);
      expect(
        await harness.scheduler.authorizeRoom(
          room(1).copyWith(automation: const LiveTaskAutomationPreferences()),
          true,
        ),
        contains('点赞'),
      );
      expect(await harness.scheduler.authorizeRoom(room(1), true), isNull);
      expect(harness.stored[1]!.roomFor(10, 1)!.authorized, isTrue);
      expect(harness.stored[1]!.enabled, isFalse);
      await harness.close();
    },
  );

  test(
    'read-only refresh does not create a player or claim watch ownership',
    () async {
      final harness = Harness([room(1)]);
      harness.scheduler.start();
      await harness.scheduler.refresh();
      expect(harness.sessions, isEmpty);
      expect(harness.coordinator.backgroundWatchClaimed, isFalse);
      expect(harness.scheduler.queue, hasLength(1));
      await harness.close();
    },
  );

  test(
    'late room recheck cannot authorize after the foreground room changes',
    () async {
      final harness = Harness([room(1, authorized: false)], enabled: false);
      await harness.tick();
      harness.scheduler.updateForeground(roomId: 10, anchorUid: 1);
      final pending = Completer<void>();
      harness.discovery.pendingRecheck = pending;
      final authorization = harness.scheduler.authorizeRoom(room(1), true);
      await Future<void>.delayed(Duration.zero);
      harness.scheduler.updateForeground(roomId: 20, anchorUid: 2);
      pending.complete();
      expect(await authorization, contains('变化'));
      expect(harness.stored[1]!.roomFor(10, 1)!.authorized, isFalse);
      await harness.close();
    },
  );

  for (final change in [
    'global_disabled',
    'room_disabled',
    'configuration_changed',
    'shutdown',
  ]) {
    test('late emoticon permissions cannot authorize after $change', () async {
      final harness = Harness([room(1, authorized: false)]);
      await harness.tick();
      harness.scheduler.updateForeground(roomId: 10, anchorUid: 1);
      final configured = room(1, authorized: false).copyWith(
        automation: const LiveTaskAutomationPreferences(
          autoLike: true,
          autoDanmaku: true,
          danmakuMode: LiveTaskDanmakuMode.emoticon,
        ),
        emoticons: const [
          LiveIntimacyEmoticonSelection(unique: 'selected', label: 'selected'),
        ],
      );
      final pending = Completer<List<LiveTaskEmoticonOption>>();
      harness.pendingEmoticons = pending;
      final authorization = harness.scheduler.authorizeRoom(configured, true);
      await Future<void>.delayed(Duration.zero);
      switch (change) {
        case 'global_disabled':
          await harness.scheduler.savePreferences(
            harness.scheduler.preferences.copyWith(enabled: false),
          );
        case 'room_disabled':
          expect(
            await harness.scheduler.authorizeRoom(configured, false),
            isNull,
          );
        case 'configuration_changed':
          await harness.scheduler.saveRoomPreferences(
            configured.copyWith(
              automation: configured.automation.copyWith(autoDanmaku: false),
            ),
          );
        case 'shutdown':
          await harness.scheduler.shutdown();
      }
      pending.complete(const [
        LiveTaskEmoticonOption(
          unique: 'selected',
          label: 'selected',
          available: true,
        ),
      ]);
      expect(await authorization, contains('变化'));
      expect(harness.stored[1]!.roomFor(10, 1)!.authorized, isFalse);
      await harness.close();
    });
  }

  test(
    'short-number configuration cannot replace an authorized canonical room',
    () async {
      final harness = Harness([room(1)]);
      await harness.tick();
      await harness.scheduler.saveRoomPreferences(
        room(1).copyWith(roomId: 999),
      );
      expect(harness.stored[1]!.roomFor(10, 1)!.authorized, isTrue);
      expect(harness.stored[1]!.roomFor(999, 1), isNull);
      await harness.close();
    },
  );

  test('concurrent shutdown awaits the one detached player before releasing ownership', () async {
    final harness = Harness([room(1)]);
    await harness.tick();
    final close = Completer<void>();
    harness.sessions.single.holdClose = close;
    var completed = 0;
    final first = harness.scheduler.shutdown().then((_) {
      completed++;
    });
    final second = harness.scheduler.shutdown().then((_) {
      completed++;
    });
    await Future<void>.delayed(Duration.zero);
    expect(completed, 0);
    expect(harness.coordinator.backgroundWatchClaimed, isTrue);
    close.complete();
    await Future.wait([first, second]);
    expect(completed, 2);
    expect(harness.coordinator.backgroundWatchClaimed, isFalse);
  });
}

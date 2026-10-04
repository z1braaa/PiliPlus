// Separate arrange/act calls keep mutable scenarios legible.
// ignore_for_file: cascade_invocations
import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/models_new/live/interactions/live_interaction_parser.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/services/live_task_automation.dart';
import 'package:flutter_test/flutter_test.dart';

class _Journal implements LiveInteractionJournal {
  final records = <String, Map<String, dynamic>>{};
  bool failWrite = false;
  Future<void> Function(String)? beforeRead;
  Future<void> Function(String)? beforeWrite;
  @override
  Future<Map<String, dynamic>?> read(String key) async {
    await beforeRead?.call(key);
    return records[key];
  }

  @override
  Future<void> write(String key, Map<String, dynamic> record) async {
    if (failWrite) throw StateError('disk full');
    await beforeWrite?.call(key);
    records[key] = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(record)) as Map,
    );
  }
}

class _Harness {
  final _Journal journal;
  _Harness([_Journal? journal]) : journal = journal ?? _Journal();
  Object identity = Object();
  int uid = 10;
  int generation = 0;
  bool loggedIn = true;
  DateTime now = DateTime.utc(2026, 10, 2, 15, 59, 50);
  int likes = 0;
  int messages = 0;
  int messageAttempts = 0;
  int reads = 0;
  Object? lastActor;
  bool? sendAllowed;
  bool? durableBeforeSend;
  String? sentMessage;
  LiveTaskDanmakuMessage? sentPayload;
  final likeBatches = <int>[];
  bool dailyRewardProgress = false;
  bool completionOnly = false;
  bool holdCompletionFlag = false;
  int actionsPerProgress = 1;
  int likeProgress = 0;
  int dmProgress = 0;
  int likeTarget = 7;
  int dmTarget = 2;
  bool countKnown = true;
  bool reflectProgress = true;
  bool returnUnknown = false;
  bool returnDeferred = false;
  LiveTaskWriteState? danmakuResultOverride;
  String period = '';
  Map<String, int> confirmedLocalCycles = {};
  List<LiveFanTask>? tasksOverride;
  Future<LiveFanTaskSnapshot> Function()? loadOverride;
  int Function(int)? random;
  bool paceLikes = false;
  bool externalScheduling = false;
  bool Function()? mayResetUnknownPeriod;
  bool permitted = true;
  LiveTaskDanmakuSelector? chooseDanmaku;
  late LiveTaskAutomationService service;

  LiveFanTask task(String type, int current, int target) => LiveFanTask(
    name: type,
    description: '当前任务',
    jumpType: type,
    completed: !holdCompletionFlag && current >= target,
    currentCount: !completionOnly && countKnown ? current : null,
    targetCount: countKnown ? target : null,
    period: period,
    dailyRewardProgress: dailyRewardProgress,
    completionOnly: completionOnly,
    actionsPerProgress: type == 'like' ? actionsPerProgress : 1,
  );
  LiveFanTaskSnapshot get snapshot => LiveFanTaskSnapshot(
    roomId: 6,
    anchorUid: 20,
    accountUid: uid,
    accountIdentity: identity,
    joined: true,
    confirmedLocalCycles: confirmedLocalCycles,
    tasks:
        tasksOverride ??
        [
          task('like', likeProgress, likeTarget),
          task('sendDanmu', dmProgress, dmTarget),
        ],
  );
  void create() {
    service = LiveTaskAutomationService.testing(
      roomId: 6,
      anchorUid: 20,
      loadTasks: () async {
        reads++;
        return loadOverride?.call() ?? snapshot;
      },
      sendLike: (count, actor, allowed) async {
        lastActor = actor;
        sendAllowed = allowed();
        durableBeforeSend = _pendingRecords.isNotEmpty;
        likes += count;
        likeBatches.add(count);
        if (reflectProgress) likeProgress += count ~/ actionsPerProgress;
        return LiveTaskWriteResult(
          returnUnknown
              ? LiveTaskWriteState.unknown
              : LiveTaskWriteState.accepted,
        );
      },
      sendDanmaku: (message, actor, allowed) async {
        messageAttempts++;
        lastActor = actor;
        sendAllowed = allowed();
        durableBeforeSend = _pendingRecords.isNotEmpty;
        if (returnDeferred) {
          return const LiveTaskWriteResult(LiveTaskWriteState.deferred);
        }
        if (danmakuResultOverride
            case LiveTaskWriteState.notSubmitted ||
                LiveTaskWriteState.rejected) {
          return LiveTaskWriteResult(danmakuResultOverride!, '表情权限未确认');
        }
        sentPayload = message;
        sentMessage = message.text;
        messages++;
        if (reflectProgress) dmProgress++;
        return LiveTaskWriteResult(
          danmakuResultOverride ??
              (returnUnknown
                  ? LiveTaskWriteState.unknown
                  : LiveTaskWriteState.accepted),
        );
      },
      accountIdentity: () => identity,
      accountUid: () => uid,
      accountGeneration: () => generation,
      isLoggedIn: () => loggedIn,
      now: () => now,
      randomInt: random ?? (_) => 0,
      journal: journal,
      paceLikes: paceLikes,
      externalScheduling: externalScheduling,
      mayResetUnknownPeriod: mayResetUnknownPeriod,
      mayRun: () => permitted,
      chooseDanmaku: chooseDanmaku,
    );
  }

  Iterable<Map<String, dynamic>> get _pendingRecords =>
      journal.records.values.where(
        (record) => (record['pending_count'] as int? ?? 0) > 0,
      );
  void update({
    bool playing = true,
    bool enhanced = true,
    bool autoLike = false,
    bool autoDanmaku = false,
    String message = '默认任务弹幕',
    LiveTaskDanmakuMessage? danmakuMessage,
  }) {
    service.update(
      playing: playing,
      enhancementEnabled: enhanced,
      autoLike: autoLike,
      autoDanmaku: autoDanmaku,
      defaultMessage: message,
      danmakuMessage: danmakuMessage,
    );
  }

  Future<void> advance(WidgetTester tester, int seconds) async {
    now = now.add(Duration(seconds: seconds));
    await tester.pump(Duration(seconds: seconds));
    await tester.pump(Duration.zero);
  }
}

void main() {
  testWidgets(
    'certified new cycle retires unresolved old write without replaying it',
    (tester) async {
      final h = _Harness()
        ..likeTarget = 2
        ..dailyRewardProgress = true
        ..reflectProgress = false
        ..returnUnknown = true;
      h.create();
      h.update(autoLike: true);
      await tester.pump(Duration.zero);
      await h.service.settled;
      expect(h.likes, 1);
      expect(h._pendingRecords, isNotEmpty);
      h.service.dispose();
      final next = _Harness(h.journal)
        ..likeTarget = 2
        ..dailyRewardProgress = true
        ..confirmedLocalCycles = {'like': 1};
      next.create();
      next.update(autoLike: true);
      await tester.pump(Duration.zero);
      await next.service.settled;
      expect(next.likes, 1);
      expect(
        next.journal.records.values.any((record) => record['retired'] == true),
        isTrue,
      );
      expect(next.service.tasks.first.period, isEmpty);
      next.service.dispose();
    },
  );
  testWidgets(
    'certified local cycle separates restored unfinished and completed budgets',
    (tester) async {
      final h = _Harness()
        ..likeTarget = 2
        ..dailyRewardProgress = true;
      h.create();
      h.update(autoLike: true);
      await tester.pump(Duration.zero);
      await h.service.settled;
      await h.advance(tester, 10);
      await h.service.settled;
      expect(h.likes, 2);
      h.service.dispose();
      final next = _Harness(h.journal)
        ..likeTarget = 2
        ..dailyRewardProgress = true
        ..confirmedLocalCycles = {'like': 1};
      next.create();
      next.update(autoLike: true);
      await tester.pump(Duration.zero);
      await next.service.settled;
      expect(next.likes, greaterThan(0));
      expect(
        next.journal.records.keys.any(
          (key) => key.contains('confirmed-local-cycle:1'),
        ),
        isTrue,
      );
      expect(next.service.tasks.first.period, isEmpty);
      next.service.dispose();
    },
  );
  testWidgets(
    'a completed explicit period never reopens its budget after a lower count',
    (tester) async {
      final h = _Harness()
        ..period = 'day-A'
        ..dailyRewardProgress = true
        ..actionsPerProgress = 30
        ..likeTarget = 10
        ..likeProgress = 10
        // This gate may authorize unnumbered cycles, never a named same-period reset.
        ..mayResetUnknownPeriod = (() => true);
      h.create();
      h.update(autoLike: true);
      await tester.pump(Duration.zero);
      await h.service.settled;
      expect(h.likes, 0);
      expect(h.service.tasks.first.completed, isTrue);
      expect(
        h.journal.records.values.any(
          (record) =>
              record['type'] == 'like' && record['server_completed'] == true,
        ),
        isTrue,
      );
      h.likeProgress = 0;
      await h.advance(tester, 30);
      expect(h.likes, 0);
      expect(h.service.state, LiveTaskAutomationState.paused);
      expect(h.service.statusText, contains('同周期'));
      h.likeProgress = 3;
      await h.advance(tester, 30);
      expect(h.likes, 0);
      h.service.dispose();
      // Re-entry must retain the completed day-A budget, not erase it on restore.
      h.create();
      h.update(autoLike: true);
      await tester.pump(Duration.zero);
      expect(h.likes, 0);
      h.period = 'day-B';
      h.likeProgress = 0;
      await h.advance(tester, 30);
      expect(h.likeBatches, [30]);
      h.service.dispose();
    },
  );

  test('account queued click slots accumulate one full round without per-room timers', () async {
    final h = _Harness()
      ..externalScheduling = true
      ..paceLikes = true
      ..dailyRewardProgress = true
      ..actionsPerProgress = 30
      ..likeTarget = 10;
    h.create();
    h.update(autoLike: true, autoDanmaku: true);
    for (var i = 0; i < 29; i++) {
      await h.service.tickFromQueue(like: true);
    }
    expect(h.likes, 0);
    expect(h.reads, 1);
    await h.service.tickFromQueue(like: true);
    expect(h.likeBatches, [30]);
    expect(h.service.issuedLikes, 30);
    expect(h.messages, 0);
    await h.service.tickFromQueue(danmaku: true);
    expect(h.messages, 1);
    expect(h.service.issuedDanmaku, 1);
    h.service.dispose();
  });

  test('queue due message does not throw away partially accumulated likes', () async {
    final h = _Harness()
      ..externalScheduling = true
      ..paceLikes = true
      ..dailyRewardProgress = true
      ..actionsPerProgress = 30
      ..likeTarget = 10;
    h.create();
    h.update(autoLike: true, autoDanmaku: true);
    for (var i = 0; i < 15; i++) {
      await h.service.tickFromQueue(like: true);
    }
    await h.service.tickFromQueue(danmaku: true);
    expect(h.messages, 1);
    // First call reconciles that message; subsequent slots retain prior clicks.
    for (var i = 0; i < 16; i++) {
      await h.service.tickFromQueue(like: true);
    }
    expect(h.likeBatches, [30]);
    h.service.dispose();
  });

  test('lighting-only task titles define a quota without inventing a server counter', () {
    final tasks = LiveInteractionParser.fanTasks([
      {
        'title': '发弹幕10次',
        'sub_title': '仅点亮',
        'jump_type': 'sendDanmu',
        'is_done': false,
      },
      {
        'title': '点赞30次',
        'sub_title': '仅点亮',
        'jump_type': 'like',
        'is_done': false,
      },
      {
        'title': '点赞奖励30',
        'sub_title': '仅点亮',
        'jump_type': 'like',
        'is_done': false,
      },
    ]);
    expect(tasks.first.completionOnly, isTrue);
    expect(tasks.first.currentCount, isNull);
    expect(tasks.first.targetCount, 10);
    expect(tasks.first.remainingCount, 10);
    expect(tasks.first.actionsPerProgress, 1);
    expect(tasks[1].remainingCount, 1);
    expect(tasks[1].actionsPerProgress, 30);
    expect(tasks[2].actionsPerProgress, isNull);
  });

  testWidgets(
    'accepted lighting messages consume the title quota while completion remains server-owned',
    (tester) async {
      final h = _Harness()
        ..completionOnly = true
        ..holdCompletionFlag = true
        ..dmTarget = 3;
      h.create();
      h.update(autoDanmaku: true);
      await tester.pump(Duration.zero);
      for (var i = 0; i < 3; i++) {
        await h.advance(tester, 30);
      }
      expect(h.messages, 3);
      expect(h.messageAttempts, 3);
      await h.advance(tester, 60);
      expect(h.messages, 3);
      expect(h.service.state, isNot(LiveTaskAutomationState.completed));
      h.holdCompletionFlag = false;
      await h.service.refreshTasks();
      expect(h.service.state, LiveTaskAutomationState.completed);
      h.service.dispose();
    },
  );

  testWidgets(
    'lighting likes send one bounded 30-click batch and preserve it across reentry',
    (tester) async {
      final journal = _Journal();
      final old = _Harness(journal)
        ..completionOnly = true
        ..holdCompletionFlag = true
        ..actionsPerProgress = 30
        ..likeTarget = 1;
      old.create();
      old.update(autoLike: true);
      await tester.pump(Duration.zero);
      expect(old.likeBatches, [30]);
      await old.advance(tester, 60);
      expect(old.likeBatches, [30]);
      old.service.dispose();
      final next = _Harness(journal)
        ..completionOnly = true
        ..holdCompletionFlag = true
        ..actionsPerProgress = 30
        ..likeTarget = 1;
      next.create();
      next.update(autoLike: true);
      await tester.pump(Duration.zero);
      expect(next.likes, 0);
      next.likeProgress = 1;
      next.holdCompletionFlag = false;
      await next.service.refreshTasks();
      expect(next.service.state, LiveTaskAutomationState.completed);
      next.service.dispose();
    },
  );

  testWidgets(
    'unknown lighting writes freeze until completion or an official daily transition',
    (tester) async {
      final h = _Harness()
        ..completionOnly = true
        ..holdCompletionFlag = true
        ..reflectProgress = false
        ..returnUnknown = true
        ..dmTarget = 10;
      h.create();
      h.update(autoDanmaku: true);
      await tester.pump(Duration.zero);
      await h.advance(tester, 30);
      await h.advance(tester, 60);
      expect(h.messages, 1);
      h.completionOnly = false;
      h.dailyRewardProgress = true;
      h.holdCompletionFlag = false;
      h.reflectProgress = true;
      h.returnUnknown = false;
      await h.service.refreshTasks();
      await tester.pump(Duration.zero);
      expect(h.messages, 2);
      expect(
        h.journal.records.values.where(
          (record) =>
              record['completion_only'] == true && record['retired'] == true,
        ),
        isNotEmpty,
      );
      h.service.dispose();
    },
  );

  testWidgets(
    'an accepted lighting quota transitions to a fresh daily budget without a mismatch halt',
    (tester) async {
      final h = _Harness()
        ..completionOnly = true
        ..holdCompletionFlag = true
        ..actionsPerProgress = 30
        ..likeTarget = 1;
      h.create();
      h.update(autoLike: true);
      await tester.pump(Duration.zero);
      expect(h.likes, 30);
      h.completionOnly = false;
      h.dailyRewardProgress = true;
      h.holdCompletionFlag = false;
      h.likeProgress = 0;
      h.likeTarget = 10;
      await h.advance(tester, 5);
      expect(h.likeBatches, [30, 30]);
      expect(h.service.statusText, isNot(contains('发生变化')));
      h.service.dispose();
    },
  );
  testWidgets(
    'changing the default expression recovers a known unsubmitted configuration halt',
    (tester) async {
      final h = _Harness()
        ..dmTarget = 1
        ..danmakuResultOverride = LiveTaskWriteState.notSubmitted;
      h.create();
      h.update(
        autoDanmaku: true,
        message: '',
        danmakuMessage: const LiveTaskDanmakuMessage.emoticon(
          emoticonUnique: 'old_room',
          roomId: 7,
          anchorUid: 20,
        ),
      );
      await tester.pump(Duration.zero);
      await h.advance(tester, 30);
      expect(h.messages, 0);
      expect(h.messageAttempts, 1);
      expect(h.service.state, LiveTaskAutomationState.paused);
      h.danmakuResultOverride = null;
      const valid = LiveTaskDanmakuMessage.emoticon(
        emoticonUnique: 'current_room',
        roomId: 6,
        anchorUid: 20,
      );
      h.update(autoDanmaku: true, message: '', danmakuMessage: valid);
      await tester.pump(Duration.zero);
      await h.advance(tester, 30);
      expect(h.messages, 1);
      expect(h.messageAttempts, 2);
      expect(h.sentPayload, valid);
      await h.advance(tester, 5);
      expect(h.service.state, LiveTaskAutomationState.completed);
      h.service.dispose();
    },
  );

  testWidgets(
    'changing a default message never releases unknown or server-rejected writes',
    (tester) async {
      for (final result in [
        LiveTaskWriteState.unknown,
        LiveTaskWriteState.rejected,
      ]) {
        final h = _Harness()
          ..reflectProgress = false
          ..danmakuResultOverride = result;
        h.create();
        h.update(autoDanmaku: true, message: '先前消息');
        await tester.pump(Duration.zero);
        await h.advance(tester, 30);
        expect(h.messageAttempts, 1);
        h.danmakuResultOverride = null;
        h.update(autoDanmaku: true, message: '新消息');
        await tester.pump(Duration.zero);
        await h.advance(tester, 60);
        expect(h.messageAttempts, 1, reason: result.name);
        expect(h.service.state, isNot(LiveTaskAutomationState.sending));
        h.service.dispose();
      }
    },
  );
  test(
    'daily reward limits keep rounds distinct from the title interaction quota',
    () {
      final tasks = LiveInteractionParser.fanTasks([
        {
          'title': '点赞30次',
          'add_text': '亲密度+1',
          'sub_title': '每日上限5/10',
          'is_done': 0,
          'jump_type': 'like',
        },
        {
          'title': '发弹幕',
          'add_text': '亲密度+1',
          'sub_title': '每日上限0/10',
          'is_done': 0,
          'jump_type': 'sendDanmu',
        },
        {
          'title': '点赞得30奖励',
          'add_text': '亲密度+30',
          'sub_title': '每日上限5/10',
          'is_done': 0,
          'jump_type': 'like',
        },
      ]);
      expect(tasks.first.currentCount, 5);
      expect(tasks.first.targetCount, 10);
      expect(tasks.first.remainingCount, 5);
      expect(tasks.first.actionsPerProgress, 30);
      expect(tasks.first.dailyRewardProgress, isTrue);
      expect(tasks[1].actionsPerProgress, 1);
      expect(tasks[1].remainingCount, 10);
      expect(tasks[2].actionsPerProgress, isNull);
    },
  );

  testWidgets(
    'remaining daily like rewards send one full round then verify server progress',
    (tester) async {
      final h = _Harness()
        ..dailyRewardProgress = true
        ..actionsPerProgress = 30
        ..likeTarget = 10
        ..likeProgress = 5;
      h.create();
      h.update(autoLike: true);
      await tester.pump(Duration.zero);
      expect(h.likeBatches, [30]);
      for (var i = 0; i < 5; i++) {
        await h.advance(tester, 5);
      }
      expect(h.likeBatches, [30, 30, 30, 30, 30]);
      expect(h.likes, 150);
      expect(h.likeProgress, 10);
      expect(h.service.state, LiveTaskAutomationState.completed);
      final budget = h.journal.records.values.singleWhere(
        (record) => record['type'] == 'like',
      );
      expect(budget['initial_remaining'], 5);
      expect(budget['sent'], 5);
      expect(budget['pending_count'], 0);
      expect(budget['actions_per_progress'], 30);
      h.service.dispose();
    },
  );

  testWidgets(
    'an uncounted daily round never resends and midnight does not reset it',
    (tester) async {
      final h = _Harness()
        ..dailyRewardProgress = true
        ..actionsPerProgress = 30
        ..likeTarget = 10
        ..likeProgress = 5
        ..reflectProgress = false;
      h.create();
      h.update(autoLike: true);
      await tester.pump(Duration.zero);
      for (var i = 0; i < 5; i++) {
        await h.advance(tester, 5);
      }
      expect(h.likeBatches, [30]);
      expect(h.service.state, LiveTaskAutomationState.paused);
      h.likeProgress = 6;
      await h.service.refreshTasks();
      expect(h.likes, 30);
      h.reflectProgress = true;
      await h.advance(tester, 1);
      expect(h.likeBatches, [30, 30]);
      h.service.dispose();
    },
  );

  testWidgets(
    'a completed daily limit can reset only after the server reports a new cycle',
    (tester) async {
      final h = _Harness()
        ..dailyRewardProgress = true
        ..actionsPerProgress = 30
        ..likeTarget = 10
        ..likeProgress = 10;
      h.period = 'cycle-one';
      h.create();
      h.update(autoLike: true);
      await tester.pump(Duration.zero);
      expect(h.likes, 0);
      h.likeProgress = 0;
      h.period = 'cycle-two';
      await h.advance(tester, 30);
      expect(h.likeBatches, [30]);
      h.service.dispose();
    },
  );

  testWidgets(
    'a default expression follows the same random interval and budget as text',
    (tester) async {
      final h = _Harness()..dmTarget = 1;
      h.create();
      const payload = LiveTaskDanmakuMessage.emoticon(
        emoticonUnique: 'room_fixture',
        roomId: 6,
        anchorUid: 20,
      );
      h.update(autoDanmaku: true, message: '', danmakuMessage: payload);
      await tester.pump(Duration.zero);
      await h.advance(tester, 29);
      expect(h.messages, 0);
      await h.advance(tester, 1);
      expect(h.messages, 1);
      expect(h.sentPayload, payload);
      await h.advance(tester, 5);
      expect(h.service.state, LiveTaskAutomationState.completed);
      expect(jsonEncode(h.journal.records), isNot(contains('room_fixture')));
      h.service.dispose();
    },
  );

  test('current official task fields preserve title, progress and is_done', () {
    final task = LiveInteractionParser.fanTasks([
      {
        'title': '直播点赞',
        'add_text': '奖励亲密度 +10',
        'sub_title': '2/10次',
        'is_done': 0,
        'jump_type': 'like',
        'task_id': 7,
      },
    ]).single;
    expect(task.name, '直播点赞');
    expect(task.description, '奖励亲密度 +10');
    expect(task.progressText, '2/10次');
    expect(task.completed, isFalse);
    expect(task.currentCount, 2);
    expect(task.targetCount, 10);
    expect(task.remainingCount, 8);
    expect(task.id, '7');
  });
  test('rewards, ambiguous text, invalid count pairs and wrong units are never targets', () {
    for (final subtitle in [
      '奖励10亲密度',
      '点赞10次得20亲密度',
      '+10',
      '进度 1/5 奖励10',
      '1/5分钟',
      '5/2',
      '1/0',
    ]) {
      expect(
        LiveInteractionParser.fanTasks([
          {'jump_type': 'like', 'sub_title': subtitle, 'is_done': false},
        ]).single.remainingCount,
        isNull,
        reason: subtitle,
      );
    }
    final invalid = LiveInteractionParser.fanTasks([
      {
        'jump_type': 'like',
        'sub_title': '0/20',
        'current_count': -1,
        'target_count': 10,
      },
    ]).single;
    expect(invalid.remainingCount, isNull);
  });
  test(
    'validated structured count pair wins and old constructors remain usable',
    () {
      final task = LiveInteractionParser.fanTasks([
        {
          'jump_type': 'sendDanmu',
          'sub_title': '1/20',
          'current_count': 2,
          'target_count': 4,
          'is_done': false,
        },
      ]).single;
      expect(task.remainingCount, 2);
      const old = LiveFanTask(name: '旧结构', description: '', jumpType: 'like');
      expect(old.remainingCount, isNull);
    },
  );

  testWidgets(
    'completed tasks cause zero writes and only count official completion',
    (tester) async {
      final h = _Harness()
        ..likeProgress = 7
        ..dmProgress = 2;
      h.create();
      h.update(autoLike: true, autoDanmaku: true);
      await tester.pump(Duration.zero);
      expect(h.likes + h.messages, 0);
      expect(h.service.state, LiveTaskAutomationState.completed);
      h.service.dispose();
    },
  );
  testWidgets(
    'likes never exceed remaining budget and verify the count mapping first',
    (tester) async {
      final h = _Harness();
      h.create();
      h.update(autoLike: true);
      await tester.pump(Duration.zero);
      expect(
        h.likes,
        1,
        reason: "${h.service.statusText} ${h.journal.records}",
      );
      expect(h.lastActor, same(h.identity));
      expect(h.sendAllowed, isTrue);
      expect(h.durableBeforeSend, isTrue);
      expect(h.service.state, LiveTaskAutomationState.verifying);
      await h.advance(tester, 5);
      expect(h.likes, 6);
      await h.advance(tester, 5);
      expect(h.likes, 7);
      await h.advance(tester, 5);
      expect(h.service.state, LiveTaskAutomationState.completed);
      await h.advance(tester, 30);
      expect(h.likes, 7);
      h.service.dispose();
    },
  );
  testWidgets(
    'random lower bound is 30 seconds and background playback continues',
    (tester) async {
      final h = _Harness();
      h.create();
      h.update(autoDanmaku: true);
      await tester.pump(Duration.zero);
      await h.advance(tester, 29);
      expect(h.messages, 0);
      // No visibility gate is passed: ongoing playback remains eligible.
      h.update(autoDanmaku: true);
      await h.advance(tester, 1);
      expect(h.messages, 1);
      expect(h.sentMessage, '默认任务弹幕');
      await h.advance(tester, 5);
      await h.advance(tester, 25);
      expect(h.messages, 2);
      await h.advance(tester, 5);
      expect(h.service.state, LiveTaskAutomationState.completed);
      h.service.dispose();
    },
  );
  testWidgets('random upper bound is 60 seconds', (tester) async {
    final h = _Harness()..random = (n) => n - 1;
    h.create();
    h.update(autoDanmaku: true);
    await tester.pump(Duration.zero);
    await h.advance(tester, 59);
    expect(h.messages, 0);
    await h.advance(tester, 1);
    expect(h.messages, 1);
    h.service.dispose();
  });
  testWidgets('missing message or unknown task counts never sends', (
    tester,
  ) async {
    final h = _Harness()..countKnown = false;
    h.create();
    h.update(autoLike: true, autoDanmaku: true);
    await tester.pump(Duration.zero);
    expect(h.service.statusText, contains('数量'));
    await h.advance(tester, 60);
    expect(h.likes + h.messages, 0);
    h.countKnown = true;
    h.update(autoDanmaku: true, message: ' ');
    await tester.pump(Duration.zero);
    expect(h.service.statusText, contains('默认弹幕'));
    expect(h.messages, 0);
    h.service.dispose();
  });
  testWidgets(
    'manual progress before the random deadline reduces automatic sends',
    (tester) async {
      final h = _Harness();
      h.create();
      h.update(autoDanmaku: true);
      await tester.pump(Duration.zero);
      h.dmProgress = 1;
      await h.advance(tester, 30);
      expect(h.messages, 1);
      await h.advance(tester, 5);
      expect(h.service.state, LiveTaskAutomationState.completed);
      h.service.dispose();
    },
  );
  testWidgets(
    'unknown writes stop; late server progress permits only the remaining next action',
    (tester) async {
      final h = _Harness()
        ..reflectProgress = false
        ..returnUnknown = true;
      h.create();
      h.update(autoDanmaku: true);
      await tester.pump(Duration.zero);
      await h.advance(tester, 30);
      for (var i = 0; i < 3; i++) {
        await h.advance(tester, 5);
      }
      expect(h.service.state, LiveTaskAutomationState.paused);
      expect(h.messages, 1);
      await h.advance(tester, 30);
      expect(h.messages, 1);
      h.dmProgress = 1;
      h.reflectProgress = true;
      await h.service.refreshTasks();
      await tester.pump(Duration.zero);
      expect(h.messages, 2);
      await h.advance(tester, 5);
      expect(h.service.state, LiveTaskAutomationState.completed);
      h.service.dispose();
    },
  );
  testWidgets('local midnight never clears an unknown task budget', (
    tester,
  ) async {
    final h = _Harness()
      ..reflectProgress = false
      ..returnUnknown = true;
    h.create();
    h.update(autoLike: true);
    await tester.pump(Duration.zero);
    expect(h.likes, 1);
    await h.advance(tester, 20); // China-calendar midnight passed.
    await h.advance(tester, 30);
    expect(h.likes, 1);
    expect(
      h.journal.records.keys.any((key) => key.contains('unknown-period')),
      isTrue,
    );
    h.service.dispose();
  });
  testWidgets(
    're-entering under a fresh same-UID login reconciles persisted unknown before sending',
    (tester) async {
      final journal = _Journal();
      final old = _Harness(journal)
        ..reflectProgress = false
        ..returnUnknown = true;
      old.create();
      old.update(autoLike: true);
      await tester.pump(Duration.zero);
      expect(old.likes, 1);
      old.service.dispose();
      final next = _Harness(journal)..generation = 9;
      next.create();
      next.update(autoLike: true);
      await tester.pump(Duration.zero);
      expect(next.likes, 0);
      await next.advance(tester, 30);
      expect(next.likes, 0);
      expect(next.service.statusText, contains('核对'));
      expect(jsonEncode(journal.records), isNot(contains('默认任务弹幕')));
      next.service.dispose();
    },
  );
  testWidgets('a disk failure prevents any write', (tester) async {
    final h = _Harness()..journal.failWrite = true;
    h.create();
    h.update(autoLike: true);
    await tester.pump(Duration.zero);
    expect(h.likes, 0);
    expect(h.service.state, LiveTaskAutomationState.paused);
    h.service.dispose();
  });
  testWidgets(
    'server completed then reset task count establishes another period',
    (tester) async {
      final h = _Harness()..likeProgress = 7;
      h.period = 'cycle-one';
      h.create();
      h.update(autoLike: true);
      await tester.pump(Duration.zero);
      expect(h.likes, 0);
      h.likeProgress = 0;
      h.period = 'cycle-two';
      await h.advance(tester, 30);
      expect(h.likes, 1);
      h.service.dispose();
    },
  );
  testWidgets(
    'explicit new server period starts its own budget without replaying old unknown',
    (tester) async {
      final h = _Harness()
        ..reflectProgress = false
        ..returnUnknown = true
        ..period = 'server-day-a';
      h.create();
      h.update(autoLike: true);
      await tester.pump(Duration.zero);
      expect(h.likes, 1);
      h.period = 'server-day-b';
      await h.advance(tester, 5);
      expect(h.likes, 2);
      h.service.dispose();
    },
  );
  testWidgets('pause, enhancement off and dispose cancel scheduled messages', (
    tester,
  ) async {
    final h = _Harness();
    h.create();
    h.update(autoDanmaku: true);
    await tester.pump(Duration.zero);
    h.update(playing: false, autoDanmaku: true);
    await h.advance(tester, 60);
    expect(h.messages, 0);
    h.update(autoDanmaku: true, enhanced: false);
    await h.advance(tester, 60);
    expect(h.messages, 0);
    h.update(autoDanmaku: true);
    await tester.pump(Duration.zero);
    h.service.dispose();
    await h.advance(tester, 60);
    expect(
      h.messages,
      1,
      reason: 'Resume may send the overdue first action before disposal.',
    );
  });
  testWidgets(
    'late read from old account cannot act or replace the new account state',
    (tester) async {
      final h = _Harness();
      h.create();
      final read = Completer<LiveFanTaskSnapshot>();
      final old = h.snapshot;
      h.loadOverride = () => read.future;
      h.update(autoLike: true);
      await tester.pump(Duration.zero);
      h.identity = Object();
      h.uid = 30;
      h.generation++;
      h.likeProgress = 7;
      h.loadOverride = null;
      h.update(autoLike: true);
      read.complete(old);
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      expect(h.likes, 0);
      expect(h.service.accountIdentity, same(h.identity));
      expect(h.service.state, LiveTaskAutomationState.completed);
      h.service.dispose();
    },
  );
  testWidgets('shared send gate deferral consumes no task budget', (
    tester,
  ) async {
    final h = _Harness()..returnDeferred = true;
    h.create();
    h.update(autoDanmaku: true);
    await tester.pump(Duration.zero);
    await h.advance(tester, 30);
    expect(h.messages, 0);
    expect(
      h.journal.records.values
          .where((record) => record['type'] == 'sendDanmu')
          .single['sent'],
      0,
    );
    h.returnDeferred = false;
    await h.advance(tester, 30);
    expect(h.messages, 1);
    h.service.dispose();
  });

  testWidgets(
    'two room instances cannot submit through the journal flush gap',
    (tester) async {
      final journal = _Journal();
      final writingBudget = Completer<void>();
      final releaseBudget = Completer<void>();
      var delayed = false;
      journal.beforeWrite = (key) async {
        if (!key.endsWith(':index') && !delayed) {
          delayed = true;
          writingBudget.complete();
          await releaseBudget.future;
        }
      };
      final first = _Harness(journal)
        ..reflectProgress = false
        ..returnUnknown = true;
      first.create();
      first.update(autoLike: true);
      await tester.pump(Duration.zero);
      expect(writingBudget.isCompleted, isTrue);
      final second = _Harness(journal);
      second.create();
      second.update(autoLike: true);
      await tester.pump(Duration.zero);
      expect(second.reads, 0);
      expect(second.likes, 0);
      releaseBudget.complete();
      await tester.pump(Duration.zero);
      expect(first.likes, 1);
      await second.advance(tester, 5);
      expect(second.reads, greaterThan(0));
      expect(second.likes, 0);
      first.service.dispose();
      second.service.dispose();
    },
  );

  testWidgets('malformed durable index pauses rather than discarding entries', (
    tester,
  ) async {
    for (final keys in [
      <Object>[10],
      <Object>['11:6:20:unknown-period:like:like'],
    ]) {
      final h = _Harness();
      h.journal.records['10:6:20:index'] = {'keys': keys};
      h.create();
      h.update(autoLike: true);
      await tester.pump(Duration.zero);
      expect(h.likes, 0);
      expect(h.service.statusText, contains('本地任务记录无法核对'));
      h.service.dispose();
    }
  });

  testWidgets('a late old-account journal read cannot block the new account', (
    tester,
  ) async {
    final journal = _Journal();
    final old = _Harness(journal)
      ..reflectProgress = false
      ..returnUnknown = true;
    old.create();
    old.update(autoLike: true);
    await tester.pump(Duration.zero);
    old.service.dispose();
    final readingIndex = Completer<void>();
    final releaseIndex = Completer<void>();
    journal.beforeRead = (key) async {
      if (key == '10:6:20:index' && !readingIndex.isCompleted) {
        readingIndex.complete();
        await releaseIndex.future;
      }
    };
    final next = _Harness(journal);
    next.create();
    next.update(autoLike: true);
    await tester.pump(Duration.zero);
    expect(readingIndex.isCompleted, isTrue);
    next.identity = Object();
    next.uid = 11;
    next.generation++;
    next.update(autoLike: true);
    releaseIndex.complete();
    await tester.pump(Duration.zero);
    await tester.pump(Duration.zero);
    expect(next.likes, 1);
    expect(next.lastActor, same(next.identity));
    expect(next.service.statusText, contains('正在核对'));
    next.service.dispose();
  });

  testWidgets(
    'missing official completion flag cannot send even with readable counts',
    (tester) async {
      final h = _Harness()
        ..tasksOverride = const [
          LiveFanTask(
            name: '点赞',
            description: '',
            jumpType: 'like',
            currentCount: 0,
            targetCount: 3,
          ),
        ];
      h.create();
      h.update(autoLike: true);
      await tester.pump(Duration.zero);
      expect(h.likes, 0);
      expect(h.service.statusText, contains('完成状态'));
      h.service.dispose();
    },
  );

  testWidgets('a satisfied count is not an official task completion', (
    tester,
  ) async {
    final h = _Harness()
      ..tasksOverride = const [
        LiveFanTask(
          name: '点赞',
          description: '',
          jumpType: 'like',
          currentCount: 3,
          targetCount: 3,
          completed: false,
        ),
      ];
    h.create();
    h.update(autoLike: true);
    await tester.pump(Duration.zero);
    expect(h.likes, 0);
    expect(h.service.state, isNot(LiveTaskAutomationState.completed));
    expect(h.service.statusText, contains('等待官方'));
    h.service.dispose();
  });
  for (final delay in [1, 3]) {
    testWidgets(
      'paced likes require 30 individual $delay-second intervals before one reward batch',
      (tester) async {
        final h = _Harness()
          ..paceLikes = true
          ..dailyRewardProgress = true
          ..actionsPerProgress = 30
          ..likeTarget = 1
          ..random = (upper) => delay == 1 ? 0 : upper - 1;
        h.create();
        h.update(autoLike: true);
        await tester.pump();
        for (var second = 0; second < 30 * delay - 1; second++) {
          await h.advance(tester, 1);
          expect(h.likes, 0);
        }
        await h.advance(tester, 1);
        expect(h.likeBatches, [30]);
        expect(h.durableBeforeSend, isTrue);
        for (var second = 0; second < 6; second++) {
          await h.advance(tester, 1);
        }
        expect(h.service.state, LiveTaskAutomationState.completed);
        h.service.dispose();
      },
    );
  }

  testWidgets(
    'due danmaku proceeds while slow reward-round clicks accumulate',
    (tester) async {
      final h = _Harness()
        ..paceLikes = true
        ..dailyRewardProgress = true
        ..actionsPerProgress = 30
        ..likeTarget = 1
        ..random = (upper) => upper == 3 ? 2 : 0;
      h.create();
      h.update(autoLike: true, autoDanmaku: true);
      await tester.pump();
      for (var i = 0; i < 30; i++) {
        await h.advance(tester, 1);
      }
      expect(h.messages, 1);
      expect(h.likes, 0);
      for (var i = 0; i < 62; i++) {
        await h.advance(tester, 1);
      }
      expect(h.messages, 2);
      expect(h.likeBatches, [30]);
      h.service.dispose();
    },
  );

  testWidgets(
    'cancelled paced accumulation never submits or consumes a durable budget',
    (tester) async {
      final h = _Harness()
        ..paceLikes = true
        ..dailyRewardProgress = true
        ..actionsPerProgress = 30
        ..likeTarget = 1;
      h.create();
      h.update(autoLike: true);
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await h.advance(tester, 1);
      }
      h.service.stop();
      await h.advance(tester, 120);
      expect(h.likes, 0);
      expect(
        h.journal.records.values.where(
          (record) => (record['sent'] as int? ?? 0) > 0,
        ),
        isEmpty,
      );
      h.service.dispose();
    },
  );

  testWidgets(
    'unknown selected emote is reconciled without another random choice',
    (tester) async {
      final h = _Harness()
        ..returnUnknown = true
        ..reflectProgress = false;
      var choices = 0;
      h.chooseDanmaku = (identity, allowed) async {
        choices++;
        return const LiveTaskDanmakuMessage.emoticon(
          emoticonUnique: 'selected-a',
          roomId: 6,
          anchorUid: 20,
        );
      };
      h.create();
      h.update(autoDanmaku: true);
      await tester.pump();
      await h.advance(tester, 30);
      expect(choices, 1);
      for (var i = 0; i < 5; i++) {
        await h.advance(tester, 30);
      }
      expect(choices, 1);
      expect(h.messageAttempts, 1);
      h.service.dispose();
    },
  );

  testWidgets(
    'privacy change during candidate selection cancels before journaling or submission',
    (tester) async {
      final h = _Harness();
      h.chooseDanmaku = (identity, allowed) async {
        h.permitted = false;
        return const LiveTaskDanmakuMessage.text('selected');
      };
      h.create();
      h.update(autoDanmaku: true);
      await tester.pump();
      await h.advance(tester, 30);
      expect(h.messageAttempts, 0);
      expect(
        h.journal.records.values.where(
          (record) => (record['pending_count'] as int? ?? 0) > 0,
        ),
        isEmpty,
      );
      h.service.dispose();
    },
  );
}

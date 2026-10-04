import 'package:PiliPlus/pages/dynamics/widgets/live_intimacy_statistics_entry.dart';
import 'package:PiliPlus/pages/setting/pages/live_intimacy_statistics.dart';
import 'package:PiliPlus/pages/live_room/widgets/live_intimacy_progress_widgets.dart';
import 'package:PiliPlus/services/live_intimacy_statistics.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:PiliPlus/utils/live_intimacy_statistics_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../services/live_intimacy_scheduler_test.dart' as fixture;

void main() {
  late LiveIntimacyStatisticsPreferences display;
  late Map<int, bool> shown;
  setUp(() {
    shown = {};
    display = LiveIntimacyStatisticsPreferences(
      read: (uid) => shown[uid] ?? false,
      write: (uid, enabled) async => shown[uid] = enabled,
    );
  });
  tearDown(() => display.dispose());

  test(
    'display consent is default off, account scoped, and cleared independently',
    () async {
      expect(display.enabledFor(1), isFalse);
      await display.setEnabled(1, true);
      expect(display.enabledFor(1), isTrue);
      expect(display.enabledFor(2), isFalse);
      await display.setEnabled(0, true);
      expect(shown.containsKey(0), isFalse);
      await display.clearFor(1);
      expect(display.enabledFor(1), isFalse);
    },
  );

  test('authorization is the statistics universe; like-only completion is distinct from all three', () async {
    final h = fixture.Harness([
      fixture.room(1).copyWith(mode: LiveIntimacyRoomMode.likeOnly),
      fixture.room(2),
      fixture.room(3, authorized: false),
    ]);
    h.taskStates[1] = fixture.taskSet(done: true);
    h.taskStates[2] = fixture.taskSet(done: true, watchDone: true);
    await h.tick();
    final summary = LiveIntimacyStatistics.fromScheduler(h.scheduler);
    expect(summary.total, 2);
    expect(summary.completed, 2);
    expect(summary.allThreeCompleted, 1);
    expect(summary.state, LiveIntimacyOverviewState.completed);
    h.scheduler
        .stateFor(20, 2)!
        .watchProgress
        .synchronizationFailed('network failure');
    h.scheduler.stateFor(20, 2)!.officialFresh = false;
    final failed = LiveIntimacyStatistics.fromScheduler(h.scheduler);
    expect(failed.completed, 1);
    expect(failed.unknown, 1);
    expect(failed.issues, 1);
    await h.close();
  });

  test('zero authorized rooms never reports completion and stale completion cannot override master off', () async {
    final h = fixture.Harness([], enabled: false);
    await h.tick();
    final summary = LiveIntimacyStatistics.fromScheduler(h.scheduler);
    expect(summary.total, 0);
    expect(summary.state, LiveIntimacyOverviewState.disabled);
    await h.scheduler.savePreferences(
      h.scheduler.preferences.copyWith(enabled: true),
    );
    expect(
      LiveIntimacyStatistics.fromScheduler(h.scheduler).state,
      LiveIntimacyOverviewState.waiting,
    );
    await h.close();
  });

  test('paused interactions cannot impersonate active work during an audio failure', () async {
    final h = fixture.Harness([fixture.room(1)]);
    await h.tick();
    final state = h.scheduler.stateFor(10, 1)!
      ..watchRunning = false
      ..interactionRunning = false
      ..interactionPauseReason = '任务数量待核对';
    expect(
      LiveIntimacyStatistics.fromScheduler(h.scheduler).state,
      isNot(LiveIntimacyOverviewState.running),
    );
    state
      ..interactionPauseReason = null
      ..interactionRunning = true;
    expect(
      LiveIntimacyStatistics.fromScheduler(h.scheduler).state,
      LiveIntimacyOverviewState.running,
    );
    await h.close();
  });

  test(
    'an interaction session with unknown counts is not active work',
    () async {
      final h = fixture.Harness([fixture.room(1)]);
      await h.tick();
      final state = h.scheduler.stateFor(10, 1)!
        ..watchRunning = false
        ..interactionRunning = true
        ..interactionPauseReason = null
        ..tasks = [
          ...fixture
              .taskSet(done: true, watchDone: true)
              .where(
                (task) => task.jumpType != 'sendDanmu',
              ),
          const LiveFanTask(
            name: '发弹幕',
            description: '',
            jumpType: 'sendDanmu',
            completed: false,
          ),
        ];
      expect(state.canAdvanceInteraction, isFalse);
      expect(
        LiveIntimacyStatistics.fromScheduler(h.scheduler).state,
        isNot(LiveIntimacyOverviewState.running),
      );
      expect(liveIntimacyRoomStatusSummary(state), isNot(contains('正在执行互动任务')));
      await h.close();
    },
  );

  test(
    'room panel summary never declares stale cached tasks complete',
    () async {
      final h = fixture.Harness([fixture.room(1)], enabled: false);
      await h.tick();
      final state = h.scheduler.stateFor(10, 1)!
        ..completed = true
        ..tasks = fixture.taskSet(done: true, watchDone: true)
        ..officialFresh = false
        ..watchPauseReason = '音频暂时不可用'
        ..interactionPauseReason = '任务数量待核对';
      final label = liveIntimacyRoomStatusSummary(state);
      expect(label, contains('待核对'));
      expect(label, contains('音频暂时不可用'));
      expect(label, contains('任务数量待核对'));
      expect(label, isNot(contains('三项任务均已由官方确认完成')));
      await h.close();
    },
  );

  test(
    'Local save failure remains separate from official synchronization',
    () async {
      final h = fixture.Harness([fixture.room(1)]);
      await h.tick();
      final state = h.scheduler.stateFor(10, 1)!
        ..recordSaveError = '本地观时记录保存失败';
      expect(state.officialFresh, isTrue);
      expect(LiveIntimacyStatistics.hasIssue(state), isTrue);
      expect(liveIntimacyRoomStatusSummary(state), contains('本地观时记录保存失败'));
      state
        ..recordSaveError = null
        ..recordRestoreError = '本地观时记录读取失败';
      expect(LiveIntimacyStatistics.hasIssue(state), isTrue);
      expect(liveIntimacyRoomStatusSummary(state), contains('本地观时记录读取失败'));
      state.recordRestoreError = null;
      expect(LiveIntimacyStatistics.hasIssue(state), isFalse);
      await h.close();
    },
  );

  testWidgets(
    'entry requires both settings; empty live list still has accessible entry without starting tasks',
    (tester) async {
      final h = fixture.Harness([], enabled: false);
      await h.tick();
      addTearDown(h.close);
      var opened = 0;
      Future<void> mount(bool expanded) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveIntimacyStatisticsEntry(
              expandSetting: expanded,
              scheduler: h.scheduler,
              display: display,
              onOpen: () => ++opened,
            ),
          ),
        ),
      );
      final entry = find.byKey(
        const ValueKey('dynamic-live-intimacy-statistics-entry'),
      );
      await mount(true);
      expect(entry, findsNothing);
      await display.setEnabled(1, true);
      await tester.pump();
      expect(entry, findsOneWidget);
      expect(find.text('0/0'), findsOneWidget);
      final rect = tester.getRect(entry);
      expect(rect.width, greaterThanOrEqualTo(48));
      expect(rect.height, greaterThanOrEqualTo(48));
      await tester.tap(entry);
      expect(opened, 1);
      expect(h.sessions, isEmpty);
      await mount(false);
      expect(entry, findsNothing);
    },
  );

  testWidgets(
    'narrow top and side entries remain legible under large text and counts',
    (tester) async {
      final h = fixture.Harness([
        for (var i = 1; i <= 110; ++i) fixture.room(i),
      ], enabled: false);
      await h.tick();
      addTearDown(h.close);
      await display.setEnabled(1, true);
      for (final top in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: SizedBox(
                  width: 64,
                  height: 76,
                  child: LiveIntimacyStatisticsEntry(
                    expandSetting: true,
                    isTop: top,
                    scheduler: h.scheduler,
                    display: display,
                    onOpen: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.text('统计'), findsOneWidget);
        expect(find.byType(Tooltip), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'panel retains all authorized offline rooms and hiding it leaves task grants intact',
    (tester) async {
      final h = fixture.Harness([
        fixture.room(1),
        fixture.room(2, authorized: false),
      ], enabled: false);
      await h.tick();
      addTearDown(h.close);
      await display.setEnabled(1, true);
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: LiveIntimacyStatisticsPage(
            scheduler: h.scheduler,
            display: display,
          ),
        ),
      );
      expect(find.text('已授权 1'), findsOneWidget);
      expect(find.text('授权任务完成 0/1'), findsOneWidget);
      await display.setEnabled(1, false);
      await tester.pump();
      expect(find.text('亲密度任务统计展示已关闭'), findsOneWidget);
      expect(h.scheduler.preferences.rooms.first.authorized, isTrue);
      expect(h.scheduler.preferences.enabled, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

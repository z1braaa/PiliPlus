import 'dart:async';

import 'package:PiliPlus/pages/live_room/widgets/interaction_panel.dart';
import 'package:PiliPlus/services/live_task_automation.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/utils/live_viewer_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Automation extends ChangeNotifier implements LiveTaskAutomationService {
  final identity = Object();
  @override
  Object get accountIdentity => identity;
  bool disposed = false;
  String message = '任务数量尚未确认，自动操作已暂停';
  List<LiveFanTask> currentTasks = [];
  @override
  List<LiveFanTask> get tasks => currentTasks;
  @override
  String get statusText => message;
  @override
  String? get error => null;
  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Interactions extends Fake implements LiveInteractionService {
  final identity = Object();
  @override
  Object get accountIdentity => identity;
  @override
  int get roomId => 6;
  @override
  int get anchorUid => 10;
  @override
  bool get isLoggedIn => true;
  @override
  LiveActionResult? get lastAction => null;
  @override
  Future<LiveInteractionSnapshot> loadPanel() async =>
      const LiveInteractionSnapshot(
        roomId: 6,
        anchorUid: 10,
        accountUid: 20,
        loggedIn: true,
      );
  @override
  void invalidateApprovals() {}
  @override
  void dispose() {}
}

void main() {
  late _Automation service;
  late LiveTaskAutomationPreferences preferences;
  late List<LiveTaskAutomationPreferences> changes;
  setUp(() {
    service = _Automation();
    preferences = const LiveTaskAutomationPreferences();
    changes = [];
  });
  tearDown(() => service.dispose());

  Future<void> mount(
    WidgetTester tester, {
    bool loggedIn = true,
    bool snapshotReady = true,
    int roomId = 6,
    int anchorUid = 10,
    Future<List<LiveTaskEmoticonOption>> Function()? loadEmoticons,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SingleChildScrollView(
            child: LiveTaskAutomationControls(
              service: service,
              preferences: preferences,
              loggedIn: loggedIn,
              snapshotReady: snapshotReady,
              roomId: roomId,
              anchorUid: anchorUid,
              loadEmoticons: loadEmoticons,
              onChanged: (value) {
                changes.add(value);
                setState(() => preferences = value);
              },
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('two switches default off and remember independently', (
    tester,
  ) async {
    await mount(tester);
    final like = find.byKey(const ValueKey('live-auto-like'));
    final danmaku = find.byKey(const ValueKey('live-auto-danmaku'));
    expect(tester.widget<SwitchListTile>(like).value, isFalse);
    expect(tester.widget<SwitchListTile>(danmaku).value, isFalse);
    expect(find.text('30–60 秒'), findsOneWidget);
    await tester.tap(like);
    await tester.pump();
    expect(preferences.autoLike, isTrue);
    expect(preferences.autoDanmaku, isFalse);
    await tester.tap(danmaku);
    await tester.pump();
    expect(preferences.autoLike, isTrue);
    expect(preferences.autoDanmaku, isTrue);
    expect(find.text('设置默认弹幕后执行；当前等待设置'), findsOneWidget);
    expect(changes.length, 2);
  });

  testWidgets('editing a default message saves only after confirmation', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('live-default-danmaku')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('live-default-danmaku-editor')),
      '  大家晚上好  ',
    );
    expect(changes, isEmpty);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(preferences.defaultMessage, '大家晚上好');
    expect(preferences.autoDanmaku, isFalse);
    expect(find.text('大家晚上好'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('interval editing rejects inverted range before saving', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('live-danmaku-interval')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('live-interval-minimum')),
      '90',
    );
    await tester.enterText(
      find.byKey(const ValueKey('live-interval-maximum')),
      '30',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('最长间隔不能小于最短间隔'), findsOneWidget);
    expect(changes, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('live-interval-minimum')),
      '45',
    );
    await tester.enterText(
      find.byKey(const ValueKey('live-interval-maximum')),
      '75',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(preferences.minIntervalSeconds, 45);
    expect(preferences.maxIntervalSeconds, 75);
    expect(find.text('45–75 秒'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selects available fan-club emoticons and keeps saved text', (
    tester,
  ) async {
    preferences = const LiveTaskAutomationPreferences(
      defaultMessage: '保存的文字',
    );
    var loads = 0;
    await mount(
      tester,
      loadEmoticons: () async {
        ++loads;
        return const [
          LiveTaskEmoticonOption(
            unique: 'official_1',
            label: '官方表情',
            available: true,
            packageName: '官方表情包',
          ),
          LiveTaskEmoticonOption(
            unique: 'room_6_1',
            label: '粉丝团点赞',
            available: true,
            packageName: '主播粉丝团',
            isFanClub: true,
          ),
          LiveTaskEmoticonOption(
            unique: 'room_6_2',
            label: '尚未解锁',
            available: false,
            packageName: '主播粉丝团',
            isFanClub: true,
          ),
        ];
      },
    );
    await tester.tap(find.byKey(const ValueKey('live-danmaku-mode-emoticon')));
    await tester.pumpAndSettle();
    expect(preferences.danmakuMode, LiveTaskDanmakuMode.emoticon);
    expect(loads, 0);
    await tester.tap(find.byKey(const ValueKey('live-default-emoticon')));
    await tester.pumpAndSettle();
    expect(loads, 1);
    final fan = find.byKey(const ValueKey('live-emoticon-option:room_6_1'));
    final official = find.byKey(
      const ValueKey('live-emoticon-option:official_1'),
    );
    expect(tester.getTopLeft(fan).dy, lessThan(tester.getTopLeft(official).dy));
    final unavailable = tester.widget<ListTile>(
      find.byKey(const ValueKey('live-emoticon-option:room_6_2')),
    );
    expect(unavailable.enabled, isFalse);
    expect(unavailable.onTap, isNull);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(fan);
    await tester.pumpAndSettle();
    expect(preferences.defaultEmoticonUnique, 'room_6_1');
    expect(preferences.defaultEmoticonName, '粉丝团点赞');
    expect(preferences.defaultEmoticonRoomId, 6);
    expect(preferences.defaultEmoticonAnchorUid, 10);
    expect(preferences.defaultMessage, '保存的文字');
    expect(preferences.autoDanmaku, isFalse);
    await tester.tap(find.byKey(const ValueKey('live-danmaku-mode-text')));
    await tester.pumpAndSettle();
    expect(find.text('保存的文字'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a saved emoticon cannot silently follow another room', (
    tester,
  ) async {
    preferences = const LiveTaskAutomationPreferences(
      autoDanmaku: true,
      danmakuMode: LiveTaskDanmakuMode.emoticon,
      defaultEmoticonUnique: 'room_6_1',
      defaultEmoticonName: '粉丝团点赞',
      defaultEmoticonRoomId: 6,
      defaultEmoticonAnchorUid: 10,
    );
    await mount(tester, roomId: 7, anchorUid: 11);
    expect(find.text('表情与当前直播间不匹配，自动操作暂停'), findsOneWidget);
    expect(find.text('已保存表情属于其他直播间，请重新选择'), findsOneWidget);
    expect(changes, isEmpty);
  });

  testWidgets(
    'room changes close the picker before a late result can be saved',
    (
      tester,
    ) async {
      preferences = const LiveTaskAutomationPreferences(
        danmakuMode: LiveTaskDanmakuMode.emoticon,
      );
      final result = Completer<List<LiveTaskEmoticonOption>>();
      await mount(tester, loadEmoticons: () => result.future);
      await tester.tap(find.byKey(const ValueKey('live-default-emoticon')));
      await tester.pump();
      await mount(tester, roomId: 7, anchorUid: 11);
      await tester.pumpAndSettle();
      result.complete(const [
        LiveTaskEmoticonOption(
          unique: 'room_6_1',
          label: '旧直播间表情',
          available: true,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('旧直播间表情'), findsNothing);
      expect(changes, isEmpty);
      expect(preferences.defaultEmoticonRoomId, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('account refresh discards an outstanding emoticon selection', (
    tester,
  ) async {
    preferences = const LiveTaskAutomationPreferences(
      danmakuMode: LiveTaskDanmakuMode.emoticon,
    );
    final result = Completer<List<LiveTaskEmoticonOption>>();
    await mount(tester, loadEmoticons: () => result.future);
    await tester.tap(find.byKey(const ValueKey('live-default-emoticon')));
    await tester.pump();
    await mount(tester, snapshotReady: false);
    await tester.pumpAndSettle();
    result.complete(const [
      LiveTaskEmoticonOption(
        unique: 'room_6_1',
        label: '旧账号表情',
        available: true,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('旧账号表情'), findsNothing);
    expect(changes, isEmpty);
    expect(preferences.defaultEmoticonUnique, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed emoticon reads can be retried without saving a choice', (
    tester,
  ) async {
    preferences = const LiveTaskAutomationPreferences(
      danmakuMode: LiveTaskDanmakuMode.emoticon,
    );
    var loads = 0;
    await mount(
      tester,
      loadEmoticons: () async {
        if (++loads == 1) throw StateError('read failed');
        return const [
          LiveTaskEmoticonOption(
            unique: 'room_6_1',
            label: '重试取得的表情',
            available: true,
          ),
        ];
      },
    );
    await tester.tap(find.byKey(const ValueKey('live-default-emoticon')));
    await tester.pumpAndSettle();
    expect(find.text('表情加载失败，请重试'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('live-emoticon-retry')));
    await tester.pumpAndSettle();
    expect(find.text('重试取得的表情'), findsOneWidget);
    expect(loads, 2);
    expect(changes, isEmpty);
    expect(preferences.defaultEmoticonUnique, isEmpty);
  });

  testWidgets(
    'service status updates and closing controls never stops automation',
    (tester) async {
      await mount(tester);
      expect(find.text(service.message), findsOneWidget);
      service
        ..message = '已完成当前亲密度任务'
        ..notifyListeners();
      await tester.pump();
      expect(find.text(service.message), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(service.disposed, isFalse);
      expect(changes, isEmpty);
    },
  );

  testWidgets('guest controls remain disabled', (tester) async {
    await mount(tester, loggedIn: false);
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const ValueKey('live-auto-like')))
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('live-auto-danmaku')),
          )
          .onChanged,
      isNull,
    );
    expect(find.text('登录后可开启自动任务。'), findsOneWidget);
    expect(
      tester
          .widget<SegmentedButton<LiveTaskDanmakuMode>>(
            find.byType(SegmentedButton<LiveTaskDanmakuMode>),
          )
          .onSelectionChanged,
      isNull,
    );
  });

  testWidgets(
    'account change cancels the open draft until current tasks load',
    (
      tester,
    ) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('live-default-danmaku')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('live-default-danmaku-editor')),
        '旧账号草稿',
      );
      await mount(tester, snapshotReady: false);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('live-default-danmaku-editor')),
        findsNothing,
      );
      expect(find.text('账号任务状态正在刷新，自动操作暂停。'), findsOneWidget);
      expect(changes, isEmpty);
      expect(preferences.defaultMessage, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('fan panel uses fresh task progress and retry delegates once', (
    tester,
  ) async {
    final session = LiveInteractionSession(
      service: _Interactions(),
      isEnabled: () => true,
    );
    service.currentTasks = const [
      LiveFanTask(
        name: '点赞任务',
        description: '每日点赞',
        jumpType: 'like',
        currentCount: 3,
        targetCount: 5,
      ),
      LiveFanTask(
        name: '弹幕任务',
        description: '每日发送弹幕',
        jumpType: 'sendDanmu',
      ),
    ];
    var retries = 0;
    Widget panel({bool canRetry = true}) => MaterialApp(
      home: Scaffold(
        body: LiveInteractionPanel(
          session: session,
          anchorName: '主播',
          initialTab: 2,
          taskAutomation: service,
          watchStatusText: '观看上报暂不可用',
          onWatchRetry: () => retries++,
          watchCanRetry: canRetry,
          onLogin: () {},
          onRecharge: () async {},
          onOpenGuard: () async {},
        ),
      ),
    );
    await tester.pumpWidget(panel());
    await tester.pumpAndSettle();
    expect(find.text('每日点赞\n进度 3 / 5'), findsOneWidget);
    expect(find.text('每日发送弹幕\n数量尚未确认，自动操作暂停'), findsOneWidget);
    final retry = find.byTooltip('重试观看上报');
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    expect(retries, 1);
    await tester.pumpWidget(panel(canRetry: false));
    await tester.pumpAndSettle();
    expect(find.byTooltip('重试观看上报'), findsNothing);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(service.disposed, isFalse);
    session.dispose();
  });

  testWidgets(
    'scheduler task updates replace legacy display, including an unknown empty response',
    (tester) async {
      final session = LiveInteractionSession(
        service: _Interactions(),
        isEnabled: () => true,
      );
      service.currentTasks = const [
        LiveFanTask(
          name: '旧任务',
          description: '',
          jumpType: 'like',
          currentCount: 1,
          targetCount: 10,
        ),
      ];
      final latest = ValueNotifier<List<LiveFanTask>>(const [
        LiveFanTask(
          name: '当前任务',
          description: '',
          jumpType: 'like',
          currentCount: 3,
          targetCount: 10,
        ),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveInteractionPanel(
              session: session,
              anchorName: '主播',
              initialTab: 2,
              taskAutomation: service,
              intimacyControls: const Text('此房间独立配置'),
              watchStatusText: '观看上报交由后台亲密度任务',
              intimacyUpdates: latest,
              intimacyTasks: () => latest.value,
              onLogin: () {},
              onRecharge: () async {},
              onOpenGuard: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('进度 3 / 10'), findsOneWidget);
      expect(find.text('旧任务'), findsNothing);
      expect(find.text('正常观看上报'), findsOneWidget);
      expect(find.text('观看上报交由后台亲密度任务'), findsOneWidget);
      latest.value = const [
        LiveFanTask(
          name: '当前任务',
          description: '',
          jumpType: 'like',
          currentCount: 10,
          targetCount: 10,
          completed: true,
        ),
      ];
      await tester.pumpAndSettle();
      expect(find.text('进度 10 / 10'), findsOneWidget);
      latest.value = const [];
      await tester.pumpAndSettle();
      expect(find.text('进度 10 / 10'), findsNothing);
      expect(find.text('旧任务'), findsNothing);
      expect(find.text('当前没有可展示的任务；每日规则以官方页面为准。'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      session.dispose();
      latest.dispose();
    },
  );
}

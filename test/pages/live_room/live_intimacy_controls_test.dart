import 'dart:async';

import 'package:PiliPlus/pages/live_room/widgets/live_intimacy_controls.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:PiliPlus/utils/live_viewer_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late LiveIntimacyRoomPreferences preferences;
  late Object identity;
  late int generation;
  late List<LiveIntimacyRoomPreferences> saves;
  late List<bool> authorizations;
  late StateSetter rebuild;
  setUp(() {
    preferences = const LiveIntimacyRoomPreferences(roomId: 6, anchorUid: 10);
    identity = Object();
    generation = 0;
    saves = [];
    authorizations = [];
  });

  Future<void> mount(
    WidgetTester tester, {
    Future<List<LiveTaskEmoticonOption>> Function()? load,
    Future<String?> Function(LiveIntimacyRoomPreferences, bool)? authorize,
    bool loggedIn = true,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return SingleChildScrollView(
              child: LiveIntimacyRoomControls(
                preferences: preferences,
                loggedIn: loggedIn,
                accountIdentity: identity,
                accountGeneration: generation,
                loadEmoticons: load ?? () async => [],
                onChanged: (value) async {
                  saves.add(value);
                  setState(() => preferences = value);
                },
                onAuthorize: (value, enabled) async {
                  if (authorize != null) return authorize(value, enabled);
                  authorizations.add(enabled);
                  setState(
                    () => preferences = value.copyWith(authorized: enabled),
                  );
                  return null;
                },
              ),
            );
          },
        ),
      ),
    ),
  );

  testWidgets('manual room authorization fails until current mode configured', (
    tester,
  ) async {
    await mount(tester);
    final authorization = find.byKey(
      const ValueKey('live-intimacy-room-authorized'),
    );
    expect(tester.widget<SwitchListTile>(authorization).value, isFalse);
    await tester.tap(authorization);
    await tester.pumpAndSettle();
    expect(find.text('请先开启自动点赞'), findsOneWidget);
    expect(authorizations, isEmpty);
    await tester.tap(find.byKey(const ValueKey('live-intimacy-auto-like')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('live-intimacy-auto-danmaku')));
    await tester.pumpAndSettle();
    await tester.tap(authorization);
    await tester.pumpAndSettle();
    expect(find.text('请先设置自动发送文字'), findsOneWidget);
    rebuild(
      () => preferences = preferences.copyWith(
        automation: preferences.automation.copyWith(defaultMessage: '晚上好'),
      ),
    );
    await tester.pump();
    await tester.tap(authorization);
    await tester.pumpAndSettle();
    expect(authorizations, [true]);
    expect(preferences.authorized, isTrue);
    expect(find.text('已授权；在其他设置开启总开关后运行'), findsOneWidget);
  });

  testWidgets(
    'like-only authorizes without message or emote permission and mode upgrade revokes grant',
    (tester) async {
      preferences = preferences.copyWith(
        mode: LiveIntimacyRoomMode.likeOnly,
        automation: const LiveTaskAutomationPreferences(autoLike: true),
      );
      var loads = 0;
      await mount(
        tester,
        load: () async {
          ++loads;
          return [];
        },
      );
      expect(find.byKey(const ValueKey('live-intimacy-content')), findsNothing);
      expect(
        find.byKey(const ValueKey('live-intimacy-auto-danmaku')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('live-intimacy-room-authorized')),
      );
      await tester.pumpAndSettle();
      expect(authorizations, [true]);
      expect(loads, 0);
      expect(preferences.authorized, isTrue);
      await tester.tap(find.byKey(const ValueKey('live-intimacy-room-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完整任务').last);
      await tester.pumpAndSettle();
      expect(preferences.mode, LiveIntimacyRoomMode.full);
      expect(preferences.authorized, isFalse);
      expect(preferences.automation.autoDanmaku, isFalse);
      expect(
        find.byKey(const ValueKey('live-intimacy-auto-danmaku')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('inactive text cannot authorize invalid emoticon pool', (
    tester,
  ) async {
    preferences = preferences.copyWith(
      automation: const LiveTaskAutomationPreferences(
        autoLike: true,
        autoDanmaku: true,
        defaultMessage: '保存的文字',
        danmakuMode: LiveTaskDanmakuMode.emoticon,
      ),
    );
    await mount(tester);
    await tester.tap(
      find.byKey(const ValueKey('live-intimacy-room-authorized')),
    );
    await tester.pumpAndSettle();
    expect(authorizations, isEmpty);
    expect(find.text('请选择1～5个自动发送表情'), findsOneWidget);
  });

  testWidgets(
    'room can be configured in small and large windows without granting permission',
    (tester) async {
      for (final size in [const Size(360, 500), const Size(1280, 900)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await mount(tester);
        final content = find.byKey(const ValueKey('live-intimacy-content'));
        await tester.ensureVisible(content);
        await tester.tap(content);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('live-intimacy-message-editor')),
          ' 保存的文字 ',
        );
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(preferences.automation.defaultMessage, '保存的文字');
        expect(preferences.authorized, isFalse);
        expect(authorizations, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );

  testWidgets(
    'pool accepts five unique selections, refuses sixth, saves atomically',
    (tester) async {
      preferences = preferences.copyWith(
        automation: const LiveTaskAutomationPreferences(
          danmakuMode: LiveTaskDanmakuMode.emoticon,
        ),
      );
      await mount(
        tester,
        load: () async => [
          for (var i = 0; i < 6; ++i)
            LiveTaskEmoticonOption(
              unique: 'e$i',
              label: '表情$i',
              available: true,
            ),
        ],
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('live-intimacy-content')),
      );
      await tester.tap(find.byKey(const ValueKey('live-intimacy-content')));
      await tester.pumpAndSettle();
      for (var i = 0; i < 6; ++i) {
        final option = find.byKey(ValueKey('live-intimacy-emoticon:e$i'));
        await tester.ensureVisible(option);
        await tester.tap(option);
        await tester.pumpAndSettle();
      }
      expect(find.text('随机发送表情 · 5/5'), findsOneWidget);
      expect(find.text('最多选择5个表情'), findsOneWidget);
      expect(saves, isEmpty);
      await tester.tap(
        find.byKey(const ValueKey('live-intimacy-emoticon-save')),
      );
      await tester.pumpAndSettle();
      expect(preferences.emoticons.map((e) => e.unique), [
        'e0',
        'e1',
        'e2',
        'e3',
        'e4',
      ]);
      expect(preferences.authorized, isFalse);
    },
  );

  testWidgets(
    'partial invalid pool keeps choices, but all-invalid blocks authorization',
    (tester) async {
      preferences = preferences.copyWith(
        automation: const LiveTaskAutomationPreferences(
          autoLike: true,
          autoDanmaku: true,
          danmakuMode: LiveTaskDanmakuMode.emoticon,
        ),
        emoticons: const [
          LiveIntimacyEmoticonSelection(unique: 'old', label: '旧表情'),
        ],
      );
      await mount(
        tester,
        load: () async => const [
          LiveTaskEmoticonOption(unique: 'old', label: '旧表情', available: false),
        ],
      );
      await tester.tap(
        find.byKey(const ValueKey('live-intimacy-room-authorized')),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选表情均不可发送，自动任务暂停'), findsOneWidget);
      expect(preferences.emoticons.single.unique, 'old');
      expect(authorizations, isEmpty);
    },
  );

  testWidgets(
    'clearing the last candidate preserves authorization and waits for configuration',
    (tester) async {
      preferences = preferences.copyWith(
        authorized: true,
        automation: const LiveTaskAutomationPreferences(
          autoLike: true,
          autoDanmaku: true,
          danmakuMode: LiveTaskDanmakuMode.emoticon,
        ),
        emoticons: const [
          LiveIntimacyEmoticonSelection(unique: 'one', label: '一'),
        ],
      );
      await mount(
        tester,
        load: () async => const [
          LiveTaskEmoticonOption(unique: 'one', label: '一', available: true),
        ],
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('live-intimacy-content')),
      );
      await tester.tap(find.byKey(const ValueKey('live-intimacy-content')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('live-intimacy-emoticon:one')),
      );
      await tester.tap(
        find.byKey(const ValueKey('live-intimacy-emoticon-save')),
      );
      await tester.pumpAndSettle();
      expect(preferences.emoticons, isEmpty);
      expect(preferences.authorized, isTrue);
      expect(preferences.configurationIssue(), contains('1～5'));
      expect(authorizations, isEmpty);
    },
  );

  testWidgets(
    'account change removes an open editor before an old result can persist',
    (tester) async {
      final load = Completer<List<LiveTaskEmoticonOption>>();
      preferences = preferences.copyWith(
        automation: const LiveTaskAutomationPreferences(
          danmakuMode: LiveTaskDanmakuMode.emoticon,
        ),
      );
      await mount(tester, load: () => load.future);
      await tester.ensureVisible(
        find.byKey(const ValueKey('live-intimacy-content')),
      );
      await tester.tap(find.byKey(const ValueKey('live-intimacy-content')));
      await tester.pump();
      expect(find.byType(LiveIntimacyEmoticonPicker), findsOneWidget);
      rebuild(() {
        identity = Object();
        ++generation;
      });
      await tester.pump();
      load.complete(const [
        LiveTaskEmoticonOption(unique: 'one', label: '一', available: true),
      ]);
      await tester.pumpAndSettle();
      expect(find.byType(LiveIntimacyEmoticonPicker), findsNothing);
      expect(saves, isEmpty);
      expect(preferences.emoticons, isEmpty);
    },
  );

  testWidgets(
    'account transition discards late editor and permission responses',
    (tester) async {
      final load = Completer<List<LiveTaskEmoticonOption>>();
      preferences = preferences.copyWith(
        automation: const LiveTaskAutomationPreferences(
          autoLike: true,
          autoDanmaku: true,
          danmakuMode: LiveTaskDanmakuMode.emoticon,
        ),
        emoticons: const [
          LiveIntimacyEmoticonSelection(unique: 'one', label: '一'),
        ],
      );
      await mount(tester, load: () => load.future);
      await tester.tap(
        find.byKey(const ValueKey('live-intimacy-room-authorized')),
      );
      await tester.pump();
      rebuild(() {
        identity = Object();
        ++generation;
      });
      await tester.pump();
      load.complete(const [
        LiveTaskEmoticonOption(unique: 'one', label: '一', available: true),
      ]);
      await tester.pumpAndSettle();
      expect(authorizations, isEmpty);
      expect(preferences.authorized, isFalse);
    },
  );

  testWidgets('late authorization error cannot be shown under a new account', (
    tester,
  ) async {
    final result = Completer<String?>();
    preferences = preferences.copyWith(
      automation: const LiveTaskAutomationPreferences(
        autoLike: true,
        autoDanmaku: true,
        defaultMessage: 'configured',
      ),
    );
    await mount(tester, authorize: (_, _) => result.future);
    await tester.tap(
      find.byKey(const ValueKey('live-intimacy-room-authorized')),
    );
    await tester.pump();
    rebuild(() {
      identity = Object();
      ++generation;
    });
    await tester.pump();
    result.complete('旧账号授权错误');
    await tester.pumpAndSettle();
    rebuild(() {});
    await tester.pump();
    expect(find.text('旧账号授权错误'), findsNothing);
    expect(preferences.authorized, isFalse);
  });

  testWidgets(
    'progress distinguishes unknown origin and clamped estimate without local credit',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LiveIntimacyWatchProgressView(
              effectiveDuration: Duration(seconds: 330),
              completedRounds: 3,
              dailyRounds: 10,
              thresholdSeconds: 900,
            ),
          ),
        ),
      );
      expect(find.text('当前周期有效观时 05:30（本地记录）'), findsOneWidget);
      expect(find.text('官方已完成3/10轮'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('live-intimacy-watch-bar')),
        findsNothing,
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LiveIntimacyWatchProgressView(
              effectiveDuration: Duration(seconds: 960),
              completedRounds: 3,
              dailyRounds: 10,
              thresholdSeconds: 900,
              currentRoundEstimateSeconds: 960,
              waitingConfirmation: true,
              progressValue: 1.2,
            ),
          ),
        ),
      );
      expect(find.text('官方已完成3/10轮'), findsOneWidget);
      expect(find.text('等待官方确认'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('live-intimacy-watch-bar')),
            )
            .value,
        1.0,
      );
    },
  );
}

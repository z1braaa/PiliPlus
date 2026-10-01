import 'dart:async';

import 'package:PiliPlus/common/widgets/flutter/text_field/controller.dart';
import 'package:PiliPlus/common/widgets/flutter/text_field/text_field.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/live/live_danmaku/danmaku_msg.dart';
import 'package:PiliPlus/pages/live_room/controller.dart';
import 'package:PiliPlus/pages/live_room/live_danmaku_send_gate.dart';
import 'package:PiliPlus/pages/live_room/live_message_session.dart';
import 'package:PiliPlus/pages/live_room/send_danmaku/view.dart';
import 'package:PiliPlus/pages/live_room/widgets/chat_panel.dart';
import 'package:PiliPlus/pages/live_room/widgets/enhancement_panel.dart';
import 'package:flutter/services.dart' show TextEditingDeltaInsertion;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class _Room extends Fake implements LiveRoomController {
  bool login = true;
  @override
  final messageConnectionState = LiveMessageConnectionState.connected.obs;
  @override
  final messages = <dynamic>[].obs;
  @override
  final disableAutoScroll = false.obs;
  @override
  final scrollController = ScrollController();
  @override
  int builtLength = 0;
  @override
  int chatSimpleIndex = 0;
  @override
  List<RichTextItem>? savedDanmaku;
  @override
  final danmakuSendGate = LiveDanmakuSendGate();
  Completer<LoadingState<void>>? sendResult;
  int writes = 0;
  @override
  int get trimDmIndex => 0;
  @override
  int get roomId => 6;
  @override
  bool get isLogin => login;
  @override
  bool get showSuperChat => false;
  @override
  void retryLiveMessages() {}
  @override
  void handleJumpToBottom() {}
  @override
  void toastNotLogin() {}
  @override
  void onLikeTapDown(dynamic _) {}
  @override
  void onLikeTapUp([dynamic _]) {}
  @override
  Future<LoadingState<void>> sendLiveDanmaku({
    required String message,
    int? dmType,
    Object? emoticonOptions,
    int replyMid = 0,
    String replayDmid = '',
  }) {
    writes++;
    return sendResult?.future ?? Future.value(const Success<void>(null));
  }
}

class _Routes extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
  }
}

void _setDraft(WidgetTester tester, String value) {
  tester.widget<RichTextField>(find.byType(RichTextField)).controller
    ..clear()
    ..syncRichText(
      TextEditingDeltaInsertion(
        oldText: '',
        textInserted: value,
        insertionOffset: 0,
        selection: TextSelection.collapsed(offset: value.length),
        composing: TextRange.empty,
      ),
    )
    ..value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  tester
      .state<LiveSendDmPanelState>(find.byType(LiveSendDmPanel))
      .onChanged(
        value,
      );
}

void main() {
  test('disposed room ignores a late successful send receipt', () async {
    final gate = LiveDanmakuSendGate();
    final receipt = Completer<LoadingState<void>>();
    var draftSuccessCalls = 0;

    final pending = gate.trySend(
      () => receipt.future,
      clearDraftOnSuccess: true,
      onDraftSuccess: (_) => draftSuccessCalls++,
    );
    expect(gate.pending, isTrue);
    gate.dispose();

    receipt.complete(const Success<void>(null));
    expect(await pending, isNull);
    expect(gate.pending, isFalse);
    expect(gate.successSerial, 0);
    expect(draftSuccessCalls, 0);
  });

  testWidgets(
    'enhanced chat edits below its list without opening a publish route and restores draft',
    (tester) async {
      final room = _Room();
      final routes = _Routes();
      Widget input() => LiveSendDmPanel(
        inline: true,
        autofocus: false,
        liveRoomController: room,
        items: room.savedDanmaku,
        onSave: (items) => room.savedDanmaku = items.toList(),
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [routes],
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 440,
              child: LiveEnhancementPanel(
                controller: room,
                inputBuilder: input,
                onMention: (DanmakuMsg _) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byType(RichTextField);
      expect(field, findsOneWidget);
      expect(
        tester.getTopLeft(field).dy,
        greaterThanOrEqualTo(
          tester.getBottomLeft(find.byType(LiveRoomChatPanel)).dy,
        ),
      );
      await tester.tap(field);
      tester.widget<RichTextField>(field).controller
        ..syncRichText(
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: '测试弹幕',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 4),
            composing: TextRange.empty,
          ),
        )
        ..value = const TextEditingValue(
          text: '测试弹幕',
          selection: TextSelection.collapsed(offset: 4),
        );
      await tester.pump();
      expect(routes.pushes, 1);
      expect(find.byType(LiveSendDmPanel), findsOneWidget);
      await tester.tap(find.widgetWithText(Tab, 'SC'));
      await tester.pumpAndSettle();
      expect(find.byType(LiveSendDmPanel), findsNothing);
      expect(room.savedDanmaku, isNotEmpty);
      await tester.tap(find.text('聊天'));
      await tester.pumpAndSettle();
      expect(find.byType(RichTextField), findsOneWidget);
      expect(
        tester
            .widget<RichTextField>(find.byType(RichTextField))
            .controller
            .text,
        '测试弹幕',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      room.scrollController.dispose();
      room.danmakuSendGate.dispose();
    },
  );

  testWidgets(
    'pending send survives SC tab replacement and an A receipt does not clear a new B draft',
    (tester) async {
      final room = _Room()..sendResult = Completer<LoadingState<void>>();
      Widget input() => LiveSendDmPanel(
        inline: true,
        autofocus: false,
        liveRoomController: room,
        items: room.savedDanmaku,
        onSave: (items) => room.savedDanmaku = items.toList(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 440,
              child: LiveEnhancementPanel(
                controller: room,
                inputBuilder: input,
                onMention: (DanmakuMsg _) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _setDraft(tester, 'A');
      final oldComposer = tester.state<LiveSendDmPanelState>(
        find.byType(LiveSendDmPanel),
      );
      final first = oldComposer.onCustomPublish();
      await tester.pump();
      expect(room.writes, 1);
      expect(room.danmakuSendGate.pending, isTrue);

      await tester.tap(find.widgetWithText(Tab, 'SC'));
      await tester.pumpAndSettle();
      expect(find.byType(LiveSendDmPanel), findsNothing);
      await tester.tap(find.text('聊天'));
      await tester.pumpAndSettle();
      final newComposer = tester.state<LiveSendDmPanelState>(
        find.byType(LiveSendDmPanel),
      );
      expect(identical(oldComposer, newComposer), isFalse);
      expect(
        tester
            .widget<RichTextField>(find.byType(RichTextField))
            .controller
            .text,
        'A',
      );
      await newComposer.onCustomPublish();
      expect(room.writes, 1);

      _setDraft(tester, 'B');
      room.sendResult!.complete(const Success<void>(null));
      await first;
      await tester.pump();
      expect(room.writes, 1);
      expect(room.danmakuSendGate.pending, isFalse);
      expect(
        tester
            .widget<RichTextField>(find.byType(RichTextField))
            .controller
            .text,
        'B',
      );
      await tester.tap(find.widgetWithText(Tab, 'SC'));
      await tester.pumpAndSettle();
      expect(room.savedDanmaku?.single.text, 'B');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      room.scrollController.dispose();
      room.danmakuSendGate.dispose();
    },
  );

  testWidgets('failed send keeps draft available for an explicit retry', (
    tester,
  ) async {
    final room = _Room()..sendResult = Completer<LoadingState<void>>();
    Widget input() => LiveSendDmPanel(
      inline: true,
      autofocus: false,
      liveRoomController: room,
      items: room.savedDanmaku,
      onSave: (items) => room.savedDanmaku = items.toList(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 440,
            child: LiveEnhancementPanel(
              controller: room,
              inputBuilder: input,
              onMention: (DanmakuMsg _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    _setDraft(tester, 'A');
    final first = tester
        .state<LiveSendDmPanelState>(find.byType(LiveSendDmPanel))
        .onCustomPublish();
    await tester.pump();
    await tester.tap(find.widgetWithText(Tab, 'SC'));
    await tester.pumpAndSettle();
    room.sendResult!.complete(const Error('暂时失败'));
    await first;
    expect(room.savedDanmaku?.single.text, 'A');
    expect(room.danmakuSendGate.pending, isFalse);
    await tester.tap(find.text('聊天'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<RichTextField>(find.byType(RichTextField)).controller.text,
      'A',
    );
    room.sendResult = Completer<LoadingState<void>>();
    final retry = tester
        .state<LiveSendDmPanelState>(find.byType(LiveSendDmPanel))
        .onCustomPublish();
    await tester.pump();
    expect(room.writes, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    room.sendResult!.complete(const Error('暂时失败'));
    await retry;
    room.scrollController.dispose();
    room.danmakuSendGate.dispose();
  });

  testWidgets(
    'confirmed send clears its unchanged draft before composer remount',
    (
      tester,
    ) async {
      final room = _Room()..sendResult = Completer<LoadingState<void>>();
      Widget input() => LiveSendDmPanel(
        inline: true,
        autofocus: false,
        liveRoomController: room,
        items: room.savedDanmaku,
        onSave: (items) => room.savedDanmaku = items.toList(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 440,
              child: LiveEnhancementPanel(
                controller: room,
                inputBuilder: input,
                onMention: (DanmakuMsg _) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _setDraft(tester, 'A');
      final pending = tester
          .state<LiveSendDmPanelState>(find.byType(LiveSendDmPanel))
          .onCustomPublish();
      await tester.pump();
      await tester.tap(find.widgetWithText(Tab, 'SC'));
      await tester.pumpAndSettle();
      expect(room.savedDanmaku?.single.text, 'A');
      room.sendResult!.complete(const Success<void>(null));
      await pending;
      expect(room.savedDanmaku, isNull);
      await tester.tap(find.text('聊天'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<RichTextField>(find.byType(RichTextField))
            .controller
            .text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      room.scrollController.dispose();
      room.danmakuSendGate.dispose();
    },
  );

  testWidgets('compact gift entry expands left and exposes the full menu', (
    tester,
  ) async {
    var fullMenu = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: LiveGiftActionBar(
              session: null,
              onFullMenu: () => fullMenu++,
              onQuickGift: (_, _) {},
            ),
          ),
        ),
      ),
    );
    expect(find.byTooltip('向左展开礼物快捷条'), findsOneWidget);
    await tester.tap(find.byTooltip('向左展开礼物快捷条'));
    await tester.pump();
    expect(find.byTooltip('展开完整礼物菜单'), findsOneWidget);
    await tester.tap(find.byTooltip('展开完整礼物菜单'));
    expect(fullMenu, 1);
    expect(find.byIcon(Icons.card_giftcard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('guest can tap fan and SC composer entries without sending', (
    tester,
  ) async {
    final room = _Room()..login = false;
    var fanOpens = 0;
    var scOpens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: SizedBox(
              width: 400,
              height: 130,
              child: LiveSendDmPanel(
                inline: true,
                autofocus: false,
                liveRoomController: room,
                onFanClub: () => fanOpens++,
                onSuperChat: () => scOpens++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('获取勋章'));
    await tester.tap(find.byTooltip('醒目留言 SC'));
    expect(fanOpens, 1);
    expect(scOpens, 1);
    expect(room.writes, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    room.danmakuSendGate.dispose();
  });

  testWidgets('landscape enhancement panel exposes guest fan and SC actions', (
    tester,
  ) async {
    final room = _Room()..login = false;
    var fanOpens = 0;
    var scOpens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 1200,
            child: LiveEnhancementPanel(
              controller: room,
              inputBuilder: () => LiveSendDmPanel(
                inline: true,
                autofocus: false,
                liveRoomController: room,
                onFanClub: () => fanOpens++,
                onSuperChat: () => scOpens++,
              ),
              onMention: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('获取勋章'));
    await tester.tap(find.byTooltip('醒目留言 SC'));
    expect(fanOpens, 1);
    expect(scOpens, 1);
    expect(room.writes, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    room.scrollController.dispose();
    room.danmakuSendGate.dispose();
  });
}

import 'package:PiliPlus/common/widgets/flutter/text_field/controller.dart';
import 'package:PiliPlus/common/widgets/flutter/text_field/text_field.dart';
import 'package:PiliPlus/models_new/live/live_danmaku/danmaku_msg.dart';
import 'package:PiliPlus/pages/live_room/controller.dart';
import 'package:PiliPlus/pages/live_room/live_message_session.dart';
import 'package:PiliPlus/pages/live_room/send_danmaku/view.dart';
import 'package:PiliPlus/pages/live_room/widgets/chat_panel.dart';
import 'package:PiliPlus/pages/live_room/widgets/enhancement_panel.dart';
import 'package:flutter/services.dart' show TextEditingDeltaInsertion;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class _Room extends Fake implements LiveRoomController {
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
  int get trimDmIndex => 0;
  @override
  int get roomId => 6;
  @override
  bool get isLogin => true;
  @override
  bool get showSuperChat => false;
  @override
  void retryLiveMessages() {}
  @override
  void handleJumpToBottom() {}
  @override
  void toastNotLogin() {}
}

class _Routes extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
  }
}

void main() {
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
      await tester.tap(find.text('SC'));
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
    },
  );

  testWidgets(
    'video action icons select gift, bag and fan flows at narrow width',
    (
      tester,
    ) async {
      final selected = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: LiveInteractionActionBar(
                onGift: () => selected.add('gift'),
                onBag: () => selected.add('bag'),
                onFan: () => selected.add('fan'),
              ),
            ),
          ),
        ),
      );
      for (final (label, expected) in [
        ('礼物', 'gift'),
        ('背包', 'bag'),
        ('粉丝团/灯牌', 'fan'),
      ]) {
        await tester.tap(find.text(label));
        await tester.pump();
        expect(selected.last, expected);
      }
      expect(find.byIcon(Icons.card_giftcard), findsOneWidget);
      expect(find.byIcon(Icons.inventory_2_outlined), findsOneWidget);
      expect(find.byIcon(Icons.groups_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

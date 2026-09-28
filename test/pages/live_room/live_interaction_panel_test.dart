import 'dart:async';

import 'package:PiliPlus/pages/live_room/widgets/interaction_panel.dart';
import 'package:PiliPlus/pages/live_room/widgets/enhancement_panel.dart';
import 'package:PiliPlus/pages/live_room/controller.dart';
import 'package:PiliPlus/pages/live_room/widgets/chat_panel.dart';
import 'package:PiliPlus/pages/live_room/superchat/superchat_panel.dart';
import 'package:PiliPlus/models_new/live/live_room_info_h5/data.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

const _gift = LiveGift(
  id: 1,
  name: '测试礼物',
  price: 80,
  coinType: 'gold',
  maxQuantity: 99,
  sendable: true,
);
const _snapshot = LiveInteractionSnapshot(
  roomId: 6,
  anchorUid: 10,
  accountUid: 20,
  loggedIn: true,
  gifts: [_gift],
);

LiveGiftConfirmation _confirmation([int quantity = 1]) => LiveGiftConfirmation(
  gift: _gift,
  quantity: quantity,
  purpose: LiveGiftPurpose.gift,
  accountUid: 20,
  roomId: 6,
  anchorUid: 10,
  operationId: 'fixture-op',
  expiresAt: DateTime.now().add(const Duration(seconds: 45)),
);

class _Service extends Fake implements LiveInteractionService {
  int writes = 0;
  int checks = 0;
  int prepares = 0;
  int invalidations = 0;
  Object identity = Object();
  LiveActionResult? saved;
  Object? savedIdentity;
  @override
  Object get accountIdentity => identity;
  Future<LiveInteractionSnapshot> Function()? reader;
  Completer<LiveActionResult>? writeResult;
  @override
  int get roomId => 6;
  @override
  int get anchorUid => 10;
  @override
  LiveActionResult? get lastAction =>
      savedIdentity == null || identical(savedIdentity, identity)
      ? saved
      : null;
  @override
  Future<LiveInteractionSnapshot> loadPanel() async =>
      reader == null ? _snapshot : await reader!();
  @override
  Future<LiveGiftConfirmation> prepareGift(
    LiveGift gift,
    int quantity, {
    LiveBagItem? bagItem,
    LiveGiftPurpose purpose = LiveGiftPurpose.gift,
  }) async {
    prepares++;
    return _confirmation(quantity);
  }

  @override
  Future<LiveActionResult> submitGift(LiveGiftConfirmation value) async {
    writes++;
    final issuedIdentity = identity;
    final settled = writeResult == null
        ? const LiveActionResult(
            state: LiveActionState.unknown,
            message: '提交结果未知',
            operationId: 'fixture-op',
          )
        : await writeResult!.future;
    saved = settled;
    savedIdentity = issuedIdentity;
    return settled;
  }

  @override
  Future<LiveActionResult> reconcile(LiveActionResult result) async {
    checks++;
    return saved = result.copyWith(
      message: '目标状态已达成，本次送礼结果仍未知',
      fanStatus: const LiveFanStatus(joined: true, isLighted: true),
    );
  }

  @override
  void dispose() {}
  @override
  void invalidateApprovals() {
    invalidations++;
  }
}

class _Room extends Fake implements LiveRoomController {
  @override
  final roomInfoH5 = Rxn<RoomInfoH5Data>();
  @override
  int get roomId => 6;
  @override
  Widget get watchedWidget => const Text('观看信息');
  @override
  Widget get timeWidget => const Text('开播时间');
}

void main() {
  test(
    'hide and reopen rejects a prepare response from the old UI generation',
    () async {
      final service = _Service();
      var enabled = true;
      final session = LiveInteractionSession(
        service: service,
        isEnabled: () => enabled,
      );
      final response = Completer<LiveGiftConfirmation>();
      final pending = session.prepare(() => response.future);
      enabled = false;
      session.hide();
      enabled = true;
      response.complete(_confirmation());
      expect(await pending, isNull);
      expect(service.writes, 0);
      session.dispose();
    },
  );

  test('hiding invalidates a ready confirmation before any submit', () async {
    final service = _Service();
    final session = LiveInteractionSession(
      service: service,
      isEnabled: () => true,
    );
    final ready = await session.prepare(() async => _confirmation());
    session.hide();
    await session.submit(ready!);
    expect(service.writes, 0);
    session.dispose();
  });

  test('concurrent submit sends once and unknown is sticky after read-only reconcile', () async {
    final service = _Service()..writeResult = Completer<LiveActionResult>();
    final session = LiveInteractionSession(
      service: service,
      isEnabled: () => true,
    );
    final ready = await session.prepare(() async => _confirmation());
    final first = session.submit(ready!);
    await session.submit(ready);
    expect(service.writes, 1);
    service.writeResult!.complete(
      const LiveActionResult(
        state: LiveActionState.unknown,
        message: '提交超时',
        operationId: 'fixture-op',
      ),
    );
    await first;
    expect(session.blocked, isTrue);
    await session.reconcile();
    expect(service.checks, 1);
    expect(service.writes, 1);
    expect(session.result!.state, LiveActionState.unknown);
    expect(session.result!.fanStatus!.joined, isTrue);
    expect(await session.prepare(() async => _confirmation()), isNull);
    session.dispose();
  });

  test('restored unknown blocks a new confirmation instead of treating restart as a retry', () async {
    final service = _Service()
      ..saved = const LiveActionResult(
        state: LiveActionState.unknown,
        message: '从上次会话恢复',
        operationId: 'fixture-op',
      );
    final session = LiveInteractionSession(
      service: service,
      isEnabled: () => true,
    );
    await session.load();
    expect(session.result!.state, LiveActionState.unknown);
    expect(await session.prepare(() async => _confirmation()), isNull);
    expect(service.writes, 0);
    session.dispose();
  });

  test('a hidden panel ignores a late read response', () async {
    final response = Completer<LiveInteractionSnapshot>();
    final service = _Service()..reader = () => response.future;
    final session = LiveInteractionSession(
      service: service,
      isEnabled: () => true,
    );
    final pending = session.load();
    session.hide();
    response.complete(_snapshot);
    await pending;
    expect(session.snapshot, isNull);
    expect(session.loading, isFalse);
    session.dispose();
  });

  test(
    'a late issued result from account A never appears in account B UI',
    () async {
      final service = _Service()..writeResult = Completer<LiveActionResult>();
      final session = LiveInteractionSession(
        service: service,
        isEnabled: () => true,
      );
      await session.load();
      final observed = <String?>[];
      session.addListener(() => observed.add(session.result?.receiptId));
      final ready = await session.prepare(() async => _confirmation());
      final issued = session.submit(ready!);
      service
        ..identity = Object()
        ..reader = () async => const LiveInteractionSnapshot(
          roomId: 6,
          anchorUid: 10,
          accountUid: 30,
          loggedIn: true,
        );
      service.writeResult!.complete(
        const LiveActionResult(
          state: LiveActionState.succeeded,
          message: '账号A回执',
          operationId: 'fixture-op',
          receiptId: 'A-only',
        ),
      );
      await issued;
      expect(session.snapshot!.accountUid, 30);
      expect(session.result, isNull);
      expect(observed, isNot(contains('A-only')));
      expect(service.saved!.receiptId, 'A-only');
      session.dispose();
    },
  );

  test(
    'unexpected exceptions cannot expose request URL or account secrets in UI',
    () async {
      final service = _Service()
        ..reader = () => throw Exception('private-cookie https://signed-url');
      final session = LiveInteractionSession(
        service: service,
        isEnabled: () => true,
      );
      await session.load();
      expect(session.error, isNot(contains('private-cookie')));
      expect(session.error, isNot(contains('https://')));
      session.dispose();
    },
  );

  testWidgets(
    'gift confirmation shows official unit, account and target; cancelling performs no write',
    (tester) async {
      final service = _Service();
      final session = LiveInteractionSession(
        service: service,
        isEnabled: () => true,
      )..snapshot = _snapshot;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 600,
              child: LiveInteractionPanel(
                session: session,
                anchorName: '测试主播',
                onLogin: () {},
                onRecharge: () async {},
                onOpenGuard: () async {},
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '3');
      await tester.tap(find.widgetWithText(TextButton, '投喂'));
      await tester.pumpAndSettle();
      expect(find.text('确认送礼'), findsOneWidget);
      expect(find.text('合计：240 金瓜子'), findsOneWidget);
      expect(find.text('付款账号 UID：20'), findsOneWidget);
      expect(find.text('房间：6；主播 UID：10'), findsOneWidget);
      expect(service.writes, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(service.writes, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );

  testWidgets('closing enhancement cancels an unsubmitted confirmation', (
    tester,
  ) async {
    var enabled = true;
    final service = _Service();
    final session = LiveInteractionSession(
      service: service,
      isEnabled: () => enabled,
    )..snapshot = _snapshot;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 600,
            child: LiveInteractionPanel(
              session: session,
              anchorName: '测试主播',
              onLogin: () {},
              onRecharge: () async {},
              onOpenGuard: () async {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.widgetWithText(TextButton, '投喂'));
    await tester.pumpAndSettle();
    expect(find.text('确认送礼'), findsOneWidget);
    enabled = false;
    session.hide();
    await tester.pumpAndSettle();
    expect(find.text('确认送礼'), findsNothing);
    expect(service.writes, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });

  testWidgets(
    'small panel scrolls status and quantity without overflow and unknown disables sending',
    (tester) async {
      final service = _Service();
      final session =
          LiveInteractionSession(service: service, isEnabled: () => true)
            ..snapshot = _snapshot
            ..result = const LiveActionResult(
              state: LiveActionState.unknown,
              message: '结果仍未知；请只读核对，避免重复扣费。',
              operationId: 'fixture-op',
            );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 220,
              child: LiveInteractionPanel(
                session: session,
                anchorName: '测试主播',
                onLogin: () {},
                onRecharge: () async {},
                onOpenGuard: () async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(NestedScrollView), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final send = find.widgetWithText(TextButton, '投喂');
      if (send.evaluate().isNotEmpty) {
        expect(tester.widget<TextButton>(send).onPressed, isNull);
      }
      expect(service.writes, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );

  testWidgets('quick gift quantity is chosen before the guarded confirmation', (
    tester,
  ) async {
    final service = _Service();
    final session = LiveInteractionSession(
      service: service,
      isEnabled: () => true,
    )..snapshot = _snapshot;
    int? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 250,
            child: LiveGiftActionBar(
              session: session,
              onFullMenu: () {},
              onQuickGift: (gift, quantity) {
                expect(gift.id, _gift.id);
                chosen = quantity;
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('向左展开礼物快捷条'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('×1'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('×3'), findsOneWidget);
    await tester.tap(find.text('投喂'));
    expect(chosen, 3);
    expect(service.writes, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });

  testWidgets(
    'guard response uses raw candidate status, not a verified subscription claim',
    (
      tester,
    ) async {
      final service = _Service();
      final session =
          LiveInteractionSession(
              service: service,
              isEnabled: () => true,
            )
            ..snapshot = const LiveInteractionSnapshot(
              roomId: 6,
              anchorUid: 10,
              accountUid: 20,
              loggedIn: true,
              guardStatus: LiveGuardStatus(
                activeState: 1,
                tiers: [LiveGuardTier(type: 3, status: 1)],
              ),
            );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: LiveInteractionPanel(
                session: session,
                anchorName: '测试主播',
                onLogin: () {},
                onRecharge: () async {},
                onOpenGuard: () async {},
                initialTab: 3,
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('大航海只读响应'), findsOneWidget);
      expect(find.text('身份状态码：1'), findsOneWidget);
      expect(find.textContaining('这些只读字段不能证明'), findsOneWidget);
      expect(find.text('在航'), findsNothing);
      expect(find.textContaining('刷新登录后重试'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );

  testWidgets('guest cannot open recharge and sees login recovery guidance', (
    tester,
  ) async {
    final service = _Service();
    final session =
        LiveInteractionSession(
            service: service,
            isEnabled: () => true,
          )
          ..snapshot = const LiveInteractionSnapshot(
            roomId: 6,
            anchorUid: 10,
            accountUid: 0,
            loggedIn: false,
          );
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: LiveInteractionPanel(
              session: session,
              anchorName: '测试主播',
              onLogin: () {},
              onRecharge: () async => opened = true,
              onOpenGuard: () async {},
            ),
          ),
        ),
      ),
    );
    final recharge = find.widgetWithText(TextButton, '充值');
    expect(tester.widget<TextButton>(recharge).onPressed, isNull);
    expect(find.textContaining('刷新登录后重试'), findsOneWidget);
    expect(opened, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });

  testWidgets(
    'guest can browse fan and guard panels without transaction actions',
    (
      tester,
    ) async {
      final service = _Service();
      final session =
          LiveInteractionSession(
              service: service,
              isEnabled: () => true,
            )
            ..snapshot = const LiveInteractionSnapshot(
              roomId: 6,
              anchorUid: 10,
              accountUid: 0,
              loggedIn: false,
            );
      var openedGuard = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: LiveInteractionPanel(
                session: session,
                anchorName: '测试主播',
                onLogin: () {},
                onRecharge: () async {},
                onOpenGuard: () async => openedGuard = true,
                initialTab: 2,
              ),
            ),
          ),
        ),
      );
      expect(find.text('测试主播的粉丝团'), findsOneWidget);
      expect(find.textContaining('访客可浏览此面板'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '大航海'));
      await tester.pumpAndSettle();
      expect(find.text('大航海'), findsWidgets);
      final guard = find.widgetWithText(FilledButton, '在应用内打开官方大航海');
      expect(tester.widget<FilledButton>(guard).onPressed, isNull);
      expect(openedGuard, isFalse);
      expect(service.writes, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );

  testWidgets(
    'replacing a room session updates listeners and loads the new session',
    (tester) async {
      final oldService = _Service();
      final nextService = _Service()
        ..reader = () async => const LiveInteractionSnapshot(
          roomId: 6,
          anchorUid: 10,
          accountUid: 30,
          loggedIn: true,
        );
      final oldSession = LiveInteractionSession(
        service: oldService,
        isEnabled: () => true,
      )..snapshot = _snapshot;
      final nextSession = LiveInteractionSession(
        service: nextService,
        isEnabled: () => true,
      );
      Widget page(LiveInteractionSession session) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 600,
            child: LiveInteractionPanel(
              session: session,
              anchorName: '测试主播',
              onLogin: () {},
              onRecharge: () async {},
              onOpenGuard: () async {},
            ),
          ),
        ),
      );
      await tester.pumpWidget(page(oldSession));
      await tester.pumpWidget(page(nextSession));
      await tester.pumpAndSettle();
      expect(nextSession.snapshot!.accountUid, 30);
      expect(oldService.invalidations, greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      oldSession.dispose();
      nextSession.dispose();
    },
  );

  testWidgets(
    'the narrow/fullscreen drawer never mounts a second room chat or SC list',
    (tester) async {
      final existingChatScroll = ScrollController();
      final room = _Room();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  height: 100,
                  child: ListView(
                    controller: existingChatScroll,
                    children: const [Text('原直播聊天仍然挂载')],
                  ),
                ),
                Expanded(
                  child: LiveEnhancementDrawer(
                    controller: room,
                    interactions: const Center(child: Text('独立互动面板')),
                    onShowRank: () {},
                    title: '礼物',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(existingChatScroll.positions.length, 1);
      expect(find.byType(LiveRoomChatPanel), findsNothing);
      expect(find.byType(SuperChatPanel), findsNothing);
      expect(find.text('独立互动面板'), findsOneWidget);
      expect(existingChatScroll.positions.length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      existingChatScroll.dispose();
    },
  );
}

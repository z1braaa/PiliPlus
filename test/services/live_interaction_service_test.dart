// Distinct Object identities simulate real logout/relogin account instances.
// ignore_for_file: prefer_const_constructors
import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/models_new/live/interactions/live_interaction_parser.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _gift = LiveGift(
  id: 3,
  name: '测试礼物',
  price: 100,
  coinType: 'gold',
  maxQuantity: 10,
  sendable: true,
);

class _Journal implements LiveInteractionJournal {
  final records = <String, Map<String, dynamic>>{};
  bool failWrite = false;
  void Function()? onWrite;
  @override
  Future<Map<String, dynamic>?> read(String key) async => records[key];
  @override
  Future<void> write(String key, Map<String, dynamic> record) async {
    if (failWrite) throw StateError('disk full');
    records[key] = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(record)) as Map,
    );
    onWrite?.call();
  }
}

class _Transport implements LiveInteractionTransport {
  int posts = 0;
  final paths = <String>[];
  final bodies = <Map<String, dynamic>>[];
  int price = 100;
  int? balance = 10000;
  int max = 10;
  int level = 0;
  bool light = false;
  bool wearing = false;
  bool failPost = false;
  Map<String, dynamic>? response;
  void Function(String)? onGet;
  Future<void> Function()? beforePost;
  final _Journal journal;
  _Transport(this.journal);
  Map<String, dynamic> get catalog => {
    'gift_data': {
      'max_send_gift': max,
      'room_gift_list': {
        'gold_list': [
          {'id': 3},
        ],
      },
    },
    'gift_config': {
      'base_config': {
        'list': [
          {
            'id': 3,
            'name': '测试礼物',
            'price': price,
            'coin_type': 'gold',
            'max_send_limit': 10,
          },
        ],
      },
    },
  };
  @override
  Future<Map<String, dynamic>> get(
    String path,
    Map<String, dynamic> query,
    LiveInteractionAccount account,
    CancelToken token,
  ) async {
    onGet?.call(path);
    final data = switch (path) {
      String p when p.endsWith('roomGiftList') => catalog,
      String p when p.endsWith('bag_list') => {
        'gift_config': [
          {'id': 3, 'name': '测试礼物', 'price': 100, 'coin_type': 'gold'},
        ],
        'list': [
          {'type': 1, 'gift_id': 3, 'bag_id': 4, 'gift_num': 2, 'expire_at': 0},
        ],
      },
      String p when p.endsWith('fansMedal/panel') => {
        'list': [
          {
            'medal': {
              'medal_id': 8,
              'target_id': 20,
              'medal_name': '测试牌',
              'level': level,
              'wearing_status': wearing ? 1 : 0,
              'is_lighted': light ? 1 : 0,
            },
          },
        ],
      },
      String p when p.endsWith('GetActivatedMedalInfo') => {
        'level': level,
        'is_lighted': light ? 1 : 0,
        'medal_name': '测试牌',
        'fans_club_gift_info': {'gift_id': 3, 'price': price},
      },
      String p when p.endsWith('GuardActiveWithFansClub') => {
        'fans_club_info': {
          'level': level,
          'fans_club_gift': {'gift_id': 3, 'price': price},
        },
      },
      String p when p.endsWith('getInfoByUser') => {
        'wallet': {if (balance != null) 'gold': balance, 'silver': 1000},
      },
      _ => <String, dynamic>{},
    };
    return {'code': 0, 'data': data};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
    LiveInteractionAccount account,
  ) async {
    expect(
      journal.records['${account.uid}:6:20']?['state'],
      'submitting',
      reason: 'Journal must be durable before any network write.',
    );
    posts++;
    paths.add(path);
    bodies.add(body);
    await beforePost?.call();
    if (failPost) throw TimeoutException('lost response');
    if (path.endsWith('/wear')) wearing = true;
    if (path.endsWith('/take_off')) wearing = false;
    return response ??
        {
          'code': 0,
          'data': {
            'uid': account.uid,
            'gift_list': [
              {
                'gift_id': body['gift_id'],
                'gift_num': body['gift_num'],
                'receive_user_info': {'uid': 20},
                'tid': 'fixture-receipt',
              },
            ],
          },
        };
  }
}

void main() {
  late _Journal journal;
  late _Transport transport;
  late LiveInteractionAccount account;
  late DateTime now;
  late LiveInteractionService service;
  setUp(() {
    journal = _Journal();
    transport = _Transport(journal);
    account = LiveInteractionAccount(
      uid: 10,
      loggedIn: true,
      identity: Object(),
      csrf: 'fixture-token',
    );
    now = DateTime.utc(2026, 9, 28);
    service = LiveInteractionService.testing(
      roomId: 6,
      anchorUid: 20,
      transport: transport,
      journal: journal,
      account: () => account,
      now: () => now,
    );
  });
  tearDown(() => service.dispose());

  test('gift sends once with matching official receipt, never credentials in journal', () async {
    final confirmation = await service.prepareGift(_gift, 2);
    final result = await service.submitGift(confirmation);
    expect(result.state, LiveActionState.succeeded);
    expect(result.receiptId, 'fixture-receipt');
    expect(transport.posts, 1);
    expect(transport.bodies.single['gift_num'], 2);
    expect(transport.bodies.single['receive_users'], '[{"uid":20}]');
    expect(jsonEncode(journal.records), isNot(contains('fixture-token')));
    expect(
      (await service.submitGift(confirmation)).state,
      LiveActionState.notSubmitted,
    );
    expect(transport.posts, 1);
  });

  test(
    'same confirmation concurrent submissions cannot double charge',
    () async {
      final confirmation = await service.prepareGift(_gift, 1);
      final results = await Future.wait([
        service.submitGift(confirmation),
        service.submitGift(confirmation),
      ]);
      expect(transport.posts, 1);
      expect(
        results.where((r) => r.state == LiveActionState.succeeded),
        hasLength(1),
      );
    },
  );

  test('timeout persists unknown and new service must not replay', () async {
    final confirmation = await service.prepareGift(_gift, 1);
    transport.failPost = true;
    final result = await service.submitGift(confirmation);
    expect(result.state, LiveActionState.unknown);
    service.dispose();
    final second = LiveInteractionService.testing(
      roomId: 6,
      anchorUid: 20,
      transport: transport,
      journal: journal,
      account: () => account,
      now: () => now,
    );
    expect((await second.restorePending())?.state, LiveActionState.unknown);
    await expectLater(
      second.prepareGift(_gift, 1),
      throwsA(isA<LiveInteractionException>()),
    );
    expect(transport.posts, 1);
    second.dispose();
  });

  test('API zero without receipt is unknown, not success', () async {
    transport.response = {'code': 0, 'data': {}};
    final result = await service.submitGift(
      await service.prepareGift(_gift, 1),
    );
    expect(result.state, LiveActionState.unknown);
  });

  test(
    'receipt for different recipient or quantity cannot prove this gift',
    () async {
      final confirmation = await service.prepareGift(_gift, 1);
      expect(
        LiveInteractionParser.giftReceipt({
          'uid': 10,
          'gift_list': [
            {
              'gift_id': 3,
              'gift_num': 1,
              'receive_user_info': {'uid': 999},
              'tid': 'other',
            },
          ],
        }, confirmation),
        isNull,
      );
      expect(
        LiveInteractionParser.giftReceipt({
          'uid': 10,
          'gift_list': [
            {
              'gift_id': 3,
              'gift_num': 2,
              'receive_user_info': {'uid': 20},
              'tid': 'other',
            },
          ],
        }, confirmation),
        isNull,
      );
    },
  );

  test('server business failure unlocks but consumed confirmation remains single use', () async {
    transport.response = {'code': 200013, 'message': '余额不足'};
    final confirmation = await service.prepareGift(_gift, 1);
    expect(
      (await service.submitGift(confirmation)).state,
      LiveActionState.failed,
    );
    expect(
      (await service.submitGift(confirmation)).state,
      LiveActionState.notSubmitted,
    );
    await service.prepareGift(_gift, 1);
    expect(transport.posts, 1);
  });

  test('cannot POST if journal write fails', () async {
    final confirmation = await service.prepareGift(_gift, 1);
    journal.failWrite = true;
    expect(
      (await service.submitGift(confirmation)).state,
      LiveActionState.notSubmitted,
    );
    expect(transport.posts, 0);
  });

  test('same UID relogin invalidates gift approval', () async {
    final confirmation = await service.prepareGift(_gift, 1);
    account = LiveInteractionAccount(
      uid: 10,
      loggedIn: true,
      identity: Object(),
      csrf: 'new-token',
    );
    expect(
      (await service.submitGift(confirmation)).state,
      LiveActionState.notSubmitted,
    );
    expect(transport.posts, 0);
  });

  test('expiry during revalidation prevents POST', () async {
    final confirmation = await service.prepareGift(_gift, 1);
    transport.onGet = (_) {
      now = now.add(const Duration(minutes: 1));
    };
    expect(
      (await service.submitGift(confirmation)).state,
      LiveActionState.notSubmitted,
    );
    expect(transport.posts, 0);
  });

  test('expiry during journal flush also prevents POST', () async {
    final confirmation = await service.prepareGift(_gift, 1);
    journal.onWrite = () {
      now = now.add(const Duration(minutes: 1));
    };
    expect(
      (await service.submitGift(confirmation)).state,
      LiveActionState.notSubmitted,
    );
    expect(transport.posts, 0);
  });

  test('current price change requires another user confirmation', () async {
    final confirmation = await service.prepareGift(_gift, 1);
    transport.price = 200;
    expect(
      (await service.submitGift(confirmation)).state,
      LiveActionState.notSubmitted,
    );
    expect(transport.posts, 0);
  });

  test(
    'unknown balance cannot be invented as zero or permit sending',
    () async {
      transport.balance = null;
      await expectLater(
        service.prepareGift(_gift, 1),
        throwsA(isA<LiveInteractionException>()),
      );
      expect(transport.posts, 0);
    },
  );

  test('join uses current server rule gift and confirms gold once', () async {
    final confirmation = await service.prepareFanAction(
      LiveGiftPurpose.joinFanClub,
    );
    transport.beforePost = () async {
      transport.level = 1;
    };
    expect(confirmation.gift.id, 3);
    expect(confirmation.quantity, 1);
    final result = await service.submitGift(confirmation);
    expect(result.state, LiveActionState.succeeded);
    expect(transport.paths.single, endsWith('sendGoldMultiUser'));
  });

  test(
    'light requires server-confirmed membership and unlighted state',
    () async {
      await expectLater(
        service.prepareFanAction(LiveGiftPurpose.lightMedal),
        throwsA(isA<LiveInteractionException>()),
      );
      transport.level = 1;
      final confirmation = await service.prepareFanAction(
        LiveGiftPurpose.lightMedal,
      );
      expect(confirmation.quantity, 1);
      expect(confirmation.purpose, LiveGiftPurpose.lightMedal);
    },
  );

  test(
    'fan state after lost gift response does not falsely prove gift receipt',
    () async {
      final confirmation = await service.prepareFanAction(
        LiveGiftPurpose.joinFanClub,
      );
      transport.failPost = true;
      final result = await service.submitGift(confirmation);
      transport.level = 1;
      final checked = await service.reconcile(result);
      expect(checked.state, LiveActionState.unknown);
      expect(checked.fanStatus?.joined, true);
      expect(transport.posts, 1);
    },
  );

  test(
    'medal action rejected before lock cannot overwrite pending gift',
    () async {
      transport.failPost = true;
      final result = await service.submitGift(
        await service.prepareGift(_gift, 1),
      );
      final operation = result.operationId;
      expect(
        (await service.takeOffMedal(expectedAccountIdentity: account.identity))
            .state,
        LiveActionState.notSubmitted,
      );
      expect(journal.records['10:6:20']?['operation_id'], operation);
      expect(journal.records['10:6:20']?['state'], 'unknown');
      expect(service.lastAction?.operationId, operation);
    },
  );

  test(
    'medal approval cannot be silently rebound to another login instance',
    () async {
      final identity = account.identity;
      account = LiveInteractionAccount(
        uid: 10,
        loggedIn: true,
        identity: Object(),
        csrf: 'new-token',
      );
      expect(
        (await service.takeOffMedal(expectedAccountIdentity: identity)).state,
        LiveActionState.notSubmitted,
      );
      expect(transport.posts, 0);
    },
  );

  test('wear success requires subsequent official wearing state', () async {
    final medal = (await service.loadPanel()).medals.single;
    final result = await service.wearMedal(
      medal,
      expectedAccountIdentity: account.identity,
    );
    expect(result.state, LiveActionState.succeeded);
    expect(transport.paths.single, endsWith('/wear'));
  });

  test(
    'account switch clears displayed old pending but preserves journal',
    () async {
      transport.failPost = true;
      await service.submitGift(await service.prepareGift(_gift, 1));
      account = LiveInteractionAccount(
        uid: 11,
        loggedIn: true,
        identity: Object(),
        csrf: 'different-token',
      );
      expect(await service.restorePending(), isNull);
      expect(service.lastAction, isNull);
      expect(journal.records['10:6:20']?['state'], 'unknown');
    },
  );

  test(
    'process-interrupted submitting restores unknown without POST',
    () async {
      journal.records['10:6:20'] = {
        'schema': 1,
        'state': 'submitting',
        'operation_id': 'interrupted',
      };
      expect((await service.restorePending())?.state, LiveActionState.unknown);
      expect(journal.records['10:6:20']?['state'], 'unknown');
      expect(transport.posts, 0);
    },
  );

  test('disposing during price revalidation stops unsubmitted gift', () async {
    final confirmation = await service.prepareGift(_gift, 1);
    transport.onGet = (_) => service.dispose();
    expect(
      (await service.submitGift(confirmation)).state,
      LiveActionState.notSubmitted,
    );
    expect(transport.posts, 0);
  });

  test('bag send uses current inventory and no paid price', () async {
    final bag = (await service.loadPanel()).bag.single;
    final confirmation = await service.prepareGift(bag.gift, 2, bagItem: bag);
    expect(confirmation.totalPrice, 0);
    expect(
      (await service.submitGift(confirmation)).state,
      LiveActionState.succeeded,
    );
    expect(transport.paths.single, endsWith('sendBagMultiUser'));
    expect(transport.bodies.single['bag_id'], 4);
    expect(transport.bodies.single['price'], 0);
  });

  test('missing or expired bag expiry cannot become infinite availability', () {
    final data = {
      'gift_config': [
        {'id': 3, 'price': 100, 'coin_type': 'gold'},
      ],
      'list': [
        for (final expiry in [null, -1, 1, 0])
          {
            'type': 1,
            'gift_id': 3,
            'bag_id': 4,
            'gift_num': 2,
            'expire_at': ?expiry,
          },
      ],
    };
    expect(
      LiveInteractionParser.bag(data, 6, 20, now).map((i) => i.available),
      [false, false, false, true],
    );
  });

  test('zero or missing room limit disables gift and special privilege is explicit', () {
    for (final limit in [0, -1]) {
      transport.max = limit;
      expect(
        LiveInteractionParser.gifts(transport.catalog, 6, 20).single.sendable,
        false,
      );
    }
    expect(
      LiveInteractionParser.gift({
        'id': 3,
        'price': 100,
        'coin_type': 'gold',
        'privilege_required': 1,
      }, maxQuantity: 10).sendable,
      false,
    );
  });

  test(
    'hide during asynchronous revalidation revokes a gift not yet submitted',
    () async {
      final confirmation = await service.prepareGift(_gift, 1);
      transport.onGet = (_) => service.invalidateApprovals();
      expect(
        (await service.submitGift(confirmation)).state,
        LiveActionState.notSubmitted,
      );
      expect(transport.posts, 0);
    },
  );

  test('hide during journal flush revokes a gift not yet submitted', () async {
    final confirmation = await service.prepareGift(_gift, 1);
    journal.onWrite = service.invalidateApprovals;
    expect(
      (await service.submitGift(confirmation)).state,
      LiveActionState.notSubmitted,
    );
    expect(transport.posts, 0);
  });

  test('hide does not cancel or replay an already issued gift', () async {
    final confirmation = await service.prepareGift(_gift, 1);
    transport.beforePost = () async {
      service.invalidateApprovals();
    };
    expect(
      (await service.submitGift(confirmation)).state,
      LiveActionState.succeeded,
    );
    expect(transport.posts, 1);
  });

  test(
    'hide cannot overwrite an older unknown operation during medal preflight',
    () async {
      transport.failPost = true;
      final result = await service.submitGift(
        await service.prepareGift(_gift, 1),
      );
      service.invalidateApprovals();
      expect(
        (await service.takeOffMedal(expectedAccountIdentity: account.identity))
            .state,
        LiveActionState.notSubmitted,
      );
      expect(journal.records['10:6:20']?['operation_id'], result.operationId);
      expect(journal.records['10:6:20']?['state'], 'unknown');
    },
  );

  test('hide during medal journal flush prevents its POST', () async {
    final medal = (await service.loadPanel()).medals.single;
    journal.onWrite = service.invalidateApprovals;
    expect(
      (await service.wearMedal(
        medal,
        expectedAccountIdentity: account.identity,
      )).state,
      LiveActionState.notSubmitted,
    );
    expect(transport.posts, 0);
  });

  test(
    'join receipt alone keeps pending until server membership confirms',
    () async {
      final result = await service.submitGift(
        await service.prepareFanAction(LiveGiftPurpose.joinFanClub),
      );
      expect(result.receiptId, 'fixture-receipt');
      expect(result.state, LiveActionState.unknown);
      expect(result.fanStatus?.joined, false);
      transport.level = 1;
      final checked = await service.reconcile(result);
      expect(checked.state, LiveActionState.succeeded);
      expect(checked.receiptId, 'fixture-receipt');
      expect(transport.posts, 1);
    },
  );

  test(
    'lighting requires both matching gift receipt and final lit state',
    () async {
      transport.level = 1;
      final result = await service.submitGift(
        await service.prepareFanAction(LiveGiftPurpose.lightMedal),
      );
      expect(result.state, LiveActionState.unknown);
      transport.light = true;
      final checked = await service.reconcile(result);
      expect(checked.state, LiveActionState.succeeded);
      expect(checked.fanStatus?.isLighted, true);
      expect(transport.posts, 1);
    },
  );

  test(
    'restored receipt can confirm late fan state without another gift',
    () async {
      await service.submitGift(
        await service.prepareFanAction(LiveGiftPurpose.joinFanClub),
      );
      service.dispose();
      final reopened = LiveInteractionService.testing(
        roomId: 6,
        anchorUid: 20,
        transport: transport,
        journal: journal,
        account: () => account,
        now: () => now,
      );
      final pending = await reopened.restorePending();
      transport.level = 1;
      expect(
        (await reopened.reconcile(pending!)).state,
        LiveActionState.succeeded,
      );
      expect(transport.posts, 1);
      reopened.dispose();
    },
  );

  test('late result settles old account journal without replacing new account view', () async {
    final confirmation = await service.prepareGift(_gift, 1);
    final issued = Completer<void>();
    final release = Completer<void>();
    transport.beforePost = () async {
      issued.complete();
      await release.future;
    };
    final pending = service.submitGift(confirmation);
    await issued.future;
    account = LiveInteractionAccount(
      uid: 11,
      loggedIn: true,
      identity: Object(),
      csrf: 'different-token',
    );
    expect((await service.loadPanel()).accountUid, 11);
    expect(service.lastAction, isNull);
    release.complete();
    expect((await pending).state, LiveActionState.succeeded);
    expect(service.lastAction, isNull);
    expect(journal.records['10:6:20']?['state'], 'succeeded');
    expect(journal.records['11:6:20'], isNull);
  });
}

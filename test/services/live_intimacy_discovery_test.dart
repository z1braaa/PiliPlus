import 'dart:async';

import 'package:PiliPlus/services/live_intimacy_discovery.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

const room = LiveIntimacyRoomPreferences(
  anchorUid: 10,
  roomId: 100,
  authorized: true,
);
Map<String, dynamic> response(Map<String, dynamic> data) => {
  'code': 0,
  'data': data,
};
Map<String, dynamic> followed(int uid, int roomId, {bool live = true}) => {
  'uid': uid,
  'roomid': roomId,
  'is_attention': 1,
  'live_status': live ? 1 : 0,
  'uname': 'anchor-$uid',
  'area_id': 1,
  'parent_area_id': 2,
};
Map<String, dynamic> medal(int uid, int roomId, int level) => {
  'medal': {'target_id': uid, 'level': level, 'medal_id': uid * 100},
  'room_info': {'room_id': roomId},
};

const secondRoom = LiveIntimacyRoomPreferences(
  anchorUid: 20,
  roomId: 200,
  authorized: true,
);

Map<String, dynamic> completePage(String path) =>
    path == LiveIntimacyDiscovery.followingPath
    ? response({
        'totalPage': 1,
        'list': [followed(10, 100), followed(20, 200)],
      })
    : response({
        'total_number': 2,
        'list': [medal(10, 100, 5), medal(20, 200, 9)],
        'special_list': [],
        'page_info': {'has_more': false},
      });

class _Identity {
  Object account = Object();
  int uid = 1;
  int generation = 1;
  bool ready = true;
  LiveIntimacyDiscoveryIdentity get current => LiveIntimacyDiscoveryIdentity(
    identity: account,
    uid: uid,
    generation: generation,
    ready: ready,
  );
}

void main() {
  test('uses complete following pages and explicit medal cursors despite short pages', () async {
    final requested = <String>[];
    final discovery = LiveIntimacyDiscovery.testing(
      read: (path, query) async {
        final page = query['page'];
        requested.add('$path:$page');
        if (path == LiveIntimacyDiscovery.followingPath) {
          return response({
            'totalPage': 2,
            'list': [
              if (page == 1)
                followed(10, 100)
              else
                followed(20, 200, live: false),
            ],
          });
        }
        return response({
          'total_number': 2,
          'list': [if (page == 1) medal(10, 100, 20)],
          'special_list': [if (page == 2) medal(20, 200, 30)],
          'page_info': {
            'has_more': page == 1,
            'next_page': 2,
            'next_light_status': 0,
          },
        });
      },
    );
    final found = await discovery.discover([
      room,
      const LiveIntimacyRoomPreferences(
        anchorUid: 20,
        roomId: 200,
        authorized: true,
      ),
      const LiveIntimacyRoomPreferences(
        anchorUid: 30,
        roomId: 300,
        authorized: false,
      ),
    ]);
    expect(requested.length, 4);
    expect(found.map((item) => item.anchorUid), [10, 20]);
    expect(found.first.eligible, isTrue);
    expect(found.last.medalLevel, 30);
    expect(found.last.eligible, isFalse);
  });

  test('missing pagination and repeated cursors are failures rather than empty lists', () async {
    final bad = LiveIntimacyDiscovery.testing(
      read: (_, _) async => response({'list': []}),
    );
    await expectLater(
      bad.discover([room]),
      throwsA(isA<LiveInteractionException>()),
    );
    final loop = LiveIntimacyDiscovery.testing(
      read: (path, query) async => path == LiveIntimacyDiscovery.followingPath
          ? response({
              'totalPage': 1,
              'list': [followed(10, 100)],
            })
          : response({
              'total_number': 0,
              'list': [],
              'special_list': [],
              'page_info': {
                'has_more': true,
                'next_page': 1,
                'next_light_status': 0,
              },
            }),
    );
    await expectLater(
      loop.discover([room]),
      throwsA(isA<LiveInteractionException>()),
    );
  });

  test(
    'terminal empty confirmation page can exceed informational total_page',
    () async {
      final pages = <int>[];
      final discovery = LiveIntimacyDiscovery.testing(
        read: (path, query) async {
          if (path == LiveIntimacyDiscovery.followingPath) {
            return response({
              'totalPage': 1,
              'list': [followed(10, 100)],
            });
          }
          final page = query['page'] as int;
          pages.add(page);
          return response({
            'total_number': 1,
            'list': [if (page == 1) medal(10, 100, 5)],
            'special_list': [],
            'page_info': {
              'current_page': page,
              'total_page': 2,
              'has_more': page < 3,
              'next_page': page + 1,
              'next_light_status': 0,
            },
          });
        },
      );
      expect((await discovery.discover([room])).single.medalOwned, isTrue);
      expect(pages, [1, 2, 3]);
    },
  );

  test(
    'declared medal total cannot hide an incomplete terminal page',
    () async {
      final discovery = LiveIntimacyDiscovery.testing(
        read: (path, query) async => path == LiveIntimacyDiscovery.followingPath
            ? response({
                'totalPage': 1,
                'list': [followed(10, 100)],
              })
            : response({
                'total_number': 2,
                'list': [medal(10, 100, 5)],
                'special_list': [],
                'page_info': {'has_more': false},
              }),
      );
      await expectLater(
        discovery.discover([room]),
        throwsA(isA<LiveInteractionException>()),
      );
    },
  );

  test(
    'recheck normalizes room and requires reliable follow plus medal state',
    () async {
      final discovery = LiveIntimacyDiscovery.testing(
        read: (path, query) async {
          if (path == LiveIntimacyDiscovery.roomPath) {
            return response({
              'room_info': {
                'room_id': 100,
                'uid': 10,
                'live_status': 0,
                'area_id': 1,
                'parent_area_id': 2,
              },
            });
          }
          if (path == '/x/relation') return response({'attribute': 6});
          return response({'level': 8});
        },
      );
      final candidate = await discovery.recheck(room.copyWith(roomId: 1));
      expect(candidate.roomId, 100);
      expect(candidate.followed, isTrue);
      expect(candidate.medalOwned, isTrue);
      expect(candidate.live, isFalse);
    },
  );

  test('only local authorization can cause discovery reads', () async {
    var reads = 0;
    final discovery = LiveIntimacyDiscovery.testing(
      read: (_, _) async {
        reads++;
        return {};
      },
    );
    expect(
      await discovery.discover([room.copyWith(authorized: false)]),
      isEmpty,
    );
    expect(reads, 0);
  });

  test(
    'complete account snapshot serves changed room selection for 60 seconds',
    () async {
      var now = DateTime.utc(2026);
      final reads = <String>[];
      final discovery = LiveIntimacyDiscovery.testing(
        now: () => now,
        read: (path, query) async {
          reads.add(path);
          return completePage(path);
        },
      );
      expect((await discovery.discover([room])).single.anchorUid, 10);
      now = now.add(const Duration(seconds: 59));
      expect((await discovery.discover([secondRoom])).single.medalLevel, 9);
      expect(reads, [
        LiveIntimacyDiscovery.followingPath,
        LiveIntimacyDiscovery.medalsPath,
      ]);
      now = now.add(const Duration(seconds: 1));
      await discovery.discover([room]);
      expect(reads.length, 4);
    },
  );

  test(
    'configuration cancellation preserves a complete same-identity snapshot',
    () async {
      var reads = 0;
      final discovery = LiveIntimacyDiscovery.testing(
        read: (path, query) async {
          reads++;
          return completePage(path);
        },
      );
      await discovery.discover([room]);
      for (var change = 0; change < 3; change++) {
        discovery.cancel();
        expect(
          await discovery.discover([room.copyWith(authorized: false)]),
          isEmpty,
        );
        expect((await discovery.discover([secondRoom])).single.anchorUid, 20);
      }
      expect(reads, 2);
    },
  );

  test('clock rollback invalidates the account snapshot', () async {
    var now = DateTime.utc(2026);
    var reads = 0;
    final discovery = LiveIntimacyDiscovery.testing(
      now: () => now,
      read: (path, query) async {
        reads++;
        return completePage(path);
      },
    );
    await discovery.discover([room]);
    now = now.subtract(const Duration(seconds: 1));
    await discovery.discover([room]);
    expect(reads, 4);
  });

  test(
    'snapshot lifetime starts with the scan rather than its last page',
    () async {
      var now = DateTime.utc(2026);
      var reads = 0;
      final discovery = LiveIntimacyDiscovery.testing(
        now: () => now,
        read: (path, query) async {
          reads++;
          if (reads == 2) now = now.add(const Duration(seconds: 60));
          return completePage(path);
        },
      );
      expect((await discovery.discover([room])).single.eligible, isTrue);
      await discovery.discover([room]);
      expect(reads, 4);
    },
  );

  for (final change in ['account object', 'uid', 'generation']) {
    test('$change cannot reuse a previous account snapshot', () async {
      final identity = _Identity();
      var reads = 0;
      final discovery = LiveIntimacyDiscovery.testing(
        identity: () => identity.current,
        read: (path, query) async {
          reads++;
          return completePage(path);
        },
      );
      await discovery.discover([room]);
      switch (change) {
        case 'account object':
          identity.account = Object();
        case 'uid':
          identity.uid++;
        case 'generation':
          identity.generation++;
      }
      await discovery.discover([room]);
      expect(reads, 4);
    });
  }

  test(
    'login transition invalidates cache and prevents reads until ready',
    () async {
      final identity = _Identity();
      var reads = 0;
      final discovery = LiveIntimacyDiscovery.testing(
        identity: () => identity.current,
        read: (path, query) async {
          reads++;
          return completePage(path);
        },
      );
      await discovery.discover([room]);
      identity.ready = false;
      discovery.cancel();
      await expectLater(
        discovery.discover([room]),
        throwsA(isA<LiveInteractionException>()),
      );
      expect(reads, 2);
      identity.ready = true;
      await discovery.discover([room]);
      expect(reads, 4);
    },
  );

  test('concurrent configurations share one complete account scan', () async {
    final firstPage = Completer<Map<String, dynamic>>();
    var reads = 0;
    final discovery = LiveIntimacyDiscovery.testing(
      read: (path, query) async {
        reads++;
        return path == LiveIntimacyDiscovery.followingPath
            ? firstPage.future
            : completePage(path);
      },
    );
    final first = discovery.discover([room]);
    final second = discovery.discover([secondRoom]);
    expect(reads, 1);
    firstPage.complete(completePage(LiveIntimacyDiscovery.followingPath));
    expect((await first).single.anchorUid, 10);
    expect((await second).single.anchorUid, 20);
    expect(reads, 2);
  });

  for (final change in ['cancel', 'identity']) {
    test(
      'late $change response neither publishes cache nor blocks the next scan',
      () async {
        final identity = _Identity();
        final oldPage = Completer<Map<String, dynamic>>();
        var reads = 0;
        final discovery = LiveIntimacyDiscovery.testing(
          identity: () => identity.current,
          read: (path, query) async {
            reads++;
            return reads == 1 ? oldPage.future : completePage(path);
          },
        );
        final first = discovery.discover([room]);
        final stopped = expectLater(
          first,
          throwsA(isA<LiveInteractionException>()),
        );
        if (change == 'cancel') {
          discovery.cancel();
        } else {
          identity.generation++;
        }
        oldPage.complete(completePage(LiveIntimacyDiscovery.followingPath));
        await stopped;
        expect(reads, 1); // The stale scan must not dispatch its medal request.
        expect((await discovery.discover([room])).single.eligible, isTrue);
        expect(reads, 3);
        await discovery.discover([secondRoom]);
        expect(reads, 3);
      },
    );
  }

  test(
    'failed full scan retains no partial snapshot and backs off for 60 seconds',
    () async {
      var now = DateTime.utc(2026);
      var reads = 0;
      var badMedals = true;
      final discovery = LiveIntimacyDiscovery.testing(
        now: () => now,
        read: (path, query) async {
          reads++;
          if (path == LiveIntimacyDiscovery.medalsPath && badMedals) {
            return response({'list': []});
          }
          return completePage(path);
        },
      );
      await expectLater(
        discovery.discover([room]),
        throwsA(isA<LiveInteractionException>()),
      );
      badMedals = false;
      discovery.cancel();
      now = now.add(const Duration(seconds: 59));
      await expectLater(
        discovery.discover([secondRoom]),
        throwsA(isA<LiveInteractionException>()),
      );
      expect(reads, 2);
      now = now.add(const Duration(seconds: 1));
      expect((await discovery.discover([secondRoom])).single.eligible, isTrue);
      expect(reads, 4); // Both following and medal pages must be fetched again.
    },
  );

  test(
    'failure cooldown belongs only to the account identity that failed',
    () async {
      final identity = _Identity();
      var reads = 0;
      final discovery = LiveIntimacyDiscovery.testing(
        identity: () => identity.current,
        read: (path, query) async {
          reads++;
          return reads == 1 ? response({'list': []}) : completePage(path);
        },
      );
      await expectLater(
        discovery.discover([room]),
        throwsA(isA<LiveInteractionException>()),
      );
      identity.generation++;
      expect((await discovery.discover([room])).single.eligible, isTrue);
      expect(reads, 3);
    },
  );

  test('execution recheck reads current qualification despite cached account lists', () async {
    var reads = 0;
    var qualified = true;
    final discovery = LiveIntimacyDiscovery.testing(
      read: (path, query) async {
        reads++;
        if (path == LiveIntimacyDiscovery.roomPath) {
          return response({
            'room_info': {
              'room_id': 100,
              'uid': 10,
              'live_status': qualified ? 1 : 0,
            },
          });
        }
        if (path == '/x/relation') {
          return response({'attribute': qualified ? 2 : 0});
        }
        if (path.endsWith('GetActivatedMedalInfo')) {
          return response({'level': qualified ? 5 : 0});
        }
        return completePage(path);
      },
    );
    expect((await discovery.discover([room])).single.eligible, isTrue);
    expect((await discovery.recheck(room)).eligible, isTrue);
    qualified = false;
    final fresh = await discovery.recheck(room);
    expect(fresh.followed, isFalse);
    expect(fresh.medalOwned, isFalse);
    expect(fresh.live, isFalse);
    expect(reads, 8);
    await discovery.discover([room]);
    expect(reads, 8);
  });

  test(
    'identity change during fresh recheck stops subsequent qualification reads',
    () async {
      final identity = _Identity();
      var reads = 0;
      final discovery = LiveIntimacyDiscovery.testing(
        identity: () => identity.current,
        read: (path, query) async {
          reads++;
          identity.generation++;
          return response({
            'room_info': {'room_id': 100, 'uid': 10, 'live_status': 1},
          });
        },
      );
      await expectLater(
        discovery.recheck(room),
        throwsA(isA<LiveInteractionException>()),
      );
      expect(reads, 1);
    },
  );
}

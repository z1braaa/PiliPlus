import 'package:PiliPlus/services/live_medal_reader.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> page({
  List<Object?> list = const [],
  int total = 1,
  bool more = false,
  int next = 2,
  int light = 0,
}) => {
  'code': 0,
  'data': {
    'total_number': total,
    'list': list,
    'special_list': [],
    'page_info': {
      'has_more': more,
      'next_page': next,
      'next_light_status': light,
    },
  },
};
Map<String, dynamic> medal(int target, {bool lighted = false}) => {
  'medal': {
    'target_id': target,
    'medal_id': target * 100,
    'level': 2,
    'is_lighted': lighted ? 1 : 0,
    'wearing_status': 0,
  },
};

void main() {
  test('overlapping terminal pages expose positive partial evidence, never completeness', () async {
    Future<Map<String, dynamic>> read(
      String _,
      Map<String, dynamic> query,
    ) async => query['page'] == 1
        ? page(list: [medal(10), medal(20)], total: 3, more: true)
        : page(list: [medal(20)], total: 3);
    final inventory = await readLiveMedalInventory(
      read: read,
      roomId: 100,
      anchorUid: 10,
    );
    expect(inventory.complete, isFalse);
    expect(inventory.medals.map((medal) => medal.targetUid), [10, 20]);
    await expectLater(
      readLiveMedals(read: read, roomId: 100, anchorUid: 10),
      throwsA(isA<LiveMedalReadException>()),
    );
    expect(
      (await readLiveMedalForAnchor(
        read: read,
        roomId: 100,
        anchorUid: 10,
      ))?.targetUid,
      10,
    );
    await expectLater(
      readLiveMedalForAnchor(read: read, roomId: 100, anchorUid: 30),
      throwsA(isA<LiveMedalReadException>()),
    );
  });

  test(
    'target absence is conclusive only after complete terminal inventory',
    () async {
      final target = await readLiveMedalForAnchor(
        read: (_, _) async => page(list: [medal(20)]),
        roomId: 100,
        anchorUid: 10,
      );
      expect(target, isNull);
    },
  );

  test('target lookup stops after validated positive page without guessing cursors', () async {
    var reads = 0;
    final target = await readLiveMedalForAnchor(
      read: (_, _) async {
        reads++;
        return page(list: [medal(10)], total: 2, more: true);
      },
      roomId: 100,
      anchorUid: 10,
    );
    expect(target?.targetUid, 10);
    expect(reads, 1);
  });

  test('target positive lookup still rejects unknown cursor and malformed identities', () async {
    for (final response in [
      page(list: [medal(10)], total: 2, more: true, light: 1),
      page(list: [medal(10), 'malformed'], total: 2),
      {'code': -101},
    ]) {
      await expectLater(
        readLiveMedalForAnchor(
          read: (_, _) async => response,
          roomId: 100,
          anchorUid: 10,
        ),
        throwsA(isA<LiveMedalReadException>()),
      );
    }
  });

  test(
    'conflicting duplicate medal identity is never partial positive evidence',
    () async {
      await expectLater(
        readLiveMedalInventory(
          read: (_, query) async => query['page'] == 1
              ? page(list: [medal(10)], total: 2, more: true)
              : page(
                  list: [
                    {
                      'medal': {
                        'target_id': 20,
                        'medal_id': 1000,
                        'level': 2,
                      },
                    },
                  ],
                  total: 2,
                ),
          roomId: 100,
          anchorUid: 10,
        ),
        throwsA(isA<LiveMedalReadException>()),
      );
    },
  );

  test('unlit and non-wearing are independent of owned inventory', () async {
    final result = await readLiveMedals(
      read: (path, query) async {
        expect(path, '/xlive/app-ucenter/v1/fansMedal/panel');
        expect(query['target_id'], 10);
        return page(list: [medal(10)]);
      },
      roomId: 100,
      anchorUid: 10,
    );
    expect(result.single.targetUid, 10);
    expect(result.single.isLighted, isFalse);
    expect(result.single.wearing, isFalse);
  });

  test('target may be in a later short page with explicit cursor', () async {
    final reads = <int>[];
    final result = await readLiveMedals(
      read: (path, query) async {
        final current = query['page'] as int;
        reads.add(current);
        return current == 1
            ? page(list: [medal(20)], total: 2, more: true, next: 3)
            : page(list: [medal(10)], total: 2);
      },
      roomId: 100,
      anchorUid: 10,
    );
    expect(reads, [1, 3]);
    expect(result.map((medal) => medal.targetUid), [20, 10]);
  });

  test('incomplete terminal inventory cannot imply no target medal', () async {
    await expectLater(
      readLiveMedals(
        read: (_, _) async => page(list: [medal(20)], total: 2),
        roomId: 100,
        anchorUid: 10,
      ),
      throwsA(isA<LiveMedalReadException>()),
    );
  });

  test('malformed list items cannot be silently dropped', () async {
    await expectLater(
      readLiveMedals(
        read: (_, _) async => page(list: ['bad item'], total: 0),
        roomId: 100,
        anchorUid: 10,
      ),
      throwsA(isA<LiveMedalReadException>()),
    );
  });

  test(
    'unverified lighting cursor stops before a guessed next request',
    () async {
      var reads = 0;
      await expectLater(
        readLiveMedals(
          read: (_, query) async {
            reads++;
            expect(query.containsKey('light_status'), isFalse);
            return page(list: [medal(20)], total: 2, more: true, light: 1);
          },
          roomId: 100,
          anchorUid: 10,
        ),
        throwsA(isA<LiveMedalReadException>()),
      );
      expect(reads, 1);
    },
  );
}

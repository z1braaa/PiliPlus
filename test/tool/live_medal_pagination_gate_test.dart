import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/live_medal_pagination_gate.dart';

Map<String, dynamic> _page({
  bool hasMore = true,
  int next = 2,
  int light = 0,
  int id = 918273,
}) => {
  'code': 0,
  'data': {
    'total_number': 25,
    'list': [
      {
        'medal': {'medal_id': id, 'target_id': 817263},
        'uname': 'private-name',
        'url': 'https://private.example/signed',
      },
    ],
    'special_list': [
      {
        'medal': {'medal_id': id, 'target_id': 817263},
      },
    ],
    'page_info': {
      'has_more': hasMore,
      'next_page': next,
      'next_light_status': light,
    },
  },
};

void main() {
  test(
    'separate scope is GET panel bounded to 30 with no light experiments',
    () {
      final uri = Uri.parse(
        'https://api.live.bilibili.com/xlive/app-ucenter/v1/fansMedal/panel',
      );
      for (final page in [1, 2, 30]) {
        expect(
          liveMedalPaginationRequestAllowed(uri, 'GET', {
            'page': page,
            'page_size': 10,
          }),
          isTrue,
        );
      }
      for (final page in [0, 31, '1']) {
        expect(
          liveMedalPaginationRequestAllowed(uri, 'GET', {
            'page': page,
            'page_size': 10,
          }),
          isFalse,
        );
      }
      expect(
        liveMedalPaginationRequestAllowed(uri, 'POST', {
          'page': 1,
          'page_size': 10,
        }),
        isFalse,
      );
      expect(
        liveMedalPaginationRequestAllowed(uri, 'GET', {
          'page': 1,
          'page_size': 10,
          'light_status': 1,
        }),
        isFalse,
      );
      expect(
        liveMedalPaginationRequestAllowed(
          Uri.parse(
            'https://api.live.bilibili.com/xlive/web-ucenter/user/following',
          ),
          'GET',
          {'page': 1, 'page_size': 9},
        ),
        isFalse,
      );
      expect(
        liveMedalPaginationRequestAllowed(
          Uri.parse(
            'https://live-trace.bilibili.com/xlive/data-interface/v1/x25Kn/E',
          ),
          'POST',
          {},
        ),
        isFalse,
      );
    },
  );

  test('uses official next page even when regular list is short', () {
    final cursor = LiveMedalPaginationCursor()..accept(1, _page(next: 3));
    expect(cursor.nextPage, 3);
    cursor.accept(3, _page(hasMore: false, id: 928374));
    expect(cursor.nextPage, isNull);
    expect(cursor.complete, isTrue);
    expect(cursor.summary['unique_medal_identity_count'], 2);
    expect(cursor.summary['regular_item_count'], 2);
    expect(cursor.summary['special_item_count'], 2);
    final encoded = jsonEncode(cursor.summary);
    for (final private in [
      '918273',
      '928374',
      '817263',
      'private-name',
      'private.example',
    ]) {
      expect(encoded.contains(private), isFalse);
    }
  });

  test('nonzero light cursor stops without inventing next request', () {
    final cursor = LiveMedalPaginationCursor()..accept(1, _page(light: 1));
    expect(cursor.nextPage, isNull);
    expect(cursor.complete, isFalse);
    expect(cursor.stopReason, 'unverified_light_status_boundary');
    final pageInfo =
        (cursor.pages.single['nested_pagination'] as Map)['page_info'] as Map;
    expect((pageInfo['values'] as Map)['next_light_status'], 1);
    expect(() => cursor.accept(2, _page()), throwsStateError);
  });

  test('missing/repeated cursors and 30-page bound stop safely', () {
    final repeated = LiveMedalPaginationCursor()..accept(1, _page(next: 1));
    expect(repeated.stopReason, 'unconfirmed_or_repeated_next_page');
    final missing = _page();
    (missing['data']['page_info'] as Map).remove('next_light_status');
    final unknown = LiveMedalPaginationCursor()..accept(1, missing);
    expect(unknown.stopReason, 'unconfirmed_light_status_shape');
    final badList = _page(hasMore: false);
    (badList['data'] as Map).remove('list');
    final malformed = LiveMedalPaginationCursor()..accept(1, badList);
    expect(malformed.stopReason, 'unconfirmed_medal_list_shape');
    expect(malformed.complete, isFalse);
    final bounded = LiveMedalPaginationCursor();
    for (var page = 1; page <= 30; page++) {
      bounded.accept(page, _page(next: page + 1));
    }
    expect(bounded.stopReason, 'page_limit');
    expect(bounded.pages.length, 30);
    expect(bounded.complete, isFalse);
  });

  test(
    'explicit independent env authorization and external report required',
    () {
      final env = {
        'LIVE_MEDAL_PAGINATION_AUTHORIZED': 'true',
        'LIVE_MEDAL_PAGINATION_ROOM': '81004',
        'LIVE_MEDAL_PAGINATION_HIVE': '/private/safe/hive',
        'LIVE_MEDAL_PAGINATION_REPORT': '/private/safe/pages.json',
      };
      expect(LiveMedalPaginationConfig.fromEnvironment(env).roomId, 81004);
      expect(
        () => LiveMedalPaginationConfig.fromEnvironment({
          ...env,
          'LIVE_MEDAL_PAGINATION_AUTHORIZED': 'false',
        }),
        throwsFormatException,
      );
      expect(
        () => LiveMedalPaginationConfig.fromEnvironment({
          ...env,
          'LIVE_MEDAL_PAGINATION_REPORT': '/private/safe/hive/pages.json',
        }),
        throwsFormatException,
      );
    },
  );
}

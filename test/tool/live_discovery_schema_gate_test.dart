import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/live_discovery_schema_gate.dart';

void main() {
  test('schema probe rejects all writes and pages outside explicit sample', () {
    bool allowed(String path, String method, Map<String, dynamic> query) =>
        liveDiscoverySchemaRequestAllowed(
          Uri.parse('https://api.live.bilibili.com$path'),
          method,
          query,
        );
    const following = '/xlive/web-ucenter/user/following';
    const panel = '/xlive/app-ucenter/v1/fansMedal/panel';
    expect(allowed(following, 'GET', {'page': 1, 'page_size': 9}), isTrue);
    expect(allowed(panel, 'GET', {'page': 2, 'page_size': 10}), isTrue);
    for (final page in [0, 3, 100]) {
      expect(
        allowed(following, 'GET', {'page': page, 'page_size': 9}),
        isFalse,
      );
    }
    expect(allowed(following, 'POST', {'page': 1, 'page_size': 9}), isFalse);
    expect(allowed(panel, 'GET', {'page': 1, 'page_size': 50}), isFalse);
    expect(allowed('/msg/send', 'GET', {}), isFalse);
    expect(
      allowed('/xlive/app-ucenter/v1/fansMedal/wear', 'POST', {}),
      isFalse,
    );
    expect(
      liveDiscoverySchemaRequestAllowed(
        Uri.parse(
          'https://live-trace.bilibili.com/xlive/data-interface/v1/x25Kn/E',
        ),
        'POST',
        {},
      ),
      isFalse,
    );
  });

  test(
    'summaries retain only code, field types, count and pagination numbers',
    () {
      final response = <String, dynamic>{
        'code': 0,
        'message': 'private-raw-response-message',
        'data': {
          'pageSize': 9,
          'totalPage': 2,
          'count': 12,
          'live_count': 3,
          'secret': 'private-account-cookie',
          '123456': {'private-uid-as-map-key': 123},
          'list': [
            {
              'uid': 932781,
              'is_attention': 1,
              'live_status': true,
              'uname': 'private-follow-name',
              'roomid': 728319,
              'url': 'https://private.example/signed',
              'medal_info': {
                'target_id': 932781,
                'level': 12,
                'medal_name': 'private-medal-name',
              },
            },
          ],
          'page_info': {
            'total_page': 2,
            'total_count': 12,
            'uid': 932781,
            'number': 9,
            'current_page': 1,
            'next_page': 2,
            'next_light_status': 1,
          },
        },
      };
      final summary = liveDiscoveryPageSummary(response);
      expect(summary['code'], 0);
      expect((summary['pagination'] as Map)['totalPage'], 2);
      final pageInfo =
          (summary['nested_pagination'] as Map)['page_info'] as Map;
      expect(pageInfo['values'], {
        'total_page': 2,
        'total_count': 12,
        'number': 9,
        'current_page': 1,
        'next_page': 2,
        'next_light_status': 1,
      });
      final encoded = jsonEncode(summary);
      for (final private in [
        '932781',
        '728319',
        '123456',
        'private-account-cookie',
        'private-follow-name',
        'private-medal-name',
        'private-raw-response-message',
        'private.example',
      ]) {
        expect(encoded.contains(private), isFalse);
      }
      final list = (summary['lists'] as Map)['list'] as Map;
      expect(list['count'], 1);
      expect((list['item_fields'] as Map)['uid'], ['int']);
      expect(list['public_state_distributions'], {
        'is_attention': {'1': 1},
        'live_status': {'true': 1},
      });
      final hiddenValue = liveDiscoveryPageSummary({
        'code': 0,
        'data': {
          'list': [
            {'is_attention': 932781, 'live_status': 'private-follow-name'},
          ],
        },
      });
      expect(jsonEncode(hiddenValue).contains('932781'), isFalse);
      expect(jsonEncode(hiddenValue).contains('private-follow-name'), isFalse);
    },
  );

  test(
    'special-list and regular-list duplicate comparison emits counts only',
    () {
      final first = <String, dynamic>{
        'list': [
          {
            'medal': {'target_id': 129381},
          },
          {
            'medal': {'target_id': 931822},
          },
        ],
        'special_list': [
          {
            'medal_info': {'target_id': 192873},
          },
        ],
      };
      final second = <String, dynamic>{
        'list': [
          {
            'medal': {'target_id': 192873},
          },
          {
            'medal': {'target_id': 931822},
          },
        ],
        'special_list': [
          {
            'medal_info': {'target_id': 192873},
          },
        ],
      };
      final summary = liveDiscoveryDuplicateSummary(first, second);
      expect(summary['list_cross_page_duplicate_count'], 1);
      expect(summary['special_cross_page_duplicate_count'], 1);
      expect(summary['special_page1_overlaps_regular_count'], 1);
      expect(summary['regular_unique_identity_count'], 3);
      expect(jsonEncode(summary).contains('192873'), isFalse);
    },
  );

  test('config requires explicit opt-in and external report destination', () {
    Map<String, String> config() => {
      'LIVE_DISCOVERY_SCHEMA_AUTHORIZED': 'true',
      'LIVE_DISCOVERY_SCHEMA_ROOM': '81004',
      'LIVE_DISCOVERY_SCHEMA_HIVE': '/private/safe/hive',
      'LIVE_DISCOVERY_SCHEMA_REPORT': '/private/safe/schema.json',
    };
    expect(LiveDiscoverySchemaConfig.fromEnvironment(config()).roomId, 81004);
    for (final change in [
      {'LIVE_DISCOVERY_SCHEMA_AUTHORIZED': 'false'},
      {'LIVE_DISCOVERY_SCHEMA_ROOM': '-1'},
      {'LIVE_DISCOVERY_SCHEMA_HIVE': 'relative'},
      {'LIVE_DISCOVERY_SCHEMA_REPORT': '/private/safe/hive/account.hive'},
      {'LIVE_DISCOVERY_SCHEMA_REPORT': '/private/safe/hive/schema.json'},
    ]) {
      expect(
        () =>
            LiveDiscoverySchemaConfig.fromEnvironment(config()..addAll(change)),
        throwsFormatException,
      );
    }
  });
}

import 'package:flutter_test/flutter_test.dart';

import '../../tool/live_room_profile_gate.dart';

void main() {
  test('default profile cannot read account without runtime authorization', () {
    expect(
      () => LiveRoomProfileConfig.fromEnvironment({}),
      throwsFormatException,
    );
  });
  test(
    'read-only room profile rejects playback, writes, and unrelated identities',
    () {
      final gate = LiveRoomProfileRequestGate([22384516]);
      bool read(
        String host,
        String path,
        Map<String, dynamic> query, {
        String method = 'GET',
      }) => gate.allows(Uri.https(host, path), method, query);
      expect(
        read(
          'api.live.bilibili.com',
          '/xlive/web-room/v1/index/getInfoByRoom',
          {'room_id': 22384516},
        ),
        isTrue,
      );
      gate.registerRoom(requested: 22384516, canonical: 22384516, anchor: 10);
      expect(read('api.bilibili.com', '/x/relation', {'fid': 10}), isTrue);
      expect(read('api.bilibili.com', '/x/relation', {'fid': 20}), isFalse);
      expect(
        read('api.live.bilibili.com', '/xlive/app-ucenter/v1/fansMedal/panel', {
          'room_id': 22384516,
          'target_id': 10,
          'page': 1,
          'page_size': 10,
        }),
        isTrue,
      );
      expect(
        read('api.live.bilibili.com', '/xlive/app-ucenter/v1/fansMedal/panel', {
          'room_id': 22384516,
          'target_id': 10,
          'page': 1,
          'page_size': 10,
          'light_status': 1,
        }),
        isFalse,
      );
      expect(
        read(
          'api.live.bilibili.com',
          '/xlive/web-room/v2/index/getRoomPlayInfo',
          {'room_id': 22384516},
        ),
        isFalse,
      );
      expect(
        read('live-trace.bilibili.com', '/xlive/data-interface/v1/x25Kn/E', {}),
        isFalse,
      );
      expect(
        read('api.live.bilibili.com', '/msg/send', {
          'roomid': 22384516,
        }, method: 'POST'),
        isFalse,
      );
    },
  );
}

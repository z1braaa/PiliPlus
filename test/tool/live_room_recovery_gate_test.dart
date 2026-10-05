import 'package:flutter_test/flutter_test.dart';

import '../../tool/live_room_recovery_gate.dart';

void main() {
  const room = 21013446;
  const anchor = 20;
  const account = 30;
  Map<String, String> environment() => {
    'LIVE_ROOM_RECOVERY_AUTHORIZED': 'true',
    'LIVE_ROOM_RECOVERY_HIVE': '/private/source',
    'LIVE_ROOM_RECOVERY_REPORT': '/private/reports/recovery.json',
    'LIVE_ROOM_RECOVERY_ROOM': '$room',
    'LIVE_ROOM_RECOVERY_ANCHOR': '$anchor',
  };
  LiveRoomRecoveryRequestGate gate() => LiveRoomRecoveryRequestGate(
    roomId: room,
    anchorUid: anchor,
    accountUid: account,
    savedEmoticons: ['saved-a', 'saved-b'],
  )..activateInteractions(0);
  bool send(
    LiveRoomRecoveryRequestGate g,
    String path,
    Map<String, dynamic> body,
    int elapsed, {
    bool enabled = true,
    bool identity = true,
    bool task = true,
  }) => g.allows(
    uri: Uri.https('api.live.bilibili.com', path),
    method: 'POST',
    query: {},
    data: body,
    elapsedMilliseconds: elapsed,
    writesEnabled: enabled,
    identityAndPrivacyConfirmed: identity,
    roomAndTaskConfirmed: task,
  );
  Map<String, dynamic> likes(int clicks) => {
    'room_id': room,
    'anchor_id': anchor,
    'uid': account,
    'click_time': clicks,
  };
  Map<String, dynamic> message(String unique) => {
    'roomid': room,
    'dm_type': 1,
    'msg': unique,
  };

  test(
    'account recovery requires explicit consent and a bounded external report',
    () {
      expect(
        () => LiveRoomRecoveryConfig.fromEnvironment({}),
        throwsFormatException,
      );
      final env = environment();
      expect(LiveRoomRecoveryConfig.fromEnvironment(env).seconds, 360);
      for (final override in [
        {'LIVE_ROOM_RECOVERY_SECONDS': '361'},
        {'LIVE_ROOM_RECOVERY_SECONDS': '120'},
        {'LIVE_ROOM_RECOVERY_REPORT': '/private/source/out.json'},
        {'LIVE_ROOM_RECOVERY_ROOM': '0'},
        {'LIVE_ROOM_RECOVERY_HIVE': 'relative'},
      ]) {
        expect(
          () => LiveRoomRecoveryConfig.fromEnvironment({...env, ...override}),
          throwsFormatException,
        );
      }
    },
  );

  test('free-like allowance is paced, identity bound, and never returned', () {
    final g = gate();
    const path = LiveRoomRecoveryRequestGate.likePath;
    expect(send(g, path, likes(30), 29999), isFalse);
    expect(send(g, path, likes(30), 30000, enabled: false), isFalse);
    expect(send(g, path, likes(30), 30000, identity: false), isFalse);
    expect(send(g, path, likes(30), 30000, task: false), isFalse);
    expect(send(g, path, {...likes(30), 'anchor_id': 21}, 30000), isFalse);
    expect(send(g, path, {...likes(30), 'room_id': 1}, 30000), isFalse);
    expect(send(g, path, likes(30), 30000), isTrue);
    expect(g.attemptedLikeClicks, 30);
    expect(send(g, path, likes(1), 360000), isFalse);
  });

  test('only fresh saved fan-club expressions consume two paced sends', () {
    final g = gate()..confirmEmoticons(['saved-a', 'not-saved'], 30000);
    expect(send(g, '/msg/send', message('not-saved'), 30000), isFalse);
    expect(send(g, '/msg/send', message('saved-b'), 30000), isFalse);
    expect(
      send(g, '/msg/send', {...message('saved-a'), 'dm_type': 0}, 30000),
      isFalse,
    );
    expect(
      send(g, '/msg/send', {...message('saved-a'), 'roomid': 1}, 30000),
      isFalse,
    );
    expect(send(g, '/msg/send', message('saved-a'), 29999), isFalse);
    expect(send(g, '/msg/send', message('saved-a'), 30000), isTrue);
    expect(send(g, '/msg/send', message('saved-a'), 59999), isFalse);
    g.confirmEmoticons(['saved-b'], 60000);
    expect(send(g, '/msg/send', message('saved-b'), 60000), isTrue);
    g.confirmEmoticons(['saved-a'], 90000);
    expect(send(g, '/msg/send', message('saved-a'), 90000), isFalse);
    expect(g.attemptedDanmaku, 2);
  });

  test('stale permissions and expired execution windows cannot send', () {
    final g = gate()..confirmEmoticons(['saved-a'], 0);
    expect(send(g, '/msg/send', message('saved-a'), 30001), isFalse);
    g.confirmEmoticons(['saved-a'], 360001);
    expect(send(g, '/msg/send', message('saved-a'), 360001), isFalse);
    expect(
      send(g, LiveRoomRecoveryRequestGate.likePath, likes(1), 360001),
      isFalse,
    );
  });

  test(
    'GET admission excludes media, watch reporting, gifts, and other rooms',
    () {
      final g = gate();
      bool read(String host, String path, Map<String, dynamic> query) =>
          g.allows(
            uri: Uri.https(host, path),
            method: 'GET',
            query: query,
            elapsedMilliseconds: 0,
            writesEnabled: false,
            identityAndPrivacyConfirmed: true,
            roomAndTaskConfirmed: false,
          );
      expect(read('api.bilibili.com', '/x/web-interface/nav', {}), isTrue);
      expect(read('api.bilibili.com', '/x/relation', {'fid': anchor}), isTrue);
      expect(read('api.bilibili.com', '/x/relation', {'fid': 21}), isFalse);
      expect(
        read(
          'api.live.bilibili.com',
          '/xlive/app-ucenter/v1/fansMedal/GetActivatedMedalInfo',
          {'room_id': room, 'target_id': anchor},
        ),
        isTrue,
      );
      expect(
        read(
          'api.live.bilibili.com',
          '/xlive/web-ucenter/v2/emoticon/GetEmoticons',
          {'room_id': room},
        ),
        isTrue,
      );
      expect(
        read(
          'api.live.bilibili.com',
          '/xlive/web-ucenter/v2/emoticon/GetEmoticons',
          {'room_id': 1},
        ),
        isFalse,
      );
      expect(
        read(
          'api.live.bilibili.com',
          '/xlive/web-room/v2/index/getRoomPlayInfo',
          {'room_id': room, 'only_audio': 1},
        ),
        isFalse,
      );
      expect(
        read('live-trace.bilibili.com', '/xlive/data-interface/v1/x25Kn/E', {}),
        isFalse,
      );
      expect(send(g, '/xlive/revenue/v1/gift/sendGold', {}, 60000), isFalse);
      expect(
        read('api.live.bilibili.com', '/xlive/app-ucenter/v1/fansMedal/panel', {
          'room_id': room,
          'target_id': anchor,
          'page': 1,
          'page_size': 10,
        }),
        isTrue,
      );
      expect(
        read('api.live.bilibili.com', '/xlive/app-ucenter/v1/fansMedal/panel', {
          'room_id': room,
          'target_id': anchor,
          'page': 1,
          'page_size': 10,
          'light_status': 1,
        }),
        isFalse,
      );
      expect(g.acceptedReads, 5);
    },
  );
}

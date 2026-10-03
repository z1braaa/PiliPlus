import 'package:flutter_test/flutter_test.dart';

import '../../tool/live_intimacy_scheduler_acceptance_gate.dart';

void main() {
  const like =
      'https://api.live.bilibili.com/xlive/app-ucenter/v1/like_info_v3/like/likeReportV3';
  const danmaku = 'https://api.live.bilibili.com/msg/send';
  const enter =
      'https://live-trace.bilibili.com/xlive/data-interface/v1/x25Kn/E';
  LiveSchedulerAcceptanceWriteGuard guard({int likes = 60, int messages = 2}) =>
      LiveSchedulerAcceptanceWriteGuard({
        10: LiveSchedulerAcceptanceRoomScope(
          anchorUid: 20,
          emoticon: 'first',
          likeClicks: likes,
          danmakuCount: messages,
        ),
        11: const LiveSchedulerAcceptanceRoomScope(
          anchorUid: 21,
          emoticon: 'other_first',
          likeClicks: 30,
          danmakuCount: 1,
        ),
      })..activateRoom(10, 0);

  bool allowed(
    LiveSchedulerAcceptanceWriteGuard gate,
    String url, {
    int now = 30000,
    String method = 'POST',
    Object? body,
    Map<String, dynamic> query = const {},
    bool enabled = true,
    bool readOnly = false,
    bool identity = true,
    bool Function(int, bool)? authorized,
  }) => gate.allow(
    uri: Uri.parse(url),
    method: method,
    query: query,
    data: body,
    elapsedMilliseconds: now,
    writesEnabled: enabled,
    readOnly: readOnly,
    identityAndPrivacyConfirmed: identity,
    roomAuthorized: authorized ?? (_, _) => true,
  );
  Map<String, dynamic> clicks(int count, {int room = 10, int anchor = 20}) => {
    'room_id': room,
    'anchor_id': anchor,
    'click_time': count,
  };

  test('diagnostic room entry is opt-in, one-shot and room-authorized', () {
    const url =
        'https://api.live.bilibili.com/xlive/web-room/v1/index/roomEntryAction';
    final body = {'room_id': 10, 'platform': 'pc'};
    final query = {'csrf': 'dummy'};
    expect(allowed(guard(), url, body: body, query: query), isFalse);
    final diagnostic = LiveSchedulerAcceptanceWriteGuard({
      10: const LiveSchedulerAcceptanceRoomScope(
        anchorUid: 20,
        emoticon: 'first',
        likeClicks: 0,
        danmakuCount: 0,
      ),
    }, diagnosticRoomEntry: true);
    expect(
      allowed(diagnostic, url, body: body, query: query, readOnly: true),
      isFalse,
    );
    expect(
      allowed(
        diagnostic,
        url,
        body: body,
        query: query,
        authorized: (_, _) => false,
      ),
      isFalse,
    );
    expect(
      allowed(diagnostic, url, body: body, query: query, identity: false),
      isFalse,
    );
    expect(
      allowed(
        diagnostic,
        url,
        body: {'room_id': 11, 'platform': 'pc'},
        query: query,
      ),
      isFalse,
    );
    expect(allowed(diagnostic, url, body: body, query: query), isTrue);
    expect(allowed(diagnostic, url, body: body, query: query), isFalse);
  });

  test('manual runtime consent, bounded native source and external report required', () {
    Map<String, String> config() => {
      'LIVE_SCHEDULER_ACCOUNT_AUTHORIZED': 'true',
      'LIVE_SCHEDULER_HIVE': '/private/acceptance/hive',
      'LIVE_SCHEDULER_MPV': '/Applications/PiliPlus.app/Mpv',
      'LIVE_SCHEDULER_REPORT': '/private/acceptance/report.json',
      'LIVE_SCHEDULER_NATIVE_SOURCE': '5440-local-build',
    };
    expect(
      LiveSchedulerAcceptanceConfig.fromEnvironment(config()).seconds,
      1200,
    );
    expect(
      LiveSchedulerAcceptanceConfig.fromEnvironment(config()).singleRoom,
      isFalse,
    );
    expect(
      LiveSchedulerAcceptanceConfig.fromEnvironment(
        config()..['LIVE_SCHEDULER_SINGLE_ROOM'] = 'true',
      ).singleRoom,
      isTrue,
    );
    for (final mutation in [
      {'LIVE_SCHEDULER_ACCOUNT_AUTHORIZED': 'false'},
      {'LIVE_SCHEDULER_HIVE': 'relative'},
      {'LIVE_SCHEDULER_MPV': '/tmp/mpv\nprivate'},
      {'LIVE_SCHEDULER_NATIVE_SOURCE': 'https://private.example/?signed'},
      {'LIVE_SCHEDULER_SECONDS': '1201'},
      {'LIVE_SCHEDULER_SECONDS': '179'},
      {'LIVE_SCHEDULER_ROOM_A': '7', 'LIVE_SCHEDULER_ROOM_B': '7'},
      {'LIVE_SCHEDULER_SINGLE_ROOM': 'true', 'LIVE_SCHEDULER_ROOM_B': '8'},
      {'LIVE_SCHEDULER_DIAGNOSTIC_ROOM_ENTRY': 'true'},
      {
        'LIVE_SCHEDULER_DIAGNOSTIC_ROOM_ENTRY': 'true',
        'LIVE_SCHEDULER_SINGLE_ROOM': 'true',
        'LIVE_SCHEDULER_READ_ONLY': 'true',
      },
      {'LIVE_SCHEDULER_REPORT': '/private/acceptance/hive/sub/../report.json'},
    ]) {
      expect(
        () => LiveSchedulerAcceptanceConfig.fromEnvironment(
          config()..addAll(mutation),
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'legitimate 30-click first batch requires paced accumulation and spends 30',
    () {
      final gate = guard();
      expect(allowed(gate, like, now: 29999, body: clicks(30)), isFalse);
      expect(gate.remainingLikes(10), 60);
      expect(allowed(gate, like, body: clicks(30)), isTrue);
      expect(gate.remainingLikes(10), 30);
      expect(
        LiveSchedulerAcceptanceWriteGuard.acceptedAmount(
          Uri.parse(like),
          {},
          clicks(30),
        ),
        30,
      );
      expect(allowed(gate, like, now: 30999, body: clicks(30)), isFalse);
      expect(gate.remainingLikes(10), 30);
      expect(allowed(gate, like, now: 31000, body: clicks(30)), isTrue);
      expect(gate.remainingLikes(10), 0);
      expect(allowed(gate, like, now: 90000, body: clicks(1)), isFalse);
    },
  );

  test('ambiguous dispatched batch never replenishes budget on retry or reactivation', () {
    final gate = guard(likes: 30);
    expect(allowed(gate, like, body: clicks(30)), isTrue);
    gate.activateRoom(10, 40000);
    expect(allowed(gate, like, now: 90000, body: clicks(30)), isFalse);
    expect(gate.remainingLikes(10), 0);
    final limited = guard(likes: 29);
    expect(allowed(limited, like, now: 90000, body: clicks(30)), isFalse);
    expect(limited.remainingLikes(10), 29);
  });

  test('invalid identity, grants, body, origin and unlisted actions cannot spend allowance', () {
    final gate = guard();
    expect(allowed(gate, like, body: clicks(30), identity: false), isFalse);
    expect(
      allowed(gate, like, body: clicks(30), authorized: (_, _) => false),
      isFalse,
    );
    expect(allowed(gate, like, body: clicks(30), enabled: false), isFalse);
    expect(allowed(gate, like, body: clicks(30), readOnly: true), isFalse);
    for (final body in [
      clicks(0),
      clicks(-1),
      clicks(61),
      clicks(1, anchor: 21),
      clicks(1, room: 99),
    ]) {
      expect(allowed(gate, like, body: body), isFalse);
    }
    for (final url in [
      like.replaceFirst('https:', 'http:'),
      like.replaceFirst(
        'api.live.bilibili.com',
        'private@api.live.bilibili.com',
      ),
      like.replaceFirst('api.live.bilibili.com', 'api.live.bilibili.com:444'),
      'https://api.live.bilibili.com/gift/v2/live/send',
      'https://api.live.bilibili.com/xlive/web-room/v1/fansMedal/join',
    ]) {
      expect(allowed(gate, url, body: clicks(1)), isFalse);
    }
    expect(gate.remainingLikes(10), 60);
  });

  test('first exact fan-club emote only, no fallback for permission loss', () {
    Map<String, dynamic> package({
      Object? type = 2,
      bool firstPermission = true,
    }) => {
      'pkg_type': type,
      'pkg_name': '粉丝团',
      'perm': true,
      'emoticons': [
        {'emoticon_unique': 'first', 'perm': firstPermission},
        {'emoticon_unique': 'second', 'perm': true},
      ],
    };
    expect(liveSchedulerFirstFanEmoticon([package()]), 'first');
    expect(
      liveSchedulerFirstFanEmoticon([package(firstPermission: false)]),
      isNull,
    );
    expect(liveSchedulerFirstFanEmoticon([package(type: 3)]), isNull);
    expect(liveSchedulerFirstFanEmoticon([package(type: 1)]), isNull);
    final gate = guard();
    Map<String, dynamic> body(String message, {int mode = 1, int room = 10}) =>
        {'roomid': room, 'dm_type': mode, 'msg': message};
    expect(allowed(gate, danmaku, body: body('second')), isFalse);
    expect(allowed(gate, danmaku, body: body('first', mode: 0)), isFalse);
    expect(allowed(gate, danmaku, body: body('first', room: 11)), isFalse);
    expect(allowed(gate, danmaku, body: body('first')), isTrue);
    expect(allowed(gate, danmaku, body: body('first'), now: 59999), isFalse);
    expect(allowed(gate, danmaku, body: body('first'), now: 60000), isTrue);
    expect(allowed(gate, danmaku, body: body('first'), now: 90000), isFalse);
  });

  test('watch writes require exact selected anchor and current single-owner admission', () {
    final gate = guard();
    Map<String, dynamic> packet(int room, int anchor) => {
      'id': '[1,2,3,$room]',
      'ruid': anchor,
    };
    expect(
      allowed(
        gate,
        enter,
        query: packet(10, 20),
        authorized: (room, interactive) => room == 10 && !interactive,
      ),
      isTrue,
    );
    expect(
      allowed(
        gate,
        enter,
        query: packet(11, 21),
        authorized: (room, interactive) => room == 10 && !interactive,
      ),
      isFalse,
    );
    expect(
      allowed(
        gate,
        enter,
        query: packet(11, 21),
        authorized: (room, interactive) => room == 11 && !interactive,
      ),
      isTrue,
    );
    expect(allowed(gate, enter, query: packet(10, 21)), isFalse);
    expect(allowed(gate, enter, query: packet(99, 20)), isFalse);
    expect(
      allowed(gate, enter, query: {'id': 'secret_or_malformed', 'ruid': 20}),
      isFalse,
    );
    expect(
      allowed(
        gate,
        'https://example.com${Uri.parse(enter).path}',
        query: packet(10, 20),
      ),
      isFalse,
    );
  });

  test('read-only selection admits listed GETs but rejects every POST', () {
    final gate = guard();
    expect(
      allowed(
        gate,
        'https://api.bilibili.com/x/web-interface/nav',
        method: 'GET',
        enabled: false,
        readOnly: true,
      ),
      isTrue,
    );
    expect(
      allowed(
        gate,
        'https://api.live.bilibili.com/xlive/app-ucenter/v1/fansMedal/panel',
        method: 'GET',
        enabled: false,
        readOnly: true,
      ),
      isTrue,
    );
    for (final url in [like, danmaku, enter]) {
      expect(
        allowed(
          gate,
          url,
          readOnly: true,
          body: clicks(30),
          query: {'id': '[1,2,3,10]', 'ruid': 20},
        ),
        isFalse,
      );
    }
  });
}

import 'package:flutter_test/flutter_test.dart';

import '../../tool/live_intimacy_like_only_acceptance_gate.dart';

void main() {
  Map<String, String> environment() => {
    'LIVE_LIKE_ONLY_ACCOUNT_AUTHORIZED': 'true',
    'LIVE_LIKE_ONLY_ROOM': '22734699',
    'LIVE_LIKE_ONLY_ANCHOR': '345564775',
    'LIVE_LIKE_ONLY_HIVE': '/private/source-hive',
    'LIVE_LIKE_ONLY_REPORT': '/private/evidence/like-only.json',
  };
  LiveLikeOnlyAcceptanceGate guard() => LiveLikeOnlyAcceptanceGate(
    roomId: 10,
    anchorUid: 20,
    accountUid: 30,
  );
  const like =
      'https://api.live.bilibili.com/xlive/app-ucenter/v1/like_info_v3/like/likeReportV3';
  Map<String, dynamic> body(
    int clicks, {
    int room = 10,
    int anchor = 20,
    int uid = 30,
  }) => {
    'room_id': room,
    'anchor_id': anchor,
    'uid': uid,
    'click_time': clicks,
  };
  bool allowed(
    LiveLikeOnlyAcceptanceGate gate,
    String url, {
    String method = 'POST',
    Map<String, dynamic> query = const {},
    Object? data,
    int now = 30000,
    bool enabled = true,
    bool identity = true,
    bool roomAndTask = true,
  }) => gate.allow(
    uri: Uri.parse(url),
    method: method,
    query: query,
    data: data,
    elapsedMilliseconds: now,
    writesEnabled: enabled,
    identityAndPrivacyConfirmed: identity,
    roomAndTaskConfirmed: roomAndTask,
  );

  test('runtime consent and explicit room binding are mandatory', () {
    final valid = LiveLikeOnlyAcceptanceConfig.fromEnvironment(environment());
    expect(valid.roomId, 22734699);
    expect(valid.anchorUid, 345564775);
    expect(valid.seconds, 150);
    for (final key in [
      'LIVE_LIKE_ONLY_ACCOUNT_AUTHORIZED',
      'LIVE_LIKE_ONLY_ROOM',
      'LIVE_LIKE_ONLY_ANCHOR',
    ]) {
      final env = environment()..remove(key);
      expect(
        () => LiveLikeOnlyAcceptanceConfig.fromEnvironment(env),
        throwsFormatException,
      );
    }
    expect(
      () => LiveLikeOnlyAcceptanceConfig.fromEnvironment(
        environment()..['LIVE_LIKE_ONLY_ACCOUNT_AUTHORIZED'] = 'yes',
      ),
      throwsFormatException,
    );
  });

  test('report cannot overwrite source storage and window is bounded', () {
    for (final path in [
      '/private/source-hive/result.json',
      '/private/evidence/../source-hive/result.json',
      'relative.json',
      '/private/evidence/no-json',
      '/private/unsafe\n.json',
    ]) {
      expect(
        () => LiveLikeOnlyAcceptanceConfig.fromEnvironment(
          environment()..['LIVE_LIKE_ONLY_REPORT'] = path,
        ),
        throwsFormatException,
      );
    }
    for (final seconds in ['0', '59', '181', '99999', 'bad']) {
      expect(
        () => LiveLikeOnlyAcceptanceConfig.fromEnvironment(
          environment()..['LIVE_LIKE_ONLY_SECONDS'] = seconds,
        ),
        throwsFormatException,
      );
    }
  });

  test('cap survives reactivation and rejected attempts do not restore it', () {
    final gate = guard()..activateInteractions(0);
    expect(allowed(gate, like, data: body(30), now: 29999), isFalse);
    expect(gate.remainingLikeClicks, 30);
    expect(allowed(gate, like, data: body(30)), isTrue);
    expect(gate.attemptedLikeClicks, 30);
    gate.activateInteractions(100000);
    expect(allowed(gate, like, data: body(1), now: 200000), isFalse);
    expect(gate.remainingLikeClicks, 0);
  });

  test(
    'each additional batch retains at least one second per modeled click',
    () {
      final gate = guard()..activateInteractions(10000);
      expect(allowed(gate, like, data: body(10), now: 19999), isFalse);
      expect(allowed(gate, like, data: body(10), now: 20000), isTrue);
      expect(allowed(gate, like, data: body(20), now: 39999), isFalse);
      expect(allowed(gate, like, data: body(20), now: 40000), isTrue);
      expect(gate.attemptedLikeClicks, 30);
    },
  );

  test('identity, current manual room authorization and fresh task gate every like', () {
    final gate = guard()..activateInteractions(0);
    expect(allowed(gate, like, data: body(30), identity: false), isFalse);
    expect(allowed(gate, like, data: body(30), roomAndTask: false), isFalse);
    expect(allowed(gate, like, data: body(30), enabled: false), isFalse);
    for (final packet in [
      body(30, room: 11),
      body(30, anchor: 21),
      body(30, uid: 31),
      body(0),
      body(-1),
      body(31),
    ]) {
      expect(allowed(gate, like, data: packet), isFalse);
    }
    expect(gate.attemptedLikeClicks, 0);
    expect(allowed(gate, like, data: body(30)), isTrue);
  });

  test('no media source, heartbeat, danmaku, gift, wear or entry endpoint is admitted', () {
    final gate = guard()..activateInteractions(0);
    for (final url in [
      'https://live-trace.bilibili.com/xlive/data-interface/v1/x25Kn/E',
      'https://live-trace.bilibili.com/xlive/data-interface/v1/x25Kn/X',
      'https://api.live.bilibili.com/msg/send',
      'https://api.live.bilibili.com/gift/v2/live/send',
      'https://api.live.bilibili.com/xlive/web-room/v1/fansMedal/join',
      'https://api.live.bilibili.com/xlive/web-room/v1/index/roomEntryAction',
      'https://api.live.bilibili.com/xlive/web-room/v1/fansMedal/wear',
    ]) {
      expect(allowed(gate, url, data: body(1)), isFalse);
    }
    for (final path in [
      '/room/v1/Room/room_init',
      '/xlive/web-room/v2/index/getRoomPlayInfo',
      '/xlive/web-ucenter/v2/emoticon/GetEmoticons',
    ]) {
      expect(
        allowed(
          gate,
          'https://api.live.bilibili.com$path',
          method: 'GET',
          query: {'room_id': 10, 'only_audio': 1},
        ),
        isFalse,
      );
    }
    expect(gate.attemptedLikeClicks, 0);
  });

  test('read-only preflight and complete medal pagination stay scoped to explicit anchor', () {
    final gate = guard();
    const medal =
        'https://api.live.bilibili.com/xlive/app-ucenter/v1/fansMedal/panel';
    final query = {'room_id': 10, 'target_id': 20, 'page': 1, 'page_size': 10};
    expect(
      allowed(gate, medal, method: 'GET', query: query, enabled: false),
      isTrue,
    );
    for (final change in [
      {'room_id': 11},
      {'target_id': 21},
      {'page': 0},
      {'page': 501},
      {'page_size': 20},
      {'light_status': 1},
    ]) {
      expect(
        allowed(gate, medal, method: 'GET', query: {...query, ...change}),
        isFalse,
      );
    }
    expect(
      allowed(
        gate,
        'https://api.bilibili.com/x/relation',
        method: 'GET',
        query: {'fid': 20},
        enabled: false,
      ),
      isTrue,
    );
    expect(
      allowed(
        gate,
        'https://api.bilibili.com/x/relation',
        method: 'GET',
        query: {'fid': 21},
      ),
      isFalse,
    );
    expect(
      allowed(gate, medal, method: 'GET', query: query, identity: false),
      isFalse,
    );
    expect(gate.attemptedLikeClicks, 0);
  });

  test(
    'URI origin manipulation and unlisted methods cannot spend the allowance',
    () {
      final gate = guard()..activateInteractions(0);
      for (final url in [
        like.replaceFirst('https:', 'http:'),
        like.replaceFirst(
          'api.live.bilibili.com',
          'private@api.live.bilibili.com',
        ),
        like.replaceFirst('api.live.bilibili.com', 'api.live.bilibili.com:444'),
        like.replaceFirst(
          'api.live.bilibili.com',
          'api.live.bilibili.com.evil.example',
        ),
        '$like#fragment',
      ]) {
        expect(allowed(gate, url, data: body(30)), isFalse);
      }
      expect(allowed(gate, like, method: 'PUT', data: body(30)), isFalse);
      expect(gate.remainingLikeClicks, 30);
    },
  );
}

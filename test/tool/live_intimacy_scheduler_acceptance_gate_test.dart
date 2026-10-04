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

  test('expanded test authorization permits only the selected five emotes in their own room', () {
    final gate = LiveSchedulerAcceptanceWriteGuard({
      10: const LiveSchedulerAcceptanceRoomScope(
        anchorUid: 20,
        emoticon: 'first',
        additionalEmoticons: {'two', 'three', 'four', 'five'},
        likeClicks: 0,
        danmakuCount: 5,
      ),
    });
    Map<String, dynamic> body(String message, {int mode = 1, int room = 10}) =>
        {'roomid': room, 'dm_type': mode, 'msg': message};
    expect(allowed(gate, danmaku, body: body('six')), isFalse);
    expect(allowed(gate, danmaku, body: body('first', mode: 0)), isFalse);
    expect(allowed(gate, danmaku, body: body('two', room: 11)), isFalse);
    var at = 30000;
    for (final expression in ['first', 'two', 'three', 'four', 'five']) {
      expect(allowed(gate, danmaku, body: body(expression), now: at), isTrue);
      at += 30000;
    }
    expect(allowed(gate, danmaku, body: body('first'), now: at), isFalse);
  });

  test('overlarge or empty emote scope cannot submit a request', () {
    for (final extras in [
      <String>{'two', 'three', 'four', 'five', 'six'},
      <String>{''},
    ]) {
      final gate = LiveSchedulerAcceptanceWriteGuard({
        10: LiveSchedulerAcceptanceRoomScope(
          anchorUid: 20,
          emoticon: 'first',
          additionalEmoticons: extras,
          likeClicks: 0,
          danmakuCount: 5,
        ),
      });
      expect(
        allowed(
          gate,
          danmaku,
          body: {'roomid': 10, 'dm_type': 1, 'msg': 'first'},
        ),
        isFalse,
      );
    }
  });

  test(
    'room diagnostic telemetry keeps fixed pause and record failure causes',
    () {
      expect(liveSchedulerSafeStateReason(null), {
        'present': false,
        'category': null,
        'message': null,
      });
      for (final entry in const {
        '仅音频播放失败，已暂停此房间': 'audio_playback_failed',
        '后台仅音频在20秒内无有效播放，已暂停此房间观时': 'audio_startup_no_effective_playback',
        '本地观时记录读取失败，此房间等待恢复后继续': 'record_restore_failed',
        '本地观时记录保存失败，尚未保存的记录等待重试': 'record_save_failed',
        '仅音频有效观时已覆盖一轮及结算等待，官方轮数仍未增长；已暂停此房间': 'watch_settlement_not_observed',
      }.entries) {
        expect(liveSchedulerSafeStateReason(entry.key), {
          'present': true,
          'category': entry.value,
          'message': entry.key,
        });
      }
    },
  );

  test(
    'room diagnostics retain bounded reporter codes without unknown text',
    () {
      const known = '观看 X 心跳失败（HTTP 503），结果未知，已暂停；不会自动重发';
      expect(liveSchedulerSafeStateReason(known), {
        'present': true,
        'category': 'watch_request_failed',
        'message': known,
      });
      const rejected = '官方拒绝本次互动（-101），自动操作暂停';
      expect(liveSchedulerSafeStateReason(rejected), {
        'present': true,
        'category': 'interaction_rejected',
        'message': rejected,
      });
      for (final text in [
        '$known https://media.example/token?cookie=private',
        '仅音频播放失败，已暂停此房间\nAuthorization: private',
        '观看 X 心跳失败（HTTP 503 private），结果未知，已暂停；不会自动重发',
        '官方拒绝本次互动（-101），自动操作暂停 https://secret.example',
        'raw native error https://secret.example',
      ]) {
        final diagnostic = liveSchedulerSafeStateReason(text);
        expect(diagnostic['present'], isTrue);
        expect(
          diagnostic['message'],
          'unrecognized_diagnostic_text_suppressed',
        );
        expect(diagnostic.toString(), isNot(contains('private')));
        expect(diagnostic.toString(), isNot(contains('https://')));
      }
    },
  );

  test('native diagnostics retain only bounded categories and qualified HTTP codes', () {
    const secret = 'https://media.example/403/token?cookie=private';
    expect(
      liveSchedulerNativeErrorCategory('HTTP error 403 Forbidden $secret'),
      {'category': 'http_error', 'http_status': 403},
    );
    expect(
      liveSchedulerNativeErrorCategory('Error while decoding frame $secret'),
      {'category': 'decode_or_format_error'},
    );
    expect(
      liveSchedulerNativeErrorCategory('Connection timed out $secret'),
      {'category': 'timeout'},
    );
    expect(
      liveSchedulerNativeErrorCategory('Unknown failure $secret'),
      {'category': 'native_error_unclassified'},
    );
  });

  test(
    'native error recovery requires three continuous effective AV samples',
    () {
      final monitor = LiveSchedulerNativeErrorMonitor()..error(0);
      for (final at in [1000, 2000]) {
        monitor.sample(
          elapsedMilliseconds: at,
          effectivePlayback: true,
          userPaused: false,
        );
        expect(monitor.state, 'native_error_awaiting_decoder_evidence');
      }
      monitor.sample(
        elapsedMilliseconds: 3000,
        effectivePlayback: true,
        userPaused: false,
      );
      expect(
        monitor.state,
        'native_error_recovered_three_effective_av_samples',
      );
      expect(monitor.effectiveAvLossObserved, isFalse);
      // Buffered output briefly recovering cannot hide a subsequent loss.
      for (final at in [4000, 24000]) {
        monitor.sample(
          elapsedMilliseconds: at,
          effectivePlayback: false,
          userPaused: false,
        );
      }
      expect(monitor.state, 'native_error_no_effective_av_for_20_seconds');
      expect(monitor.effectiveAvLossObserved, isTrue);
    },
  );

  test(
    'native monitoring does not count manual pause as persistent decoder loss',
    () {
      final monitor = LiveSchedulerNativeErrorMonitor()
        ..error(0)
        ..sample(
          elapsedMilliseconds: 1000,
          effectivePlayback: false,
          userPaused: false,
        )
        ..sample(
          elapsedMilliseconds: 30000,
          effectivePlayback: false,
          userPaused: true,
        );
      expect(monitor.state, 'native_error_observation_user_paused');
      expect(monitor.effectiveAvLossObserved, isFalse);
      monitor.sample(
        elapsedMilliseconds: 31000,
        effectivePlayback: false,
        userPaused: false,
      );
      expect(monitor.effectiveAvLossObserved, isFalse);
      monitor.sample(
        elapsedMilliseconds: 51000,
        effectivePlayback: false,
        userPaused: false,
      );
      expect(monitor.effectiveAvLossObserved, isTrue);
    },
  );

  test(
    'stale or sparse native samples do not establish continuous recovery',
    () {
      final monitor = LiveSchedulerNativeErrorMonitor()..error(0);
      for (final at in [1000, 1000, 8000, 9000]) {
        monitor.sample(
          elapsedMilliseconds: at,
          effectivePlayback: true,
          userPaused: false,
        );
        expect(monitor.state, 'native_error_awaiting_decoder_evidence');
      }
      monitor.sample(
        elapsedMilliseconds: 10000,
        effectivePlayback: true,
        userPaused: false,
      );
      expect(
        monitor.state,
        'native_error_recovered_three_effective_av_samples',
      );
    },
  );

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

  test('watch-only zero write budgets block both interactions but admit the selected watch owner', () {
    final gate = guard(likes: 0, messages: 0);
    expect(allowed(gate, like, body: clicks(30)), isFalse);
    expect(
      allowed(
        gate,
        danmaku,
        body: {'roomid': 10, 'dm_type': 1, 'msg': 'first'},
      ),
      isFalse,
    );
    expect(
      allowed(
        gate,
        enter,
        query: {'id': '[1,2,3,10]', 'ruid': 20},
        authorized: (room, interactive) => room == 10 && !interactive,
      ),
      isTrue,
    );
    expect(gate.remainingLikes(10), 0);
    expect(gate.remainingDanmaku(10), 0);
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
      LiveSchedulerAcceptanceConfig.fromEnvironment(config()).fanEmotePoolSize,
      1,
    );
    expect(
      LiveSchedulerAcceptanceConfig.fromEnvironment(
        config()..['LIVE_SCHEDULER_FAN_EMOTE_POOL_SIZE'] = '5',
      ).fanEmotePoolSize,
      5,
    );
    expect(
      LiveSchedulerAcceptanceConfig.fromEnvironment(config()).singleRoom,
      isFalse,
    );
    expect(
      LiveSchedulerAcceptanceConfig.fromEnvironment(config()).stopMarkerPath,
      '/private/acceptance/report.json.stop',
    );
    expect(
      LiveSchedulerAcceptanceConfig.fromEnvironment(
        config()..['LIVE_SCHEDULER_SINGLE_ROOM'] = 'true',
      ).singleRoom,
      isTrue,
    );
    final continued = LiveSchedulerAcceptanceConfig.fromEnvironment(
      config()
        ..['LIVE_SCHEDULER_MAX_LIKE_A'] = '270'
        ..['LIVE_SCHEDULER_MAX_DM_A'] = '8'
        ..['LIVE_SCHEDULER_MAX_LIKE_B'] = '270'
        ..['LIVE_SCHEDULER_MAX_DM_B'] = '9'
        ..['LIVE_SCHEDULER_KEEP_B_WATCH'] = 'true',
    );
    expect(continued.keepBWatchPriority, isTrue);
    expect(continued.limitedInteractionBudget('A', 'like', 300), 270);
    expect(continued.limitedInteractionBudget('A', 'like', 240), 240);
    expect(continued.limitedInteractionBudget('A', 'sendDanmu', 10), 8);
    expect(continued.limitedInteractionBudget('B', 'sendDanmu', 10), 9);
    expect(continued.watchOnly, isFalse);
    final watchOnly = LiveSchedulerAcceptanceConfig.fromEnvironment(
      config()
        ..['LIVE_SCHEDULER_SINGLE_ROOM'] = 'true'
        ..['LIVE_SCHEDULER_MAX_LIKE_A'] = '0'
        ..['LIVE_SCHEDULER_MAX_DM_A'] = '0',
    );
    expect(watchOnly.watchOnly, isTrue);
    expect(watchOnly.limitedInteractionBudget('A', 'like', 300), 0);
    expect(watchOnly.limitedInteractionBudget('A', 'sendDanmu', 10), 0);
    expect(
      LiveSchedulerAcceptanceConfig.fromEnvironment(
        config()..['LIVE_SCHEDULER_SINGLE_ROOM'] = 'true',
      ).watchOnly,
      isFalse,
    );
    for (final mutation in [
      {'LIVE_SCHEDULER_ACCOUNT_AUTHORIZED': 'false'},
      {'LIVE_SCHEDULER_HIVE': 'relative'},
      {'LIVE_SCHEDULER_MPV': '/tmp/mpv\nprivate'},
      {'LIVE_SCHEDULER_NATIVE_SOURCE': 'https://private.example/?signed'},
      {'LIVE_SCHEDULER_SECONDS': '1201'},
      {'LIVE_SCHEDULER_SECONDS': '179'},
      {'LIVE_SCHEDULER_MAX_LIKE_A': '-1'},
      {'LIVE_SCHEDULER_MAX_LIKE_A': '10001'},
      {'LIVE_SCHEDULER_MAX_DM_A': 'not_a_number'},
      {'LIVE_SCHEDULER_FAN_EMOTE_POOL_SIZE': '0'},
      {'LIVE_SCHEDULER_FAN_EMOTE_POOL_SIZE': '6'},
      {'LIVE_SCHEDULER_FAN_EMOTE_POOL_SIZE': 'invalid'},
      {
        'LIVE_SCHEDULER_SINGLE_ROOM': 'true',
        'LIVE_SCHEDULER_KEEP_B_WATCH': 'true',
      },
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

  test('watch transfers do not restart first interaction activation or like cooldown', () {
    final gate = guard()..activateRoom(10, 29000);
    expect(allowed(gate, like, now: 30000, body: clicks(30)), isTrue);
    gate.activateRoom(10, 30001);
    expect(allowed(gate, like, now: 30999, body: clicks(30)), isFalse);
    expect(allowed(gate, like, now: 31000, body: clicks(30)), isTrue);
    expect(gate.remainingLikes(10), 0);
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

  test('emote attempts share a global account cooldown across rooms and reactivation', () {
    final gate = guard();
    Map<String, dynamic> body(int room, String emote) => {
      'roomid': room,
      'dm_type': 1,
      'msg': emote,
    };
    expect(allowed(gate, danmaku, body: body(10, 'first')), isTrue);
    gate.activateRoom(11, 40000);
    expect(
      allowed(gate, danmaku, now: 59999, body: body(11, 'other_first')),
      isFalse,
    );
    expect(gate.remainingDanmaku(11), 1);
    expect(
      allowed(gate, danmaku, now: 60000, body: body(11, 'other_first')),
      isTrue,
    );
    gate.activateRoom(10, 70000);
    expect(
      allowed(gate, danmaku, now: 89999, body: body(10, 'first')),
      isFalse,
    );
    expect(
      allowed(gate, danmaku, now: 90000, body: body(10, 'first')),
      isTrue,
    );
  });

  test(
    'eligible authorized interaction room need not own the watch reporter',
    () {
      final gate = guard()..activateRoom(11, 0);
      bool admission(int room, bool interactive) =>
          interactive ? const {10, 11}.contains(room) : room == 10;
      expect(
        allowed(
          gate,
          like,
          body: clicks(30, room: 11, anchor: 21),
          authorized: admission,
        ),
        isTrue,
      );
      expect(
        allowed(
          gate,
          danmaku,
          body: {'roomid': 11, 'dm_type': 1, 'msg': 'other_first'},
          authorized: admission,
        ),
        isTrue,
      );
      expect(
        allowed(
          gate,
          enter,
          query: {'id': '[1,2,3,11]', 'ruid': 21},
          authorized: admission,
        ),
        isFalse,
      );
      expect(
        allowed(
          gate,
          enter,
          query: {'id': '[1,2,3,10]', 'ruid': 20},
          authorized: admission,
        ),
        isTrue,
      );
    },
  );

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

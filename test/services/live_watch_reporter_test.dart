// Distinct identities exercise account-instance and login-generation boundaries.
// ignore_for_file: prefer_const_constructors
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/live_watch_reporter.dart';
import 'package:PiliPlus/services/live_watch_signer.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Timer implements Timer {
  final Duration delay;
  final void Function() callback;
  bool active = true;
  _Timer(this.delay, this.callback);
  void fire() {
    if (!active) return;
    active = false;
    callback();
  }

  @override
  void cancel() => active = false;
  @override
  bool get isActive => active;
  @override
  int get tick => active ? 0 : 1;
}

class _Transport implements LiveWatchTransport {
  final paths = <String>[];
  final queries = <Map<String, Object>>[];
  final tokens = <CancelToken>[];
  final owners = <Object>[];
  Future<Map<String, dynamic>> Function(String)? onPost;
  Future<LiveWatchDevice> Function()? onPrepare;
  int prepares = 0;
  Map<String, dynamic> challenge = {
    'heartbeat_interval': 60,
    'secret_key': 'fixture-key',
    'secret_rule': [0, 1, 2, 3, 4, 5],
    'timestamp': 1700000000,
  };
  @override
  Future<LiveWatchDevice> prepare(
    int roomId,
    LiveWatchAccount account,
    CancelToken token,
  ) async {
    ++prepares;
    tokens.add(token);
    return onPrepare?.call() ??
        const LiveWatchDevice(
          buvid: 'FAKE-BUVID',
          mixinKey: '0123456789abcdef0123456789abcdef',
        );
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, Object> query,
    LiveWatchAccount account,
    CancelToken token,
  ) async {
    paths.add(path);
    queries.add(Map.of(query));
    tokens.add(token);
    owners.add(account.identity);
    return onPost?.call(path) ?? {'code': 0, 'data': Map.of(challenge)};
  }
}

class _Fixture {
  final transport = _Transport();
  Duration elapsed = Duration.zero;
  DateTime wall = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  LiveWatchAccount account = LiveWatchAccount(
    uid: 123,
    identity: Object(),
    loggedIn: true,
    csrf: 'fixture-csrf',
  );
  final timers = <_Timer>[];
  bool _enabled = true;
  bool _playing = true;
  bool _buffering = false;
  bool _live = true;
  late final reporter = LiveWatchReporter.testing(
    roomId: 21452505,
    anchorUid: 434334701,
    areaId: 2,
    parentAreaId: 1,
    transport: transport,
    account: () => account,
    now: () => wall,
    monotonicNow: () => elapsed,
    uuid: () => '00000000-0000-4000-8000-000000000000',
    schedule: (delay, callback) {
      final timer = _Timer(delay, callback);
      timers.add(timer);
      return timer;
    },
  );
  Future<void> play({
    bool enabled = true,
    bool playing = true,
    bool buffering = false,
    bool live = true,
  }) async {
    _enabled = enabled;
    _playing = playing;
    _buffering = buffering;
    _live = live;
    reporter.updatePlayback(
      enabled: enabled,
      playing: playing,
      buffering: buffering,
      live: live,
    );
    await reporter.settled;
  }

  Future<void> advance(int seconds) async {
    for (var second = 0; second < seconds; ++second) {
      elapsed += const Duration(seconds: 1);
      wall = wall.add(const Duration(seconds: 1));
      reporter.updatePlayback(
        enabled: _enabled,
        playing: _playing,
        buffering: _buffering,
        live: _live,
      );
    }
    timers.last.fire();
    await reporter.settled;
  }

  void dispose() => reporter.dispose();
}

void main() {
  test(
    'Native watch samples reject stalled positions, seeks and missing media',
    () {
      final observation = LiveWatchMediaObservation()
        ..observe(position: Duration.zero, clock: Duration.zero)
        ..observe(
          position: Duration.zero,
          clock: const Duration(seconds: 1),
        );
      expect(observation.advancingAt(const Duration(seconds: 1)), isFalse);
      observation.observe(
        position: const Duration(seconds: 1),
        clock: const Duration(seconds: 2),
      );
      expect(observation.advancingAt(const Duration(seconds: 2)), isTrue);
      expect(observation.advancingAt(const Duration(seconds: 6)), isFalse);
      observation.observe(
        position: const Duration(seconds: 600),
        clock: const Duration(seconds: 602),
      );
      expect(observation.advancingAt(const Duration(seconds: 602)), isFalse);
      observation.observe(
        position: const Duration(seconds: 601),
        clock: const Duration(seconds: 603),
      );
      expect(observation.advancingAt(const Duration(seconds: 603)), isTrue);
      observation.observe(
        position: const Duration(seconds: 900),
        clock: const Duration(seconds: 604),
      );
      expect(observation.advancingAt(const Duration(seconds: 604)), isFalse);
      observation.freeze();
      expect(observation.advancingAt(const Duration(seconds: 604)), isFalse);
    },
  );

  Map<String, Object> navigation({int code = 0, int uid = 123}) => {
    'code': code,
    'data': {
      'isLogin': code == 0,
      if (code == 0) 'mid': uid,
      'wbi_img': {
        'img_url':
            'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
        'sub_url':
            'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
      },
    },
  };

  group('Official device and WBI preparation', () {
    test(
      'Missing device uses room-init cookie before account navigation',
      () async {
        var buvid = '';
        final paths = <String>[];
        final queries = <Map<String, Object>>[];
        final device = await LiveWatchPreparation.prepare(
          roomId: 5438,
          uid: 123,
          readBuvid: () async => buvid,
          guard: () {},
          get: (path, query) async {
            paths.add(path);
            queries.add(query);
            if (path == LiveWatchPreparation.roomInit) {
              // Simulates AccountManager saving the official response cookie.
              buvid = 'fixture-live-buvid';
              return {
                'code': 0,
                'data': {'room_id': 5438},
              };
            }
            return navigation();
          },
        );
        expect(paths, [
          LiveWatchPreparation.roomInit,
          LiveWatchPreparation.nav,
        ]);
        expect(queries, [
          {'id': 5438},
          <String, Object>{},
        ]);
        expect(device.buvid, 'fixture-live-buvid');
        expect(device.mixinKey.length, 32);
      },
    );

    test('Existing device does not repeat room initialization', () async {
      final paths = <String>[];
      await LiveWatchPreparation.prepare(
        roomId: 5438,
        uid: 123,
        readBuvid: () async => 'fixture-live-buvid',
        guard: () {},
        get: (path, _) async {
          paths.add(path);
          return navigation();
        },
      );
      expect(paths, [LiveWatchPreparation.nav]);
    });

    test(
      'Missing response cookie stops with a device-specific diagnostic',
      () async {
        final paths = <String>[];
        await expectLater(
          LiveWatchPreparation.prepare(
            roomId: 5438,
            uid: 123,
            readBuvid: () async => '',
            guard: () {},
            get: (path, _) async {
              paths.add(path);
              return {'code': 0};
            },
          ),
          throwsA(
            isA<LiveWatchProtocolException>()
                .having((e) => e.diagnostic, 'reason', contains('LIVE_BUVID'))
                .having((e) => e.unsupported, 'retryable preparation', isFalse),
          ),
        );
        expect(paths, [LiveWatchPreparation.roomInit]);
      },
    );

    test(
      'Expired navigation cannot reuse its publicly available WBI keys',
      () async {
        await expectLater(
          LiveWatchPreparation.prepare(
            roomId: 5438,
            uid: 123,
            readBuvid: () async => 'fixture-live-buvid',
            guard: () {},
            get: (_, _) async => navigation(code: -101),
          ),
          throwsA(
            isA<LiveWatchProtocolException>()
                .having((e) => e.diagnostic, 'reason', contains('登录会话已过期'))
                .having((e) => e.apiCode, 'code', -101),
          ),
        );
      },
    );

    test('Different logged-in navigation identity stops before E', () async {
      await expectLater(
        LiveWatchPreparation.prepare(
          roomId: 5438,
          uid: 123,
          readBuvid: () async => 'fixture-live-buvid',
          guard: () {},
          get: (_, _) async => navigation(uid: 456),
        ),
        throwsA(
          isA<LiveWatchProtocolException>().having(
            (e) => e.diagnostic,
            'reason',
            contains('身份不一致'),
          ),
        ),
      );
    });

    test('Malformed WBI address never appears in the diagnostic', () async {
      final response = navigation();
      (response['data'] as Map)['wbi_img'] = {
        'img_url': 'PRIVATE-WBI-CONTENT',
        'sub_url': 5,
      };
      await expectLater(
        LiveWatchPreparation.prepare(
          roomId: 5438,
          uid: 123,
          readBuvid: () async => 'fixture-live-buvid',
          guard: () {},
          get: (_, _) async => response,
        ),
        throwsA(
          isA<LiveWatchProtocolException>()
              .having((e) => e.diagnostic, 'reason', contains('WBI'))
              .having(
                (e) => e.diagnostic,
                'does not expose response',
                isNot(contains('PRIVATE-WBI-CONTENT')),
              ),
        ),
      );
    });

    test(
      'Initialization rejection retains code without proceeding to navigation',
      () async {
        final paths = <String>[];
        await expectLater(
          LiveWatchPreparation.prepare(
            roomId: 5438,
            uid: 123,
            readBuvid: () async => '',
            guard: () {},
            get: (path, _) async {
              paths.add(path);
              return {'code': -352, 'message': 'PRIVATE-SERVER-MESSAGE'};
            },
          ),
          throwsA(
            isA<LiveWatchProtocolException>()
                .having((e) => e.apiCode, 'code', -352)
                .having(
                  (e) => e.diagnostic,
                  'does not expose response',
                  isNot(contains('PRIVATE-SERVER-MESSAGE')),
                ),
          ),
        );
        expect(paths, [LiveWatchPreparation.roomInit]);
      },
    );

    test('Cancellation during room-init prevents navigation', () async {
      var stopped = false;
      final paths = <String>[];
      await expectLater(
        LiveWatchPreparation.prepare(
          roomId: 5438,
          uid: 123,
          readBuvid: () async => '',
          guard: () {
            if (stopped) throw StateError('fixture-stopped');
          },
          get: (path, _) async {
            paths.add(path);
            stopped = true;
            return {'code': 0};
          },
        ),
        throwsStateError,
      );
      expect(paths, [LiveWatchPreparation.roomInit]);
    });
  });

  test(
    'Preparation failure is displayed specifically, without sending E',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      fixture.transport.onPrepare = () => Future.error(
        const LiveWatchProtocolException(
          '房间初始化未提供有效的 LIVE_BUVID 设备标识',
          unsupported: false,
        ),
      );
      await fixture.play();
      expect(fixture.reporter.status.value.state, LiveWatchState.error);
      expect(fixture.reporter.status.value.message, contains('LIVE_BUVID'));
      expect(fixture.transport.paths, isEmpty);
    },
  );

  test(
    'Unexpected format errors are redacted into a fixed phase reason',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      fixture.transport.onPrepare = () => Future.error(
        const FormatException('PRIVATE-KEY-OR-COOKIE'),
      );
      await fixture.play();
      expect(fixture.reporter.status.value.message, contains('观看准备参数无法解析'));
      expect(
        fixture.reporter.status.value.message,
        isNot(contains('PRIVATE-KEY-OR-COOKIE')),
      );
      expect(fixture.transport.paths, isEmpty);
    },
  );

  test('Malformed E challenge identifies its missing field', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    fixture.transport.challenge.remove('timestamp');
    await fixture.play();
    expect(fixture.reporter.status.value.state, LiveWatchState.unsupported);
    expect(
      fixture.reporter.status.value.message,
      contains('观看 E 返回的 timestamp 无效或缺失'),
    );
    expect(fixture.transport.paths, [LiveWatchReporter.enterPath]);
  });

  test(
    'Malformed X challenge identifies rules without exposing its key',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.play();
      fixture.transport.challenge
        ..['secret_key'] = 'PRIVATE-ROTATED-KEY'
        ..['secret_rule'] = [6];
      await fixture.advance(60);
      expect(fixture.reporter.status.value.state, LiveWatchState.unsupported);
      expect(
        fixture.reporter.status.value.message,
        contains('观看 X 返回的 secret_rule 算法不受支持'),
      );
      expect(
        fixture.reporter.status.value.message,
        isNot(contains('PRIVATE-ROTATED-KEY')),
      );
      expect(fixture.reporter.status.value.reportedSeconds, 0);
    },
  );

  test('Native signatures equal 16 current official WASM vectors', () {
    final source = jsonDecode(
      File(
        'docs/requirements/research/live-watch-signing-2026-10-02.json',
      ).readAsStringSync(),
    ) as Map;
    final vectors = source['vectors'] as List;
    expect(vectors.length, 16);
    for (final raw in vectors) {
      final vector = raw as Map;
      final body = Map<String, Object>.from(vector['body'] as Map);
      expect(LiveWatchSigner.canonical(body), vector['canonical']);
      expect(
        LiveWatchSigner.sign(body, List<int>.from(vector['rules'] as List)),
        vector['signature'],
      );
    }
  });

  test('Unknown or empty rules and malformed identity fail closed', () {
    expect(LiveWatchSigner.supportsRules([]), isFalse);
    expect(LiveWatchSigner.supportsRules([0, 6]), isFalse);
    expect(LiveWatchSigner.supportsRules([-1]), isFalse);
    expect(LiveWatchSigner.supportsRules(List.filled(33, 0)), isFalse);
    expect(() => LiveWatchSigner.sign({}, [6]), throwsFormatException);
    expect(
      () => LiveWatchSigner.canonical({
        'id': '[1,2,"3",4]',
        'device': '["b","u"]',
        'ets': 1,
        'time': 60,
        'ts': 1000,
      }),
      throwsFormatException,
    );
  });

  test(
    'Current WBI middleware rounds wall seconds and hashes filtered values',
    () {
      final first = LiveWatchSigner.signQuery(
        {'fixture': "a!'()*b", 'csrf': 'fixture-csrf'},
        '0123456789abcdef0123456789abcdef',
        DateTime.fromMillisecondsSinceEpoch(1700000000499),
      );
      final second = LiveWatchSigner.signQuery(
        {'fixture': 'ab', 'csrf': 'fixture-csrf'},
        '0123456789abcdef0123456789abcdef',
        DateTime.fromMillisecondsSinceEpoch(1700000000499),
      );
      expect(first['wts'], '1700000000');
      expect(first['w_rid'], second['w_rid']);
      expect(first['fixture'], "a!'()*b");
      expect(
        LiveWatchSigner.signQuery(
          {},
          '0' * 32,
          DateTime.fromMillisecondsSinceEpoch(1700000000500),
        )['wts'],
        '1700000001',
      );
      expect(
        () => LiveWatchSigner.mixinKey('short', 'short'),
        throwsFormatException,
      );
    },
  );

  test(
    'Guest, disabled, paused, buffering and offline playback send nothing',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.play(enabled: false);
      await fixture.play(playing: false);
      await fixture.play(buffering: true);
      await fixture.play(live: false);
      fixture.account = LiveWatchAccount(
        uid: 0,
        identity: Object(),
        loggedIn: false,
        csrf: '',
      );
      await fixture.play();
      expect(fixture.transport.prepares, 0);
      expect(fixture.transport.paths, isEmpty);
    },
  );

  test(
    'E session starts at sequence zero, X uses challenge and native signature',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.play();
      expect(fixture.transport.paths, [LiveWatchReporter.enterPath]);
      final enter = fixture.transport.queries.single;
      expect(jsonDecode(enter['id'] as String), [1, 2, 0, 21452505]);
      expect(enter['csrf'], 'fixture-csrf');
      expect(enter['is_patch'], 0);
      expect(enter['heart_beat'], '[]');
      expect((enter['w_rid'] as String).length, 32);
      await fixture.advance(60);
      final heartbeat = fixture.transport.queries.last;
      expect(jsonDecode(heartbeat['id'] as String), [1, 2, 1, 21452505]);
      expect(heartbeat['time'], 60);
      expect(heartbeat['ets'], 1700000000);
      expect(
        heartbeat['s'],
        LiveWatchSigner.sign(heartbeat, [0, 1, 2, 3, 4, 5]),
      );
      expect(fixture.reporter.status.value.reportedSeconds, 60);
      expect(fixture.reporter.status.value.message, contains('以官方任务进度为准'));
    },
  );

  test('Repeated playing updates cannot create duplicate E or timer', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.play();
    for (var i = 0; i < 20; ++i) {
      await fixture.play();
    }
    expect(fixture.transport.paths.length, 1);
    expect(fixture.timers.length, 1);
  });

  test(
    'Unchanged inactive polling does not repeatedly notify the UI',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      var changes = 0;
      fixture.reporter.status.addListener(() => ++changes);
      for (var i = 0; i < 20; ++i) {
        await fixture.play(enabled: false);
      }
      expect(changes, 0);
      await fixture.play(buffering: true);
      final afterBuffer = changes;
      for (var i = 0; i < 20; ++i) {
        await fixture.play(buffering: true);
      }
      expect(changes, afterBuffer);
    },
  );

  test(
    'Same account object A to B to A generation invalidates old E',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final old = Completer<Map<String, dynamic>>();
      fixture.transport.onPost = (_) => old.future;
      fixture.reporter.updatePlayback(
        enabled: true,
        playing: true,
        buffering: false,
        live: true,
      );
      await Future<void>.delayed(Duration.zero);
      final pending = fixture.reporter.settled;
      final oldToken = fixture.transport.tokens.last;
      fixture.account = LiveWatchAccount(
        uid: fixture.account.uid,
        identity: fixture.account.identity,
        loggedIn: true,
        csrf: fixture.account.csrf,
        generation: 2,
      );
      fixture.transport.onPost = null;
      await fixture.play();
      old.complete({'code': 0, 'data': fixture.transport.challenge});
      await pending;
      expect(oldToken.isCancelled, isTrue);
      expect(fixture.transport.paths.length, 2);
      expect(fixture.timers.length, 1);
    },
  );

  test(
    'Pause and buffering cancel tokens and exclude interrupted seconds',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.play();
      fixture.elapsed += const Duration(seconds: 59);
      final oldTimer = fixture.timers.last;
      final oldToken = fixture.transport.tokens.last;
      await fixture.play(buffering: true);
      expect(oldTimer.isActive, isFalse);
      expect(oldToken.isCancelled, isTrue);
      fixture.elapsed += const Duration(hours: 2);
      oldTimer.fire();
      expect(fixture.transport.paths.length, 1);
      await fixture.play();
      expect(fixture.transport.paths.length, 2);
      await fixture.advance(1);
      expect(fixture.transport.paths.length, 2);
      await fixture.advance(59);
      expect(fixture.transport.queries.last['time'], 60);
      await fixture.play(playing: false);
      expect(fixture.timers.last.isActive, isFalse);
    },
  );

  test('Wall clock jump alone cannot earn watching time', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.play();
    fixture.wall = fixture.wall.add(const Duration(days: 1));
    fixture.timers.last.fire();
    await fixture.reporter.settled;
    expect(fixture.transport.paths.length, 1);
    expect(fixture.timers.last.delay, const Duration(seconds: 60));
  });

  test(
    'Heartbeat callback before resumed playback never credits a sleep gap',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.play();
      await fixture.advance(10);
      fixture.elapsed += const Duration(minutes: 10);
      fixture.wall = fixture.wall.add(const Duration(minutes: 10));
      fixture.timers.last.fire();
      await fixture.reporter.settled;
      expect(fixture.transport.paths.length, 1);
      expect(fixture.reporter.status.value.reportedSeconds, 0);
      expect(fixture.reporter.status.value.state, LiveWatchState.paused);
      await fixture.play();
      await fixture.advance(59);
      expect(fixture.transport.paths.length, 2);
      await fixture.advance(1);
      expect(fixture.transport.queries.last['time'], 60);
    },
  );

  test(
    'Playback callback before a delayed heartbeat starts a new segment',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.play();
      await fixture.advance(10);
      final staleTimer = fixture.timers.last;
      fixture.elapsed += const Duration(minutes: 10);
      fixture.wall = fixture.wall.add(const Duration(minutes: 10));
      await fixture.play();
      staleTimer.fire();
      await fixture.reporter.settled;
      expect(fixture.transport.paths.length, 2);
      expect(
        fixture.transport.paths,
        everyElement(LiveWatchReporter.enterPath),
      );
      expect(fixture.reporter.status.value.reportedSeconds, 0);
      await fixture.advance(60);
      expect(fixture.reporter.status.value.reportedSeconds, 60);
    },
  );

  test(
    'Sleep gap is excluded even if the monotonic clock did not advance',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.play();
      await fixture.advance(10);
      fixture.wall = fixture.wall.add(const Duration(minutes: 10));
      fixture.timers.last.fire();
      await fixture.reporter.settled;
      expect(fixture.transport.paths.length, 1);
      expect(fixture.reporter.status.value.reportedSeconds, 0);
      await fixture.play();
      await fixture.advance(60);
      expect(fixture.reporter.status.value.reportedSeconds, 60);
    },
  );

  test(
    'Rotating challenge updates key, timestamp, rule and interval',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.play();
      fixture.transport.challenge = {
        'heartbeat_interval': 15,
        'timestamp': 1700000060,
        'secret_key': 'rotated-key',
        'secret_rule': [5, 2],
      };
      await fixture.advance(60);
      expect(fixture.timers.last.delay, const Duration(seconds: 15));
      await fixture.advance(15);
      final query = fixture.transport.queries.last;
      expect(query['time'], 15);
      expect(query['ets'], 1700000060);
      expect(query['benchmark'], 'rotated-key');
      expect(query['s'], LiveWatchSigner.sign(query, [5, 2]));
      expect(jsonDecode(query['id'] as String)[2], 2);
    },
  );

  test(
    'Timeout result is unknown, locks session and never retries automatically',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.play();
      fixture.transport.onPost = (_) =>
          Future.error(TimeoutException('fixture'));
      await fixture.advance(60);
      expect(fixture.reporter.status.value.state, LiveWatchState.error);
      expect(fixture.reporter.status.value.reportedSeconds, 0);
      for (var i = 0; i < 4; ++i) {
        await fixture.play();
      }
      expect(fixture.transport.paths.length, 2);
      fixture.transport.onPost = null;
      await fixture.reporter.restart();
      expect(fixture.transport.paths.length, 3);
    },
  );

  test(
    'Official rejection is retained as an error, with no counter credit',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.play();
      fixture.transport.onPost = (_) async => {'code': 1012001, 'data': {}};
      await fixture.advance(60);
      expect(fixture.reporter.status.value.state, LiveWatchState.error);
      expect(fixture.reporter.status.value.apiCode, 1012001);
      expect(fixture.reporter.status.value.reportedSeconds, 0);
      expect(fixture.timers.last.isActive, isFalse);
    },
  );

  test(
    'Malformed or unknown signing challenge suspends without a heartbeat',
    () async {
      for (final challenge in [
        {
          'heartbeat_interval': 60,
          'secret_key': 'key',
          'secret_rule': [6],
          'timestamp': 1,
        },
        {
          'heartbeat_interval': 0,
          'secret_key': 'key',
          'secret_rule': [0],
          'timestamp': 1,
        },
        {
          'heartbeat_interval': 60,
          'secret_key': 'key',
          'secret_rule': [0],
        },
      ]) {
        final fixture = _Fixture();
        fixture.transport.challenge = challenge;
        await fixture.play();
        expect(fixture.reporter.status.value.state, LiveWatchState.unsupported);
        expect(fixture.transport.paths.length, 1);
        expect(fixture.timers, isEmpty);
        fixture.dispose();
      }
    },
  );

  test(
    'Account change while E is pending discards old result, even same UID',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final old = Completer<Map<String, dynamic>>();
      fixture.transport.onPost = (_) => old.future;
      fixture.reporter.updatePlayback(
        enabled: true,
        playing: true,
        buffering: false,
        live: true,
      );
      await Future<void>.delayed(Duration.zero);
      final pending = fixture.reporter.settled;
      final oldToken = fixture.transport.tokens.last;
      fixture.account = LiveWatchAccount(
        uid: 123,
        identity: Object(),
        loggedIn: true,
        csrf: 'new-csrf',
      );
      fixture.transport.onPost = null;
      fixture.reporter.accountChanged();
      await fixture.reporter.settled;
      old.complete({'code': 0, 'data': fixture.transport.challenge});
      await pending;
      expect(oldToken.isCancelled, isTrue);
      expect(fixture.transport.owners.last, same(fixture.account.identity));
      expect(fixture.timers.length, 1);
      expect(fixture.reporter.status.value.reportedSeconds, 0);
    },
  );

  test(
    'Room switch discards in-flight old heartbeat and resets progress',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.play();
      final old = Completer<Map<String, dynamic>>();
      fixture.transport.onPost = (_) => old.future;
      fixture.elapsed += const Duration(seconds: 60);
      fixture.timers.last.fire();
      final pending = fixture.reporter.settled;
      fixture.transport.onPost = null;
      fixture.reporter.updateRoom(
        roomId: 3000,
        anchorUid: 4000,
        areaId: 5,
        parentAreaId: 6,
      );
      await fixture.reporter.settled;
      old.complete({'code': 0, 'data': fixture.transport.challenge});
      await pending;
      expect(fixture.reporter.status.value.reportedSeconds, 0);
      expect(jsonDecode(fixture.transport.queries.last['id'] as String), [
        6,
        5,
        0,
        3000,
      ]);
      await fixture.advance(60);
      expect(fixture.transport.queries.last['ruid'], 4000);
    },
  );

  test('Dispose cancels pending preparation before E can be issued', () async {
    final fixture = _Fixture();
    final device = Completer<LiveWatchDevice>();
    fixture.transport.onPrepare = () => device.future;
    fixture.reporter.updatePlayback(
      enabled: true,
      playing: true,
      buffering: false,
      live: true,
    );
    final pending = fixture.reporter.settled;
    fixture.dispose();
    device.complete(
      const LiveWatchDevice(
        buvid: 'FAKE-BUVID',
        mixinKey: '00000000000000000000000000000000',
      ),
    );
    await pending;
    expect(fixture.transport.paths, isEmpty);
    expect(fixture.transport.tokens.single.isCancelled, isTrue);
  });
}

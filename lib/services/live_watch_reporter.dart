// Testing arguments keep readable public names distinct from private fields.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/retry_interceptor.dart';
import 'package:PiliPlus/services/live_watch_signer.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

enum LiveWatchState {
  inactive,
  connecting,
  reporting,
  paused,
  error,
  unsupported,
}

class LiveWatchStatus {
  final LiveWatchState state;
  final String message;

  /// Accepted by the watch endpoint; this is not confirmed intimacy credit.
  final int reportedSeconds;
  final int? apiCode;
  const LiveWatchStatus(
    this.state,
    this.message, [
    this.reportedSeconds = 0,
    this.apiCode,
  ]);
}

/// Native position observations distinguish playing flags from actual media.
/// Missing samples, a stalled clock and seeks cannot confirm continuous watch.
class LiveWatchMediaObservation {
  Duration? _position;
  Duration? _clock;
  bool _advancing = false;

  void observe({required Duration position, required Duration clock}) {
    final previousPosition = _position;
    final previousClock = _clock;
    _position = position;
    _clock = clock;
    final elapsed = previousClock == null ? null : clock - previousClock;
    final media = previousPosition == null ? null : position - previousPosition;
    _advancing =
        elapsed != null &&
        media != null &&
        elapsed > Duration.zero &&
        elapsed <= const Duration(seconds: 3) &&
        media > Duration.zero &&
        media <= elapsed + const Duration(seconds: 1);
  }

  bool advancingAt(Duration clock) {
    final previousClock = _clock;
    if (!_advancing || previousClock == null) return false;
    final elapsed = clock - previousClock;
    return !elapsed.isNegative && elapsed <= const Duration(seconds: 3);
  }

  void freeze() {
    _position = null;
    _clock = null;
    _advancing = false;
  }
}

class LiveWatchAccount {
  final int uid;
  final Object identity;
  final bool loggedIn;
  final String csrf;
  final int generation;
  const LiveWatchAccount({
    required this.uid,
    required this.identity,
    required this.loggedIn,
    required this.csrf,
    this.generation = 0,
  });
}

class LiveWatchDevice {
  final String buvid;
  final String mixinKey;
  const LiveWatchDevice({required this.buvid, required this.mixinKey});
}

/// Expected failures contain fixed diagnostics, never response bodies or keys.
class LiveWatchProtocolException implements Exception {
  final String diagnostic;
  final bool unsupported;
  final int? apiCode;
  const LiveWatchProtocolException(
    this.diagnostic, {
    this.unsupported = true,
    this.apiCode,
  });
}

/// The official room-init response supplies LIVE_BUVID; the room HTML does not
/// currently supply it. Injected reads exercise preparation without credentials.
abstract final class LiveWatchPreparation {
  static const roomInit =
      'https://api.live.bilibili.com/room/v1/Room/room_init';
  static const nav = 'https://api.bilibili.com/x/web-interface/nav';

  static Future<LiveWatchDevice> prepare({
    required int roomId,
    required int uid,
    required Future<String> Function() readBuvid,
    required Future<Object?> Function(String, Map<String, Object>) get,
    required void Function() guard,
  }) async {
    guard();
    var buvid = await readBuvid();
    guard();
    if (buvid.isEmpty) {
      final response = await get(roomInit, {'id': roomId});
      guard();
      if (response is! Map || response['code'] is! int) {
        throw const LiveWatchProtocolException('房间初始化响应缺少 code');
      }
      final code = response['code'] as int;
      if (code != 0) {
        throw LiveWatchProtocolException(
          '房间初始化被官方拒绝（$code）',
          unsupported: false,
          apiCode: code,
        );
      }
      buvid = await readBuvid();
      guard();
    }
    if (buvid.isEmpty || buvid.length > 1024) {
      throw const LiveWatchProtocolException(
        '房间初始化未提供有效的 LIVE_BUVID 设备标识',
        unsupported: false,
      );
    }
    final response = await get(nav, const {});
    guard();
    if (response is! Map || response['code'] is! int) {
      throw const LiveWatchProtocolException('账号导航响应缺少 code');
    }
    final code = response['code'] as int;
    final data = response['data'];
    if (code != 0 ||
        data is! Map ||
        data['isLogin'] != true ||
        data['mid'] != uid) {
      throw LiveWatchProtocolException(
        code == -101
            ? '主账号网页登录会话已过期，请重新登录'
            : code != 0
            ? '账号导航被官方拒绝（$code）'
            : '账号导航与当前主账号身份不一致',
        unsupported: false,
        apiCode: code == 0 ? null : code,
      );
    }
    final wbi = data['wbi_img'];
    if (wbi is! Map) {
      throw const LiveWatchProtocolException('账号导航缺少 wbi_img 签名信息');
    }
    String key(Object? value) {
      final uri = value is String ? Uri.tryParse(value) : null;
      if (uri == null || uri.pathSegments.isEmpty) {
        throw const LiveWatchProtocolException('账号导航的 WBI 签名地址无效');
      }
      return uri.pathSegments.last.split('.').first;
    }

    try {
      return LiveWatchDevice(
        buvid: buvid,
        mixinKey: LiveWatchSigner.mixinKey(
          key(wbi['img_url']),
          key(wbi['sub_url']),
        ),
      );
    } on FormatException {
      throw const LiveWatchProtocolException('账号导航的 WBI 签名密钥格式无效');
    }
  }
}

abstract interface class LiveWatchTransport {
  Future<LiveWatchDevice> prepare(
    int roomId,
    LiveWatchAccount account,
    CancelToken token,
  );
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, Object> query,
    LiveWatchAccount account,
    CancelToken token,
  );
}

/// Only current official origins are reachable through this adapter. The
/// request clone shares the application adapter, which this service never closes.
class _RequestWatchTransport implements LiveWatchTransport {
  static const _live = 'https://live.bilibili.com';
  static const _trace = 'https://live-trace.bilibili.com';
  Dio? _client;
  Dio get client {
    Request();
    return _client ??= Request.dio.clone()
      ..interceptors.removeWhere(
        (interceptor) =>
            interceptor is RetryInterceptor || interceptor is LogInterceptor,
      )
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final account = Accounts.main;
            if (Accounts.mainIdentityChangeInProgress ||
                !identical(options.extra['account'], account) ||
                !account.isLogin ||
                options.extra['watchUid'] != account.mid ||
                options.extra['watchGeneration'] !=
                    Accounts.mainChangeGeneration ||
                options.cancelToken?.isCancelled == true) {
              handler.reject(
                DioException.requestCancelled(
                  requestOptions: options,
                  reason: 'Live watch account changed',
                ),
              );
            } else {
              handler.next(options);
            }
          },
        ),
      );
  }

  Options _options(LiveWatchAccount account, int roomId) => Options(
    extra: {
      'account': account.identity,
      'watchUid': account.uid,
      'watchGeneration': account.generation,
    },
    followRedirects: false,
    maxRedirects: 0,
    sendTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    headers: {
      'referer': '$_live/$roomId',
      'origin': _live,
      'user-agent': LiveWatchReporter.userAgent,
    },
  );

  void _guard(LiveWatchAccount owner, CancelToken token) {
    final current = Accounts.main;
    if (token.isCancelled ||
        Accounts.mainIdentityChangeInProgress ||
        !identical(current, owner.identity) ||
        owner.generation != Accounts.mainChangeGeneration ||
        !current.isLogin ||
        current.mid != owner.uid) {
      throw const _WatchStopped();
    }
  }

  @override
  Future<LiveWatchDevice> prepare(
    int roomId,
    LiveWatchAccount account,
    CancelToken token,
  ) {
    _guard(account, token);
    final owner = account.identity as Account;
    final uri = Uri.parse('$_live/$roomId');
    Future<String> readBuvid() async {
      final cookies = await owner.cookieJar.loadForRequest(uri);
      for (final cookie in cookies) {
        if (cookie.name == 'LIVE_BUVID' && cookie.value.isNotEmpty) {
          return cookie.value;
        }
      }
      return '';
    }

    return LiveWatchPreparation.prepare(
      roomId: roomId,
      uid: account.uid,
      readBuvid: readBuvid,
      guard: () => _guard(account, token),
      get: (url, query) async {
        // The helper reaches only these two fixed official read endpoints.
        if (url != LiveWatchPreparation.roomInit &&
            url != LiveWatchPreparation.nav) {
          throw const LiveWatchProtocolException('观看准备请求地址不受支持');
        }
        _guard(account, token);
        final response = await client.get<dynamic>(
          url,
          queryParameters: query,
          options: _options(account, roomId),
          cancelToken: token,
        );
        _guard(account, token);
        return response.data;
      },
    );
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, Object> query,
    LiveWatchAccount account,
    CancelToken token,
  ) async {
    if (path != LiveWatchReporter.enterPath &&
        path != LiveWatchReporter.heartbeatPath) {
      throw const FormatException('Unsupported live watch origin/path');
    }
    _guard(account, token);
    final id = jsonDecode(query['id'] as String) as List;
    final response = await client.post<dynamic>(
      _trace + path,
      queryParameters: query,
      options: _options(account, id[3] as int),
      cancelToken: token,
    );
    _guard(account, token);
    if (response.data is! Map) {
      throw const LiveWatchProtocolException('官方观看响应不是 JSON 对象');
    }
    return Map<String, dynamic>.from(response.data as Map);
  }
}

/// Native E/X watcher. Playback flags describe actual media playback; background
/// visibility deliberately is not a flag. A pause/buffer/owner change cancels the
/// session immediately. Interrupted intervals are discarded rather than replayed.
class LiveWatchReporter {
  static const enterPath = '/xlive/data-interface/v1/x25Kn/E';
  static const heartbeatPath = '/xlive/data-interface/v1/x25Kn/X';
  static const userAgent = BrowserUa.pc;
  final LiveWatchTransport _transport;
  final LiveWatchAccount Function() _account;
  final DateTime Function() _now;
  final Duration Function() _monotonicNow;
  final Timer Function(Duration, void Function()) _schedule;
  final String Function() _uuid;
  final ValueNotifier<LiveWatchStatus> status = ValueNotifier(
    const LiveWatchStatus(LiveWatchState.inactive, '观看上报未开启'),
  );
  int _roomId;
  int _anchorUid;
  int _areaId;
  int _parentAreaId;
  bool _enabled = false;
  bool _playing = false;
  bool _buffering = false;
  bool _live = false;
  bool _disposed = false;
  bool _failed = false;
  bool _running = false;
  int _generation = 0;
  int _sequence = 0;
  int _reportedSeconds = 0;
  Timer? _timer;
  CancelToken _token = CancelToken();
  LiveWatchAccount? _owner;
  LiveWatchDevice? _device;
  String _sessionUuid = '';
  _WatchParameters? _parameters;
  Duration? _segmentStart;
  Duration? _lastPlaybackObservation;
  DateTime? _lastPlaybackWallObservation;
  static const _observationGapLimit = Duration(seconds: 3);
  Future<void>? _operation;

  LiveWatchReporter({
    required int roomId,
    required int anchorUid,
    required int areaId,
    required int parentAreaId,
  }) : this.testing(
         roomId: roomId,
         anchorUid: anchorUid,
         areaId: areaId,
         parentAreaId: parentAreaId,
         transport: _RequestWatchTransport(),
         account: _currentAccount,
       );

  LiveWatchReporter.testing({
    required int roomId,
    required int anchorUid,
    required int areaId,
    required int parentAreaId,
    required LiveWatchTransport transport,
    required LiveWatchAccount Function() account,
    DateTime Function()? now,
    Duration Function()? monotonicNow,
    Timer Function(Duration, void Function())? schedule,
    String Function()? uuid,
  }) : _roomId = roomId,
       _anchorUid = anchorUid,
       _areaId = areaId,
       _parentAreaId = parentAreaId,
       _transport = transport,
       _account = account,
       _now = now ?? DateTime.now,
       _monotonicNow = monotonicNow ?? _stopwatchClock(),
       _schedule = schedule ?? Timer.new,
       _uuid = uuid ?? const Uuid().v4;

  static Duration Function() _stopwatchClock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  static LiveWatchAccount _currentAccount() {
    final account = Accounts.main;
    return LiveWatchAccount(
      uid: account.isLogin ? account.mid : 0,
      identity: account,
      loggedIn: account.isLogin,
      csrf: account.isLogin ? account.csrf : '',
      generation: Accounts.mainChangeGeneration,
    );
  }

  Future<void> get settled => _operation ?? Future<void>.value();

  void updatePlayback({
    required bool enabled,
    required bool playing,
    required bool buffering,
    required bool live,
  }) {
    if (_disposed) return;
    final current = _monotonicNow();
    final wall = _now();
    // Every owner observes playback at least once a second. A long gap may be
    // sleep or a suspended event loop even when no platform sleep hook exists.
    // Start a fresh segment before accepting another heartbeat in either order
    // of resumed callbacks; do not retain a stale pre-sleep playing flag.
    if (_running && !_observationFresh(current, wall)) _invalidate();
    _lastPlaybackObservation = current;
    _lastPlaybackWallObservation = wall;
    _enabled = enabled;
    _playing = playing;
    _buffering = buffering;
    _live = live;
    _reconcile();
  }

  void updateRoom({
    required int roomId,
    required int anchorUid,
    required int areaId,
    required int parentAreaId,
  }) {
    if (_disposed ||
        (_roomId == roomId &&
            _anchorUid == anchorUid &&
            _areaId == areaId &&
            _parentAreaId == parentAreaId)) {
      return;
    }
    _invalidate();
    _roomId = roomId;
    _anchorUid = anchorUid;
    _areaId = areaId;
    _parentAreaId = parentAreaId;
    _failed = false;
    _reportedSeconds = 0;
    _reconcile();
  }

  void accountChanged() {
    if (_disposed) return;
    _invalidate();
    _failed = false;
    _reportedSeconds = 0;
    _reconcile();
  }

  Future<void> restart() async {
    if (_disposed) return;
    _invalidate();
    _failed = false;
    _reconcile();
    await settled;
  }

  bool _observationFresh(Duration current, DateTime wall) {
    final last = _lastPlaybackObservation;
    final lastWall = _lastPlaybackWallObservation;
    if (last == null || lastWall == null) return false;
    final elapsed = current - last;
    final wallElapsed = wall.difference(lastWall);
    return !elapsed.isNegative &&
        !wallElapsed.isNegative &&
        elapsed <= _observationGapLimit &&
        wallElapsed <= _observationGapLimit;
  }

  bool get _playbackAllowed => _enabled && _playing && !_buffering && _live;
  bool get _validRoom =>
      _roomId > 0 && _anchorUid > 0 && _areaId > 0 && _parentAreaId > 0;

  void _emit(LiveWatchState state, String message, {int? apiCode}) {
    if (_disposed) return;
    final previous = status.value;
    if (previous.state == state &&
        previous.message == message &&
        previous.reportedSeconds == _reportedSeconds &&
        previous.apiCode == apiCode) {
      return;
    }
    status.value = LiveWatchStatus(state, message, _reportedSeconds, apiCode);
  }

  void _reconcile() {
    final account = _account();
    final eligible =
        account.loggedIn && account.uid > 0 && account.csrf.isNotEmpty;
    if (!_playbackAllowed || !eligible || !_validRoom) {
      if (_running || _owner != null || _timer != null) _invalidate();
      if (_failed) return;
      _emit(
        _enabled ? LiveWatchState.paused : LiveWatchState.inactive,
        !_enabled
            ? '观看上报未开启'
            : !eligible
            ? '请先登录有效观看账号'
            : !_validRoom
            ? '等待直播房间信息'
            : !_live
            ? '直播未开播，观看上报已暂停'
            : _buffering
            ? '播放器缓冲中，观看上报已暂停'
            : '播放器已暂停，观看上报已暂停',
      );
      return;
    }
    if (_owner case final owner?) {
      if (!_sameAccount(owner, account)) {
        _invalidate();
        _failed = false;
        _reportedSeconds = 0;
      }
    }
    if (_failed || _running) return;
    _running = true;
    _owner = account;
    final generation = _generation;
    _operation = _begin(account, generation);
  }

  static bool _sameAccount(LiveWatchAccount a, LiveWatchAccount b) =>
      a.loggedIn &&
      b.loggedIn &&
      a.uid == b.uid &&
      identical(a.identity, b.identity) &&
      a.generation == b.generation &&
      a.csrf == b.csrf;

  void _guard(LiveWatchAccount account, int generation) {
    if (_disposed ||
        generation != _generation ||
        !_playbackAllowed ||
        !_sameAccount(account, _account()) ||
        !_validRoom ||
        _token.isCancelled) {
      throw const _WatchStopped();
    }
  }

  Future<void> _begin(LiveWatchAccount account, int generation) async {
    _emit(LiveWatchState.connecting, '正在建立官方观看上报会话');
    var phase = '观看准备';
    try {
      final device = await _transport.prepare(_roomId, account, _token);
      _guard(account, generation);
      if (device.buvid.isEmpty || device.mixinKey.length != 32) {
        throw const FormatException('官方观看设备或签名参数不受支持');
      }
      _device = device;
      _sessionUuid = _uuid();
      _sequence = 0;
      final query = _signedQuery(
        {
          'id': _id,
          'device': _deviceJson,
          'ruid': _anchorUid,
          'ts': _now().millisecondsSinceEpoch,
          'is_patch': 0,
          'heart_beat': '[]',
          'ua': userAgent,
        },
        account,
        device,
      );
      _guard(account, generation);
      phase = '观看 E 入场';
      final response = await _transport.post(enterPath, query, account, _token);
      _guard(account, generation);
      _parameters = _WatchParameters.parse(_data(response), phase: 'E');
      _sequence = 1;
      _segmentStart = _monotonicNow();
      _emit(LiveWatchState.reporting, '观看上报运行中；亲密度以官方任务进度为准');
      _arm(account, generation);
    } on _WatchStopped {
      // A stale result must not mutate the new session's flags or visible status.
    } on LiveWatchProtocolException catch (error) {
      _fail(
        generation,
        unsupported: error.unsupported,
        apiCode: error.apiCode,
        diagnostic: error.diagnostic,
      );
    } on FormatException {
      _fail(
        generation,
        unsupported: true,
        diagnostic: '$phase参数无法解析',
      );
    } on _WatchRejected catch (error) {
      _fail(generation, apiCode: error.code, diagnostic: '$phase被官方拒绝');
    } catch (error) {
      _fail(generation, diagnostic: _requestFailure(error, phase));
    }
  }

  String get _id => jsonEncode([_parentAreaId, _areaId, _sequence, _roomId]);
  String get _deviceJson => jsonEncode([_device!.buvid, _sessionUuid]);

  Map<String, Object> _signedQuery(
    Map<String, Object> body,
    LiveWatchAccount account,
    LiveWatchDevice device,
  ) => LiveWatchSigner.signQuery(
    {
      ...body,
      'web_location': '444.8',
      'csrf': account.csrf,
    },
    device.mixinKey,
    _now(),
  );

  Map<String, dynamic> _data(Map<String, dynamic> response) {
    final code = response['code'];
    if (code is! int) {
      throw const LiveWatchProtocolException('官方观看响应缺少有效的 code');
    }
    if (code != 0) throw _WatchRejected(code);
    final data = response['data'];
    if (data is! Map) {
      throw const LiveWatchProtocolException('官方观看响应缺少 data 对象');
    }
    return Map<String, dynamic>.from(data);
  }

  void _arm(LiveWatchAccount account, int generation) {
    _guard(account, generation);
    _timer?.cancel();
    final elapsed = _monotonicNow() - _segmentStart!;
    final remaining = Duration(seconds: _parameters!.interval) - elapsed;
    _timer = _schedule(remaining.isNegative ? Duration.zero : remaining, () {
      _operation = _heartbeat(account, generation);
    });
  }

  Future<void> _heartbeat(LiveWatchAccount account, int generation) async {
    try {
      _guard(account, generation);
      if (!_observationFresh(_monotonicNow(), _now())) {
        _invalidate();
        _emit(LiveWatchState.paused, '播放状态中断，等待恢复后重新开始观时');
        return;
      }
      final start = _segmentStart!;
      final current = _monotonicNow();
      final seconds = (current - start).inSeconds;
      final params = _parameters!;
      if (seconds < params.interval) {
        _arm(account, generation);
        return;
      }
      // Delayed timers cannot backfill elapsed wall time or multiple intervals.
      final watched = params.interval;
      final body = <String, Object>{
        'id': _id,
        'device': _deviceJson,
        'ruid': _anchorUid,
        'ets': params.timestamp,
        'benchmark': params.key,
        'time': watched,
        'ts': _now().millisecondsSinceEpoch,
        'ua': userAgent,
        'trackid': '-999998',
      };
      body['s'] = LiveWatchSigner.sign(body, params.rules);
      final query = _signedQuery(body, account, _device!);
      _guard(account, generation);
      _segmentStart = current;
      final response = await _transport.post(
        heartbeatPath,
        query,
        account,
        _token,
      );
      _guard(account, generation);
      _parameters = _WatchParameters.parse(
        _data(response),
        previous: params,
        phase: 'X',
      );
      ++_sequence;
      _reportedSeconds += watched;
      _emit(LiveWatchState.reporting, '观看上报运行中；亲密度以官方任务进度为准');
      _arm(account, generation);
    } on _WatchStopped {
      // Cancellation does not credit an unknown or late heartbeat response.
    } on LiveWatchProtocolException catch (error) {
      _fail(
        generation,
        unsupported: error.unsupported,
        apiCode: error.apiCode,
        diagnostic: error.diagnostic,
      );
    } on FormatException {
      _fail(
        generation,
        unsupported: true,
        diagnostic: '观看 X 心跳签名参数无法解析',
      );
    } on _WatchRejected catch (error) {
      _fail(generation, apiCode: error.code, diagnostic: '观看 X 心跳被官方拒绝');
    } catch (error) {
      _fail(generation, diagnostic: _requestFailure(error, '观看 X 心跳'));
    }
  }

  static String _requestFailure(Object error, String phase) {
    if (error is DioException) {
      final httpCode = error.response?.statusCode;
      if (httpCode != null) return '$phase失败（HTTP $httpCode），结果未知';
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        return '$phase超时，结果未知';
      }
    }
    if (error is TimeoutException) return '$phase超时，结果未知';
    return '$phase请求失败，结果未知';
  }

  void _fail(
    int generation, {
    bool unsupported = false,
    int? apiCode,
    String? diagnostic,
  }) {
    if (_disposed || generation != _generation) return;
    _invalidate();
    _failed = true;
    _emit(
      unsupported ? LiveWatchState.unsupported : LiveWatchState.error,
      diagnostic != null
          ? '$diagnostic${apiCode != null && !diagnostic.contains('（$apiCode）') ? '（$apiCode）' : ''}，已暂停；不会自动重发'
          : unsupported
          ? '官方观看上报规则不受支持，已暂停'
          : apiCode != null
          ? '观看上报被官方拒绝（$apiCode），已暂停；不会自动重发'
          : '观看上报失败，结果未知，已暂停；不会自动重发',
      apiCode: apiCode,
    );
  }

  void _invalidate() {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    _token.cancel('Live watch session stopped');
    _token = CancelToken();
    _running = false;
    _owner = null;
    _device = null;
    _parameters = null;
    _segmentStart = null;
  }

  void dispose() {
    if (_disposed) return;
    _invalidate();
    _disposed = true;
    status.dispose();
  }
}

class _WatchParameters {
  final int interval;
  final int timestamp;
  final String key;
  final List<int> rules;
  const _WatchParameters(this.interval, this.timestamp, this.key, this.rules);

  factory _WatchParameters.parse(
    Map<String, dynamic> data, {
    _WatchParameters? previous,
    required String phase,
  }) {
    final interval = data['heartbeat_interval'] ?? previous?.interval;
    final timestamp = data['timestamp'];
    final key = data['secret_key'] ?? previous?.key;
    final rawRules = data['secret_rule'] ?? previous?.rules;
    if (interval is! int || interval < 1 || interval > 3600) {
      throw LiveWatchProtocolException('观看 $phase 返回的 heartbeat_interval 无效');
    }
    if (timestamp is! int || timestamp <= 0 || timestamp > 9007199254740991) {
      throw LiveWatchProtocolException('观看 $phase 返回的 timestamp 无效或缺失');
    }
    if (key is! String || key.isEmpty || key.length > 4096) {
      throw LiveWatchProtocolException('观看 $phase 返回的 secret_key 无效或缺失');
    }
    if (rawRules is! List || rawRules.any((value) => value is! int)) {
      throw LiveWatchProtocolException('观看 $phase 返回的 secret_rule 格式不受支持');
    }
    final rules = List<int>.from(rawRules);
    if (!LiveWatchSigner.supportsRules(rules)) {
      throw LiveWatchProtocolException('观看 $phase 返回的 secret_rule 算法不受支持');
    }
    return _WatchParameters(interval, timestamp, key, List.unmodifiable(rules));
  }
}

class _WatchStopped implements Exception {
  const _WatchStopped();
}

class _WatchRejected implements Exception {
  final int code;
  const _WatchRejected(this.code);
}

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
  static const _nav = 'https://api.bilibili.com/x/web-interface/nav';
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
            if (!identical(options.extra['account'], account) ||
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
  ) async {
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

    var buvid = await readBuvid();
    _guard(account, token);
    if (buvid.isEmpty) {
      // Official live HTML establishes LIVE_BUVID through its response cookie.
      // No HTML scripts are executed, and no second player is created.
      await client.get<String>(
        uri.toString(),
        options: _options(
          account,
          roomId,
        ).copyWith(responseType: ResponseType.plain),
        cancelToken: token,
      );
      _guard(account, token);
      buvid = await readBuvid();
      _guard(account, token);
    }
    if (buvid.isEmpty || buvid.length > 1024) {
      throw const FormatException('官方直播设备标识不可用，观看上报已暂停');
    }
    final response = await client.get<dynamic>(
      _nav,
      options: _options(account, roomId),
      cancelToken: token,
    );
    _guard(account, token);
    final data = response.data;
    final wbi = data is Map && data['code'] == 0 && data['data'] is Map
        ? data['data']['wbi_img']
        : null;
    if (wbi is! Map) {
      throw const FormatException('官方 WBI 参数不可用，观看上报已暂停');
    }
    String key(Object? value) {
      if (value is! String) throw const FormatException('Invalid WBI URL');
      final uri = Uri.tryParse(value);
      if (uri == null || uri.pathSegments.isEmpty) {
        throw const FormatException('Invalid WBI URL');
      }
      return uri.pathSegments.last.split('.').first;
    }

    return LiveWatchDevice(
      buvid: buvid,
      mixinKey: LiveWatchSigner.mixinKey(
        key(wbi['img_url']),
        key(wbi['sub_url']),
      ),
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
      throw const FormatException('官方观看响应格式不受支持');
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
      final response = await _transport.post(enterPath, query, account, _token);
      _guard(account, generation);
      _parameters = _WatchParameters.parse(_data(response));
      _sequence = 1;
      _segmentStart = _monotonicNow();
      _emit(LiveWatchState.reporting, '观看上报运行中；亲密度以官方任务进度为准');
      _arm(account, generation);
    } on _WatchStopped {
      // A stale result must not mutate the new session's flags or visible status.
    } on FormatException {
      _fail(generation, unsupported: true);
    } on _WatchRejected catch (error) {
      _fail(generation, apiCode: error.code);
    } catch (_) {
      _fail(generation);
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
    if (code is! int) throw const FormatException('Invalid watch result code');
    if (code != 0) throw _WatchRejected(code);
    final data = response['data'];
    if (data is! Map) throw const FormatException('Invalid watch response');
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
      _parameters = _WatchParameters.parse(_data(response), previous: params);
      ++_sequence;
      _reportedSeconds += watched;
      _emit(LiveWatchState.reporting, '观看上报运行中；亲密度以官方任务进度为准');
      _arm(account, generation);
    } on _WatchStopped {
      // Cancellation does not credit an unknown or late heartbeat response.
    } on FormatException {
      _fail(generation, unsupported: true);
    } on _WatchRejected catch (error) {
      _fail(generation, apiCode: error.code);
    } catch (_) {
      _fail(generation);
    }
  }

  void _fail(int generation, {bool unsupported = false, int? apiCode}) {
    if (_disposed || generation != _generation) return;
    _invalidate();
    _failed = true;
    _emit(
      unsupported ? LiveWatchState.unsupported : LiveWatchState.error,
      unsupported
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
  }) {
    final interval = data['heartbeat_interval'] ?? previous?.interval;
    final timestamp = data['timestamp'];
    final key = data['secret_key'] ?? previous?.key;
    final rawRules = data['secret_rule'] ?? previous?.rules;
    if (interval is! int ||
        interval < 1 ||
        interval > 3600 ||
        timestamp is! int ||
        timestamp <= 0 ||
        timestamp > 9007199254740991 ||
        key is! String ||
        key.isEmpty ||
        key.length > 4096 ||
        rawRules is! List ||
        rawRules.any((value) => value is! int)) {
      throw const FormatException('Unsupported official watch challenge');
    }
    final rules = List<int>.from(rawRules);
    if (!LiveWatchSigner.supportsRules(rules)) {
      throw const FormatException('Unsupported official watch signature rules');
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

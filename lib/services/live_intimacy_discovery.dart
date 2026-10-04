// The injected public read callback intentionally differs from its field name.
// ignore_for_file: prefer_initializing_formals
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/retry_interceptor.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/services/live_medal_reader.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:dio/dio.dart';

class LiveIntimacyCandidate {
  final int roomId;
  final int anchorUid;
  final String anchorName;
  final int medalLevel;
  final bool followed;
  final bool medalOwned;
  final bool live;
  final int areaId;
  final int parentAreaId;
  const LiveIntimacyCandidate({
    required this.roomId,
    required this.anchorUid,
    this.anchorName = '',
    required this.medalLevel,
    required this.followed,
    required this.medalOwned,
    required this.live,
    this.areaId = 0,
    this.parentAreaId = 0,
  });
  bool get eligible => followed && medalOwned && live;
}

abstract interface class LiveIntimacyDiscoverySource {
  Future<List<LiveIntimacyCandidate>> discover(
    List<LiveIntimacyRoomPreferences> rooms,
  );
  Future<LiveIntimacyCandidate> recheck(LiveIntimacyRoomPreferences room);
  void cancel();
}

/// Optional: older injected sources already provide complete snapshots.
abstract interface class LiveIntimacyDiscoveryDiagnostics {
  bool get complete;
}

typedef LiveIntimacyRead = Future<Map<String, dynamic>> Function(
  String path,
  Map<String, dynamic> query,
);

/// A login transition is a boundary even if the numeric UID stays the same.
class LiveIntimacyDiscoveryIdentity {
  final Object identity;
  final int uid;
  final int generation;
  final bool ready;
  const LiveIntimacyDiscoveryIdentity({
    required this.identity,
    required this.uid,
    required this.generation,
    this.ready = true,
  });

  bool sameAs(LiveIntimacyDiscoveryIdentity other) =>
      identical(identity, other.identity) &&
      uid == other.uid &&
      generation == other.generation &&
      ready == other.ready;
}

/// Raw responses retain UID and pagination information omitted by the existing
/// live-list UI model. Only official read endpoints are used here.
class LiveIntimacyDiscovery
    implements LiveIntimacyDiscoverySource, LiveIntimacyDiscoveryDiagnostics {
  LiveIntimacyDiscovery.testing({
    required LiveIntimacyRead read,
    LiveIntimacyDiscoveryIdentity Function()? identity,
    DateTime Function()? now,
  }) : _read = read,
       _identity = identity,
       _now = now ?? DateTime.now;
  factory LiveIntimacyDiscovery.production() {
    final adapter = _DiscoveryReader();
    return LiveIntimacyDiscovery.testing(
      read: adapter.read,
      identity: () {
        final account = Accounts.main;
        return LiveIntimacyDiscoveryIdentity(
          identity: account,
          uid: account.isLogin ? account.mid : 0,
          generation: Accounts.mainChangeGeneration,
          ready: account.isLogin && !Accounts.mainIdentityChangeInProgress,
        );
      },
    ).._cancel = adapter.cancel;
  }
  final LiveIntimacyRead _read;
  final LiveIntimacyDiscoveryIdentity Function()? _identity;
  final DateTime Function() _now;
  final Object _testingIdentity = Object();
  void Function()? _cancel;
  LiveIntimacyDiscoveryIdentity? _boundary;
  _DiscoverySnapshot? _cache;
  _DiscoveryPending? _pending;
  _DiscoveryFailure? _failure;
  int _readEpoch = 0;
  bool _complete = false;
  @override
  bool get complete {
    final identity = _synchronizeIdentity();
    final cache = _cache;
    return _complete &&
        cache != null &&
        cache.identity.sameAs(identity) &&
        _recent(cache.started, _now());
  }

  // This is a client request budget, not a claimed platform rate limit. Only a
  // trusted terminal account-wide scan can be reused, including an explicitly
  // partial positive snapshot; room qualification always bypasses this cache.
  static const _scanInterval = Duration(seconds: 60);
  static const followingPath = '/xlive/web-ucenter/user/following';
  static const medalsPath = '/xlive/app-ucenter/v1/fansMedal/panel';
  static const roomPath = '/xlive/web-room/v1/index/getInfoByRoom';

  LiveIntimacyDiscoveryIdentity _synchronizeIdentity() {
    final identity =
        _identity?.call() ??
        LiveIntimacyDiscoveryIdentity(
          identity: _testingIdentity,
          uid: 1,
          generation: 0,
        );
    if (_boundary != null && !_boundary!.sameAs(identity)) {
      _readEpoch++;
      _cache = null;
      _complete = false;
      _failure = null;
      _pending = null;
      _cancel?.call();
    }
    _boundary = identity;
    return identity;
  }

  void _requireReady(LiveIntimacyDiscoveryIdentity identity) {
    if (!identity.ready || identity.uid <= 0) {
      throw const _DiscoveryStopped('登录身份尚未就绪');
    }
  }

  bool _current(LiveIntimacyDiscoveryIdentity identity, int epoch) {
    final latest = _synchronizeIdentity();
    return latest.ready &&
        latest.uid > 0 &&
        identity.sameAs(latest) &&
        epoch == _readEpoch;
  }

  void _guard(LiveIntimacyDiscoveryIdentity identity, int epoch) {
    if (!_current(identity, epoch)) {
      throw const _DiscoveryStopped('账号或任务已变化，旧列表已忽略');
    }
  }

  LiveIntimacyRead _guardedRead(
    LiveIntimacyDiscoveryIdentity identity,
    int epoch,
  ) => (path, query) async {
    _guard(identity, epoch);
    final result = await _read(path, query);
    _guard(identity, epoch);
    return result;
  };

  bool _recent(DateTime started, DateTime now) {
    final age = now.difference(started);
    return !age.isNegative && age < _scanInterval;
  }

  Future<_DiscoverySnapshot> _scan(
    LiveIntimacyDiscoveryIdentity identity,
    int epoch,
    LiveIntimacyRoomPreferences reference,
  ) async {
    final started = _now();
    try {
      final read = _guardedRead(identity, epoch);
      final following = await _following(read);
      final medals = await _medals(reference, read);
      _guard(identity, epoch);
      final snapshot = _DiscoverySnapshot(
        identity: identity,
        started: started,
        following: following,
        medals: medals,
      );
      _cache = snapshot;
      _complete = medals.complete;
      _failure = null;
      return snapshot;
    } catch (error) {
      // Cancellation and late responses from another identity neither populate
      // the cache nor suppress a new identity's first legitimate scan.
      if (error is! _DiscoveryStopped && _current(identity, epoch)) {
        _cache = null;
        _complete = false;
        _failure = _DiscoveryFailure(identity: identity, started: _now());
      }
      rethrow;
    }
  }

  Map<String, dynamic> _data(Map<String, dynamic> response) {
    if (liveInt(response['code']) != 0 || response['data'] is! Map) {
      throw const LiveInteractionException('关注或勋章列表暂时无法核对');
    }
    return liveMap(response['data']);
  }

  Future<Map<int, Map<String, dynamic>>> _following(
    LiveIntimacyRead read,
  ) async {
    final result = <int, Map<String, dynamic>>{};
    final pageSignatures = <String>{};
    final seenIdentities = <int>{};
    int? total;
    for (var page = 1; page <= 500; page++) {
      final data = _data(
        await read(followingPath, {
          'page': page,
          'page_size': 9,
          'ignoreRecord': 1,
          'hit_ab': true,
        }),
      );
      final pages = liveInt(data['totalPage']);
      if (pages == null || pages < 0 || pages > 500 || data['list'] is! List) {
        throw const LiveInteractionException('关注列表分页规则尚未确认');
      }
      if (total != null && total != pages) {
        throw const LiveInteractionException('关注列表正在变化，稍后重新核对');
      }
      total = pages;
      final entries = liveMaps(data['list']);
      if (pages == 0 && entries.isEmpty) return result;
      if (pages == 0) {
        throw const LiveInteractionException('关注列表分页状态不一致');
      }
      if (entries.isEmpty && page < pages) {
        throw const LiveInteractionException('关注列表分页不完整');
      }
      final signature = entries.map((item) => item['uid']).join(',');
      if (entries.isNotEmpty && !pageSignatures.add(signature)) {
        throw const LiveInteractionException('关注列表返回重复分页');
      }
      for (final item in entries) {
        final uid = liveInt(item['uid']);
        if (uid == null || uid <= 0 || liveInt(item['is_attention']) == null) {
          throw const LiveInteractionException('关注列表缺少可靠主播身份');
        }
        if (!seenIdentities.add(uid)) {
          throw const LiveInteractionException('关注列表主播重复，等待稳定分页');
        }
        if (liveInt(item['is_attention']) == 1) result[uid] = item;
      }
      if (page >= pages) return result;
    }
    throw const LiveInteractionException('关注列表分页超出核对范围');
  }

  Future<LiveMedalInventory> _medals(
    LiveIntimacyRoomPreferences reference,
    LiveIntimacyRead read,
  ) async {
    try {
      return await readLiveMedalInventory(
        read: read,
        roomId: reference.roomId,
        anchorUid: reference.anchorUid,
      );
    } on LiveMedalReadException catch (error) {
      throw LiveInteractionException(error.message);
    }
  }

  @override
  Future<List<LiveIntimacyCandidate>> discover(
    List<LiveIntimacyRoomPreferences> rooms,
  ) async {
    final identity = _synchronizeIdentity();
    final authorized = rooms.where((room) => room.authorized).toList();
    if (authorized.isEmpty) return const [];
    _requireReady(identity);
    final epoch = _readEpoch;
    final now = _now();
    var snapshot = _cache;
    if (snapshot != null &&
        (!snapshot.identity.sameAs(identity) ||
            !_recent(snapshot.started, now))) {
      _cache = snapshot = null;
    }
    if (snapshot == null) {
      final failure = _failure;
      if (failure != null &&
          failure.identity.sameAs(identity) &&
          _recent(failure.started, now)) {
        throw const LiveInteractionException('关注或勋章列表稍后重新核对');
      }
      _failure = null;
      var pending = _pending;
      if (pending == null ||
          !pending.identity.sameAs(identity) ||
          pending.epoch != epoch) {
        pending = _DiscoveryPending(
          identity: identity,
          epoch: epoch,
          future: _scan(identity, epoch, authorized.first),
        );
        _pending = pending;
      }
      try {
        snapshot = await pending.future;
      } finally {
        if (identical(_pending, pending)) _pending = null;
      }
    }
    _guard(identity, epoch);
    final following = snapshot.following;
    final inventory = snapshot.medals;
    _complete = inventory.complete;
    final medals = inventory.entriesByAnchor;
    final owned = {
      for (final medal in inventory.medals) medal.targetUid: medal,
    };
    final result = <LiveIntimacyCandidate>[];
    final seen = <int>{};
    for (final room in authorized) {
      if (!seen.add(room.anchorUid)) continue;
      final follow = following[room.anchorUid];
      final medal = medals[room.anchorUid];
      // A terminal inventory with a count gap proves only the medals actually
      // observed. Omit missing anchors so the scheduler keeps them unknown.
      if (medal == null && !inventory.complete) continue;
      final confirmedMedal = owned[room.anchorUid];
      result.add(
        LiveIntimacyCandidate(
          roomId:
              liveInt(follow?['roomid']) ??
              liveInt(liveMap(medal?['room_info'])['room_id']) ??
              room.roomId,
          anchorUid: room.anchorUid,
          anchorName: follow?['uname']?.toString() ?? room.anchorName,
          medalLevel: confirmedMedal?.level ?? 0,
          followed: follow != null,
          medalOwned: confirmedMedal != null,
          live: liveInt(follow?['live_status']) == 1,
          areaId: liveInt(follow?['area_id']) ?? 0,
          parentAreaId: liveInt(follow?['parent_area_id']) ?? 0,
        ),
      );
    }
    return result;
  }

  @override
  Future<LiveIntimacyCandidate> recheck(
    LiveIntimacyRoomPreferences room,
  ) async {
    final identity = _synchronizeIdentity();
    _requireReady(identity);
    final read = _guardedRead(identity, _readEpoch);
    final data = _data(await read(roomPath, {'room_id': room.roomId}));
    final info = liveMap(data['room_info']);
    final canonical = liveInt(info['room_id']);
    if (canonical == null ||
        canonical <= 0 ||
        liveInt(info['uid']) != room.anchorUid ||
        liveInt(info['live_status']) == null) {
      throw const LiveInteractionException('直播间真实身份尚未确认');
    }
    final relation = _data(await read('/x/relation', {'fid': room.anchorUid}));
    final attribute = liveInt(relation['attribute']);
    if (attribute == null) {
      throw const LiveInteractionException('关注身份尚未确认');
    }
    LiveMedal? medal;
    try {
      medal = await readLiveMedalForAnchor(
        read: read,
        roomId: canonical,
        anchorUid: room.anchorUid,
      );
    } on LiveMedalReadException catch (error) {
      throw LiveInteractionException(error.message);
    }
    final level = medal?.level ?? 0;
    return LiveIntimacyCandidate(
      roomId: canonical,
      anchorUid: room.anchorUid,
      anchorName: room.anchorName,
      medalLevel: level,
      followed: const [2, 6].contains(attribute),
      medalOwned: medal != null,
      live: liveInt(info['live_status']) == 1,
      areaId: liveInt(info['area_id']) ?? 0,
      parentAreaId: liveInt(info['parent_area_id']) ?? 0,
    );
  }

  @override
  void cancel() {
    // Configuration edits/preemption cancel work in flight. They do not erase a
    // trusted same-account positive scan and cause another request burst.
    _synchronizeIdentity();
    _readEpoch++;
    _pending = null;
    _cancel?.call();
  }
}

class _DiscoveryStopped extends LiveInteractionException {
  const _DiscoveryStopped(super.message);
}

class _DiscoverySnapshot {
  final LiveIntimacyDiscoveryIdentity identity;
  final DateTime started;
  final Map<int, Map<String, dynamic>> following;
  final LiveMedalInventory medals;
  const _DiscoverySnapshot({
    required this.identity,
    required this.started,
    required this.following,
    required this.medals,
  });
}

class _DiscoveryPending {
  final LiveIntimacyDiscoveryIdentity identity;
  final int epoch;
  final Future<_DiscoverySnapshot> future;
  const _DiscoveryPending({
    required this.identity,
    required this.epoch,
    required this.future,
  });
}

class _DiscoveryFailure {
  final LiveIntimacyDiscoveryIdentity identity;
  final DateTime started;
  const _DiscoveryFailure({required this.identity, required this.started});
}

class _DiscoveryReader {
  Dio? _client;
  CancelToken _token = CancelToken();
  Dio get client {
    Request();
    return _client ??= Request.dio.clone()
      ..interceptors.removeWhere(
        (item) => item is RetryInterceptor || item is LogInterceptor,
      )
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (Accounts.mainIdentityChangeInProgress ||
                !identical(options.extra['account'], Accounts.main) ||
                options.extra['intimacyDiscoveryGeneration'] !=
                    Accounts.mainChangeGeneration ||
                options.cancelToken?.isCancelled == true) {
              handler.reject(
                DioException.requestCancelled(
                  requestOptions: options,
                  reason: 'Live intimacy read identity changed',
                ),
              );
            } else {
              handler.next(options);
            }
          },
        ),
      );
  }

  Future<Map<String, dynamic>> read(
    String path,
    Map<String, dynamic> query,
  ) async {
    final owner = Accounts.main;
    final generation = Accounts.mainChangeGeneration;
    if (!owner.isLogin || Accounts.mainIdentityChangeInProgress) {
      throw const LiveInteractionException('登录身份尚未就绪');
    }
    final token = _token;
    final origin = path == '/x/relation'
        ? 'https://api.bilibili.com'
        : 'https://api.live.bilibili.com';
    final response = await client.get<dynamic>(
      origin + path,
      queryParameters: query,
      cancelToken: token,
      options: Options(
        extra: {'account': owner, 'intimacyDiscoveryGeneration': generation},
        followRedirects: false,
        maxRedirects: 0,
        receiveTimeout: const Duration(seconds: 15),
      ),
    );
    if (token.isCancelled ||
        !identical(owner, Accounts.main) ||
        generation != Accounts.mainChangeGeneration ||
        Accounts.mainIdentityChangeInProgress) {
      throw const LiveInteractionException('账号已变化，旧列表已忽略');
    }
    return liveMap(response.data);
  }

  void cancel() {
    _token.cancel('Live intimacy discovery cancelled');
    _token = CancelToken();
  }
}

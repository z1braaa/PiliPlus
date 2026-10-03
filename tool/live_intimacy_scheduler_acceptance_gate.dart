// Pure manual-harness admission checks. No storage, player or network access.
import 'dart:convert';

class LiveSchedulerAcceptanceConfig {
  const LiveSchedulerAcceptanceConfig({
    required this.hivePath,
    required this.libraryPath,
    required this.reportPath,
    required this.nativeSource,
    required this.seconds,
    this.preferredA,
    this.preferredB,
    this.readOnly = false,
    this.singleRoom = false,
    this.diagnosticRoomEntry = false,
  });
  final String hivePath;
  final String libraryPath;
  final String reportPath;
  final String nativeSource;
  final int seconds;
  final int? preferredA;
  final int? preferredB;
  final bool readOnly;
  final bool singleRoom;
  final bool diagnosticRoomEntry;

  factory LiveSchedulerAcceptanceConfig.fromEnvironment(
    Map<String, String> env,
  ) {
    if (env['LIVE_SCHEDULER_ACCOUNT_AUTHORIZED'] != 'true') {
      throw const FormatException('explicit_authorization_required');
    }
    String path(String key) {
      final value = env[key];
      if (value == null ||
          !value.startsWith('/') ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        throw const FormatException('explicit_absolute_path_required');
      }
      return value;
    }

    int? preferred(String key) {
      final raw = env[key];
      if (raw == null || raw.isEmpty) return null;
      final value = int.tryParse(raw);
      if (value == null || value <= 0) {
        throw const FormatException('invalid_preferred_room');
      }
      return value;
    }

    final seconds = int.tryParse(env['LIVE_SCHEDULER_SECONDS'] ?? '1200');
    if (seconds == null || seconds < 180 || seconds > 1200) {
      throw const FormatException('bounded_window_required');
    }
    final source = env['LIVE_SCHEDULER_NATIVE_SOURCE'] ?? '';
    if (!RegExp(r'^[a-zA-Z0-9+_.-]{1,80}$').hasMatch(source)) {
      throw const FormatException('public_native_source_required');
    }
    final hive = path('LIVE_SCHEDULER_HIVE');
    final report = path('LIVE_SCHEDULER_REPORT');
    final normalizedHive = Uri.file(hive)
        .normalizePath()
        .path
        .replaceAll(RegExp(r'/+$'), '');
    final normalizedReport = Uri.file(report).normalizePath().path;
    if (!report.endsWith('.json') ||
        normalizedReport == normalizedHive ||
        normalizedReport.startsWith('$normalizedHive/')) {
      throw const FormatException('report_must_be_external_json');
    }
    final a = preferred('LIVE_SCHEDULER_ROOM_A');
    final b = preferred('LIVE_SCHEDULER_ROOM_B');
    final singleRoom = env['LIVE_SCHEDULER_SINGLE_ROOM'] == 'true';
    final diagnosticRoomEntry =
        env['LIVE_SCHEDULER_DIAGNOSTIC_ROOM_ENTRY'] == 'true';
    if (diagnosticRoomEntry &&
        (!singleRoom || env['LIVE_SCHEDULER_READ_ONLY'] == 'true')) {
      throw const FormatException(
        'diagnostic_entry_requires_single_write_scope',
      );
    }
    if (singleRoom && b != null) {
      throw const FormatException('single_room_must_not_request_room_b');
    }
    if (a != null && a == b) {
      throw const FormatException('two_distinct_rooms_required');
    }
    return LiveSchedulerAcceptanceConfig(
      hivePath: hive,
      libraryPath: path('LIVE_SCHEDULER_MPV'),
      reportPath: report,
      nativeSource: source,
      seconds: seconds,
      preferredA: a,
      preferredB: b,
      readOnly: env['LIVE_SCHEDULER_READ_ONLY'] == 'true',
      singleRoom: singleRoom,
      diagnosticRoomEntry: diagnosticRoomEntry,
    );
  }
}

class LiveSchedulerAcceptanceRoomScope {
  const LiveSchedulerAcceptanceRoomScope({
    required this.anchorUid,
    required this.emoticon,
    required this.likeClicks,
    required this.danmakuCount,
  });
  final int anchorUid;
  final String emoticon;
  final int likeClicks;
  final int danmakuCount;
}

/// The user's test authorization names the first anchor fan-club expression.
/// If it is unusable, do not substitute the second expression or another pack.
String? liveSchedulerFirstFanEmoticon(Object? packages) {
  if (packages is! List) return null;
  bool permitted(Object? value) => value == true || value == 1 || value == '1';
  for (final package in packages.whereType<Map>()) {
    if (LiveSchedulerAcceptanceWriteGuard.integer(package['pkg_type']) != 2) {
      continue;
    }
    final expressions = package['emoticons'];
    if (expressions is! List ||
        expressions.isEmpty ||
        expressions.first is! Map) {
      return null;
    }
    final first = expressions.first as Map;
    final unique = first['emoticon_unique'];
    if (unique is! String ||
        unique.isEmpty ||
        package.containsKey('perm') && !permitted(package['perm']) ||
        !permitted(first['perm'] ?? package['perm'])) {
      return null;
    }
    return unique;
  }
  return null;
}

/// Budgets are spent before a write is dispatched, including ambiguous failures.
/// A permitted retry cannot silently restore an already spent task allowance.
class LiveSchedulerAcceptanceWriteGuard {
  LiveSchedulerAcceptanceWriteGuard(
    Map<int, LiveSchedulerAcceptanceRoomScope> rooms, {
    this.diagnosticRoomEntry = false,
  }) : rooms = Map.unmodifiable(rooms),
       _likesRemaining = {
         for (final entry in rooms.entries) entry.key: entry.value.likeClicks,
       },
       _danmakuRemaining = {
         for (final entry in rooms.entries) entry.key: entry.value.danmakuCount,
       };

  final Map<int, LiveSchedulerAcceptanceRoomScope> rooms;
  final bool diagnosticRoomEntry;
  final Set<int> _entered = {};
  final Map<int, int> _likesRemaining;
  final Map<int, int> _danmakuRemaining;
  final Map<int, int> _activation = {};
  final Map<int, int> _lastLike = {};
  final Map<int, int> _lastDanmaku = {};
  final Set<int> _firstLikeAfterActivation = {};

  void activateRoom(int roomId, int elapsedMilliseconds) {
    if (!rooms.containsKey(roomId) || elapsedMilliseconds < 0) return;
    _activation[roomId] = elapsedMilliseconds;
    _firstLikeAfterActivation.add(roomId);
  }

  int remainingLikes(int roomId) => _likesRemaining[roomId] ?? 0;
  int remainingDanmaku(int roomId) => _danmakuRemaining[roomId] ?? 0;

  static int? integer(Object? value) => value is int
      ? value
      : value is String && RegExp(r'^\d+$').hasMatch(value)
      ? int.tryParse(value)
      : null;

  static int? watchRoom(Map<String, dynamic> query) {
    try {
      final raw = query['id'];
      final list = raw is String ? jsonDecode(raw) : raw;
      return list is List && list.length == 4 ? integer(list[3]) : null;
    } on FormatException {
      return null;
    }
  }

  bool allow({
    required Uri uri,
    required String method,
    required Map<String, dynamic> query,
    Object? data,
    required int elapsedMilliseconds,
    required bool writesEnabled,
    required bool readOnly,
    required bool identityAndPrivacyConfirmed,
    required bool Function(int roomId, bool interactive) roomAuthorized,
  }) {
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      return false;
    }
    if (method == 'GET') {
      if (uri.host == 'api.bilibili.com') {
        return const {'/x/web-interface/nav', '/x/relation'}.contains(uri.path);
      }
      if (uri.host != 'api.live.bilibili.com') return false;
      return const {
        '/xlive/web-ucenter/user/following',
        '/xlive/app-ucenter/v1/fansMedal/panel',
        '/room/v1/Room/room_init',
        '/xlive/web-room/v1/index/getInfoByRoom',
        '/xlive/web-room/v2/index/getRoomPlayInfo',
        '/xlive/app-ucenter/v1/fansMedal/GetActivatedMedalInfo',
        '/xlive/web-ucenter/v2/emoticon/GetEmoticons',
      }.contains(uri.path);
    }
    if (method != 'POST' ||
        !writesEnabled ||
        readOnly ||
        !identityAndPrivacyConfirmed ||
        elapsedMilliseconds < 0) {
      return false;
    }
    if (uri.host == 'live-trace.bilibili.com' &&
        const {
          '/xlive/data-interface/v1/x25Kn/E',
          '/xlive/data-interface/v1/x25Kn/X',
        }.contains(uri.path)) {
      final room = watchRoom(query);
      return room != null &&
          rooms.containsKey(room) &&
          integer(query['ruid']) == rooms[room]!.anchorUid &&
          roomAuthorized(room, false);
    }
    if (uri.host != 'api.live.bilibili.com' || data is! Map) return false;
    final room = integer(data['room_id'] ?? data['roomid']);
    final scope = rooms[room];
    if (uri.path == '/xlive/web-room/v1/index/roomEntryAction') {
      if (!diagnosticRoomEntry ||
          room == null ||
          scope == null ||
          !roomAuthorized(room, false) ||
          _entered.contains(room) ||
          data.length != 2 ||
          data['platform'] != 'pc' ||
          integer(data['room_id']) != room ||
          query.length != 1 ||
          query['csrf'] is! String ||
          (query['csrf'] as String).isEmpty) {
        return false;
      }
      _entered.add(room);
      return true;
    }
    if (room == null || scope == null || !roomAuthorized(room, true)) {
      return false;
    }
    if (uri.path == '/xlive/app-ucenter/v1/like_info_v3/like/likeReportV3') {
      final clicks = integer(data['click_time']);
      final activation = _activation[room];
      // Production accumulates 1–3 seconds per virtual click, then reports one
      // bounded batch. Validate its minimum first-batch duration, not one-click
      // requests. Subsequent requests also retain a minimum one-second gap.
      if (clicks == null ||
          clicks < 1 ||
          clicks > remainingLikes(room) ||
          integer(data['anchor_id']) != scope.anchorUid ||
          activation == null ||
          _firstLikeAfterActivation.contains(room) &&
              elapsedMilliseconds - activation < clicks * 1000 ||
          _lastLike[room] != null &&
              elapsedMilliseconds - _lastLike[room]! < 1000) {
        return false;
      }
      _likesRemaining[room] = remainingLikes(room) - clicks;
      _lastLike[room] = elapsedMilliseconds;
      _firstLikeAfterActivation.remove(room);
      return true;
    }
    if (uri.path == '/msg/send') {
      if (integer(data['dm_type']) != 1 ||
          data['msg'] != scope.emoticon ||
          remainingDanmaku(room) < 1 ||
          _lastDanmaku[room] != null &&
              elapsedMilliseconds - _lastDanmaku[room]! < 30000) {
        return false;
      }
      _danmakuRemaining[room] = remainingDanmaku(room) - 1;
      _lastDanmaku[room] = elapsedMilliseconds;
      return true;
    }
    return false;
  }

  static int acceptedAmount(Uri uri, Map<String, dynamic> query, Object? data) {
    if (uri.path.endsWith('/X')) return integer(query['time']) ?? 0;
    if (uri.path == '/xlive/app-ucenter/v1/like_info_v3/like/likeReportV3') {
      return data is Map ? integer(data['click_time']) ?? 0 : 0;
    }
    return 1;
  }
}

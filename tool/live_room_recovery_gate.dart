// Pure limits for the opt-in, single-room recovery acceptance harness.
// No account, storage, player or network code is imported here.
class LiveRoomRecoveryConfig {
  const LiveRoomRecoveryConfig({
    required this.hivePath,
    required this.reportPath,
    required this.roomId,
    required this.anchorUid,
    required this.seconds,
  });
  final String hivePath;
  final String reportPath;
  final int roomId;
  final int anchorUid;
  final int seconds;
  String get stopMarkerPath => '$reportPath.stop';

  factory LiveRoomRecoveryConfig.fromEnvironment(Map<String, String> env) {
    if (env['LIVE_ROOM_RECOVERY_AUTHORIZED'] != 'true') {
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

    int positive(String key) {
      final value = int.tryParse(env[key] ?? '');
      if (value == null || value <= 0) {
        throw const FormatException('explicit_room_and_anchor_required');
      }
      return value;
    }

    final hive = path('LIVE_ROOM_RECOVERY_HIVE');
    final report = path('LIVE_ROOM_RECOVERY_REPORT');
    final source = Uri.file(hive)
        .normalizePath()
        .path
        .replaceAll(RegExp(r'/+$'), '');
    final destination = Uri.file(report).normalizePath().path;
    if (!report.endsWith('.json') ||
        destination == source ||
        destination.startsWith('$source/')) {
      throw const FormatException('report_must_be_external_json');
    }
    final seconds = int.tryParse(env['LIVE_ROOM_RECOVERY_SECONDS'] ?? '360');
    if (seconds == null || seconds < 150 || seconds > 360) {
      throw const FormatException('bounded_recovery_window_required');
    }
    return LiveRoomRecoveryConfig(
      hivePath: hive,
      reportPath: report,
      roomId: positive('LIVE_ROOM_RECOVERY_ROOM'),
      anchorUid: positive('LIVE_ROOM_RECOVERY_ANCHOR'),
      seconds: seconds,
    );
  }
}

class LiveRoomRecoveryRequestGate {
  LiveRoomRecoveryRequestGate({
    required this.roomId,
    required this.anchorUid,
    required this.accountUid,
    required Iterable<String> savedEmoticons,
    this.windowSeconds = 360,
  }) : _savedEmoticons = Set.unmodifiable(savedEmoticons);
  static const likePath =
      '/xlive/app-ucenter/v1/like_info_v3/like/likeReportV3';
  static const maximumLikeClicks = 30;
  static const maximumDanmaku = 2;
  final int roomId;
  final int anchorUid;
  final int accountUid;
  final int windowSeconds;
  final Set<String> _savedEmoticons;
  Set<String> _availableFanClubEmoticons = {};
  int? _emoticonsObservedAt;
  int? _activation;
  int? _lastLike;
  int? _lastDanmaku;
  int acceptedReads = 0;
  int blockedRequests = 0;
  int attemptedLikeClicks = 0;
  int attemptedDanmaku = 0;
  int get remainingLikeClicks => maximumLikeClicks - attemptedLikeClicks;
  int get remainingDanmaku => maximumDanmaku - attemptedDanmaku;

  void activateInteractions(int elapsedMilliseconds) {
    if (elapsedMilliseconds >= 0) _activation ??= elapsedMilliseconds;
  }

  void confirmEmoticons(
    Iterable<String> availableFanClub,
    int elapsedMilliseconds,
  ) {
    _availableFanClubEmoticons = availableFanClub.toSet().intersection(
      _savedEmoticons,
    );
    _emoticonsObservedAt = elapsedMilliseconds;
  }

  static int? integer(Object? value) => value is int
      ? value
      : value is String && RegExp(r'^\d+$').hasMatch(value)
      ? int.tryParse(value)
      : null;

  bool allows({
    required Uri uri,
    required String method,
    required Map<String, dynamic> query,
    Object? data,
    required int elapsedMilliseconds,
    required bool writesEnabled,
    required bool identityAndPrivacyConfirmed,
    required bool roomAndTaskConfirmed,
  }) {
    var allowed = false;
    if (uri.scheme == 'https' &&
        uri.port == 443 &&
        uri.userInfo.isEmpty &&
        uri.fragment.isEmpty &&
        identityAndPrivacyConfirmed) {
      if (method == 'GET' && acceptedReads < 1000) {
        allowed = _allowsRead(uri, query);
        if (allowed) ++acceptedReads;
      } else if (method == 'POST' &&
          uri.host == 'api.live.bilibili.com' &&
          data is Map &&
          writesEnabled &&
          roomAndTaskConfirmed &&
          _activation != null &&
          elapsedMilliseconds >= _activation! &&
          elapsedMilliseconds - _activation! <= windowSeconds * 1000 &&
          roomId > 0 &&
          anchorUid > 0 &&
          accountUid > 0) {
        if (uri.path == likePath) {
          final count = integer(data['click_time']);
          final origin = _lastLike ?? _activation!;
          allowed =
              integer(data['room_id']) == roomId &&
              integer(data['anchor_id']) == anchorUid &&
              integer(data['uid']) == accountUid &&
              count != null &&
              count > 0 &&
              count <= remainingLikeClicks &&
              elapsedMilliseconds - origin >= count * 1000;
          if (allowed) {
            attemptedLikeClicks += count;
            _lastLike = elapsedMilliseconds;
          }
        } else if (uri.path == '/msg/send') {
          final unique = data['msg'];
          final origin = _lastDanmaku ?? _activation!;
          allowed =
              integer(data['roomid']) == roomId &&
              integer(data['dm_type']) == 1 &&
              unique is String &&
              _availableFanClubEmoticons.contains(unique) &&
              _emoticonsObservedAt != null &&
              elapsedMilliseconds >= _emoticonsObservedAt! &&
              elapsedMilliseconds - _emoticonsObservedAt! <= 30000 &&
              elapsedMilliseconds - origin >= 30000 &&
              remainingDanmaku > 0;
          if (allowed) {
            ++attemptedDanmaku;
            _lastDanmaku = elapsedMilliseconds;
          }
        }
      }
    }
    if (!allowed) ++blockedRequests;
    return allowed;
  }

  bool _allowsRead(Uri uri, Map<String, dynamic> query) {
    if (uri.host == 'api.bilibili.com') {
      return uri.path == '/x/web-interface/nav' ||
          uri.path == '/x/relation' && integer(query['fid']) == anchorUid;
    }
    if (uri.host != 'api.live.bilibili.com') return false;
    final room = integer(query['room_id']);
    final page = integer(query['page']);
    return switch (uri.path) {
      '/xlive/web-room/v1/index/getInfoByRoom' => room == roomId,
      '/xlive/web-ucenter/user/following' =>
        page != null &&
            page > 0 &&
            page <= 500 &&
            integer(query['page_size']) == 9 &&
            query['ignoreRecord'] == 1 &&
            query['hit_ab'] == true,
      '/xlive/app-ucenter/v1/fansMedal/GetActivatedMedalInfo' =>
        room == roomId && integer(query['target_id']) == anchorUid,
      '/xlive/app-ucenter/v1/fansMedal/panel' =>
        room == roomId &&
            integer(query['target_id']) == anchorUid &&
            page != null &&
            page > 0 &&
            page <= 500 &&
            integer(query['page_size']) == 10 &&
            !query.containsKey('light_status') &&
            !query.containsKey('next_light_status'),
      '/xlive/web-ucenter/v2/emoticon/GetEmoticons' => room == roomId,
      _ => false,
    };
  }
}

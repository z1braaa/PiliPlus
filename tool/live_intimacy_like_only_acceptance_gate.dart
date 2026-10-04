// Pure admission checks for the opt-in, single-room, free-like harness.
// This file never opens accounts, storage, media or a network connection.
class LiveLikeOnlyAcceptanceConfig {
  const LiveLikeOnlyAcceptanceConfig({
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

  factory LiveLikeOnlyAcceptanceConfig.fromEnvironment(
    Map<String, String> env,
  ) {
    if (env['LIVE_LIKE_ONLY_ACCOUNT_AUTHORIZED'] != 'true') {
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

    final hive = path('LIVE_LIKE_ONLY_HIVE');
    final report = path('LIVE_LIKE_ONLY_REPORT');
    final hivePath = Uri.file(hive)
        .normalizePath()
        .path
        .replaceAll(RegExp(r'/+$'), '');
    final reportPath = Uri.file(report).normalizePath().path;
    if (!report.endsWith('.json') ||
        reportPath == hivePath ||
        reportPath.startsWith('$hivePath/')) {
      throw const FormatException('report_must_be_external_json');
    }
    final seconds = int.tryParse(env['LIVE_LIKE_ONLY_SECONDS'] ?? '150');
    if (seconds == null || seconds < 60 || seconds > 180) {
      throw const FormatException('bounded_window_required');
    }
    return LiveLikeOnlyAcceptanceConfig(
      hivePath: hive,
      reportPath: report,
      roomId: positive('LIVE_LIKE_ONLY_ROOM'),
      anchorUid: positive('LIVE_LIKE_ONLY_ANCHOR'),
      seconds: seconds,
    );
  }
}

/// A consumed allowance never returns, even after an error, switch or restart
/// of the scheduler inside this test. A successful request is separate from
/// an official medal or task change.
class LiveLikeOnlyAcceptanceGate {
  LiveLikeOnlyAcceptanceGate({
    required this.roomId,
    required this.anchorUid,
    required this.accountUid,
  });
  static const likePath =
      '/xlive/app-ucenter/v1/like_info_v3/like/likeReportV3';
  static const maximumLikeClicks = 30;
  final int roomId;
  final int anchorUid;
  final int accountUid;
  int acceptedReads = 0;
  int blockedRequests = 0;
  int attemptedLikeClicks = 0;
  int? _activation;
  int? _lastLike;

  int get remainingLikeClicks => maximumLikeClicks - attemptedLikeClicks;

  void activateInteractions(int elapsedMilliseconds) {
    if (elapsedMilliseconds >= 0) _activation ??= elapsedMilliseconds;
  }

  static int? integer(Object? value) => value is int
      ? value
      : value is String && RegExp(r'^\d+$').hasMatch(value)
      ? int.tryParse(value)
      : null;

  bool allow({
    required Uri uri,
    required String method,
    required Map<String, dynamic> query,
    Object? data,
    required int elapsedMilliseconds,
    required bool writesEnabled,
    required bool identityAndPrivacyConfirmed,
    required bool roomAndTaskConfirmed,
  }) {
    final allowed = _allow(
      uri: uri,
      method: method,
      query: query,
      data: data,
      elapsedMilliseconds: elapsedMilliseconds,
      writesEnabled: writesEnabled,
      identityAndPrivacyConfirmed: identityAndPrivacyConfirmed,
      roomAndTaskConfirmed: roomAndTaskConfirmed,
    );
    if (!allowed) ++blockedRequests;
    return allowed;
  }

  bool _allow({
    required Uri uri,
    required String method,
    required Map<String, dynamic> query,
    required Object? data,
    required int elapsedMilliseconds,
    required bool writesEnabled,
    required bool identityAndPrivacyConfirmed,
    required bool roomAndTaskConfirmed,
  }) {
    if (uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        !identityAndPrivacyConfirmed) {
      return false;
    }
    if (method == 'GET' && acceptedReads < 1000) {
      var allowed = false;
      if (uri.host == 'api.bilibili.com') {
        allowed =
            uri.path == '/x/web-interface/nav' ||
            uri.path == '/x/relation' && integer(query['fid']) == anchorUid;
      } else if (uri.host == 'api.live.bilibili.com') {
        final room = integer(query['room_id']);
        final page = integer(query['page']);
        allowed = switch (uri.path) {
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
          _ => false,
        };
      }
      if (allowed) ++acceptedReads;
      return allowed;
    }
    if (method != 'POST' ||
        uri.host != 'api.live.bilibili.com' ||
        uri.path != likePath ||
        data is! Map ||
        !writesEnabled ||
        !roomAndTaskConfirmed ||
        elapsedMilliseconds < 0 ||
        roomId <= 0 ||
        anchorUid <= 0 ||
        accountUid <= 0 ||
        integer(data['room_id']) != roomId ||
        integer(data['anchor_id']) != anchorUid ||
        integer(data['uid']) != accountUid) {
      return false;
    }
    final clicks = integer(data['click_time']);
    final pacingOrigin = _lastLike ?? _activation;
    if (clicks == null ||
        clicks < 1 ||
        clicks > remainingLikeClicks ||
        pacingOrigin == null ||
        elapsedMilliseconds - pacingOrigin < clicks * 1000) {
      return false;
    }
    attemptedLikeClicks += clicks;
    _lastLike = elapsedMilliseconds;
    return true;
  }
}

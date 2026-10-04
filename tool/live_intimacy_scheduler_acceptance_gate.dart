// Pure manual-harness admission checks. No storage, player or network access.
import 'dart:convert';

/// Room state can carry a server-origin exception. Preserve only diagnostics
/// whose complete text is locally authored, never a raw exception or URL.
Map<String, Object?> liveSchedulerSafeStateReason(String? reason) {
  if (reason == null) {
    return {'present': false, 'category': null, 'message': null};
  }
  const exact = {
    '仅音频会话初始化失败，已暂停此房间': 'audio_initialization_failed',
    '后台音频静音状态未确认': 'audio_silent_output_unconfirmed',
    '仅音频流暂时不可用': 'audio_stream_unavailable',
    '官方未提供仅音频地址': 'audio_address_missing',
    '仅音频请求返回了视频轨道，已暂停此房间': 'audio_video_track_returned',
    '仅音频播放失败，已暂停此房间': 'audio_playback_failed',
    '后台仅音频在20秒内无有效播放，已暂停此房间观时': 'audio_startup_no_effective_playback',
    // The app exposes a combined condition; neither cause can be inferred.
    '仅音频持续断流或无法确认解码，已暂停此房间': 'audio_stream_or_decode_unconfirmed',
    '音频房间身份或开播状态已变化': 'audio_room_identity_or_live_state_changed',
    '本地观时记录读取失败，此房间等待恢复后继续': 'record_restore_failed',
    '本地观时记录保存失败，尚未保存的记录等待重试': 'record_save_failed',
    '仅音频有效观时已覆盖一轮及结算等待，官方轮数仍未增长；已暂停此房间': 'watch_settlement_not_observed',
    '观时任务阶段或完成状态尚未确认': 'watch_phase_unconfirmed',
    '观看任务阶段仍未确认，稍后重新核对此房间': 'watch_phase_unconfirmed',
    '官方任务进度发生校正，任务周期待核对': 'official_cycle_unconfirmed',
    '官方同周期任务进度发生校正，自动操作暂停': 'official_cycle_unconfirmed',
    '官方任务周期待核对，自动操作暂停': 'official_cycle_unconfirmed',
    '官方任务同步失败': 'official_task_read_failed',
    '官方任务暂时无法核对': 'official_task_read_failed',
    '官方任务字段尚未取得，自动操作暂停': 'official_task_read_failed',
    '此房间尚未授权': 'room_unauthorized',
    '资格尚未确认': 'room_qualification_unconfirmed',
    '直播间资格暂时无法核对': 'room_qualification_unconfirmed',
    '未关注该主播': 'room_not_followed',
    '未拥有该主播粉丝勋章': 'room_medal_not_owned',
    '主播尚未开播': 'room_offline',
    '开播、关注、勋章或观看信息已变化': 'room_qualification_changed',
    '表情发送权限暂时无法确认': 'emoticon_permission_unconfirmed',
    '所选表情均不可发送，请重新配置': 'emoticon_permission_unconfirmed',
    '已选表情均不可发送，自动任务暂停': 'emoticon_permission_unconfirmed',
    '表情选择无效，请重新选择': 'emoticon_selection_invalid',
    '请选择1～5个自动发送表情': 'emoticon_selection_missing',
    '当前配置没有可发送的任务表情，自动弹幕已暂停': 'emoticon_permission_unconfirmed',
    '当前房间表情权限未确认或已失效，请重新选择': 'emoticon_permission_unconfirmed',
    '当前直播间尚未加入粉丝团': 'room_medal_not_owned',
    '粉丝团身份尚未确认，自动操作暂停': 'room_qualification_unconfirmed',
    '任务所属账号或直播间不一致，自动操作暂停': 'task_identity_changed',
    '账号已变化，请重新确认': 'account_identity_changed',
    '任务所属账号已变化，自动操作暂停': 'account_identity_changed',
    '账号正在变化，自动操作暂停': 'account_identity_changed',
    '系统休眠，后台亲密度已暂停': 'system_sleep',
    '请先开启自动点赞': 'auto_like_disabled',
    '请先开启自动弹幕': 'auto_danmaku_disabled',
    '等待官方主播和真实房间信息': 'room_identity_unconfirmed',
    '本地任务记录无法核对，自动操作暂停': 'local_task_record_unconfirmed',
    '本地任务记录超出核对范围，自动操作暂停': 'local_task_record_unconfirmed',
    '互动结果未知，仅核对任务；不会自动重发': 'interaction_result_unknown',
    '互动结果未知，正在只读核对任务；不会自动重发': 'interaction_result_unknown',
    '官方任务进度尚未增长，已停止自动发送；仅继续只读核对': 'interaction_settlement_not_observed',
    '互动未提交或被拒绝，自动操作暂停': 'interaction_not_accepted',
    '官方任务或本地记录暂时无法核对，自动操作暂停': 'official_or_local_task_read_failed',
  };
  final category = exact[reason];
  if (category != null) {
    return {'present': true, 'category': category, 'message': reason};
  }
  // Reporter text is assembled from fixed phases and numeric API/HTTP codes.
  // Match its complete bounded grammar; arbitrary suffixes are suppressed.
  final watchFailure = RegExp(
    r'^(?:观看准备|观看 E 入场|观看 X 心跳)(?:超时，结果未知|请求失败，结果未知|失败（HTTP [45]\d{2}），结果未知|被官方拒绝|参数无法解析)(?:（-?\d{1,8}）)?，已暂停；不会自动重发$',
  ).hasMatch(reason);
  final rejectedInteraction = RegExp(
    r'^官方拒绝本次互动（-?\d{1,8}），自动操作暂停$',
  ).hasMatch(reason);
  if (watchFailure || rejectedInteraction) {
    return {
      'present': true,
      'category': watchFailure
          ? 'watch_request_failed'
          : 'interaction_rejected',
      'message': reason,
    };
  }
  return {
    'present': true,
    'category': reason.contains('观时') || reason.contains('观看')
        ? 'watch_rule_or_settlement_unconfirmed'
        : reason.contains('表情')
        ? 'emoticon_permission_unconfirmed'
        : reason.contains('账号')
        ? 'account_identity_or_privacy_changed'
        : reason.contains('资格')
        ? 'room_qualification_unconfirmed'
        : 'task_paused',
    'message': 'unrecognized_diagnostic_text_suppressed',
  };
}

/// A native error can contain a signed media URL. Retain only fixed categories
/// and a context-qualified HTTP code; never retain or print the original text.
Map<String, Object?> liveSchedulerNativeErrorCategory(String error) {
  final lower = error.toLowerCase();
  final http = RegExp(
    r'(?:http(?:/[\d.]+)?(?: error)?|server returned)\s*(?:status(?: code)?\s*)?([45]\d{2})\b',
  ).firstMatch(lower);
  return {
    'category': http != null
        ? 'http_error'
        : lower.contains('timed out') || lower.contains('timeout')
        ? 'timeout'
        : lower.contains('resolve hostname') ||
              lower.contains('failed to resolve')
        ? 'name_resolution_failed'
        : lower.contains('connection reset') ||
              lower.contains('connection refused') ||
              lower.contains('network is unreachable')
        ? 'connection_failed'
        : lower.contains('decod') ||
              lower.contains('codec') ||
              lower.contains('invalid data') ||
              lower.contains('corrupt')
        ? 'decode_or_format_error'
        : 'native_error_unclassified',
    if (http != null) 'http_status': int.parse(http.group(1)!),
  };
}

/// Checks subsequent real decoder data before calling a native error recovered.
/// A terminal loss is reported independently of the interaction queue. This
/// helper never retries a stream or performs a network operation.
class LiveSchedulerNativeErrorMonitor {
  int? _lastSample;
  int? _invalidSince;
  int _consecutiveEffective = 0;
  String state = 'no_error_observed';
  int observedErrors = 0;
  bool effectiveAvLossObserved = false;

  void error(int elapsedMilliseconds) {
    if (elapsedMilliseconds < 0) return;
    ++observedErrors;
    _consecutiveEffective = 0;
    _invalidSince ??= elapsedMilliseconds;
    state = 'native_error_awaiting_decoder_evidence';
  }

  void sample({
    required int elapsedMilliseconds,
    required bool effectivePlayback,
    required bool userPaused,
  }) {
    // Keep checking after apparent recovery: buffered decoder data alone must
    // not hide a later persistent stall.
    if (observedErrors == 0 || elapsedMilliseconds < 0) return;
    if (_lastSample != null && elapsedMilliseconds <= _lastSample!) return;
    final continuous =
        _lastSample != null && elapsedMilliseconds - _lastSample! <= 3000;
    _lastSample = elapsedMilliseconds;
    if (userPaused) {
      _invalidSince = null;
      _consecutiveEffective = 0;
      state = 'native_error_observation_user_paused';
      return;
    }
    if (effectivePlayback) {
      _invalidSince = null;
      _consecutiveEffective = continuous ? _consecutiveEffective + 1 : 1;
      if (_consecutiveEffective >= 3) {
        state = 'native_error_recovered_three_effective_av_samples';
      } else {
        state = 'native_error_awaiting_decoder_evidence';
      }
    } else {
      _consecutiveEffective = 0;
      _invalidSince ??= elapsedMilliseconds;
      state = elapsedMilliseconds - _invalidSince! >= 20000
          ? 'native_error_no_effective_av_for_20_seconds'
          : 'native_error_awaiting_decoder_evidence';
      if (elapsedMilliseconds - _invalidSince! >= 20000) {
        effectiveAvLossObserved = true;
      }
    }
  }
}

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
    this.interactionLimits = const {},
    this.keepBWatchPriority = false,
    this.fanEmotePoolSize = 1,
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
  final Map<String, int> interactionLimits;
  final bool keepBWatchPriority;
  final int fanEmotePoolSize;
  String get stopMarkerPath => '$reportPath.stop';

  /// Admit an already-completed interaction baseline only when the operator
  /// explicitly sets both hard write limits to zero in a single-room run.
  bool get watchOnly =>
      singleRoom &&
      interactionLimits['A_like'] == 0 &&
      interactionLimits['A_sendDanmu'] == 0;

  int limitedInteractionBudget(String alias, String kind, int officialBudget) {
    final limit = interactionLimits['${alias}_$kind'];
    return limit != null && limit < officialBudget ? limit : officialBudget;
  }

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
    final fanEmotePoolSize = int.tryParse(
      env['LIVE_SCHEDULER_FAN_EMOTE_POOL_SIZE'] ?? '1',
    );
    if (fanEmotePoolSize == null ||
        fanEmotePoolSize < 1 ||
        fanEmotePoolSize > 5) {
      throw const FormatException('one_to_five_fan_emoticons_required');
    }
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
    final keepBWatchPriority = env['LIVE_SCHEDULER_KEEP_B_WATCH'] == 'true';
    if (singleRoom && keepBWatchPriority) {
      throw const FormatException('held_b_priority_requires_two_rooms');
    }
    final limits = <String, int>{};
    for (final alias in const ['A', 'B']) {
      for (final kind in const ['like', 'sendDanmu']) {
        final key =
            'LIVE_SCHEDULER_MAX_${kind == "like" ? "LIKE" : "DM"}_$alias';
        final raw = env[key];
        if (raw == null) continue;
        final count = int.tryParse(raw);
        if (count == null || count < 0 || count > 10000) {
          throw const FormatException('bounded_interaction_limit_required');
        }
        limits['${alias}_$kind'] = count;
      }
    }
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
      interactionLimits: Map.unmodifiable(limits),
      keepBWatchPriority: keepBWatchPriority,
      fanEmotePoolSize: fanEmotePoolSize,
    );
  }
}

class LiveSchedulerAcceptanceRoomScope {
  const LiveSchedulerAcceptanceRoomScope({
    required this.anchorUid,
    required this.emoticon,
    required this.likeClicks,
    required this.danmakuCount,
    this.additionalEmoticons = const {},
  });
  final int anchorUid;
  final String emoticon;
  final int likeClicks;
  final int danmakuCount;
  final Set<String> additionalEmoticons;
  Set<String> get permittedEmoticons => {emoticon, ...additionalEmoticons};
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
  int? _lastAccountDanmaku;
  final Set<int> _firstLikeAfterActivation = {};

  void activateRoom(int roomId, int elapsedMilliseconds) {
    if (!rooms.containsKey(roomId) || elapsedMilliseconds < 0) return;
    // Interaction sessions may resume after a watch transfer or a foreground
    // route change. Neither resets an account's pacing or restores a budget.
    if (_activation.containsKey(roomId)) return;
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
          scope.permittedEmoticons.length > 5 ||
          scope.permittedEmoticons.any((value) => value.isEmpty) ||
          !scope.permittedEmoticons.contains(data['msg']) ||
          remainingDanmaku(room) < 1 ||
          _lastAccountDanmaku != null &&
              elapsedMilliseconds - _lastAccountDanmaku! < 30000) {
        return false;
      }
      _danmakuRemaining[room] = remainingDanmaku(room) - 1;
      _lastAccountDanmaku = elapsedMilliseconds;
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

// Pure admission/response checks for the explicitly invoked manual harness.
// This file never opens storage, starts playback or makes network requests.

class LiveAudioAcceptanceConfig {
  final int roomId;
  final String hivePath;
  final String mpvPath;
  final String reportPath;
  final String nativeSource;

  const LiveAudioAcceptanceConfig({
    required this.roomId,
    required this.hivePath,
    required this.mpvPath,
    required this.reportPath,
    required this.nativeSource,
  });

  factory LiveAudioAcceptanceConfig.fromEnvironment(Map<String, String> env) {
    if (env['LIVE_AUDIO_ACCOUNT_AUTHORIZED'] != 'true') {
      throw const FormatException('explicit_authorization_required');
    }
    final room = int.tryParse(env['LIVE_AUDIO_ROOM'] ?? '');
    String path(String key) {
      final value = env[key];
      if (value == null ||
          !value.startsWith('/') ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        throw const FormatException('explicit_absolute_path_required');
      }
      return value;
    }

    if (room == null || room <= 0) {
      throw const FormatException('explicit_room_required');
    }
    final source = env['LIVE_AUDIO_NATIVE_SOURCE'] ?? '';
    // A short public build tag, never a path or URL, is sufficient provenance.
    if (!RegExp(r'^[a-zA-Z0-9+_.-]{1,80}$').hasMatch(source)) {
      throw const FormatException('public_native_source_required');
    }
    final hive = path('LIVE_AUDIO_HIVE');
    final report = path('LIVE_AUDIO_REPORT');
    final normalizedHive = Uri.file(hive).normalizePath().path.replaceAll(
      RegExp(r'/+$'),
      '',
    );
    final normalizedReport = Uri.file(report).normalizePath().path;
    if (!report.endsWith('.json') ||
        normalizedReport == normalizedHive ||
        normalizedReport.startsWith('$normalizedHive/')) {
      throw const FormatException('report_must_be_external_json');
    }
    return LiveAudioAcceptanceConfig(
      roomId: room,
      hivePath: hive,
      mpvPath: path('LIVE_AUDIO_MPV'),
      reportPath: report,
      nativeSource: source,
    );
  }
}

/// Whitelisted observations only: never preserve arbitrary subprocess fields.
class LiveAudioNativeSample {
  final Map<String, Object?> safe;
  const LiveAudioNativeSample._(this.safe);

  factory LiveAudioNativeSample.fromJson(Object? data) {
    if (data is! Map) return const LiveAudioNativeSample._({});
    Object? boolean(String key) => data[key] is bool ? data[key] : null;
    Object? number(String key) {
      final value = data[key];
      return value is num && value.isFinite ? value : null;
    }

    return LiveAudioNativeSample._({
      for (final key in [
        'playing',
        'buffering',
        'tracks_decoded',
        'audio_decoded',
        'audio_track_present',
        'video_track_present',
        'muted',
        'silent_output_confirmed',
      ])
        key: boolean(key),
      'position': number('position'),
      'volume': number('volume'),
    });
  }

  bool get valid =>
      safe['playing'] == true &&
      safe['position'] is num &&
      (safe['position'] as num) >= 0 &&
      safe['audio_decoded'] == true &&
      safe['audio_track_present'] == true &&
      safe['video_track_present'] == false &&
      safe['silent_output_confirmed'] == true &&
      safe['muted'] == true &&
      safe['volume'] == 0 &&
      safe['buffering'] == false;
}

class LiveAudioWatchProgress {
  final int thresholdSeconds;
  final int completedRounds;
  final int dailyRounds;
  final bool done;
  const LiveAudioWatchProgress(
    this.thresholdSeconds,
    this.completedRounds,
    this.dailyRounds,
    this.done,
  );

  static LiveAudioWatchProgress? fromTaskData(Map<String, dynamic> data) {
    final tasks = data['task_info'];
    if (tasks is! List) return null;
    final watches = tasks.whereType<Map>().where(
      (task) => task['jump_type'] == 'watchLive',
    );
    if (watches.length != 1) return null;
    final task = watches.single;
    final title = task['title'];
    final subtitle = task['sub_title'];
    if (title is! String || subtitle is! String || task['is_done'] is! bool) {
      return null;
    }
    final threshold = RegExp(r'^观看直播满([1-9]\d*)(秒|分钟|小时)$').firstMatch(title);
    final rounds = RegExp(r'^每日上限\s*(\d+)\s*/\s*([1-9]\d*)$')
        .firstMatch(subtitle);
    if (threshold == null || rounds == null) return null;
    final amount = int.tryParse(threshold[1]!);
    final current = int.tryParse(rounds[1]!);
    final total = int.tryParse(rounds[2]!);
    if (amount == null || current == null || total == null || current > total) {
      return null;
    }
    final multiplier = switch (threshold[2]) {
      '分钟' => 60,
      '小时' => 3600,
      _ => 1,
    };
    return LiveAudioWatchProgress(
      amount * multiplier,
      current,
      total,
      task['is_done'] as bool,
    );
  }

  Map<String, Object> toSafeJson() => {
    'threshold_seconds': thresholdSeconds,
    'completed_rounds': completedRounds,
    'daily_rounds': dailyRounds,
    'done': done,
  };
}

bool liveAudioAcceptanceRequestAllowed(
  Uri uri,
  String method,
  Map<String, dynamic> query,
) {
  if (uri.scheme != 'https' ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    return false;
  }
  if (method == 'POST') {
    return uri.host == 'live-trace.bilibili.com' &&
        const {
          '/xlive/data-interface/v1/x25Kn/E',
          '/xlive/data-interface/v1/x25Kn/X',
        }.contains(uri.path);
  }
  if (method != 'GET') return false;
  if (uri.host == 'api.bilibili.com') {
    return const {'/x/web-interface/nav', '/x/relation'}.contains(uri.path);
  }
  if (uri.host != 'api.live.bilibili.com') return false;
  if (uri.path == '/xlive/web-room/v2/index/getRoomPlayInfo') {
    return query['only_audio'] == 1;
  }
  return const {
    '/room/v1/Room/room_init',
    '/xlive/web-room/v1/index/getInfoByRoom',
    '/xlive/app-ucenter/v1/fansMedal/GetActivatedMedalInfo',
  }.contains(uri.path);
}

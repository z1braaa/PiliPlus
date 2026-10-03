import 'package:flutter_test/flutter_test.dart';

import '../../tool/live_audio_acceptance_gate.dart';

void main() {
  Map<String, String> config() => {
    'LIVE_AUDIO_ACCOUNT_AUTHORIZED': 'true',
    'LIVE_AUDIO_ROOM': '123',
    'LIVE_AUDIO_HIVE': '/private/audio-gate/hive',
    'LIVE_AUDIO_MPV': '/Applications/PiliPlus.app/Mpv',
    'LIVE_AUDIO_REPORT': '/private/audio-gate/report.json',
    'LIVE_AUDIO_NATIVE_SOURCE': '5439-b0e2f7f96',
  };

  test(
    'manual authorization and explicit bounded provenance are mandatory',
    () {
      expect(LiveAudioAcceptanceConfig.fromEnvironment(config()).roomId, 123);
      for (final mutation in [
        {'LIVE_AUDIO_ACCOUNT_AUTHORIZED': 'false'},
        {'LIVE_AUDIO_ROOM': '0'},
        {'LIVE_AUDIO_HIVE': 'relative/hive'},
        {'LIVE_AUDIO_MPV': '/tmp/native\ninvalid'},
        {'LIVE_AUDIO_NATIVE_SOURCE': 'https://private.example/signed'},
        {'LIVE_AUDIO_REPORT': '/private/audio-gate/hive/account.hive'},
        {'LIVE_AUDIO_REPORT': '/private/audio-gate/hive/captured.json'},
        {'LIVE_AUDIO_REPORT': '/private/audio-gate/hive/sub/../captured.json'},
      ]) {
        expect(
          () => LiveAudioAcceptanceConfig.fromEnvironment(
            config()..addAll(mutation),
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('only watch writes and explicitly audio play-info requests are admitted', () {
    bool permitted(
      String url,
      String method, [
      Map<String, dynamic> query = const {},
    ]) => liveAudioAcceptanceRequestAllowed(Uri.parse(url), method, query);
    expect(
      permitted(
        'https://live-trace.bilibili.com/xlive/data-interface/v1/x25Kn/E',
        'POST',
      ),
      isTrue,
    );
    expect(
      permitted(
        'https://live-trace.bilibili.com/xlive/data-interface/v1/x25Kn/X',
        'POST',
      ),
      isTrue,
    );
    const play =
        'https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo';
    expect(permitted(play, 'GET', {'only_audio': 1}), isTrue);
    expect(permitted(play, 'GET'), isFalse);
    for (final url in [
      'https://api.live.bilibili.com/msg/send',
      'https://api.live.bilibili.com/xlive/app-ucenter/v1/like_info_v3/like/likeReportV3',
      'https://api.live.bilibili.com/gift/v2/live/send',
      'https://example.com/xlive/data-interface/v1/x25Kn/E',
      'http://live-trace.bilibili.com/xlive/data-interface/v1/x25Kn/E',
      'https://private@live-trace.bilibili.com/xlive/data-interface/v1/x25Kn/E',
      'https://live-trace.bilibili.com:444/xlive/data-interface/v1/x25Kn/E',
    ]) {
      expect(permitted(url, 'POST'), isFalse);
    }
  });

  test(
    'official rounds are parsed strictly and incomplete fields stay unknown',
    () {
      Map<String, dynamic> data(String title, String subtitle) => {
        'task_info': [
          {
            'jump_type': 'watchLive',
            'title': title,
            'sub_title': subtitle,
            'is_done': false,
          },
        ],
      };
      final parsed = LiveAudioWatchProgress.fromTaskData(
        data('观看直播满15分钟', '每日上限 3/10'),
      )!;
      expect(parsed.thresholdSeconds, 900);
      expect(parsed.completedRounds, 3);
      expect(parsed.dailyRounds, 10);
      expect(
        LiveAudioWatchProgress.fromTaskData(data('观看直播满20秒', '每日上限 0/10'))!
            .thresholdSeconds,
        20,
      );
      expect(
        LiveAudioWatchProgress.fromTaskData(data('观看直播满1小时', '每日上限 0/10'))!
            .thresholdSeconds,
        3600,
      );
      for (final invalid in [
        <String, dynamic>{},
        data('观看直播', '每日上限 0/10'),
        data('观看直播满15分钟', '每日上限 11/10'),
        data('观看直播满15分钟', '每日上限 0/0'),
        {
          'task_info': [
            ...data('观看直播满15分钟', '每日上限 0/10')['task_info'] as List,
            ...data('观看直播满15分钟', '每日上限 0/10')['task_info'] as List,
          ],
        },
      ]) {
        expect(LiveAudioWatchProgress.fromTaskData(invalid), isNull);
      }
    },
  );

  test(
    'native evidence requires audio-only silence and discards private fields',
    () {
      final sample = <String, Object?>{
        'playing': true,
        'buffering': false,
        'tracks_decoded': true,
        'audio_decoded': true,
        'audio_track_present': true,
        'video_track_present': false,
        'muted': true,
        'volume': 0,
        'silent_output_confirmed': true,
        'position': 1.5,
        'live_url': 'https://private.example/signed',
        'cookie': 'private',
        'uid': 123,
      };
      final parsed = LiveAudioNativeSample.fromJson(sample);
      expect(parsed.valid, isTrue);
      expect(parsed.safe.containsKey('live_url'), isFalse);
      expect(parsed.safe.containsKey('cookie'), isFalse);
      expect(parsed.safe.containsKey('uid'), isFalse);
      for (final mutation in [
        {'audio_decoded': false},
        {'video_track_present': true},
        {'muted': false},
        {'volume': 1},
        {'buffering': true},
        {'position': double.nan},
        {'position': null},
        {'position': -1},
      ]) {
        expect(
          LiveAudioNativeSample.fromJson({...sample, ...mutation}).valid,
          isFalse,
        );
      }
    },
  );
}

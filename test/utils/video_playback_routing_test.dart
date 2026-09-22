import 'dart:io';

import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory tempDir;
  const video =
      'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/00/01/video-avc.m4s?sign=video';
  const backup =
      'https://upos-sz-mirrorali.bilivideo.com/upgcxcode/00/01/video-avc.m4s?sign=backup';
  const audio =
      'https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/00/01/audio.m4s?sign=audio';

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('piliplus-routing-test-');
    Hive.init(tempDir.path);
    GStorage.setting = await Hive.openBox<dynamic>('setting');
  });

  setUp(() async {
    await GStorage.setting.clear();
    VideoUtils.cdnService = CDNService.akamai;
    VideoUtils.disableAudioCDN = false;
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test(
    'parallel playback bypasses manual overseas CDN for both streams',
    () async {
      final before = VideoUtils.getPlaybackCdnUrl([video, backup]);
      expect(Uri.parse(before).host, CDNService.akamai.host);

      await GStorage.setting.put(SettingBoxKey.cdnParallelLoading, true);
      expect(VideoUtils.getPlaybackCdnUrl([video, backup]), video);
      expect(VideoUtils.getPlaybackCdnUrl([audio], isAudio: true), audio);

      // Non-playback URL consumers such as downloads and casting retain their
      // existing selection, regardless of the playback transport setting.
      expect(VideoUtils.getCdnUrl([video, backup]), before);

      await GStorage.setting.put(SettingBoxKey.cdnParallelLoading, false);
      expect(VideoUtils.getPlaybackCdnUrl([video, backup]), before);
    },
  );

  test(
    'a fetched source retains signed API URLs across a later toggle',
    () async {
      final source = NetworkSource(
        videoSource: VideoUtils.getPlaybackCdnUrl([video, backup]),
        audioSource: VideoUtils.getPlaybackCdnUrl([audio], isAudio: true),
        originalVideoUrls: [video, backup],
        originalAudioUrls: [audio],
      );
      expect(Uri.parse(source.videoSource).host, CDNService.akamai.host);

      await GStorage.setting.put(SettingBoxKey.cdnParallelLoading, true);
      expect(source.originalVideoSource, video);
      expect(source.originalAudioSource, audio);
      expect(source.originalVideoUrls.skip(1), [backup]);
      expect(source.originalAudioUrls.skip(1), isEmpty);
    },
  );

  test('representation replacement does not mutate an open source pool', () {
    final item = VideoItem.fromJson({
      'id': 80,
      'codecs': 'avc1.640028',
      'base_url': video,
      'backup_url': [backup],
    });
    final source = NetworkSource(
      videoSource: video,
      audioSource: audio,
      originalVideoUrls: item.playUrls,
      originalAudioUrls: [audio],
    );
    item.baseUrl = video.replaceAll('video-avc', 'video-hevc');
    item.backupUrl!.clear();
    expect(source.originalVideoUrls, [video, backup]);
    expect(source.originalAudioUrls, [audio]);
    expect(() => source.originalVideoUrls.add(audio), throwsUnsupportedError);
  });

  test(
    'explicit and live sources retain their direct URL without API candidates',
    () {
      final source = NetworkSource(
        videoSource: 'https://example.com/custom.mp4',
        audioSource: null,
      );
      expect(source.originalVideoSource, source.videoSource);
      expect(source.originalAudioSource, isNull);
      expect(source.originalVideoUrls, isEmpty);
    },
  );
}

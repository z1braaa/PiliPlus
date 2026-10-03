// Optional local-media probe. No accounts, remote URLs or interaction writes.
// Separate header fields keep the WAV fixture offsets legible.
// ignore_for_file: cascade_invocations
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  test('fork native audio player decodes while muted', () async {
    final library = Platform.environment['LIVE_AUDIO_MPV'];
    expect(library, isNotNull);
    MediaKit.ensureInitialized(libmpv: library);
    final directory = await Directory.systemTemp.createTemp('pili-audio-api-');
    Player? player;
    HttpServer? server;
    try {
      const sampleRate = 8000;
      const samples = sampleRate * 6;
      final bytes = ByteData(44 + samples * 2);
      void text(int offset, String value) {
        for (var i = 0; i < value.length; i++) {
          bytes.setUint8(offset + i, value.codeUnitAt(i));
        }
      }

      text(0, 'RIFF');
      bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
      text(8, 'WAVEfmt ');
      bytes.setUint32(16, 16, Endian.little);
      bytes.setUint16(20, 1, Endian.little);
      bytes.setUint16(22, 1, Endian.little);
      bytes.setUint32(24, sampleRate, Endian.little);
      bytes.setUint32(28, sampleRate * 2, Endian.little);
      bytes.setUint16(32, 2, Endian.little);
      bytes.setUint16(34, 16, Endian.little);
      text(36, 'data');
      bytes.setUint32(40, samples * 2, Endian.little);
      final file = File('${directory.path}/silent.wav');
      await file.writeAsBytes(bytes.buffer.asUint8List());
      player = await Player.create(
        configuration: const PlayerConfiguration(
          options: {'vid': 'no', 'volume': '0', 'mute': 'yes', 'ao': 'null'},
        ),
      );
      await player.setVolume(0);
      await player.setVideoTrack(const VideoTrack('no', null, null));
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final headers = Completer<Map<String, String?>>();
      server.listen((request) async {
        if (!headers.isCompleted) {
          headers.complete({
            'user-agent': request.headers.value('user-agent'),
            'referer': request.headers.value('referer'),
          });
        }
        request.response
          ..headers.contentType = ContentType('audio', 'wav')
          ..contentLength = bytes.lengthInBytes
          ..add(await file.readAsBytes());
        await request.response.close();
      });
      const referer = 'https://live.bilibili.com/10';
      if (Platform.environment['LIVE_NATIVE_AUDIO_HEADERS_RAW'] == 'true') {
        player.setProperty(
          'http-header-fields',
          'User-Agent: ${BrowserUa.pc},Referer: $referer',
        );
      } else {
        player.setMediaHeader(userAgent: BrowserUa.pc, referer: referer);
      }
      await player.open(
        Media('http://127.0.0.1:${server.port}/silent.wav'),
        play: false,
      );
      final sent = await headers.future.timeout(const Duration(seconds: 12));
      expect(sent['user-agent'], BrowserUa.pc);
      expect(sent['referer'], referer);
      expect(double.parse(player.getProperty('volume')), 0);
      expect(player.getProperty('mute'), 'yes');
      await player.play();
      await player.stream.position
          .firstWhere(
            (position) => position >= const Duration(seconds: 2),
          )
          .timeout(const Duration(seconds: 12));
      expect(player.state.playing, isTrue);
      expect(double.parse(player.getProperty('volume')), 0);
      expect(player.getProperty('mute'), 'yes');
      expect(player.state.audioParams.sampleRate, greaterThan(0));
      expect(
        player.state.tracks.audio.any(
          (track) => track.id != 'auto' && track.id != 'no',
        ),
        isTrue,
      );
      expect(
        player.state.tracks.video.where(
          (track) => track.id != 'auto' && track.id != 'no',
        ),
        isEmpty,
      );
    } finally {
      await player?.dispose();
      await server?.close(force: true);
      await directory.delete(recursive: true);
    }
  }, skip: !const bool.fromEnvironment('LIVE_NATIVE_AUDIO_API_PROBE'));
}

// Optional local-media probe. No accounts, remote URLs or interaction writes.
// Separate header fields keep the WAV fixture offsets legible.
// ignore_for_file: cascade_invocations
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('fork native audio player decodes while muted', () async {
    final library = Platform.environment['LIVE_AUDIO_MPV'];
    expect(library, isNotNull);
    MediaKit.ensureInitialized(libmpv: library);
    final directory = await Directory.systemTemp.createTemp('pili-audio-api-');
    Player? player;
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
      await player.open(Media(file.path), play: false);
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
      await directory.delete(recursive: true);
    }
  }, skip: !const bool.fromEnvironment('LIVE_NATIVE_AUDIO_API_PROBE'));
}

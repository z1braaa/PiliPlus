import 'package:PiliPlus/models_new/live/live_room_play_info/stream.dart';

typedef LiveSourceIndexes = ({int stream, int format, int codec, int cdn});

/// The unsigned server identity of a chosen source. Only this in-memory choice
/// is retained for startup recovery; signed paths and query strings never enter
/// diagnostics. Reordered response arrays must not switch the user's CDN.
class LiveSourceSelection {
  final String? protocol;
  final String? format;
  final String? codec;
  final int quality;
  final String host;
  const LiveSourceSelection({
    required this.protocol,
    required this.format,
    required this.codec,
    required this.quality,
    required this.host,
  });

  static LiveSourceSelection? capture(
    List<Stream> streams,
    LiveSourceIndexes indexes,
  ) {
    try {
      final s = streams[indexes.stream];
      final f = s.format[indexes.format];
      final c = f.codec[indexes.codec];
      final uri = Uri.tryParse(c.urlInfo[indexes.cdn].host);
      if (uri == null || uri.host.isEmpty) return null;
      return LiveSourceSelection(
        protocol: s.protocolName,
        format: f.formatName,
        codec: c.codecName,
        quality: c.currentQn,
        host: uri.host,
      );
    } catch (_) {
      return null;
    }
  }

  LiveSourceIndexes? find(List<Stream> streams) {
    for (final (si, s) in streams.indexed) {
      if (s.protocolName != protocol) continue;
      for (final (fi, f) in s.format.indexed) {
        if (f.formatName != format) continue;
        for (final (ci, c) in f.codec.indexed) {
          if (c.codecName != codec || c.currentQn != quality) continue;
          for (final (ui, url) in c.urlInfo.indexed) {
            if (Uri.tryParse(url.host)?.host == host) {
              return (stream: si, format: fi, codec: ci, cdn: ui);
            }
          }
        }
      }
    }
    return null;
  }
}

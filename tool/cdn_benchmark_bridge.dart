// Python benchmark bridge. Signed media URLs remain in memory and are never
// emitted; stdout contains only loopback URLs and candidate counts.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Keep this runnable before Flutter package resolution.
// ignore: avoid_relative_lib_imports
import '../lib/http/cdn_origin_policy.dart';
// ignore: avoid_relative_lib_imports
import '../lib/http/cdn_playback_proxy.dart';
// ignore: avoid_relative_lib_imports
import '../lib/utils/cdn_startup_trace.dart';

const _headers = {
  'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.2 Safari/605.1.15',
  'Referer': 'https://www.bilibili.com/',
};

List<String> _urls(Map<String, dynamic> payload, String key) {
  final value = payload[key];
  if (value is! List || value.isEmpty || value.length > 8) {
    throw const FormatException('invalid_track');
  }
  final urls = <String>[];
  for (final url in value) {
    if (url is! String || url.length > 16384) {
      throw const FormatException('invalid_media');
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !CdnOriginPolicy.isMedia(uri)) {
      throw const FormatException('unsupported_media');
    }
    if (!urls.contains(url)) urls.add(url);
  }
  return urls;
}

int _integer(Map<String, dynamic> data, String key, int fallback) {
  final value = data[key];
  if (value == null) return fallback;
  if (value is! int) throw const FormatException('invalid_limit');
  return value;
}

Map<String, int> _counts(List<String> urls) {
  final originals = <Uri>[];
  for (final value in urls) {
    final uri = Uri.parse(value);
    if ((originals.isEmpty || uri.path == originals.first.path) &&
        !originals.contains(uri)) {
      originals.add(uri);
    }
    if (originals.length == 4) break;
  }
  final candidates = CdnOriginPolicy.resolve(originals).take(40).toList();
  final mainland = candidates.where((origin) => origin.mainland).length;
  return {'total': candidates.length, 'mainland': mainland};
}

Future<void> main() async {
  final input = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  CdnPlaybackProxy? proxy;
  try {
    if (!await input.moveNext()) {
      throw const FormatException('missing_input');
    }
    if (input.current.length > 262144) {
      throw const FormatException('oversized_input');
    }
    final decoded = jsonDecode(input.current);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('invalid_input');
    }
    final video = _urls(decoded, 'video_urls');
    final audio = _urls(decoded, 'audio_urls');
    proxy = await CdnPlaybackProxy.start(
      concurrency: _integer(decoded, 'concurrency', 8),
      chunkSize: _integer(decoded, 'chunk_kib', 1024) * 1024,
      timeout: Duration(
        seconds: _integer(decoded, 'request_timeout_seconds', 10),
      ),
    );
    final videoUrl = proxy.register(
      video.first,
      alternatives: video.skip(1),
      headers: _headers,
      track: CdnStartupTrack.video,
    );
    final audioUrl = proxy.register(
      audio.first,
      alternatives: audio.skip(1),
      headers: _headers,
      track: CdnStartupTrack.audio,
    );
    bool local(String value) {
      final uri = Uri.parse(value);
      return uri.scheme == 'http' && uri.host == '127.0.0.1';
    }

    if (!local(videoUrl) || !local(audioUrl)) {
      throw StateError('proxy_bypassed');
    }
    final videoCounts = _counts(video);
    final audioCounts = _counts(audio);
    stdout.writeln(
      jsonEncode({
        'status': 'ready',
        'video_url': videoUrl,
        'audio_url': audioUrl,
        'candidate_count': videoCounts['total']! + audioCounts['total']!,
        'candidate_counts': {'video': videoCounts, 'audio': audioCounts},
      }),
    );
    await stdout.flush();
    // Each playback trial owns a fresh bridge and proxy. Closing the parent's
    // pipe or sending stop cancels both foreground and speculative transfers.
    while (await input.moveNext()) {
      if (input.current.trim() == 'stop') break;
    }
  } catch (error) {
    // Exception text/stack traces can contain a signed URL. Emit only its type.
    stderr.writeln(
      jsonEncode({'status': 'failed', 'kind': '${error.runtimeType}'}),
    );
    exitCode = 1;
  } finally {
    await proxy?.close();
    await input.cancel();
  }
}

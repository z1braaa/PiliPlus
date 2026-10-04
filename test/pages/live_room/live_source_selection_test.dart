import 'package:PiliPlus/models_new/live/live_room_play_info/codec.dart';
import 'package:PiliPlus/models_new/live/live_room_play_info/format.dart';
import 'package:PiliPlus/models_new/live/live_room_play_info/stream.dart';
import 'package:PiliPlus/models_new/live/live_room_play_info/url_info.dart';
import 'package:PiliPlus/pages/live_room/live_source_selection.dart';
import 'package:flutter_test/flutter_test.dart';

List<Stream> source({
  List<String> hosts = const ['a.test', 'b.test'],
  int qn = 10000,
  String codec = 'avc',
  String format = 'flv',
}) => [
  Stream(
    protocolName: 'http_stream',
    format: [
      Format(
        formatName: format,
        codec: [
          CodecItem(
            codecName: codec,
            currentQn: qn,
            acceptQn: [qn],
            baseUrl: '/stream/signed-path',
            urlInfo: hosts
                .map(
                  (host) => UrlInfo(
                    host: 'https://$host/',
                    extra: '?signed=private-memory',
                  ),
                )
                .toList(),
          ),
        ],
      ),
    ],
  ),
];

void main() {
  test(
    'response reorder preserves selected source rather than numeric CDN index',
    () {
      final chosen = LiveSourceSelection.capture(source(), (
        stream: 0,
        format: 0,
        codec: 0,
        cdn: 1,
      ));
      expect(chosen?.host, 'b.test');
      expect(chosen?.find(source(hosts: ['b.test', 'a.test']))?.cdn, 0);
      expect(chosen?.quality, 10000);
    },
  );
  test('automatic recovery cannot silently change quality, protocol format or codec', () {
    final chosen = LiveSourceSelection.capture(source(), (
      stream: 0,
      format: 0,
      codec: 0,
      cdn: 1,
    ));
    expect(chosen?.find(source(qn: 80)), isNull);
    expect(chosen?.find(source(codec: 'hevc')), isNull);
    expect(chosen?.find(source(format: 'fmp4')), isNull);
    expect(chosen?.find(source(hosts: ['a.test'])), isNull);
  });
  test('missing current selection stays unknown instead of capturing another source', () {
    expect(
      LiveSourceSelection.capture(source(), (
        stream: 2,
        format: 0,
        codec: 0,
        cdn: 1,
      )),
      isNull,
    );
  });
}

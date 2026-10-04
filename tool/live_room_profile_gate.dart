import 'live_discovery_schema_gate.dart';

class LiveRoomProfileConfig {
  final List<int> rooms;
  final String hivePath;
  final String reportPath;
  const LiveRoomProfileConfig(this.rooms, this.hivePath, this.reportPath);

  factory LiveRoomProfileConfig.fromEnvironment(Map<String, String> env) {
    if (env['LIVE_ROOM_PROFILE_AUTHORIZED'] != 'true') {
      throw const FormatException('explicit_authorization_required');
    }
    final rooms = (env['LIVE_ROOM_PROFILE_ROOMS'] ?? '')
        .split(',')
        .map((value) => int.tryParse(value.trim()))
        .toList();
    if (rooms.isEmpty ||
        rooms.length > 6 ||
        rooms.any((room) => room == null || room <= 0) ||
        rooms.toSet().length != rooms.length) {
      throw const FormatException(
        'one_to_six_distinct_explicit_rooms_required',
      );
    }
    final parsed = LiveDiscoverySchemaConfig.fromEnvironment({
      'LIVE_DISCOVERY_SCHEMA_AUTHORIZED': 'true',
      'LIVE_DISCOVERY_SCHEMA_ROOM': rooms.first.toString(),
      'LIVE_DISCOVERY_SCHEMA_HIVE': env['LIVE_ROOM_PROFILE_HIVE'] ?? '',
      'LIVE_DISCOVERY_SCHEMA_REPORT': env['LIVE_ROOM_PROFILE_REPORT'] ?? '',
    });
    return LiveRoomProfileConfig(
      rooms.cast<int>(),
      parsed.hivePath,
      parsed.reportPath,
    );
  }
}

class LiveRoomProfileRequestGate {
  LiveRoomProfileRequestGate(Iterable<int> rooms) : _rooms = rooms.toSet();
  final Set<int> _rooms;
  final Set<int> _anchors = {};
  final Map<int, int> _roomAnchors = {};
  int acceptedReads = 0;
  int blockedRequests = 0;

  void registerRoom({
    required int requested,
    required int canonical,
    required int anchor,
  }) {
    if (!_rooms.contains(requested) || canonical <= 0 || anchor <= 0) {
      throw const FormatException('unconfirmed_room_identity');
    }
    _rooms.add(canonical);
    _anchors.add(anchor);
    _roomAnchors[canonical] = anchor;
  }

  bool allows(Uri uri, String method, Map<String, dynamic> query) {
    int? number(Object? value) => value is int
        ? value
        : value is String
        ? int.tryParse(value)
        : null;
    var allowed = false;
    if (method == 'GET' &&
        uri.scheme == 'https' &&
        uri.port == 443 &&
        uri.userInfo.isEmpty &&
        uri.fragment.isEmpty &&
        acceptedReads < 300) {
      if (uri.host == 'api.bilibili.com') {
        allowed =
            uri.path == '/x/web-interface/nav' ||
            uri.path == '/x/relation' &&
                _anchors.contains(number(query['fid']));
      } else if (uri.host == 'api.live.bilibili.com') {
        final room = number(query['room_id']);
        allowed = switch (uri.path) {
          '/xlive/web-room/v1/index/getInfoByRoom' => _rooms.contains(room),
          '/xlive/web-ucenter/user/following' =>
            number(query['page']) != null &&
                number(query['page'])! > 0 &&
                number(query['page'])! <= 100 &&
                number(query['page_size']) == 9 &&
                query['ignoreRecord'] == 1 &&
                query['hit_ab'] == true,
          '/xlive/app-ucenter/v1/fansMedal/GetActivatedMedalInfo' =>
            _rooms.contains(room) &&
                _roomAnchors[room] == number(query['target_id']),
          '/xlive/app-ucenter/v1/fansMedal/panel' =>
            _rooms.contains(room) &&
                _roomAnchors[room] == number(query['target_id']) &&
                number(query['page']) != null &&
                number(query['page'])! > 0 &&
                number(query['page'])! <= 100 &&
                number(query['page_size']) == 10 &&
                !query.containsKey('light_status') &&
                !query.containsKey('next_light_status'),
          '/xlive/web-ucenter/v2/emoticon/GetEmoticons' => _rooms.contains(
            room,
          ),
          _ => false,
        };
      }
    }
    if (allowed) {
      acceptedReads++;
    } else {
      blockedRequests++;
    }
    return allowed;
  }
}

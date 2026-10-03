// Pure shape/redaction helpers for the explicitly authorized read-only probe.
class LiveDiscoverySchemaConfig {
  final int roomId;
  final String hivePath;
  final String reportPath;
  const LiveDiscoverySchemaConfig(this.roomId, this.hivePath, this.reportPath);

  factory LiveDiscoverySchemaConfig.fromEnvironment(Map<String, String> env) {
    if (env['LIVE_DISCOVERY_SCHEMA_AUTHORIZED'] != 'true') {
      throw const FormatException('explicit_authorization_required');
    }
    String path(String name) {
      final value = env[name];
      if (value == null ||
          !value.startsWith('/') ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        throw const FormatException('explicit_absolute_path_required');
      }
      return value;
    }

    final room = int.tryParse(env['LIVE_DISCOVERY_SCHEMA_ROOM'] ?? '');
    if (room == null || room <= 0) {
      throw const FormatException('explicit_room_required');
    }
    final hive = path('LIVE_DISCOVERY_SCHEMA_HIVE');
    final report = path('LIVE_DISCOVERY_SCHEMA_REPORT');
    final hivePath = Uri.file(hive)
        .normalizePath()
        .path
        .replaceAll(RegExp(r'/+$'), '');
    final reportPath = Uri.file(report).normalizePath().path;
    if (!report.endsWith('.json') ||
        reportPath == hivePath ||
        reportPath.startsWith('$hivePath/')) {
      throw const FormatException('report_must_be_external_json');
    }
    return LiveDiscoverySchemaConfig(room, hive, report);
  }
}

bool liveDiscoverySchemaRequestAllowed(
  Uri uri,
  String method,
  Map<String, dynamic> query,
) {
  if (method != 'GET' ||
      uri.scheme != 'https' ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    return false;
  }
  if (uri.host == 'api.bilibili.com') return uri.path == '/x/web-interface/nav';
  if (uri.host != 'api.live.bilibili.com') return false;
  if (uri.path == '/xlive/web-room/v2/index/getRoomPlayInfo') {
    return query['only_audio'] == 1;
  }
  final expectedSize = switch (uri.path) {
    '/xlive/web-ucenter/user/following' => 9,
    '/xlive/app-ucenter/v1/fansMedal/panel' => 10,
    _ => null,
  };
  return expectedSize != null &&
      query['page_size'] == expectedSize &&
      const [1, 2].contains(query['page']);
}

Map<String, dynamic> _map(Object? value) => value is Map
    ? {
        for (final entry in value.entries)
          if (entry.key is String) entry.key as String: entry.value,
      }
    : {};

String _type(Object? value) => switch (value) {
  null => 'null',
  bool() => 'bool',
  int() => 'int',
  num() => 'num',
  String() => 'string',
  List() => 'list',
  Map() => 'map',
  _ => 'other',
};

Map<String, Object> _fieldTypes(Map<String, dynamic> data) => {
  for (final entry in data.entries)
    if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,79}$').hasMatch(entry.key))
      entry.key: _type(entry.value),
};

Map<String, Object> _listShape(List<dynamic> list) {
  final fields = <String, Set<String>>{};
  final nested = <String, Map<String, Set<String>>>{};
  for (final raw in list) {
    for (final entry in _map(raw).entries) {
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,79}$').hasMatch(entry.key)) {
        continue;
      }
      (fields[entry.key] ??= {}).add(_type(entry.value));
      if (entry.value is Map) {
        final target = nested[entry.key] ??= {};
        for (final child in _map(entry.value).entries) {
          if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,79}$').hasMatch(child.key)) {
            (target[child.key] ??= {}).add(_type(child.value));
          }
        }
      }
    }
  }
  return {
    'count': list.length,
    'item_types': (list.map(_type).toSet().toList()..sort()),
    'item_fields': {
      for (final entry in fields.entries)
        entry.key: entry.value.toList()..sort(),
    },
    'nested_item_fields': {
      for (final entry in nested.entries)
        entry.key: {
          for (final child in entry.value.entries)
            child.key: child.value.toList()..sort(),
        },
    },
    'public_state_distributions': {
      for (final key in ['is_attention', 'live_status'])
        key: _stateDistribution(list, key),
    },
  };
}

Map<String, int> _stateDistribution(List<dynamic> list, String key) {
  final counts = <String, int>{};
  for (final raw in list) {
    final entry = _map(raw);
    final value = entry[key];
    final category = !entry.containsKey(key)
        ? 'missing'
        : value is bool
        ? value.toString()
        : value is int && const [0, 1, 2].contains(value)
        ? value.toString()
        : value is int
        ? 'other_int'
        : 'other_type';
    counts.update(category, (count) => count + 1, ifAbsent: () => 1);
  }
  return counts;
}

Set<String> _identities(Object? value) {
  if (value is! List) return {};
  final identities = <String>{};
  for (final entry in value) {
    final raw = _map(entry);
    final medal = _map(raw['medal'] ?? raw['medal_info'] ?? raw);
    final id =
        medal['target_id'] ??
        medal['target_uid'] ??
        raw['uid'] ??
        raw['mid'] ??
        raw['roomid'] ??
        medal['medal_id'];
    if (id is int && id > 0 ||
        id is String && RegExp(r'^[1-9]\d*$').hasMatch(id)) {
      identities.add(id.toString());
    }
  }
  return identities;
}

/// Counts compare identity values only in memory, never expose or hash them.
Map<String, Object> liveDiscoveryDuplicateSummary(
  Map<String, dynamic> first,
  Map<String, dynamic> second,
) {
  final list1 = _identities(first['list']);
  final list2 = _identities(second['list']);
  final special1 = _identities(first['special_list']);
  final special2 = _identities(second['special_list']);
  return {
    'list_cross_page_duplicate_count': list1.intersection(list2).length,
    'special_cross_page_duplicate_count': special1
        .intersection(special2)
        .length,
    'special_page1_overlaps_regular_count': special1.intersection({
      ...list1,
      ...list2,
    }).length,
    'special_page2_overlaps_regular_count': special2.intersection({
      ...list1,
      ...list2,
    }).length,
    'regular_unique_identity_count': {...list1, ...list2}.length,
    'special_unique_identity_count': {...special1, ...special2}.length,
  };
}

Map<String, Object?> liveDiscoveryPageSummary(Map<String, dynamic> response) {
  final data = _map(response['data']);
  const paginationKeys = {
    'page',
    'page_size',
    'pageSize',
    'totalPage',
    'total_page',
    'total_pages',
    'count',
    'live_count',
    'total',
    'total_count',
    'has_more',
    'total_number',
    'number',
    'current_page',
    'next_page',
    'next_light_status',
  };
  Map<String, Object?> pagination(Map<String, dynamic> map) => {
    for (final key in paginationKeys)
      if (map[key] is int || map[key] is bool) key: map[key],
  };
  return {
    'code': response['code'] is int ? response['code'] : null,
    'response_fields': _fieldTypes(response),
    'data_fields': _fieldTypes(data),
    'pagination': pagination(data),
    'nested_pagination': {
      for (final key in ['page_info', 'pageinfo', 'pagination'])
        if (data[key] is Map)
          key: {
            'fields': _fieldTypes(_map(data[key])),
            'values': pagination(_map(data[key])),
          },
    },
    'lists': {
      for (final entry in data.entries)
        if (entry.value is List &&
            RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,79}$').hasMatch(entry.key))
          entry.key: _listShape(entry.value as List),
    },
  };
}

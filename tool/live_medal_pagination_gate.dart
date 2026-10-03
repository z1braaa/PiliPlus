// Pure safety, cursor and redaction helpers for the separate panel-only probe.
import 'live_discovery_schema_gate.dart';

class LiveMedalPaginationConfig {
  final int roomId;
  final String hivePath;
  final String reportPath;
  const LiveMedalPaginationConfig(this.roomId, this.hivePath, this.reportPath);

  factory LiveMedalPaginationConfig.fromEnvironment(Map<String, String> env) {
    final config = LiveDiscoverySchemaConfig.fromEnvironment({
      'LIVE_DISCOVERY_SCHEMA_AUTHORIZED':
          env['LIVE_MEDAL_PAGINATION_AUTHORIZED'] ?? '',
      'LIVE_DISCOVERY_SCHEMA_ROOM': env['LIVE_MEDAL_PAGINATION_ROOM'] ?? '',
      'LIVE_DISCOVERY_SCHEMA_HIVE': env['LIVE_MEDAL_PAGINATION_HIVE'] ?? '',
      'LIVE_DISCOVERY_SCHEMA_REPORT': env['LIVE_MEDAL_PAGINATION_REPORT'] ?? '',
    });
    return LiveMedalPaginationConfig(
      config.roomId,
      config.hivePath,
      config.reportPath,
    );
  }
}

bool liveMedalPaginationRequestAllowed(
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
  final page = query['page'];
  return uri.path == '/xlive/app-ucenter/v1/fansMedal/panel' &&
      page is int &&
      page >= 1 &&
      page <= 30 &&
      query['page_size'] == 10 &&
      !query.containsKey('light_status') &&
      !query.containsKey('next_light_status');
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};

/// Keeps account identities in memory only. The public result contains counts.
/// Nonzero lighting cursors deliberately stop before any exploratory request.
class LiveMedalPaginationCursor {
  static const maxPages = 30;
  int? nextPage = 1;
  String? stopReason;
  bool complete = false;
  final _visited = <int>{};
  final _identities = <String>{};
  final pages = <Map<String, Object?>>[];
  int regularItemCount = 0;
  int specialItemCount = 0;

  void accept(int requestedPage, Map<String, dynamic> response) {
    if (stopReason != null || nextPage != requestedPage) {
      throw StateError('cursor_not_current');
    }
    _visited.add(requestedPage);
    final data = _map(response['data']);
    pages.add({
      'requested_page': requestedPage,
      'requested_page_size': 10,
      ...liveDiscoveryPageSummary(response),
    });
    for (final name in ['list', 'special_list']) {
      final list = data[name];
      if (list is! List) continue;
      if (name == 'list') {
        regularItemCount += list.length;
      } else {
        specialItemCount += list.length;
      }
      for (final raw in list) {
        final entry = _map(raw);
        final medal = _map(entry['medal'] ?? entry['medal_info'] ?? entry);
        for (final key in ['medal_id', 'target_id', 'target_uid']) {
          final id = medal[key];
          if (id is int && id > 0 ||
              id is String && RegExp(r'^[1-9]\d*$').hasMatch(id)) {
            _identities.add('$key:$id');
            break;
          }
        }
      }
    }
    void stop(String reason) {
      stopReason = reason;
      nextPage = null;
    }

    if (response['code'] != 0) {
      stop('service_rejected');
      return;
    }
    if (data['list'] is! List || data['special_list'] is! List) {
      stop('unconfirmed_medal_list_shape');
      return;
    }
    final pageInfo = _map(data['page_info']);
    final hasMore = pageInfo['has_more'];
    if (hasMore == false) {
      complete = true;
      stop('official_has_more_false');
      return;
    }
    if (hasMore != true) {
      stop('unconfirmed_has_more_shape');
      return;
    }
    final light = pageInfo['next_light_status'];
    if (light is! int || light != 0) {
      stop(
        light is int
            ? 'unverified_light_status_boundary'
            : 'unconfirmed_light_status_shape',
      );
      return;
    }
    final next = pageInfo['next_page'];
    if (next is! int || next <= 0 || _visited.contains(next)) {
      stop('unconfirmed_or_repeated_next_page');
      return;
    }
    if (_visited.length >= maxPages || next > maxPages) {
      stop('page_limit');
      return;
    }
    nextPage = next;
  }

  Map<String, Object?> get summary => {
    'pagination_complete': complete,
    'stop_reason': stopReason,
    'requested_page_count': pages.length,
    'regular_item_count': regularItemCount,
    'special_item_count': specialItemCount,
    'unique_medal_identity_count': _identities.length,
    'pages': pages,
  };
}

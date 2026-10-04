import 'package:PiliPlus/models_new/live/interactions/live_interaction.dart';
import 'package:PiliPlus/models_new/live/interactions/live_interaction_parser.dart';

typedef LiveMedalRead = Future<Map<String, dynamic>> Function(
  String path,
  Map<String, dynamic> query,
);

class LiveMedalReadException implements Exception {
  final String message;
  const LiveMedalReadException(this.message);
}

class LiveMedalInventory {
  final List<LiveMedal> medals;
  final Map<int, Map<String, dynamic>> entriesByAnchor;
  final bool complete;
  const LiveMedalInventory({
    required this.medals,
    required this.entriesByAnchor,
    required this.complete,
  });
}

/// Reads the complete personal medal inventory. Activation and wearing are
/// independent states, so GetActivatedMedalInfo.level == 0 cannot prove that
/// the account does not own a medal. Explicit official cursors determine the
/// end of this read; a short page and informational total_page do not.
Future<List<LiveMedal>> readLiveMedals({
  required LiveMedalRead read,
  required int roomId,
  required int anchorUid,
}) async {
  final inventory = await readLiveMedalInventory(
    read: read,
    roomId: roomId,
    anchorUid: anchorUid,
  );
  if (!inventory.complete) {
    throw const LiveMedalReadException('勋章列表分页不完整，稍后重新核对');
  }
  return inventory.medals;
}

/// An observed valid target is positive ownership evidence independently of
/// other inventory entries. Absence requires a complete terminal inventory.
Future<LiveMedal?> readLiveMedalForAnchor({
  required LiveMedalRead read,
  required int roomId,
  required int anchorUid,
}) async {
  final inventory = await _readLiveMedalInventory(
    read: read,
    roomId: roomId,
    anchorUid: anchorUid,
    stopAtAnchor: anchorUid,
  );
  final target = inventory.medals
      .where((medal) => medal.targetUid == anchorUid)
      .firstOrNull;
  if (target != null) return target;
  if (!inventory.complete) {
    throw const LiveMedalReadException('勋章列表分页不完整，稍后重新核对');
  }
  return null;
}

/// Only a trustworthy terminal cursor with fewer unique medals than declared
/// may produce a partial positive snapshot. All protocol and identity errors
/// still throw. Partial snapshots never prove an unobserved medal absent.
Future<LiveMedalInventory> readLiveMedalInventory({
  required LiveMedalRead read,
  required int roomId,
  required int anchorUid,
}) => _readLiveMedalInventory(
  read: read,
  roomId: roomId,
  anchorUid: anchorUid,
);

Future<LiveMedalInventory> _readLiveMedalInventory({
  required LiveMedalRead read,
  required int roomId,
  required int anchorUid,
  int? stopAtAnchor,
}) async {
  final medals = <int, LiveMedal>{};
  final entries = <int, Map<String, dynamic>>{};
  final cursors = <String>{};
  int? expected;
  var page = 1;
  var lightStatus = 0;
  for (var request = 0; request < 500; request++) {
    if (!cursors.add('$page:$lightStatus')) {
      throw const LiveMedalReadException('勋章列表返回重复分页');
    }
    final response = await read('/xlive/app-ucenter/v1/fansMedal/panel', {
      'page': page,
      'page_size': 10,
      'room_id': roomId,
      'target_id': anchorUid,
    });
    if (liveInt(response['code']) != 0 || response['data'] is! Map) {
      throw const LiveMedalReadException('粉丝勋章暂时无法核对');
    }
    final data = liveMap(response['data']);
    final total = liveInt(data['total_number']);
    if (total == null || total < 0 || expected != null && total != expected) {
      throw const LiveMedalReadException('勋章列表总数缺失或正在变化');
    }
    expected = total;
    if (data['list'] is! List || data['special_list'] is! List) {
      throw const LiveMedalReadException('勋章列表数据尚未确认');
    }
    final pageMedals = LiveInteractionParser.medals(data);
    final rawCount =
        (data['list'] as List).length + (data['special_list'] as List).length;
    if (pageMedals.length != rawCount) {
      throw const LiveMedalReadException('勋章列表缺少可靠勋章身份');
    }
    final rawEntries = [
      ...liveMaps(data['list']),
      ...liveMaps(data['special_list']),
    ];
    for (var index = 0; index < pageMedals.length; index++) {
      final medal = pageMedals[index];
      if (medal.medalId <= 0 || medal.targetUid <= 0 || medal.level <= 0) {
        throw const LiveMedalReadException('勋章列表缺少可靠主播身份');
      }
      final prior = medals[medal.medalId];
      if (prior != null && prior.targetUid != medal.targetUid) {
        throw const LiveMedalReadException('勋章身份与主播对应关系不一致');
      }
      medals[medal.medalId] = medal;
      entries[medal.targetUid] = rawEntries[index];
    }
    final info = liveMap(data['page_info']);
    final more = liveBool(info['has_more']);
    if (more == null) {
      throw const LiveMedalReadException('勋章列表分页规则尚未确认');
    }
    if (medals.length > expected) {
      throw const LiveMedalReadException('勋章列表总数与身份数量不一致');
    }
    final next = liveInt(info['next_page']);
    final nextLight = liveInt(info['next_light_status']);
    if (more) {
      if (next == null || next <= 0 || nextLight == null || nextLight < 0) {
        throw const LiveMedalReadException('勋章列表分页游标尚未确认');
      }
      if (nextLight != 0) {
        // Preserve the verified request contract, including target lookups.
        throw const LiveMedalReadException('勋章列表光照分段分页规则待确认');
      }
    }
    LiveMedalInventory snapshot() => LiveMedalInventory(
      medals: List.unmodifiable(medals.values),
      entriesByAnchor: Map.unmodifiable(entries),
      complete: !more && medals.length == expected,
    );
    if (stopAtAnchor != null && entries.containsKey(stopAtAnchor)) {
      return snapshot();
    }
    if (!more) {
      return snapshot();
    }
    page = next!;
    lightStatus = nextLight!;
  }
  throw const LiveMedalReadException('勋章列表分页超出核对范围');
}

import 'package:PiliPlus/utils/live_viewer_preferences.dart';
import 'package:flutter/foundation.dart' show listEquals;

enum LiveIntimacySort { medalHighToLow, medalLowToHigh }

class LiveIntimacyEmoticonSelection {
  const LiveIntimacyEmoticonSelection({
    required this.unique,
    required this.label,
  });

  final String unique;
  final String label;

  Map<String, Object> toJson() => {'unique': unique, 'label': label};

  static LiveIntimacyEmoticonSelection? fromJson(Object? value) {
    if (value is! Map || value['unique'] is! String) return null;
    final unique = (value['unique'] as String).trim();
    if (unique.isEmpty) return null;
    return LiveIntimacyEmoticonSelection(
      unique: unique,
      label: value['label'] is String ? (value['label'] as String).trim() : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LiveIntimacyEmoticonSelection &&
      unique == other.unique &&
      label == other.label;
  @override
  int get hashCode => Object.hash(unique, label);
}

/// Identity and selected content are persisted; availability is always reread.
class LiveIntimacyRoomPreferences {
  const LiveIntimacyRoomPreferences({
    required this.anchorUid,
    required this.roomId,
    this.anchorName = '',
    this.authorized = false,
    this.automation = const LiveTaskAutomationPreferences(),
    this.emoticons = const [],
  });

  final int anchorUid;
  final int roomId;
  final String anchorName;
  final bool authorized;
  final LiveTaskAutomationPreferences automation;
  final List<LiveIntimacyEmoticonSelection> emoticons;
  String get key => '$anchorUid:$roomId';

  static LiveIntimacyRoomPreferences? fromJson(Object? value) {
    if (value is! Map) return null;
    final anchor = value['anchorUid'];
    final room = value['roomId'];
    if (anchor is! int || anchor <= 0 || room is! int || room <= 0) {
      return null;
    }
    final selections = <LiveIntimacyEmoticonSelection>[];
    final seen = <String>{};
    final raw = value['emoticons'];
    if (raw is List) {
      for (final entry in raw) {
        final selection = LiveIntimacyEmoticonSelection.fromJson(entry);
        if (selection != null && seen.add(selection.unique)) {
          selections.add(selection);
        }
      }
    }
    // A malformed oversized import cannot silently authorize a shortened pool.
    final oversized = selections.length > 5;
    return LiveIntimacyRoomPreferences(
      anchorUid: anchor,
      roomId: room,
      anchorName: value['anchorName'] is String
          ? (value['anchorName'] as String).trim()
          : '',
      authorized:
          !oversized &&
          value['authorized'] is bool &&
          value['authorized'] == true,
      automation: LiveTaskAutomationPreferences.fromJson(value['automation']),
      emoticons: List.unmodifiable(selections.take(5)),
    );
  }

  String? configurationIssue({Iterable<String>? availableEmoticons}) {
    if (anchorUid <= 0 || roomId <= 0) return '等待官方主播和真实房间信息';
    if (!automation.autoLike) return '请先开启自动点赞';
    if (!automation.autoDanmaku) return '请先开启自动弹幕';
    if (automation.danmakuMode == LiveTaskDanmakuMode.text) {
      return automation.defaultMessage.trim().isEmpty ? '请先设置自动发送文字' : null;
    }
    if (emoticons.isEmpty || emoticons.length > 5) return '请选择1～5个自动发送表情';
    if (emoticons.any((e) => e.unique.trim().isEmpty) ||
        emoticons.map((e) => e.unique).toSet().length != emoticons.length) {
      return '表情选择无效，请重新选择';
    }
    if (availableEmoticons != null &&
        !emoticons.any((e) => availableEmoticons.contains(e.unique))) {
      return '已选表情均不可发送，自动任务暂停';
    }
    return null;
  }

  LiveIntimacyRoomPreferences copyWith({
    int? anchorUid,
    int? roomId,
    String? anchorName,
    bool? authorized,
    LiveTaskAutomationPreferences? automation,
    List<LiveIntimacyEmoticonSelection>? emoticons,
  }) => LiveIntimacyRoomPreferences(
    anchorUid: anchorUid ?? this.anchorUid,
    roomId: roomId ?? this.roomId,
    anchorName: anchorName ?? this.anchorName,
    authorized: authorized ?? this.authorized,
    automation: automation ?? this.automation,
    emoticons: emoticons ?? this.emoticons,
  );

  Map<String, Object> toJson() => {
    'anchorUid': anchorUid,
    'roomId': roomId,
    'anchorName': anchorName,
    'authorized': authorized,
    'automation': automation.toJson(),
    'emoticons': emoticons.map((e) => e.toJson()).toList(),
  };

  @override
  bool operator ==(Object other) =>
      other is LiveIntimacyRoomPreferences &&
      anchorUid == other.anchorUid &&
      roomId == other.roomId &&
      anchorName == other.anchorName &&
      authorized == other.authorized &&
      automation == other.automation &&
      listEquals(emoticons, other.emoticons);
  @override
  int get hashCode => Object.hash(
    anchorUid,
    roomId,
    anchorName,
    authorized,
    automation,
    Object.hashAll(emoticons),
  );
}

/// A new, account-scoped authorization domain. Legacy task settings are not read.
class LiveIntimacyPreferences {
  const LiveIntimacyPreferences({
    this.enabled = false,
    this.sort = LiveIntimacySort.medalHighToLow,
    this.rooms = const [],
  });

  final bool enabled;
  final LiveIntimacySort sort;
  final List<LiveIntimacyRoomPreferences> rooms;

  factory LiveIntimacyPreferences.fromJson(Object? value) {
    if (value is! Map) return const LiveIntimacyPreferences();
    final rooms = <LiveIntimacyRoomPreferences>[];
    final seen = <String>{};
    final raw = value['rooms'];
    if (raw is List) {
      for (final entry in raw) {
        final room = LiveIntimacyRoomPreferences.fromJson(entry);
        if (room != null && seen.add(room.key)) rooms.add(room);
      }
    }
    return LiveIntimacyPreferences(
      enabled: value['enabled'] is bool && value['enabled'] == true,
      sort: value['sort'] == LiveIntimacySort.medalLowToHigh.name
          ? LiveIntimacySort.medalLowToHigh
          : LiveIntimacySort.medalHighToLow,
      rooms: List.unmodifiable(rooms),
    );
  }

  LiveIntimacyRoomPreferences? roomFor(int roomId, int anchorUid) {
    for (final room in rooms) {
      if (room.roomId == roomId && room.anchorUid == anchorUid) return room;
    }
    return null;
  }

  LiveIntimacyPreferences copyWith({
    bool? enabled,
    LiveIntimacySort? sort,
    List<LiveIntimacyRoomPreferences>? rooms,
  }) => LiveIntimacyPreferences(
    enabled: enabled ?? this.enabled,
    sort: sort ?? this.sort,
    rooms: rooms ?? this.rooms,
  );

  Map<String, Object> toJson() => {
    'version': 1,
    'enabled': enabled,
    'sort': sort.name,
    'rooms': rooms.map((e) => e.toJson()).toList(),
  };

  @override
  bool operator ==(Object other) =>
      other is LiveIntimacyPreferences &&
      enabled == other.enabled &&
      sort == other.sort &&
      listEquals(rooms, other.rooms);
  @override
  int get hashCode => Object.hash(enabled, sort, Object.hashAll(rooms));
}

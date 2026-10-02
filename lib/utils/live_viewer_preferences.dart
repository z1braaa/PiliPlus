/// The experimental live viewer is independent from all playback preferences.
/// Only an explicitly stored boolean true enables it, including after restore.
bool decodeLiveRoomEnhancement(Object? value) => value is bool && value;

/// Reserve a readable sidebar only when the player still has useful space.
bool useLiveEnhancementSidebar({
  required double width,
  required bool isFullScreen,
}) => !isFullScreen && width >= 900;

/// These are account preferences, not a saved task or an action queue.
enum LiveTaskDanmakuMode { text, emoticon }

class LiveTaskAutomationPreferences {
  const LiveTaskAutomationPreferences({
    this.autoLike = false,
    this.autoDanmaku = false,
    this.defaultMessage = '',
    this.danmakuMode = LiveTaskDanmakuMode.text,
    this.defaultEmoticonUnique = '',
    this.defaultEmoticonName = '',
    this.defaultEmoticonRoomId = 0,
    this.defaultEmoticonAnchorUid = 0,
    this.minIntervalSeconds = 30,
    this.maxIntervalSeconds = 60,
  });

  static const minimumIntervalSeconds = 10;
  static const maximumIntervalSeconds = 3600;

  final bool autoLike;
  final bool autoDanmaku;
  final String defaultMessage;
  final LiveTaskDanmakuMode danmakuMode;
  final String defaultEmoticonUnique;
  final String defaultEmoticonName;
  final int defaultEmoticonRoomId;
  final int defaultEmoticonAnchorUid;
  final int minIntervalSeconds;
  final int maxIntervalSeconds;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LiveTaskAutomationPreferences &&
          autoLike == other.autoLike &&
          autoDanmaku == other.autoDanmaku &&
          defaultMessage == other.defaultMessage &&
          danmakuMode == other.danmakuMode &&
          defaultEmoticonUnique == other.defaultEmoticonUnique &&
          defaultEmoticonName == other.defaultEmoticonName &&
          defaultEmoticonRoomId == other.defaultEmoticonRoomId &&
          defaultEmoticonAnchorUid == other.defaultEmoticonAnchorUid &&
          minIntervalSeconds == other.minIntervalSeconds &&
          maxIntervalSeconds == other.maxIntervalSeconds;

  @override
  int get hashCode => Object.hash(
    autoLike,
    autoDanmaku,
    defaultMessage,
    danmakuMode,
    defaultEmoticonUnique,
    defaultEmoticonName,
    defaultEmoticonRoomId,
    defaultEmoticonAnchorUid,
    minIntervalSeconds,
    maxIntervalSeconds,
  );

  factory LiveTaskAutomationPreferences.fromJson(Object? value) {
    if (value is! Map) return const LiveTaskAutomationPreferences();
    final minimum = value['minIntervalSeconds'];
    final maximum = value['maxIntervalSeconds'];
    final validInterval =
        minimum is int &&
        maximum is int &&
        minimum >= minimumIntervalSeconds &&
        maximum <= maximumIntervalSeconds &&
        minimum <= maximum;
    return LiveTaskAutomationPreferences(
      autoLike: value['autoLike'] is bool && value['autoLike'] == true,
      autoDanmaku: value['autoDanmaku'] is bool && value['autoDanmaku'] == true,
      defaultMessage: value['defaultMessage'] is String
          ? (value['defaultMessage'] as String).trim()
          : '',
      danmakuMode: value['danmakuMode'] == LiveTaskDanmakuMode.emoticon.name
          ? LiveTaskDanmakuMode.emoticon
          : LiveTaskDanmakuMode.text,
      defaultEmoticonUnique: value['defaultEmoticonUnique'] is String
          ? (value['defaultEmoticonUnique'] as String).trim()
          : '',
      defaultEmoticonName: value['defaultEmoticonName'] is String
          ? (value['defaultEmoticonName'] as String).trim()
          : '',
      defaultEmoticonRoomId:
          value['defaultEmoticonRoomId'] is int &&
              (value['defaultEmoticonRoomId'] as int) > 0
          ? value['defaultEmoticonRoomId'] as int
          : 0,
      defaultEmoticonAnchorUid:
          value['defaultEmoticonAnchorUid'] is int &&
              (value['defaultEmoticonAnchorUid'] as int) > 0
          ? value['defaultEmoticonAnchorUid'] as int
          : 0,
      minIntervalSeconds: validInterval ? minimum : 30,
      maxIntervalSeconds: validInterval ? maximum : 60,
    );
  }

  LiveTaskAutomationPreferences copyWith({
    bool? autoLike,
    bool? autoDanmaku,
    String? defaultMessage,
    LiveTaskDanmakuMode? danmakuMode,
    String? defaultEmoticonUnique,
    String? defaultEmoticonName,
    int? defaultEmoticonRoomId,
    int? defaultEmoticonAnchorUid,
    int? minIntervalSeconds,
    int? maxIntervalSeconds,
  }) => LiveTaskAutomationPreferences(
    autoLike: autoLike ?? this.autoLike,
    autoDanmaku: autoDanmaku ?? this.autoDanmaku,
    defaultMessage: defaultMessage ?? this.defaultMessage,
    danmakuMode: danmakuMode ?? this.danmakuMode,
    defaultEmoticonUnique: defaultEmoticonUnique ?? this.defaultEmoticonUnique,
    defaultEmoticonName: defaultEmoticonName ?? this.defaultEmoticonName,
    defaultEmoticonRoomId: defaultEmoticonRoomId ?? this.defaultEmoticonRoomId,
    defaultEmoticonAnchorUid:
        defaultEmoticonAnchorUid ?? this.defaultEmoticonAnchorUid,
    minIntervalSeconds: minIntervalSeconds ?? this.minIntervalSeconds,
    maxIntervalSeconds: maxIntervalSeconds ?? this.maxIntervalSeconds,
  );

  Map<String, Object> toJson() => {
    'autoLike': autoLike,
    'autoDanmaku': autoDanmaku,
    'defaultMessage': defaultMessage,
    'danmakuMode': danmakuMode.name,
    'defaultEmoticonUnique': defaultEmoticonUnique,
    'defaultEmoticonName': defaultEmoticonName,
    'defaultEmoticonRoomId': defaultEmoticonRoomId,
    'defaultEmoticonAnchorUid': defaultEmoticonAnchorUid,
    'minIntervalSeconds': minIntervalSeconds,
    'maxIntervalSeconds': maxIntervalSeconds,
  };
}

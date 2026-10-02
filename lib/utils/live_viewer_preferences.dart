/// The experimental live viewer is independent from all playback preferences.
/// Only an explicitly stored boolean true enables it, including after restore.
bool decodeLiveRoomEnhancement(Object? value) => value is bool && value;

/// Reserve a readable sidebar only when the player still has useful space.
bool useLiveEnhancementSidebar({
  required double width,
  required bool isFullScreen,
}) => !isFullScreen && width >= 900;

/// These are account preferences, not a saved task or an action queue.
class LiveTaskAutomationPreferences {
  const LiveTaskAutomationPreferences({
    this.autoLike = false,
    this.autoDanmaku = false,
    this.defaultMessage = '',
    this.minIntervalSeconds = 30,
    this.maxIntervalSeconds = 60,
  });

  static const minimumIntervalSeconds = 10;
  static const maximumIntervalSeconds = 3600;

  final bool autoLike;
  final bool autoDanmaku;
  final String defaultMessage;
  final int minIntervalSeconds;
  final int maxIntervalSeconds;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LiveTaskAutomationPreferences &&
          autoLike == other.autoLike &&
          autoDanmaku == other.autoDanmaku &&
          defaultMessage == other.defaultMessage &&
          minIntervalSeconds == other.minIntervalSeconds &&
          maxIntervalSeconds == other.maxIntervalSeconds;

  @override
  int get hashCode => Object.hash(
    autoLike,
    autoDanmaku,
    defaultMessage,
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
      minIntervalSeconds: validInterval ? minimum : 30,
      maxIntervalSeconds: validInterval ? maximum : 60,
    );
  }

  LiveTaskAutomationPreferences copyWith({
    bool? autoLike,
    bool? autoDanmaku,
    String? defaultMessage,
    int? minIntervalSeconds,
    int? maxIntervalSeconds,
  }) => LiveTaskAutomationPreferences(
    autoLike: autoLike ?? this.autoLike,
    autoDanmaku: autoDanmaku ?? this.autoDanmaku,
    defaultMessage: defaultMessage ?? this.defaultMessage,
    minIntervalSeconds: minIntervalSeconds ?? this.minIntervalSeconds,
    maxIntervalSeconds: maxIntervalSeconds ?? this.maxIntervalSeconds,
  );

  Map<String, Object> toJson() => {
    'autoLike': autoLike,
    'autoDanmaku': autoDanmaku,
    'defaultMessage': defaultMessage,
    'minIntervalSeconds': minIntervalSeconds,
    'maxIntervalSeconds': maxIntervalSeconds,
  };
}

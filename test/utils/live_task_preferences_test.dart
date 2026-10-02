import 'package:PiliPlus/utils/live_viewer_preferences.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

class _Settings extends Fake implements Box<dynamic> {
  final stored = <dynamic, dynamic>{};
  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      stored[key] ?? defaultValue;
  @override
  Future<void> put(dynamic key, dynamic value) async => stored[key] = value;
}

void main() {
  final settings = _Settings();
  setUpAll(() => GStorage.setting = settings);
  setUp(settings.stored.clear);

  test(
    'new and malformed settings default to off without invented content',
    () {
      for (final value in [null, true, 'true', <String, Object>{}]) {
        final preferences = LiveTaskAutomationPreferences.fromJson(value);
        expect(preferences.autoLike, isFalse);
        expect(preferences.autoDanmaku, isFalse);
        expect(preferences.defaultMessage, isEmpty);
        expect(preferences.danmakuMode, LiveTaskDanmakuMode.text);
        expect(preferences.defaultEmoticonUnique, isEmpty);
        expect(preferences.defaultEmoticonRoomId, 0);
        expect(preferences.defaultEmoticonAnchorUid, 0);
        expect(preferences.minIntervalSeconds, 30);
        expect(preferences.maxIntervalSeconds, 60);
      }
      final restored = LiveTaskAutomationPreferences.fromJson({
        'autoLike': 'true',
        'autoDanmaku': 1,
        'defaultMessage': 3,
        'minIntervalSeconds': 60,
        'maxIntervalSeconds': 30,
        'pending': true,
      });
      expect(restored.autoLike, isFalse);
      expect(restored.autoDanmaku, isFalse);
      expect(restored.defaultMessage, isEmpty);
      expect(restored.minIntervalSeconds, 30);
      expect(restored.maxIntervalSeconds, 60);
      expect(restored.toJson(), isNot(contains('pending')));
    },
  );

  test('legacy text preferences keep their mode and saved text', () {
    final preferences = LiveTaskAutomationPreferences.fromJson({
      'autoDanmaku': true,
      'defaultMessage': '晚上好',
    });
    expect(preferences.danmakuMode, LiveTaskDanmakuMode.text);
    expect(preferences.defaultMessage, '晚上好');
    expect(preferences.autoDanmaku, isTrue);
    final malformed = LiveTaskAutomationPreferences.fromJson({
      'danmakuMode': 'anything',
      'defaultEmoticonUnique': 1,
      'defaultEmoticonName': false,
      'defaultEmoticonRoomId': '6',
      'defaultEmoticonAnchorUid': -10,
    });
    expect(malformed.danmakuMode, LiveTaskDanmakuMode.text);
    expect(malformed.defaultEmoticonUnique, isEmpty);
    expect(malformed.defaultEmoticonName, isEmpty);
    expect(malformed.defaultEmoticonRoomId, 0);
    expect(malformed.defaultEmoticonAnchorUid, 0);
  });

  test(
    'emoticon selection retains its room scope without saved permission',
    () {
      const selected = LiveTaskAutomationPreferences(
        danmakuMode: LiveTaskDanmakuMode.emoticon,
        defaultMessage: '保存的文字',
        defaultEmoticonUnique: 'room_6_1',
        defaultEmoticonName: '赞',
        defaultEmoticonRoomId: 6,
        defaultEmoticonAnchorUid: 10,
      );
      final restored = LiveTaskAutomationPreferences.fromJson({
        ...selected.toJson(),
        'available': true,
      });
      expect(restored, selected);
      expect(restored.hashCode, selected.hashCode);
      expect(restored.toJson(), isNot(contains('available')));
      expect(
        restored.copyWith(danmakuMode: LiveTaskDanmakuMode.text),
        isNot(restored),
      );
      expect(restored.copyWith(defaultEmoticonAnchorUid: 11), isNot(restored));
      expect(restored.copyWith(defaultEmoticonRoomId: 7), isNot(restored));
    },
  );

  test('interval imports reject invalid bounds and keep valid choices', () {
    for (final range in [(5, 60), (30, 3601), (60, 30)]) {
      final restored = LiveTaskAutomationPreferences.fromJson({
        'minIntervalSeconds': range.$1,
        'maxIntervalSeconds': range.$2,
      });
      expect(restored.minIntervalSeconds, 30);
      expect(restored.maxIntervalSeconds, 60);
    }
    final restored = LiveTaskAutomationPreferences.fromJson({
      'autoLike': true,
      'autoDanmaku': false,
      'defaultMessage': '  晚上好  ',
      'minIntervalSeconds': 45,
      'maxIntervalSeconds': 90,
    });
    expect(restored.autoLike, isTrue);
    expect(restored.autoDanmaku, isFalse);
    expect(restored.defaultMessage, '晚上好');
    expect(restored.minIntervalSeconds, 45);
    expect(restored.maxIntervalSeconds, 90);
  });

  test(
    'preferences remain account-scoped and guest writes do not persist',
    () async {
      const first = LiveTaskAutomationPreferences(
        autoLike: true,
        autoDanmaku: true,
        defaultMessage: '晚上好',
        danmakuMode: LiveTaskDanmakuMode.emoticon,
        defaultEmoticonUnique: 'room_6_1',
        defaultEmoticonName: '赞',
        defaultEmoticonRoomId: 6,
        defaultEmoticonAnchorUid: 10,
      );
      const second = LiveTaskAutomationPreferences(
        autoDanmaku: true,
        defaultMessage: '大家好',
        minIntervalSeconds: 45,
        maxIntervalSeconds: 75,
      );
      await Pref.saveLiveTaskAutomationFor(11, first);
      await Pref.saveLiveTaskAutomationFor(22, second);
      await Pref.saveLiveTaskAutomationFor(0, first);
      await Pref.saveLiveTaskAutomationFor(-1, first);
      expect(Pref.liveTaskAutomationFor(11).toJson(), first.toJson());
      expect(Pref.liveTaskAutomationFor(22).toJson(), second.toJson());
      expect(Pref.liveTaskAutomationFor(33).autoLike, isFalse);
      expect(Pref.liveTaskAutomationFor(0).autoDanmaku, isFalse);
      expect(settings.stored.length, 2);
      expect(
        settings.stored.keys,
        unorderedEquals([
          Pref.liveTaskAutomationStorageKey(11),
          Pref.liveTaskAutomationStorageKey(22),
        ]),
      );
      settings.stored.clear();
      expect(Pref.liveTaskAutomationFor(11).autoLike, isFalse);
    },
  );
}

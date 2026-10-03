import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:PiliPlus/utils/live_viewer_preferences.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

class _Settings extends Fake implements Box<dynamic> {
  final stored = <dynamic, dynamic>{};
  var flushes = 0;
  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      stored[key] ?? defaultValue;
  @override
  Future<void> put(dynamic key, dynamic value) async => stored[key] = value;
  @override
  Future<void> flush() async => flushes++;
}

void main() {
  final settings = _Settings();
  setUpAll(() => GStorage.setting = settings);
  setUp(() {
    settings.stored.clear();
    settings.flushes = 0;
  });

  const configured = LiveIntimacyRoomPreferences(
    anchorUid: 10,
    roomId: 6,
    automation: LiveTaskAutomationPreferences(
      autoLike: true,
      autoDanmaku: true,
      defaultMessage: '晚上好',
    ),
  );

  test('new domain remains off and never migrates old authorization', () async {
    for (final raw in [
      null,
      true,
      'true',
      {'enabled': 'true'},
      {'enabled': 1},
    ]) {
      final preferences = LiveIntimacyPreferences.fromJson(raw);
      expect(preferences.enabled, isFalse);
      expect(preferences.rooms, isEmpty);
    }
    await Pref.saveLiveTaskAutomationFor(11, configured.automation);
    expect(Pref.liveIntimacyPreferencesFor(11).enabled, isFalse);
    expect(Pref.liveIntimacyPreferencesFor(11).rooms, isEmpty);
    expect(configured.authorized, isFalse);
  });

  test(
    'account scoped content, sorting and explicit authorization roundtrip',
    () async {
      final room = configured.copyWith(
        authorized: true,
        emoticons: const [
          LiveIntimacyEmoticonSelection(unique: 'one', label: '一'),
        ],
      );
      final first = LiveIntimacyPreferences(enabled: true, rooms: [room]);
      final second = LiveIntimacyPreferences(
        sort: LiveIntimacySort.medalLowToHigh,
        rooms: [
          configured.copyWith(
            automation: configured.automation.copyWith(defaultMessage: '另一房间'),
          ),
        ],
      );
      await Pref.saveLiveIntimacyPreferencesFor(11, first);
      await Pref.saveLiveIntimacyPreferencesFor(22, second);
      await Pref.saveLiveIntimacyPreferencesFor(0, first);
      expect(Pref.liveIntimacyPreferencesFor(11), first);
      expect(Pref.liveIntimacyPreferencesFor(22), second);
      expect(Pref.liveIntimacyPreferencesFor(0).rooms, isEmpty);
      expect(settings.stored.length, 2);
      expect(settings.flushes, 2);
      expect(first.roomFor(6, 10), room);
      expect(first.roomFor(6, 11), isNull);
      expect(first.roomFor(7, 10), isNull);
      expect(room.toJson(), isNot(contains('available')));
    },
  );

  test('current mode checks content and keeps inactive mode independent', () {
    final room = configured.copyWith(
      emoticons: const [
        LiveIntimacyEmoticonSelection(unique: 'one', label: '一'),
      ],
    );
    expect(room.configurationIssue(availableEmoticons: []), isNull);
    expect(
      room
          .copyWith(
            automation: room.automation.copyWith(
              danmakuMode: LiveTaskDanmakuMode.emoticon,
            ),
          )
          .configurationIssue(availableEmoticons: []),
      contains('均不可'),
    );
    expect(
      room
          .copyWith(
            automation: room.automation.copyWith(
              autoLike: false,
            ),
          )
          .configurationIssue(),
      contains('点赞'),
    );
    expect(
      room
          .copyWith(
            automation: room.automation.copyWith(
              autoDanmaku: false,
            ),
          )
          .configurationIssue(),
      contains('弹幕'),
    );
    expect(
      room
          .copyWith(
            automation: room.automation.copyWith(
              defaultMessage: '',
            ),
          )
          .configurationIssue(),
      contains('文字'),
    );
    final emotes = room.copyWith(
      automation: room.automation.copyWith(
        danmakuMode: LiveTaskDanmakuMode.emoticon,
      ),
    );
    expect(emotes.configurationIssue(availableEmoticons: ['one']), isNull);
    expect(
      emotes.copyWith(emoticons: []).configurationIssue(),
      contains('1～5'),
    );
  });

  test('invalid identities and duplicate rooms do not invent permissions', () {
    final preferences = LiveIntimacyPreferences.fromJson({
      'rooms': [
        configured.toJson(),
        configured.copyWith(authorized: true).toJson(),
        {'anchorUid': '10', 'roomId': 6, 'authorized': true},
        {'anchorUid': 10, 'roomId': -1, 'authorized': true},
      ],
    });
    expect(preferences.rooms.length, 1);
    expect(preferences.rooms.single.authorized, isFalse);
  });

  test(
    'pool deduplication and oversized restore cannot broaden authorization',
    () {
      final raw = configured.copyWith(authorized: true).toJson();
      raw['emoticons'] = [
        {'unique': 'one', 'label': '一'},
        {'unique': 'one', 'label': '重复'},
        {'unique': '', 'label': '无效'},
      ];
      final deduped = LiveIntimacyRoomPreferences.fromJson(raw)!;
      expect(deduped.emoticons.length, 1);
      expect(deduped.authorized, isTrue);
      raw['emoticons'] = List.generate(
        6,
        (i) => {'unique': 'e$i', 'label': '$i'},
      );
      final oversized = LiveIntimacyRoomPreferences.fromJson(raw)!;
      expect(oversized.emoticons.length, 5);
      expect(oversized.authorized, isFalse);
    },
  );
}

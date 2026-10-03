import 'package:PiliPlus/services/live_intimacy_audio_session.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:PiliPlus/utils/live_viewer_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

LiveIntimacyRoomPreferences pool(int count) => LiveIntimacyRoomPreferences(
  roomId: 100,
  anchorUid: 10,
  automation: const LiveTaskAutomationPreferences(
    autoLike: true,
    autoDanmaku: true,
    danmakuMode: LiveTaskDanmakuMode.emoticon,
  ),
  emoticons: [
    for (var i = 0; i < count; i++)
      LiveIntimacyEmoticonSelection(unique: 'selected-$i', label: 'choice-$i'),
  ],
);
LiveTaskEmoticonOption option(String id, {bool available = true}) =>
    LiveTaskEmoticonOption(unique: id, label: id, available: available);

void main() {
  test('five saved candidates are independently selectable and remain bound to this room', () {
    final preferences = pool(5);
    final available = [
      for (var i = 0; i < 5; i++) option('selected-$i'),
      option('outside-pool'),
    ];
    for (var i = 0; i < 5; i++) {
      final message = chooseLiveIntimacyEmoticon(
        preferences: preferences,
        options: available,
        randomInt: (upper) {
          expect(upper, 5);
          return i;
        },
      );
      expect(message.emoticonUnique, 'selected-$i');
      expect(message.roomId, 100);
      expect(message.anchorUid, 10);
    }
  });

  test(
    'repeated draws and one-item pools send the same allowed single expression',
    () {
      final preferences = pool(1);
      for (var i = 0; i < 3; i++) {
        expect(
          chooseLiveIntimacyEmoticon(
            preferences: preferences,
            options: [option('selected-0')],
            randomInt: (upper) {
              expect(upper, 1);
              return 0;
            },
          ).emoticonUnique,
          'selected-0',
        );
      }
    },
  );

  test(
    'invalid candidates are excluded but never deleted from saved choices',
    () {
      final preferences = pool(3);
      final message = chooseLiveIntimacyEmoticon(
        preferences: preferences,
        options: [
          option('selected-0', available: false),
          option('selected-2'),
          option('outside'),
        ],
        randomInt: (upper) {
          expect(upper, 1);
          return 0;
        },
      );
      expect(message.emoticonUnique, 'selected-2');
      expect(preferences.emoticons, hasLength(3));
    },
  );

  test('empty, oversized and wholly invalid pools pause without fallback or pool-outside choice', () {
    for (final preferences in [pool(0), pool(6), pool(1)]) {
      expect(
        () => chooseLiveIntimacyEmoticon(
          preferences: preferences,
          options: [option('outside')],
          randomInt: (_) => 0,
        ),
        throwsA(isA<LiveInteractionException>()),
      );
    }
  });
}

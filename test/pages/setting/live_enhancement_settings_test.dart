import 'dart:async';

import 'package:PiliPlus/pages/setting/models/video_settings.dart';
import 'package:PiliPlus/pages/live_room/widgets/interaction_focus_boundary.dart';
import 'package:PiliPlus/utils/live_viewer_preferences.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';

class _SettingsBox extends Fake implements Box<dynamic> {
  final _values = <dynamic, dynamic>{};
  final changes = StreamController<BoxEvent>.broadcast();
  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      _values[key] ?? defaultValue;
  @override
  Future<void> put(dynamic key, dynamic value) async {
    _values[key] = value;
    changes.add(BoxEvent(key, value, false));
  }

  @override
  Future<int> clear() async {
    final count = _values.length;
    final keys = _values.keys.toList();
    _values.clear();
    for (final key in keys) {
      changes.add(BoxEvent(key, null, true));
    }
    return count;
  }

  @override
  Stream<BoxEvent> watch({dynamic key}) =>
      changes.stream.where((e) => e.key == key);
  @override
  Future<void> close() => changes.close();
}

void main() {
  late _SettingsBox box;
  setUpAll(() {
    box = _SettingsBox();
    GStorage.setting = box;
  });
  setUp(() => box.clear());
  tearDownAll(() => box.close());

  test(
    'missing and malformed restored values are off; only boolean true opts in',
    () async {
      expect(Pref.liveRoomEnhancement, isFalse);
      for (final value in [
        null,
        false,
        1,
        0,
        'true',
        'false',
        <int>[],
        <String, int>{},
      ]) {
        await box.put(SettingBoxKey.liveRoomEnhancement, value);
        expect(Pref.liveRoomEnhancement, isFalse, reason: '$value');
        expect(decodeLiveRoomEnhancement(value), isFalse);
      }
      await box.put(SettingBoxKey.liveRoomEnhancement, true);
      expect(Pref.liveRoomEnhancement, isTrue);
      await box.clear();
      expect(Pref.liveRoomEnhancement, isFalse);
    },
  );

  testWidgets(
    'the real setting restores safely and preserves every CDN field over 20 toggles',
    (tester) async {
      final cdn = {
        SettingBoxKey.cdnParallelLoading: true,
        SettingBoxKey.cdnParallelConnections: 8,
        SettingBoxKey.cdnParallelChunkSizeKiB: 1024,
        SettingBoxKey.liveCdnUrl: 'existing-live-cdn.example',
        SettingBoxKey.liveQuality: 10000,
        SettingBoxKey.CDNService: 'huawei',
      };
      for (final entry in cdn.entries) {
        await box.put(entry.key, entry.value);
      }
      await box.put(SettingBoxKey.liveRoomEnhancement, 'true');
      Widget widget() => MaterialApp(
        home: Scaffold(
          body: videoSettings
              .singleWhere((e) => e.title == '直播界面增强（实验性）')
              .widget,
        ),
      );
      await tester.pumpWidget(widget());
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      for (var index = 0; index < 20; index++) {
        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        expect(Pref.liveRoomEnhancement, index.isEven);
        for (final entry in cdn.entries) {
          expect(box.get(entry.key), entry.value);
        }
      }
      await box.put(SettingBoxKey.liveRoomEnhancement, true);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(widget());
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      await box.clear();
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    },
  );

  test(
    'narrow and fullscreen viewers use the panel entry instead of a sidebar',
    () {
      expect(
        useLiveEnhancementSidebar(width: 899, isFullScreen: false),
        isFalse,
      );
      expect(
        useLiveEnhancementSidebar(width: 900, isFullScreen: false),
        isTrue,
      );
      expect(
        useLiveEnhancementSidebar(width: 1600, isFullScreen: true),
        isFalse,
      );
    },
  );

  testWidgets('interaction input leaves player keyboard handlers untouched', (
    tester,
  ) async {
    var playerEvents = 0;
    final text = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            onKeyEvent: (_, _) {
              playerEvents++;
              return KeyEventResult.handled;
            },
            child: LiveInteractionFocusBoundary(
              child: TextField(controller: text),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '礼物数量');
    for (final key in [
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.keyF,
      LogicalKeyboardKey.keyR,
      LogicalKeyboardKey.enter,
    ]) {
      await tester.sendKeyEvent(key);
    }
    expect(playerEvents, 0);
    expect(text.text, contains('礼物数量'));
    await tester.pumpWidget(const SizedBox.shrink());
    text.dispose();
  });
}

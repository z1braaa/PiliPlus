import 'dart:async';

import 'package:PiliPlus/pages/setting/models/video_settings.dart';
import 'package:PiliPlus/pages/setting/widgets/select_dialog.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';

/// Exercise the real preferences and settings widgets without filesystem I/O
/// inside Flutter's fake asynchronous clock.
class _SettingsBox extends Fake implements Box<dynamic> {
  final _values = <dynamic, dynamic>{};
  final _changes = StreamController<BoxEvent>.broadcast();

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      _values.containsKey(key) ? _values[key] : defaultValue;

  @override
  Future<void> put(dynamic key, dynamic value) async {
    _values[key] = value;
    _changes.add(BoxEvent(key, value, false));
  }

  @override
  Future<void> putAll(Map<dynamic, dynamic> entries) async {
    for (final entry in entries.entries) {
      await put(entry.key, entry.value);
    }
  }

  @override
  Stream<BoxEvent> watch({dynamic key}) =>
      _changes.stream.where((event) => key == null || event.key == key);

  @override
  Future<int> clear() async {
    final length = _values.length;
    _values.clear();
    return length;
  }

  @override
  Future<void> close() => _changes.close();
}

Widget _settings(List<String> titles) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: Column(
        children: [
          for (final model in videoSettings)
            if (titles.contains(model.title)) model.widget,
        ],
      ),
    ),
  ),
);

void main() {
  setUpAll(() => GStorage.setting = _SettingsBox());

  setUp(() => GStorage.setting.clear());

  tearDownAll(() => GStorage.setting.close());

  test(
    'parallel settings default and defend against imported invalid data',
    () async {
      expect(Pref.cdnParallelConnections, 8);
      expect(Pref.cdnParallelChunkSizeKiB, 1024);
      for (final value in [-10, 0, 1, 8, 32, 33, 100]) {
        await GStorage.setting.put(SettingBoxKey.cdnParallelConnections, value);
        expect(Pref.cdnParallelConnections, value.clamp(1, 32));
      }
      for (final value in [-1, 63, 64, 513, 4096, 4097]) {
        await GStorage.setting.put(
          SettingBoxKey.cdnParallelChunkSizeKiB,
          value,
        );
        expect(Pref.cdnParallelChunkSizeKiB, value.clamp(64, 4096));
      }
      for (final value in [
        '16',
        3.5,
        false,
        <int>[1],
      ]) {
        await GStorage.setting.putAll({
          SettingBoxKey.cdnParallelConnections: value,
          SettingBoxKey.cdnParallelChunkSizeKiB: value,
        });
        expect(Pref.cdnParallelConnections, 8);
        expect(Pref.cdnParallelChunkSizeKiB, 1024);
      }
    },
  );

  testWidgets(
    'manual CDN options immediately disable and retain saved values',
    (
      tester,
    ) async {
      await GStorage.setting.putAll({
        SettingBoxKey.cdnSpeedTest: true,
        SettingBoxKey.disableAudioCDN: true,
        SettingBoxKey.enableSystemProxy: true,
      });
      await tester.pumpWidget(
        _settings([
          'CDN 设置',
          '自动选择 CDN（实验性）',
          'CDN 测速',
          '音频不跟随 CDN 设置',
        ]),
      );
      expect(
        tester.widgetList<Switch>(find.byType(Switch)).map((v) => v.value),
        [
          false,
          true,
          true,
        ],
      );
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(Pref.cdnAutoSelect, isTrue);
      expect(
        tester
            .widgetList<Switch>(find.byType(Switch))
            .skip(1)
            .every((v) => v.onChanged == null),
        isTrue,
      );
      expect(find.textContaining('此项已停用'), findsNWidgets(3));
      await tester.tap(find.text('CDN 设置'));
      await tester.pumpAndSettle();
      expect(find.byType(CdnSelectDialog), findsNothing);
      expect(GStorage.setting.get(SettingBoxKey.cdnSpeedTest), isTrue);
      expect(GStorage.setting.get(SettingBoxKey.disableAudioCDN), isTrue);

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(Pref.cdnAutoSelect, isFalse);
      expect(find.textContaining('此项已停用'), findsNothing);
      expect(
        tester.widgetList<Switch>(find.byType(Switch)).map((v) => v.value),
        [
          false,
          true,
          true,
        ],
      );
    },
  );

  testWidgets(
    'already open CDN dialog loses choices when parallel loading starts',
    (
      tester,
    ) async {
      await GStorage.setting.put(SettingBoxKey.cdnSpeedTest, false);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CdnSelectDialog())),
      );
      expect(find.text('CDN 设置'), findsOneWidget);
      await GStorage.setting.put(SettingBoxKey.cdnAutoSelect, true);
      await tester.pumpAndSettle();
      expect(find.text('CDN 设置已停用'), findsOneWidget);
      expect(find.text('CDN 设置'), findsNothing);
    },
  );

  testWidgets(
    'automatic source selection and parallel download toggle independently',
    (tester) async {
      await tester.pumpWidget(
        _settings([
          '自动选择 CDN（实验性）',
          '并发 CDN 加载（实验性）',
          'CDN 设置',
        ]),
      );
      await tester.tap(find.text('自动选择 CDN（实验性）'));
      await tester.pumpAndSettle();
      expect(Pref.cdnAutoSelect, isTrue);
      expect(Pref.cdnParallelLoading, isFalse);
      await tester.tap(find.text('并发 CDN 加载（实验性）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自动选择 CDN（实验性）'));
      await tester.pumpAndSettle();
      expect(Pref.cdnAutoSelect, isFalse);
      expect(Pref.cdnParallelLoading, isTrue);
      expect(find.textContaining('此项已停用'), findsNothing);
    },
  );

  for (final (title, key, min, max) in [
    ('并发路数', SettingBoxKey.cdnParallelConnections, 1, 32),
    ('分块大小', SettingBoxKey.cdnParallelChunkSizeKiB, 64, 4096),
  ]) {
    testWidgets(
      '$title validates custom integer limits and saves both endpoints',
      (
        tester,
      ) async {
        await tester.pumpWidget(_settings([title]));
        for (final endpoint in [min, max]) {
          await tester.tap(find.text(title));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.textContaining('自定义（'));
          await tester.tap(find.textContaining('自定义（'));
          await tester.pumpAndSettle();
          for (final input in ['', '1.5', '${min - 1}', '${max + 1}']) {
            await tester.enterText(find.byType(TextFormField), input);
            await tester.tap(find.text('保存'));
            await tester.pumpAndSettle();
            expect(find.text('请输入 $min–$max 之间的整数'), findsOneWidget);
            expect(find.byType(TextFormField), findsOneWidget);
          }
          await tester.enterText(find.byType(TextFormField), '$endpoint');
          await tester.tap(find.text('保存'));
          await tester.pumpAndSettle();
          expect(GStorage.setting.get(key), endpoint);
          expect(find.byType(TextFormField), findsNothing);
          expect(find.textContaining('手动模式：$endpoint '), findsOneWidget);
        }
      },
    );
  }
}

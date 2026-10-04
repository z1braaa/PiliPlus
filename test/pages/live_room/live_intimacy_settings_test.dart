import 'package:PiliPlus/pages/setting/pages/live_intimacy.dart';
import 'package:PiliPlus/services/live_intimacy_discovery.dart';
import 'package:PiliPlus/services/live_intimacy_scheduler.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/live_intimacy_statistics_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';

class _Discovery extends Fake implements LiveIntimacyDiscoverySource {
  int reads = 0;
  @override
  void cancel() {}
  @override
  Future<List<LiveIntimacyCandidate>> discover(
    List<LiveIntimacyRoomPreferences> rooms,
  ) async {
    ++reads;
    return const [];
  }
}

class _LocalCache extends Fake implements Box<dynamic> {
  final stored = <dynamic, dynamic>{};
  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      stored[key] ?? defaultValue;
  @override
  Future<void> put(dynamic key, dynamic value) async => stored[key] = value;
}

void main() {
  setUpAll(() => GStorage.localCache = _LocalCache());
  late LiveIntimacyPreferences stored;
  late LiveIntimacyScheduler scheduler;
  late _Discovery discovery;
  late LiveIntimacyStatisticsPreferences display;
  var loggedIn = true;
  var sessionStarts = 0;
  setUp(() {
    final shown = <int, bool>{};
    display = LiveIntimacyStatisticsPreferences(
      read: (uid) => shown[uid] ?? false,
      write: (uid, enabled) async {
        shown[uid] = enabled;
      },
    );
    stored = const LiveIntimacyPreferences(
      rooms: [
        LiveIntimacyRoomPreferences(
          anchorUid: 10,
          roomId: 6,
          anchorName: '示例主播',
        ),
      ],
    );
    loggedIn = true;
    sessionStarts = 0;
    discovery = _Discovery();
    final identity = Object();
    scheduler = LiveIntimacyScheduler.testing(
      account: () => LiveIntimacyAccount(
        uid: loggedIn ? 11 : 0,
        identity: identity,
        generation: 0,
        loggedIn: loggedIn,
      ),
      readPreferences: (_) => stored,
      writePreferences: (_, value) async => stored = value,
      discovery: discovery,
      createSession: (_, _, _, _) {
        ++sessionStarts;
        throw StateError('No authorized rooms');
      },
      loadEmoticons: (_) async => [],
      automaticTimers: false,
    )..start();
  });
  tearDown(() {
    scheduler.dispose();
    display.dispose();
  });

  testWidgets(
    'settings master and sorting preserve explicit room authorization in a small window',
    (tester) async {
      tester.view.physicalSize = const Size(360, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: LiveIntimacySettingsPage(
            scheduler: scheduler,
            display: display,
          ),
        ),
      );
      final master = find.byKey(const ValueKey('live-intimacy-master-switch'));
      expect(tester.widget<SwitchListTile>(master).value, isFalse);
      expect(stored.rooms.single.authorized, isFalse);
      await tester.tap(master);
      await tester.pumpAndSettle();
      expect(stored.enabled, isTrue);
      expect(stored.rooms.single.authorized, isFalse);
      expect(sessionStarts, 0);
      expect(discovery.reads, 0);
      await tester.tap(find.byKey(const ValueKey('live-intimacy-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('低→高').last);
      await tester.pumpAndSettle();
      expect(stored.sort, LiveIntimacySort.medalLowToHigh);
      expect(stored.rooms.single.authorized, isFalse);
      expect(
        find.text('未授权'),
        findsNothing,
      ); // Part of the scoped room subtitle.
      expect(find.textContaining('未授权'), findsOneWidget);
      expect(find.text('停用授权'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('guest has no writable master or sort control', (tester) async {
    loggedIn = false;
    await scheduler.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: LiveIntimacySettingsPage(scheduler: scheduler, display: display),
      ),
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('live-intimacy-master-switch')),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<DropdownButton<LiveIntimacySort>>(
            find.byKey(const ValueKey('live-intimacy-sort')),
          )
          .onChanged,
      isNull,
    );
    expect(find.text('登录后才能配置后台任务'), findsOneWidget);
    expect(stored.enabled, isFalse);
    expect(sessionStarts, 0);
  });
}

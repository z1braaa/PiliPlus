import 'package:PiliPlus/services/live_intimacy_discovery.dart';
import 'package:PiliPlus/services/live_intimacy_scheduler.dart';
import 'package:PiliPlus/services/live_intimacy_statistics.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'live_intimacy_scheduler_test.dart' as fixture;

class _PartialDiscovery extends fixture.Discovery
    implements LiveIntimacyDiscoveryDiagnostics {
  @override
  bool complete = false;
}

void main() {
  test('partial known ownership can run while missing rooms and totals stay unknown', () async {
    final discovery = _PartialDiscovery();
    discovery.candidates[1] = const LiveIntimacyCandidate(
      roomId: 10,
      anchorUid: 1,
      medalLevel: 5,
      followed: true,
      medalOwned: true,
      live: true,
      areaId: 1,
      parentAreaId: 2,
    );
    final identity = Object();
    final account = LiveIntimacyAccount(
      uid: 1,
      identity: identity,
      generation: 1,
      loggedIn: true,
    );
    var preferences = LiveIntimacyPreferences(
      enabled: true,
      rooms: [fixture.room(1), fixture.room(2)],
    );
    final sessions = <fixture.Session>[];
    final scheduler = LiveIntimacyScheduler.testing(
      account: () => account,
      readPreferences: (_) => preferences,
      writePreferences: (_, value) async => preferences = value,
      discovery: discovery,
      automaticTimers: false,
      loadEmoticons: (_) async => const [
        LiveTaskEmoticonOption(
          unique: 'selected',
          label: 'selected',
          available: true,
        ),
      ],
      readTasks: (room) async => LiveFanTaskSnapshot(
        roomId: room.roomId,
        anchorUid: room.anchorUid,
        accountUid: 1,
        accountIdentity: identity,
        joined: true,
        tasks: fixture.taskSet(),
      ),
      createSession: (_, _, progress, allowed) {
        final session = fixture.Session(fixture.taskSet(), progress, allowed);
        sessions.add(session);
        return session;
      },
    );
    addTearDown(scheduler.shutdown);
    await scheduler.tickForTesting();
    expect(scheduler.discoveryReliable, isTrue);
    expect(scheduler.discoveryComplete, isFalse);
    expect(sessions.single.started, isTrue);
    expect(scheduler.currentRoom?.anchorUid, 1);
    final missing = scheduler.stateFor(20, 2)!;
    expect(missing.candidate, isNull);
    expect(missing.pauseReason, '资格尚未确认');
    expect(LiveIntimacyStatistics.fromScheduler(scheduler).live, isNull);
  });

  test(
    'legacy injected discovery defaults to complete only after success',
    () async {
      final harness = fixture.Harness([fixture.room(1)]);
      addTearDown(harness.close);
      expect(harness.scheduler.discoveryComplete, isFalse);
      await harness.tick();
      expect(harness.scheduler.discoveryComplete, isTrue);
      expect(LiveIntimacyStatistics.fromScheduler(harness.scheduler).live, 1);
    },
  );
}

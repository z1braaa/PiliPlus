import 'package:PiliPlus/pages/live_room/live_startup_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime now;
  late LiveStartupMonitor monitor;
  setUp(() {
    now = DateTime.utc(2026);
    monitor = LiveStartupMonitor(
      window: const Duration(seconds: 20),
      maxRetries: 2,
      now: () => now,
    )..begin();
  });
  LiveStartupDecision observe({
    int seconds = 0,
    bool playing = false,
    bool buffering = true,
    bool decoded = false,
  }) => monitor.observe(
    position: Duration(seconds: seconds),
    playing: playing,
    buffering: buffering,
    decoded: decoded,
  );

  test(
    'command intent and old media progress do not prove new source ready',
    () {
      expect(
        observe(seconds: 100, playing: true, buffering: false, decoded: true),
        LiveStartupDecision.waiting,
      );
      monitor
        ..sourceSelected()
        ..sourceReady(const Duration(seconds: 100));
      expect(
        observe(seconds: 100, playing: true, buffering: false, decoded: true),
        LiveStartupDecision.waiting,
      );
      expect(
        observe(seconds: 101, playing: true, buffering: false, decoded: true),
        LiveStartupDecision.progressing,
      );
    },
  );

  test('buffering or undecoded progress cannot mark usable video', () {
    monitor.sourceReady(Duration.zero);
    expect(
      observe(seconds: 1, playing: true, decoded: true),
      LiveStartupDecision.waiting,
    );
    expect(
      observe(seconds: 2, playing: true, buffering: false),
      LiveStartupDecision.waiting,
    );
    expect(
      observe(seconds: 3, playing: true, buffering: false, decoded: true),
      LiveStartupDecision.progressing,
    );
  });

  test('stuck address and native open both share a finite recovery budget', () {
    now = now.add(const Duration(seconds: 20));
    expect(observe(), LiveStartupDecision.retry);
    expect(monitor.retries, 1);
    monitor.sourceSelected();
    now = now.add(const Duration(seconds: 20));
    expect(observe(), LiveStartupDecision.retry);
    monitor.sourceReady(Duration.zero);
    now = now.add(const Duration(seconds: 20));
    expect(observe(), LiveStartupDecision.failed);
    expect(monitor.active, isFalse);
    expect(monitor.retries, 2);
  });

  test('replacement and user pause cancel pending automatic recovery', () {
    monitor.cancel();
    now = now.add(const Duration(minutes: 1));
    expect(observe(), LiveStartupDecision.waiting);
    expect(monitor.retries, 0);
  });

  test('retry never reuses an old source ready marker', () {
    monitor.sourceReady(Duration.zero);
    now = now.add(const Duration(seconds: 20));
    expect(observe(), LiveStartupDecision.retry);
    expect(
      observe(seconds: 1, playing: true, buffering: false, decoded: true),
      LiveStartupDecision.waiting,
    );
  });
  test(
    'late native completion after final failure cannot restore playback state',
    () {
      for (var attempt = 0; attempt < 3; attempt++) {
        now = now.add(const Duration(seconds: 20));
        observe();
      }
      monitor.sourceReady(Duration.zero);
      expect(
        observe(seconds: 1, playing: true, buffering: false, decoded: true),
        LiveStartupDecision.waiting,
      );
      expect(monitor.phase, LiveStartupPhase.failed);
      expect(monitor.failureAt, LiveStartupPhase.retrying);
    },
  );
}

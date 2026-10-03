import 'package:PiliPlus/services/live_intimacy_watch_progress.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:flutter_test/flutter_test.dart';

LiveFanTask watch({
  int current = 3,
  String title = '观看直播满15分钟',
  String period = '',
  bool done = false,
}) => LiveFanTask(
  name: title,
  description: '',
  jumpType: 'watchLive',
  completed: done,
  currentCount: current,
  targetCount: 10,
  dailyRewardProgress: true,
  period: period,
);

void main() {
  test('initial round fraction stays unknown despite growing decoded time', () {
    final progress = LiveIntimacyWatchProgress()
      ..synchronize([watch()], DateTime(2026, 10, 3))
      ..sample(
        position: Duration.zero,
        monotonicClock: Duration.zero,
        validPlayback: true,
      )
      ..sample(
        position: const Duration(seconds: 1),
        monotonicClock: const Duration(seconds: 1),
        validPlayback: true,
      );
    expect(progress.effectiveDuration.inSeconds, 1);
    expect(progress.completedRounds, 3);
    expect(progress.thresholdSeconds, 900);
    expect(progress.progressValue, isNull);
  });

  test('official new round establishes estimate but reaching quota never grants a round', () {
    final progress = LiveIntimacyWatchProgress()
      ..synchronize([watch(title: '观看直播满2秒')], DateTime(2026, 10, 3))
      ..synchronize([
        watch(current: 4, title: '观看直播满2秒'),
      ], DateTime(2026, 10, 3));
    for (var i = 0; i < 4; i++) {
      progress.sample(
        position: Duration(seconds: i),
        monotonicClock: Duration(seconds: i),
        validPlayback: true,
      );
    }
    expect(progress.effectiveDuration.inSeconds, 3);
    expect(progress.progressValue, 1);
    expect(progress.waitingConfirmation, isTrue);
    expect(progress.completedRounds, 4);
  });

  test(
    'buffering, invalid playback, long clock gaps and seeks do not accrue',
    () {
      final progress = LiveIntimacyWatchProgress();
      void sample(int position, int clock, bool valid) => progress.sample(
        position: Duration(seconds: position),
        monotonicClock: Duration(seconds: clock),
        validPlayback: valid,
      );
      sample(0, 0, true);
      sample(1, 1, true);
      sample(2, 2, false);
      sample(3, 3, true);
      sample(70, 70, true);
      sample(71, 71, true);
      sample(1, 72, true);
      sample(20, 73, true);
      expect(progress.effectiveDuration.inSeconds, 2);
      progress.freeze();
      sample(21, 74, true);
      expect(progress.effectiveDuration.inSeconds, 2);
    },
  );

  test('server reset or new period removes obsolete estimate', () {
    final progress = LiveIntimacyWatchProgress()
      ..synchronize([watch(current: 9)], DateTime(2026, 10, 3))
      ..synchronize([watch(current: 10)], DateTime(2026, 10, 3));
    expect(progress.progressValue, 0);
    progress.synchronize([watch(current: 0)], DateTime(2026, 10, 4));
    expect(progress.progressValue, isNull);
    expect(progress.completedRounds, 0);
    progress.synchronize([
      watch(current: 1, period: 'new-cycle'),
    ], DateTime(2026, 10, 4));
    expect(progress.completedRounds, 1);
  });

  test('ambiguous watch definitions never produce fabricated percentages', () {
    final progress = LiveIntimacyWatchProgress()
      ..synchronize([watch(title: '观时奖励+1')], DateTime(2026, 10, 3));
    expect(progress.thresholdSeconds, isNull);
    expect(progress.progressValue, isNull);
    expect(
      LiveIntimacyWatchProgress.thresholdFor(watch(title: '观看直播满1小时')),
      3600,
    );
    expect(
      LiveIntimacyWatchProgress.thresholdFor(watch(title: '观看直播满0分钟')),
      isNull,
    );
  });

  test('non-round counts are not labeled as official rewarded rounds', () {
    const task = LiveFanTask(
      name: '观看直播满15分钟',
      description: '',
      jumpType: 'watchLive',
      completed: false,
      currentCount: 5,
      targetCount: 15,
      progressText: '5/15分钟',
    );
    final progress = LiveIntimacyWatchProgress()
      ..synchronize([task], DateTime(2026, 10, 3));
    expect(progress.completedRounds, isNull);
    expect(progress.dailyRounds, isNull);
    expect(progress.progressValue, isNull);
    final guard = LiveIntimacyAudioSettlementGuard(progress);
    expect(guard.verifyFreshRead([task], const Duration(hours: 1)), isNull);
  });

  test('only three unique official completion flags complete a room', () {
    List<LiveFanTask> tasks(bool done) => [
      for (final type in ['like', 'sendDanmu', 'watchLive'])
        LiveFanTask(
          name: '',
          description: '',
          jumpType: type,
          completed: done,
          currentCount: 10,
          targetCount: 10,
        ),
      const LiveFanTask(
        name: '',
        description: '',
        jumpType: 'gift',
        completed: false,
      ),
    ];
    expect(liveIntimacyTasksCompleted(tasks(true)), isTrue);
    expect(liveIntimacyTasksCompleted(tasks(false)), isFalse);
    expect(
      liveIntimacyTasksCompleted(
        tasks(true).where((task) => task.jumpType != 'watchLive').toList(),
      ),
      isFalse,
    );
    expect(
      liveIntimacyTasksCompleted([...tasks(true), tasks(true).first]),
      isFalse,
    );
    expect(liveIntimacyTasksCompleted(const []), isFalse);
  });

  test('audio credit failure requires a full effective threshold and fresh settlement wait', () {
    final progress = LiveIntimacyWatchProgress()
      ..synchronize([watch()], DateTime(2026, 10, 3));
    final guard = LiveIntimacyAudioSettlementGuard(progress);
    expect(
      guard.verifyFreshRead([watch()], const Duration(seconds: 899)),
      isNull,
    );
    expect(
      guard.verifyFreshRead([watch()], const Duration(seconds: 989)),
      isNull,
    );
    expect(
      guard.verifyFreshRead([watch()], const Duration(seconds: 990)),
      contains('仍未增长'),
    );
  });

  test('a confirmed audio round renews the next-round settlement gate', () {
    final progress = LiveIntimacyWatchProgress()
      ..synchronize([watch()], DateTime(2026, 10, 3));
    final guard = LiveIntimacyAudioSettlementGuard(progress);
    expect(
      guard.verifyFreshRead([watch(current: 4)], const Duration(seconds: 990)),
      isNull,
    );
    expect(
      guard.verifyFreshRead([watch(current: 4)], const Duration(seconds: 1979)),
      isNull,
    );
    expect(
      guard.verifyFreshRead([watch(current: 4)], const Duration(seconds: 1980)),
      isNotNull,
    );
    expect(
      guard.verifyFreshRead([
        watch(title: '进度未知'),
      ], const Duration(seconds: 5000)),
      isNull,
    );
  });
}

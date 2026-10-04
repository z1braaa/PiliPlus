import 'package:PiliPlus/services/live_intimacy_official_cycle.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:flutter_test/flutter_test.dart';

LiveFanTask task(
  String type,
  int count, {
  bool done = false,
  String period = '',
  bool daily = false,
  int target = 10,
}) => LiveFanTask(
  name: type,
  description: '',
  jumpType: type,
  currentCount: count,
  targetCount: target,
  completed: done,
  period: period,
  dailyRewardProgress: daily,
);

void main() {
  test('two independent daily reads certify one unnumbered reset only', () {
    final cycle = LiveIntimacyOfficialCycle()
      ..synchronize([task('like', 10, done: true, daily: true)], ['like']);
    final first = Object();
    expect(
      cycle.synchronize(
        [task('like', 0, daily: true)],
        ['like'],
        observation: first,
      ),
      isEmpty,
    );
    expect(cycle.confirmed, isFalse);
    expect(
      cycle.synchronize(
        [task('like', 0, daily: true)],
        ['like'],
        observation: first,
      ),
      isEmpty,
    );
    expect(cycle.confirmed, isFalse);
    expect(
      cycle.synchronize(
        [task('like', 1, daily: true)],
        ['like'],
        observation: Object(),
      ),
      {'like'},
    );
    expect(cycle.confirmed, isTrue);
    expect(cycle.confirmedLocalCycles, {'like': 1});
    expect(
      cycle.synchronize(
        [task('like', 1, daily: true)],
        ['like'],
        observation: Object(),
      ),
      isEmpty,
    );
    expect(cycle.confirmedLocalCycles, {'like': 1});
  });

  test('one transient decline followed by recovery never resets', () {
    final cycle = LiveIntimacyOfficialCycle()
      ..synchronize([task('like', 10, done: true, daily: true)], ['like'])
      ..synchronize(
        [task('like', 0, daily: true)],
        ['like'],
        observation: Object(),
      );
    expect(
      cycle.synchronize(
        [task('like', 10, done: true, daily: true)],
        ['like'],
        observation: Object(),
      ),
      isEmpty,
    );
    expect(cycle.confirmed, isTrue);
    expect(cycle.confirmedLocalCycles, isEmpty);
  });

  test('failed, absent and duplicated task reads break consecutive proof', () {
    for (final interruption in [0, 1, 2]) {
      final cycle = LiveIntimacyOfficialCycle()
        ..synchronize([task('like', 10, done: true, daily: true)], ['like'])
        ..synchronize(
          [task('like', 0, daily: true)],
          ['like'],
          observation: Object(),
        );
      if (interruption == 0) {
        cycle.interruptConfirmation();
      } else {
        cycle.synchronize(
          interruption == 1
              ? []
              : [task('like', 0, daily: true), task('like', 0, daily: true)],
          ['like'],
          observation: Object(),
        );
      }
      expect(
        cycle.synchronize(
          [task('like', 0, daily: true)],
          ['like'],
          observation: Object(),
        ),
        isEmpty,
      );
      expect(cycle.confirmed, isFalse);
      expect(
        cycle.synchronize(
          [task('like', 0, daily: true)],
          ['like'],
          observation: Object(),
        ),
        {'like'},
      );
    }
  });

  test('restart retains baseline and generations but requires fresh proof', () {
    final cycle = LiveIntimacyOfficialCycle()
      ..synchronize([task('like', 10, done: true, daily: true)], ['like'])
      ..synchronize(
        [task('like', 0, daily: true)],
        ['like'],
        observation: Object(),
      );
    final restored = LiveIntimacyOfficialCycle()..restore(cycle.toJson());
    expect(
      restored.synchronize(
        [task('like', 0, daily: true)],
        ['like'],
        observation: Object(),
      ),
      isEmpty,
    );
    expect(
      restored.synchronize(
        [task('like', 0, daily: true)],
        ['like'],
        observation: Object(),
      ),
      {'like'},
    );
    final again = LiveIntimacyOfficialCycle()..restore(restored.toJson());
    expect(again.confirmedLocalCycles, {'like': 1});
    expect(
      again.synchronize(
        [task('like', 0, daily: true)],
        ['like'],
        observation: Object(),
      ),
      isEmpty,
    );
    expect(again.confirmed, isTrue);
  });

  test('same explicit period correction cannot create a local cycle', () {
    final cycle = LiveIntimacyOfficialCycle()
      ..synchronize(
        [task('like', 10, done: true, daily: true, period: 'day')],
        ['like'],
      );
    for (var i = 0; i < 3; i++) {
      expect(
        cycle.synchronize(
          [task('like', 0, daily: true, period: 'day')],
          ['like'],
          observation: Object(),
        ),
        isEmpty,
      );
    }
    expect(cycle.confirmed, isFalse);
    expect(cycle.confirmedLocalCycles, isEmpty);
    cycle.synchronize(
      [task('like', 0, daily: true, period: 'new-day')],
      ['like'],
      observation: Object(),
    );
    expect(cycle.confirmed, isTrue);
  });

  test(
    'missing known period and contradictory quotas cannot certify reset',
    () {
      for (final oldPeriod in ['', 'known']) {
        final cycle = LiveIntimacyOfficialCycle()
          ..synchronize(
            [task('like', 10, done: true, daily: true, period: oldPeriod)],
            ['like'],
          );
        for (var i = 0; i < 2; i++) {
          cycle.synchronize(
            [task('like', 5, done: true, target: 5, daily: true)],
            ['like'],
            observation: Object(),
          );
        }
        expect(cycle.confirmed, isFalse);
        expect(cycle.confirmedLocalCycles, isEmpty);
        if (oldPeriod.isNotEmpty) {
          for (var i = 0; i < 2; i++) {
            cycle.synchronize(
              [task('like', 0, daily: true)],
              ['like'],
              observation: Object(),
            );
          }
          expect(cycle.confirmed, isFalse);
        }
      }
    },
  );

  test(
    'changing definition or another decline requires a new confirming read',
    () {
      final cycle = LiveIntimacyOfficialCycle()
        ..synchronize([task('like', 10, done: true, daily: true)], ['like'])
        ..synchronize(
          [task('like', 2, daily: true)],
          ['like'],
          observation: Object(),
        );
      expect(
        cycle.synchronize(
          [task('like', 1, daily: true)],
          ['like'],
          observation: Object(),
        ),
        isEmpty,
      );
      expect(
        cycle.synchronize(
          [task('like', 1, target: 5, daily: true)],
          ['like'],
          observation: Object(),
        ),
        isEmpty,
      );
      expect(
        cycle.synchronize(
          [task('like', 1, target: 5, daily: true)],
          ['like'],
          observation: Object(),
        ),
        {'like'},
      );
    },
  );

  test('resets belong to their task type and room only', () {
    final a = LiveIntimacyOfficialCycle()
      ..synchronize(
        [
          task('like', 10, done: true, daily: true),
          task('watchLive', 7, daily: true),
        ],
        ['like'],
      );
    final b = LiveIntimacyOfficialCycle()
      ..synchronize([task('like', 10, done: true, daily: true)], ['like']);
    for (var i = 0; i < 2; i++) {
      a.synchronize(
        [task('like', 0, daily: true), task('watchLive', 7, daily: true)],
        ['like'],
        observation: Object(),
      );
    }
    expect(a.confirmedLocalCycles, {'like': 1});
    expect(b.confirmedLocalCycles, isEmpty);
  });

  test(
    'like only certifies its own task without requiring any watch definition',
    () {
      final cycle = LiveIntimacyOfficialCycle()
        ..synchronize([task('like', 10, done: true)], ['like']);
      expect(cycle.confirmed, isTrue);
      expect(cycle.confirmedFor(['like', 'sendDanmu', 'watchLive']), isFalse);
    },
  );
  test('each authorized type has independent cycle reset protection', () {
    final cycle = LiveIntimacyOfficialCycle()
      ..synchronize([task('like', 5), task('watchLive', 5)], ['like'])
      ..synchronize([task('like', 5), task('watchLive', 2)], ['like']);
    expect(cycle.confirmed, isTrue);
    cycle.synchronize([task('like', 2), task('watchLive', 2)], ['like']);
    expect(cycle.confirmed, isFalse);
    final restored = LiveIntimacyOfficialCycle()
      ..restore(cycle.toJson())
      ..synchronize([task('like', 2)], ['like']);
    expect(restored.confirmed, isFalse);
    restored.synchronize(
      [task('like', 2, period: 'official-period')],
      ['like'],
    );
    expect(restored.confirmed, isTrue);
  });
  test(
    'unknown flags, duplicate definitions and empty list never certify tasks',
    () {
      final cycle = LiveIntimacyOfficialCycle()
        ..synchronize([task('like', 10), task('like', 10)], ['like']);
      expect(cycle.confirmed, isFalse);
      cycle.synchronize([], ['like']);
      expect(cycle.confirmed, isFalse);
    },
  );
}

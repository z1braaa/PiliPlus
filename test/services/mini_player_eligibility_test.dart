import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/mini_player_eligibility.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only a loaded active or previously started paused source can move', () {
    const cases =
        <
          ({
            PlayerStatus status,
            bool loaded,
            bool started,
            bool completed,
            bool expected,
          })
        >[
          (
            status: .playing,
            loaded: true,
            started: true,
            completed: false,
            expected: true,
          ),
          (
            status: .playing,
            loaded: true,
            started: false,
            completed: false,
            expected: true,
          ),
          (
            status: .paused,
            loaded: true,
            started: true,
            completed: false,
            expected: true,
          ),
          (
            status: .paused,
            loaded: true,
            started: false,
            completed: false,
            expected: false,
          ),
          (
            status: .playing,
            loaded: false,
            started: true,
            completed: false,
            expected: false,
          ),
          (
            status: .completed,
            loaded: true,
            started: true,
            completed: true,
            expected: false,
          ),
          (
            status: .paused,
            loaded: true,
            started: true,
            completed: true,
            expected: false,
          ),
        ];

    for (final testCase in cases) {
      expect(
        canEnterInAppMiniPlayer(
          status: testCase.status,
          sourceLoaded: testCase.loaded,
          hasStartedPlayback: testCase.started,
          sourceCompleted: testCase.completed,
        ),
        testCase.expected,
        reason: '$testCase',
      );
    }
  });
}

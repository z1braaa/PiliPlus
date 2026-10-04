import 'dart:async';

import 'package:PiliPlus/services/live_intimacy_startup_gate.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a native open that never returns is bounded by twenty seconds', (
    tester,
  ) async {
    final gate = LiveIntimacyStartupGate();
    var done = false;
    Object? error;
    unawaited(
      gate
          .run(Completer<void>().future)
          .then(
            (_) {
              done = true;
            },
            onError: (Object value) {
              error = value;
              done = true;
            },
          ),
    );
    await tester.pump(const Duration(seconds: 19));
    expect(done, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(done, isTrue);
    expect(error, isA<LiveInteractionException>());
  });

  test(
    'cancellation does not wait on native future and retires a late player',
    () async {
      final gate = LiveIntimacyStartupGate();
      final player = Completer<Object>();
      var disposed = 0;
      final startup = gate.run(
        player.future,
        onAbandoned: (_) {
          disposed++;
        },
      );
      final rejected = expectLater(
        startup,
        throwsA(isA<LiveInteractionException>()),
      );
      gate.cancel();
      await rejected;
      expect(disposed, 0);
      player.complete(Object());
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(disposed, 1);
    },
  );
}

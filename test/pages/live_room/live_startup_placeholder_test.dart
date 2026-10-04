import 'package:PiliPlus/pages/live_room/live_startup_monitor.dart';
import 'package:PiliPlus/pages/live_room/widgets/live_startup_placeholder.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('covered startup failure retains a visible retry when restored', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveStartupPlaceholder(
            phase: LiveStartupPhase.failed,
            onRetry: () => retries++,
          ),
        ),
      ),
    );
    expect(find.text('直播加载未能恢复，请重试'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('重试直播'));
    expect(retries, 1);
  });

  testWidgets('loading exposes progress without an overlapping restart', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveStartupPlaceholder(
            phase: LiveStartupPhase.retrying,
            onRetry: () => fail('automatic recovery still active'),
          ),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('重试直播'), findsNothing);
  });

  testWidgets('a cancelled or lost session never leaves a blank player', (
    tester,
  ) async {
    for (final phase in [
      LiveStartupPhase.cancelled,
      LiveStartupPhase.progressing,
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 80,
              child: LiveStartupPlaceholder(phase: phase, onRetry: () {}),
            ),
          ),
        ),
      );
      expect(find.text('重试直播'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}

import 'package:PiliPlus/services/mini_overlay_handoff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('restore hides the old overlay before the route adopts its lease', () {
    final handoff = MiniOverlayHandoff<String>();
    final visibleChanges = <String?>[];
    handoff.visible.addListener(
      () => visibleChanges.add(handoff.visible.value),
    );

    expect(handoff.show('first video'), isTrue);
    expect(handoff.beginRestore(), 'first video');
    expect(handoff.visible.value, isNull);
    expect(handoff.pending, 'first video');
    expect(handoff.show('duplicate old view'), isFalse);
    expect(handoff.visible.value, isNull);

    expect(handoff.takePending(), 'first video');
    expect(handoff.pending, isNull);
    expect(handoff.show('next video'), isTrue);
    expect(handoff.visible.value, 'next video');
    expect(visibleChanges, ['first video', null, 'next video']);
  });

  test('closing the visible view leaves no pending restore lease', () {
    final handoff = MiniOverlayHandoff<String>()..show('live room');

    expect(handoff.hideVisible(), 'live room');
    expect(handoff.visible.value, isNull);
    expect(handoff.pending, isNull);
    expect(handoff.takePending(), isNull);
  });
}

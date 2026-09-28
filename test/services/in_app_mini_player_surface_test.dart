import 'package:PiliPlus/services/in_app_mini_player_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [320.0, 160.0]) {
    testWidgets('mini controls stay clickable at width $width', (tester) async {
      var playPauseCount = 0;
      var restoreCount = 0;
      var closeCount = 0;
      var pageTapCount = 0;
      var coveredPageTapCount = 0;
      var shown = true;
      var playing = true;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Stack(
                children: [
                  Positioned(
                    left: 80,
                    top: 40,
                    width: width,
                    height: 200,
                    child: ElevatedButton(
                      onPressed: () => coveredPageTapCount++,
                      child: const Text('原小窗区域按钮'),
                    ),
                  ),
                  Positioned(
                    left: 80,
                    top: 280,
                    width: 200,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: () => pageTapCount++,
                      child: const Text('页面按钮'),
                    ),
                  ),
                  if (shown)
                    Positioned(
                      left: 80,
                      top: 40,
                      width: width,
                      height: 200,
                      child: InAppMiniPlayerSurface(
                        width: width,
                        playing: playing,
                        title: '测试视频',
                        frame: const ColoredBox(
                          color: Colors.blue,
                          child: SizedBox(width: 800, height: 450),
                        ),
                        onPlayPause: () => setState(() {
                          playPauseCount++;
                          playing = !playing;
                        }),
                        onRestore: () => restoreCount++,
                        onClose: () => setState(() {
                          closeCount++;
                          shown = false;
                        }),
                        onMove: (_) {},
                        onResize: (_) {},
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );

      // Space below the mini player belongs to the page, even while the
      // mini player is visible.
      await tester.tap(find.text('页面按钮'));
      expect(pageTapCount, 1);

      await tester.tap(find.byTooltip('暂停'));
      await tester.pump();
      expect(playPauseCount, 1);
      expect(find.byTooltip('播放'), findsOneWidget);

      await tester.tap(find.byTooltip('返回播放页'));
      expect(restoreCount, 1);

      await tester.tap(find.byTooltip('关闭小窗并停止播放'));
      await tester.pump();
      expect(closeCount, 1);
      expect(find.byType(InAppMiniPlayerSurface), findsNothing);

      await tester.tap(find.text('原小窗区域按钮'));
      expect(coveredPageTapCount, 1);
      await tester.tap(find.text('页面按钮'));
      expect(pageTapCount, 2);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('oversized frame is fitted, clipped and cannot take input', (
    tester,
  ) async {
    var frameTapCount = 0;
    var restoreCount = 0;
    var closeCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 80,
                top: 40,
                width: 160,
                height: 200,
                child: InAppMiniPlayerSurface(
                  width: 160,
                  playing: false,
                  frame: GestureDetector(
                    key: const Key('oversized-frame'),
                    onTap: () => frameTapCount++,
                    child: const ColoredBox(
                      color: Colors.blue,
                      child: SizedBox(width: 800, height: 450),
                    ),
                  ),
                  onPlayPause: () {},
                  onRestore: () => restoreCount++,
                  onClose: () => closeCount++,
                  onMove: (_) {},
                  onResize: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final frameFinder = find.byKey(const Key('oversized-frame'));
    final videoClip = find.ancestor(
      of: frameFinder,
      matching: find.byType(ClipRect),
    );
    expect(videoClip, findsOneWidget);
    expect(
      find.ancestor(
        of: frameFinder,
        matching: find.byWidgetPredicate(
          (widget) => widget is IgnorePointer && widget.ignoring,
        ),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FittedBox>(
            find.ancestor(of: frameFinder, matching: find.byType(FittedBox)),
          )
          .fit,
      BoxFit.contain,
    );

    final frameRect = tester.getRect(frameFinder);
    final clipRect = tester.getRect(videoClip);
    expect(frameRect.left, greaterThanOrEqualTo(clipRect.left - 0.01));
    expect(frameRect.top, greaterThanOrEqualTo(clipRect.top - 0.01));
    expect(frameRect.right, lessThanOrEqualTo(clipRect.right + 0.01));
    expect(frameRect.bottom, lessThanOrEqualTo(clipRect.bottom + 0.01));

    await tester.tapAt(clipRect.center);
    expect(restoreCount, 1);
    expect(frameTapCount, 0);

    await tester.tap(find.byTooltip('关闭小窗并停止播放'));
    expect(closeCount, 1);
    expect(tester.takeException(), isNull);
  });
}

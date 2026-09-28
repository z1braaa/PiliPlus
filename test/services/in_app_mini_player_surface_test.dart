import 'dart:ui' as ui;

import 'package:PiliPlus/services/in_app_mini_player_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const closeButton = Key('mini-close');
  const restoreButton = Key('mini-restore');
  const playPauseButton = Key('mini-play-pause');

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

      await tester.tap(find.byKey(playPauseButton));
      await tester.pump();
      expect(playPauseCount, 1);
      expect(find.byKey(playPauseButton), findsOneWidget);

      await tester.tap(find.byKey(restoreButton));
      expect(restoreCount, 1);

      await tester.tap(find.byKey(closeButton));
      await tester.pump();
      expect(closeCount, 1);
      expect(find.byType(InAppMiniPlayerSurface), findsNothing);

      await tester.tap(find.text('原小窗区域按钮'));
      expect(coveredPageTapCount, 1);
      await tester.tap(find.text('页面按钮'));
      expect(pageTapCount, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('hovering controls does not cover their neighbors at $width', (
      tester,
    ) async {
      var playPauseCount = 0;
      var restoreCount = 0;
      var closeCount = 0;
      var outsidePageTapCount = 0;
      const boundaryKey = Key('mini-hover-boundary');

      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            // Production mounts the mini host in MaterialApp.builder, outside
            // the Navigator's own overlay. Capture the whole app so tooltip
            // or ink layers outside the mini rectangle are included.
            builder: (context, child) => Overlay(
              initialEntries: [
                OverlayEntry(
                  builder: (context) => Stack(
                    children: [
                      child!,
                      Positioned(
                        left: 80,
                        top: 40,
                        width: width,
                        height: 200,
                        child: InAppMiniPlayerSurface(
                          width: width,
                          playing: false,
                          title: '测试视频',
                          frame: const ColoredBox(
                            color: Colors.blue,
                            child: SizedBox(width: 800, height: 450),
                          ),
                          onPlayPause: () => playPauseCount++,
                          onRestore: () => restoreCount++,
                          onClose: () => closeCount++,
                          onMove: (_) {},
                          onResize: (_) {},
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned(
                    left: 80,
                    top: 280,
                    width: 160,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: () => outsidePageTapCount++,
                      child: const Text('小窗外按钮'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      Future<void> expectFarEndBlack() async {
        // The user recording showed a gray rectangle beginning at the
        // hovered button and extending to the right edge of this row.
        // Sample the far end, above the resize icon and rounded corner.
        final rgb = await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final rgba = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          if (rgba == null) return <int>[];
          final x = (80 + width - 8).round();
          const y = 40 + 161;
          final offset = (y * image.width + x) * 4;
          final result = [
            rgba.getUint8(offset),
            rgba.getUint8(offset + 1),
            rgba.getUint8(offset + 2),
          ];
          image.dispose();
          return result;
        });
        expect(rgb, [lessThan(20), lessThan(20), lessThan(20)]);
      }

      await expectFarEndBlack();
      expect(
        find.descendant(
          of: find.byType(InAppMiniPlayerSurface),
          matching: find.byType(Tooltip),
        ),
        findsNothing,
      );
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);

      for (final hovered in [closeButton, restoreButton, playPauseButton]) {
        await mouse.moveTo(tester.getCenter(find.byKey(hovered)));
        await tester.pump(const Duration(seconds: 1));
        await expectFarEndBlack();
        expect(find.byKey(closeButton), findsOneWidget);
        expect(find.byKey(restoreButton), findsOneWidget);
        expect(find.byKey(playPauseButton), findsOneWidget);
      }

      // Each button must remain hittable while a different control is hovered.
      await mouse.moveTo(tester.getCenter(find.byKey(closeButton)));
      await tester.pump();
      await tester.tap(find.byKey(restoreButton));
      expect(restoreCount, 1);

      await mouse.moveTo(tester.getCenter(find.byKey(restoreButton)));
      await tester.pump();
      await tester.tap(find.byKey(playPauseButton));
      expect(playPauseCount, 1);

      await mouse.moveTo(tester.getCenter(find.byKey(playPauseButton)));
      await tester.pump();
      await tester.tap(find.byKey(closeButton));
      expect(closeCount, 1);
      await tester.tap(find.text('小窗外按钮'));
      expect(outsidePageTapCount, 1);
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

    await tester.tap(find.byKey(closeButton));
    expect(closeCount, 1);
    expect(tester.takeException(), isNull);
  });
}

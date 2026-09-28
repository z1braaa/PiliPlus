import 'dart:async';
import 'dart:math' as math;

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/mini_overlay_handoff.dart';
import 'package:PiliPlus/services/shutdown_timer_service.dart';
import 'package:PiliPlus/services/temporary_queue_service.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Holds one reference to the existing media session after its route leaves.
/// The host below only creates another video *view*, never another Player.
class InAppMiniPlayer {
  InAppMiniPlayer._();

  static final instance = InAppMiniPlayer._();

  static const restoreOwnerArgument = '_piliMiniRestoreOwner';

  final MiniOverlayHandoff<MiniPlayback> _handoff = MiniOverlayHandoff();
  ValueNotifier<MiniPlayback?> get current => _handoff.visible;
  MiniPlayback? get _pendingRestore => _handoff.pending;
  String? _restoringOwner;
  final Set<String> _stoppedOwners = <String>{};
  final Set<String> _suppressedNavigations = <String>{};

  bool isOwner(String ownerKey) =>
      current.value?.ownerKey == ownerKey ||
      _pendingRestore?.ownerKey == ownerKey;

  /// Consume the stop marker when a covered playback page becomes visible.
  /// Its own play button can start a fresh session afterwards.
  bool wasClosedForOwner(String ownerKey) => _stoppedOwners.remove(ownerKey);

  /// Call immediately before opening an in-app payment/WebView route which
  /// may contain its own media. The next push must not create a mini-player.
  void suppressNextNavigation(String ownerKey) {
    _suppressedNavigations.add(ownerKey);
    Timer(const Duration(seconds: 5), () {
      _suppressedNavigations.remove(ownerKey);
    });
  }

  bool show({
    required String ownerKey,
    required String routeName,
    required Object? routeArguments,
    required Route<dynamic>? ownerRoute,
    required PlPlayerController controller,
    String? title,
  }) {
    if (_suppressedNavigations.remove(ownerKey)) return false;
    if (_pendingRestore != null ||
        _restoringOwner == ownerKey ||
        _stoppedOwners.contains(ownerKey)) {
      return false;
    }
    if (!Pref.inAppMiniPlayer ||
        controller.playerStatus != PlayerStatus.playing ||
        controller.videoController == null ||
        controller.videoPlayerController == null ||
        controller.isFullScreen.value ||
        controller.isPipMode) {
      return false;
    }

    if (isOwner(ownerKey)) return true;
    dismissForOtherMedia();
    controller
      ..retainForInAppMiniPlayer()
      ..addStatusLister(_onStatus);
    PlPlayerController.setPlayCallBack(controller.play);
    _handoff.show(
      MiniPlayback(
        ownerKey: ownerKey,
        routeName: routeName,
        routeArguments: routeArguments,
        ownerRoute: ownerRoute,
        controller: controller,
        title: title,
      ),
    );
    return true;
  }

  /// A route that was covered (rather than popped) gets back its own view.
  bool consumeExistingRestore(String ownerKey) {
    if (_restoringOwner != ownerKey) return false;
    _restoringOwner = null;
    final pending = _pendingRestore;
    if (pending?.ownerKey == ownerKey) {
      _handoff.takePending();
      pending!.controller.releaseFromInAppMiniPlayer();
    }
    return true;
  }

  /// A route recreated after a pop adopts exactly the retained Player.
  bool adoptByPage({
    required String ownerKey,
    required String routeName,
  }) {
    final session = _pendingRestore ?? current.value;
    if (session == null ||
        session.ownerKey != ownerKey ||
        session.routeName != routeName) {
      return false;
    }
    if (identical(_pendingRestore, session)) {
      _handoff.takePending();
      session.controller.releaseFromInAppMiniPlayer();
    } else {
      _clear(session);
    }
    _restoringOwner = null;
    _stoppedOwners.remove(ownerKey);
    return true;
  }

  void restore() {
    final session = current.value;
    if (session == null) return;
    // Hide before navigating. The destination may be built on a later frame;
    // leaving the overlay visible until adoption creates two video views.
    _handoff.beginRestore();
    session.controller.removeStatusLister(_onStatus);
    final navigator = Get.key.currentState;
    final route = session.ownerRoute;
    if (route != null && route.isActive && navigator != null) {
      _restoringOwner = session.ownerKey;
      navigator.popUntil((candidate) => candidate == route);
    } else {
      // Keep the reference until the newly created detail page adopts it.
      final arguments = session.routeArguments;
      Get.toNamed(
        session.routeName,
        arguments: arguments is Map
            ? {...arguments, restoreOwnerArgument: session.ownerKey}
            : arguments,
      );
    }
  }

  /// Opening another media item replaces the one global player session.
  void dismissForOtherMedia({String? exceptOwner}) {
    final session = current.value ?? _pendingRestore;
    if (session == null || session.ownerKey == exceptOwner) return;
    _stoppedOwners.add(session.ownerKey);
    _handoff.takePending();
    _restoringOwner = null;
    unawaited(session.controller.pause());
    _hide(session);
    session.controller.releaseFromInAppMiniPlayer();
    TemporaryQueueService.instance.clearCurrent();
  }

  /// Explicitly closing the small window stops the current media source.
  Future<void> close() async {
    final session = current.value ?? _pendingRestore;
    if (session == null) return;
    _stoppedOwners.add(session.ownerKey);
    _handoff.takePending();
    _restoringOwner = null;
    _hide(session);
    try {
      await session.controller.videoPlayerController?.stop();
    } finally {
      session.controller.releaseFromInAppMiniPlayer();
      TemporaryQueueService.instance.clearCurrent();
    }
  }

  void _onStatus(PlayerStatus status) {
    if (status == PlayerStatus.completed) {
      // Player notifies a mutable listener set. Finish after that iteration.
      scheduleMicrotask(() async {
        final session = current.value;
        if (session == null) return;
        if (shutdownTimerService.isWaiting) {
          shutdownTimerService.handleWaiting();
          await close();
          return;
        }
        if (!session.controller.isLive &&
            session.controller.playRepeat == PlayRepeat.singleCycle) {
          await session.controller.play(repeat: true);
          return;
        }
        final next = session.controller.isLive
            ? null
            : TemporaryQueueService.instance.nextAfterCompletion();
        await close();
        if (next?.cid case final cid?) {
          PageUtils.toVideoPage(
            bvid: next!.bvid,
            cid: cid,
            aid: next.aid,
            title: next.title,
            cover: next.cover,
            extraArguments: {
              TemporaryQueueService.attemptArgument: TemporaryQueueService
                  .instance
                  .attemptFor(next),
            },
          );
        }
      });
    }
  }

  void _clear(MiniPlayback session) {
    if (!identical(current.value, session)) return;
    _hide(session);
    session.controller.releaseFromInAppMiniPlayer();
  }

  void _hide(MiniPlayback session) {
    if (!identical(current.value, session)) return;
    _handoff.hideVisible();
    session.controller.removeStatusLister(_onStatus);
  }
}

class MiniPlayback {
  const MiniPlayback({
    required this.ownerKey,
    required this.routeName,
    required this.routeArguments,
    required this.ownerRoute,
    required this.controller,
    this.title,
  });

  final String ownerKey;
  final String routeName;
  final Object? routeArguments;
  final Route<dynamic>? ownerRoute;
  final PlPlayerController controller;
  final String? title;
}

/// App-window overlay. It is deliberately inside the app's Navigator window.
class InAppMiniPlayerHost extends StatefulWidget {
  const InAppMiniPlayerHost({required this.child, super.key});

  final Widget child;

  @override
  State<InAppMiniPlayerHost> createState() => _InAppMiniPlayerHostState();
}

class _InAppMiniPlayerHostState extends State<InAppMiniPlayerHost> {
  Offset? _topLeft;
  double _width = 300;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        ValueListenableBuilder<MiniPlayback?>(
          valueListenable: InAppMiniPlayer.instance.current,
          builder: (context, session, _) {
            if (session == null) return const SizedBox.shrink();
            final safe = MediaQuery.paddingOf(context);
            final availableWidth = math.max(1.0, constraints.maxWidth - 24);
            final state = session.controller.videoPlayerController!.state;
            final ratio = state.width > 0 && state.height > 0
                ? state.width / state.height
                : 16 / 9;
            final fitRatio = ratio.clamp(0.5, 2.0).toDouble();
            final availableHeight = math.max(
              1.0,
              constraints.maxHeight - safe.vertical - 16,
            );
            final maxWidth = math.min(
              520.0,
              math.min(
                availableWidth,
                math.max(1.0, (availableHeight - 44) * fitRatio),
              ),
            );
            final minWidth = math.min(160.0, maxWidth);
            final width = _width.clamp(minWidth, maxWidth).toDouble();
            final height = width / fitRatio + 44;
            final maxX = math.max(0.0, constraints.maxWidth - width - 8);
            final maxY = math.max(
              safe.top,
              constraints.maxHeight - height - safe.bottom - 8,
            );
            final position = _topLeft ?? Offset(maxX, maxY);
            final x = position.dx.clamp(8.0, math.max(8.0, maxX)).toDouble();
            final y = position.dy.clamp(safe.top, maxY).toDouble();

            return Positioned(
              left: x,
              top: y,
              width: width,
              height: height,
              child: Material(
                elevation: 12,
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(12),
                color: Colors.black,
                child: Column(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: InAppMiniPlayer.instance.restore,
                        child: ColoredBox(
                          color: Colors.black,
                          child: Center(
                            child: FittedBox(
                              fit: BoxFit.contain,
                              child: SimpleVideo(
                                controller: session.controller.videoController!,
                                aspectRatio: ratio,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 44,
                      child: Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onPanUpdate: (details) => setState(() {
                                _topLeft = Offset(
                                  x + details.delta.dx,
                                  y + details.delta.dy,
                                );
                              }),
                              child: Padding(
                                padding: const EdgeInsets.only(left: 10),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: width < 220
                                      ? const Icon(
                                          Icons.drag_indicator,
                                          color: Colors.white70,
                                          size: 18,
                                        )
                                      : Text(
                                          session.title?.isNotEmpty == true
                                              ? session.title!
                                              : '拖动小窗',
                                          overflow: TextOverflow.ellipsis,
                                          maxLines: 1,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                          ),
                                        ),
                                ),
                              ),
                            ),
                          ),
                          if (width >= 160)
                            StreamBuilder<bool>(
                              stream: session
                                  .controller
                                  .videoPlayerController!
                                  .stream
                                  .playing,
                              initialData:
                                  session.controller.playerStatus.isPlaying,
                              builder: (context, snapshot) => IconButton(
                                tooltip: snapshot.data == true ? '暂停' : '播放',
                                onPressed: () {
                                  if (snapshot.data == true) {
                                    session.controller.pause();
                                  } else {
                                    session.controller.play();
                                  }
                                },
                                icon: Icon(
                                  snapshot.data == true
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                            ),
                          if (width >= 220)
                            IconButton(
                              tooltip: '返回播放页',
                              onPressed: InAppMiniPlayer.instance.restore,
                              icon: const Icon(
                                Icons.open_in_full,
                                color: Colors.white,
                                size: 18,
                              ),
                            ),
                          IconButton(
                            tooltip: '关闭小窗并停止播放',
                            onPressed: InAppMiniPlayer.instance.close,
                            icon: const Icon(
                              Icons.close,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanUpdate: (details) => setState(() {
                              _width = (_width + details.delta.dx).clamp(
                                minWidth,
                                maxWidth,
                              );
                            }),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 6),
                              child: Icon(
                                Icons.drag_handle,
                                color: Colors.white70,
                                size: 18,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    ),
  );
}

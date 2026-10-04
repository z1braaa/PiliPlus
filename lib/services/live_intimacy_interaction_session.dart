import 'dart:math' as math;

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/services/live_automation_coordinator.dart';
import 'package:PiliPlus/services/live_intimacy_audio_session.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/services/live_task_automation.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:PiliPlus/utils/live_viewer_preferences.dart';
import 'package:flutter/foundation.dart';

abstract class LiveIntimacyInteractionSession extends ChangeNotifier {
  List<LiveFanTask> get tasks;
  String? get pauseReason;
  String get statusText;
  bool get pending;
  Future<void> tick({bool like = false, bool danmaku = false});
  Future<void> close();
}

/// No player or page is needed. The account queue owns every dispatch slot.
class LiveIntimacyRoomInteractionSession
    extends LiveIntimacyInteractionSession {
  LiveIntimacyRoomInteractionSession({
    required this.preferences,
    required Future<LiveFanTaskSnapshot> Function() readTasks,
    required bool Function() stillAllowed,
  }) : _allowed = stillAllowed,
       _identity = Accounts.main {
    _service = LiveInteractionService(
      roomId: preferences.roomId,
      anchorUid: preferences.anchorUid,
    );
    _lease = LiveAutomationCoordinator.instance.acquireDanmakuGate(
      _identity,
      Accounts.main.mid,
      preferences.roomId,
    );
    _automation = LiveTaskAutomationService.production(
      roomId: preferences.roomId,
      anchorUid: preferences.anchorUid,
      taskService: _service,
      loadTasks: readTasks,
      externalScheduling: true,
      chooseDanmaku: _chooseDanmaku,
      sendDanmaku: _sendDanmaku,
      mayRun: () => !_closed && _allowed(),
    );
    final automation = preferences.automation;
    _automation.update(
      playing: true,
      enhancementEnabled: true,
      autoLike: automation.autoLike,
      autoDanmaku:
          preferences.mode == LiveIntimacyRoomMode.full &&
          automation.autoDanmaku,
      defaultMessage: automation.defaultMessage,
      danmakuMessage: automation.danmakuMode == LiveTaskDanmakuMode.text
          ? LiveTaskDanmakuMessage.text(automation.defaultMessage)
          : LiveTaskDanmakuMessage.emoticon(
              emoticonUnique: preferences.emoticons.firstOrNull?.unique ?? '',
              roomId: preferences.roomId,
              anchorUid: preferences.anchorUid,
            ),
    );
    _automation.addListener(_changed);
  }
  final LiveIntimacyRoomPreferences preferences;
  final bool Function() _allowed;
  final Object _identity;
  final _random = math.Random();
  late final LiveInteractionService _service;
  late final LiveTaskAutomationService _automation;
  late final LiveDanmakuGateLease _lease;
  bool _closed = false;
  @override
  List<LiveFanTask> get tasks => _automation.tasks;
  @override
  String? get pauseReason => _automation.state == LiveTaskAutomationState.paused
      ? _automation.statusText
      : null;
  @override
  String get statusText => _automation.statusText;
  @override
  bool get pending => _automation.pending;
  void _changed() {
    if (!_closed) notifyListeners();
  }

  Future<LiveTaskDanmakuMessage?> _chooseDanmaku(
    Object identity,
    bool Function() allowed,
  ) async {
    if (_closed || !_allowed() || !allowed() || !identical(identity, _identity)) {
      return null;
    }
    if (preferences.automation.danmakuMode == LiveTaskDanmakuMode.text) {
      return LiveTaskDanmakuMessage.text(preferences.automation.defaultMessage);
    }
    final options = await _service.loadTaskEmoticons();
    if (_closed || !_allowed() || !allowed()) return null;
    return chooseLiveIntimacyEmoticon(
      preferences: preferences,
      options: options,
      randomInt: _random.nextInt,
    );
  }

  Future<LiveTaskWriteResult> _sendDanmaku(
    LiveTaskDanmakuMessage message,
    Object identity,
    bool Function() allowed,
  ) async {
    LiveTaskWriteResult? result;
    final attempted = await _lease.gate.trySend(
      () async {
        result = await _service.sendTaskDanmaku(
          taskMessage: message,
          expectedAccountIdentity: identity,
          stillAllowed: () => !_closed && _allowed() && allowed(),
        );
        return result!.state == LiveTaskWriteState.accepted
            ? const Success(null)
            : Error(result!.message);
      },
      clearDraftOnSuccess: false,
      minimumInterval: const Duration(seconds: 30),
      stillCurrent: () => !_closed && _allowed() && allowed(),
    );
    return attempted == null
        ? const LiveTaskWriteResult(LiveTaskWriteState.deferred)
        : result!;
  }

  @override
  Future<void> tick({bool like = false, bool danmaku = false}) =>
      _automation.tickFromQueue(like: like, danmaku: danmaku);
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _automation.stop();
    await _automation.settled;
    _automation.removeListener(_changed);
    _automation.dispose();
    _service.dispose();
    _lease.release();
    super.dispose();
  }
}

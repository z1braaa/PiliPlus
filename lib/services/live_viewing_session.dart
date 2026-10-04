import 'dart:async';

import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/pages/live_room/live_danmaku_send_gate.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/services/live_automation_coordinator.dart';
import 'package:PiliPlus/services/live_intimacy_scheduler.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:PiliPlus/services/live_task_automation.dart';
import 'package:PiliPlus/services/live_watch_reporter.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/live_viewer_preferences.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';

/// Owned by the media session, including its transfer to the in-app mini player.
/// A room panel has no ownership of timers, sender locks or watch reporting.
class LiveViewingSession extends ChangeNotifier {
  LiveViewingSession({
    required this.roomId,
    required this.anchorUid,
    required int areaId,
    required int parentAreaId,
  }) : _areaId = areaId,
       _parentAreaId = parentAreaId,
       interaction = LiveInteractionService(
         roomId: roomId,
         anchorUid: anchorUid,
       ),
       watch = LiveWatchReporter(
         roomId: roomId,
         anchorUid: anchorUid,
         areaId: areaId,
         parentAreaId: parentAreaId,
       ) {
    tasks = LiveTaskAutomationService.production(
      roomId: roomId,
      anchorUid: anchorUid,
      taskService: interaction,
      sendDanmaku: _sendAutomaticDanmaku,
    );
    tasks.addListener(_notify);
    watch.status.addListener(_notify);
    LiveAutomationCoordinator.instance
      ..registerForeground(_surrenderWatch)
      ..addListener(_synchronize);
    _settings = GStorage.setting.watch().listen((_) => _synchronize());
    Accounts.addMainIdentityChangeListener(_beforeMainIdentityChange);
    Accounts.addMainIdentitySettledListener(_synchronize);
    Accounts.addAccountRoleChangeListener(_synchronize);
    // Retain a bounded fallback for settings/account changes outside the normal
    // account APIs. Normal identity and privacy changes notify synchronously.
    _accountPoll = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _synchronize(),
    );
    _synchronize();
  }

  final int roomId;
  final int anchorUid;
  final LiveInteractionService interaction;
  final LiveWatchReporter watch;
  late final LiveTaskAutomationService tasks;
  final _fallbackDanmakuSendGate = LiveDanmakuSendGate();
  LiveDanmakuGateLease? _gateLease;
  LiveDanmakuSendGate get danmakuSendGate =>
      _gateLease?.gate ?? _fallbackDanmakuSendGate;
  LiveTaskAutomationPreferences preferences =
      const LiveTaskAutomationPreferences();
  StreamSubscription<dynamic>? _settings;
  Timer? _accountPoll;
  Object? _identity;
  int? _accountGeneration;
  int _areaId;
  int _parentAreaId;
  final _mediaClock = Stopwatch()..start();
  final _mediaObservation = LiveWatchMediaObservation();
  bool _playing = false;
  bool _buffering = false;
  bool _live = true;
  bool _disposed = false;
  String? _watchUnavailable;

  String get watchStatusText => _watchUnavailable ?? watch.status.value.message;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _beforeMainIdentityChange() async {
    if (_disposed) return;
    watch.updatePlayback(
      enabled: false,
      playing: false,
      buffering: _buffering,
      live: _live,
    );
    tasks.stop();
    _notify();
    await watch.settled;
  }

  Future<void> _surrenderWatch() async {
    if (!_disposed) _apply();
    await watch.settled;
  }

  void updateRoomDetails({required int areaId, required int parentAreaId}) {
    if (_disposed || _areaId == areaId && _parentAreaId == parentAreaId) return;
    _areaId = areaId;
    _parentAreaId = parentAreaId;
    watch.updateRoom(
      roomId: roomId,
      anchorUid: anchorUid,
      areaId: areaId,
      parentAreaId: parentAreaId,
    );
    _synchronize();
  }

  void updatePlayback({
    required bool playing,
    required bool buffering,
    required bool live,
    Duration? position,
  }) {
    if (_disposed) return;
    _playing = playing;
    _buffering = buffering;
    _live = live;
    if (!playing || buffering || !live) {
      _mediaObservation.freeze();
    } else if (position != null) {
      _mediaObservation.observe(position: position, clock: _mediaClock.elapsed);
    }
    _synchronize();
  }

  Future<void> savePreferences(LiveTaskAutomationPreferences value) async {
    final account = Accounts.main;
    if (_disposed ||
        Accounts.mainIdentityChangeInProgress ||
        !account.isLogin ||
        !identical(_identity, account)) {
      return;
    }
    // Fixed UID prevents a delayed write being stored under a newly chosen user.
    preferences = value;
    _apply();
    _notify();
    final scheduler = LiveIntimacyScheduler.instance;
    final previous = scheduler.preferences.roomFor(roomId, anchorUid);
    await scheduler.saveRoomPreferences(
      (previous ??
              LiveIntimacyRoomPreferences(roomId: roomId, anchorUid: anchorUid))
          .copyWith(automation: value),
    );
    if (!_disposed && identical(account, Accounts.main)) _synchronize();
  }

  void _synchronize() {
    if (_disposed) return;
    final account = Accounts.main;
    final generation = Accounts.mainChangeGeneration;
    final changed =
        !identical(_identity, account) || _accountGeneration != generation;
    if (changed) {
      _gateLease?.release();
      _gateLease = LiveAutomationCoordinator.instance.acquireDanmakuGate(
        account,
        account.isLogin ? account.mid : 0,
        roomId,
      );
      _identity = account;
      _accountGeneration = generation;
      watch.updatePlayback(
        enabled: false,
        playing: false,
        buffering: _buffering,
        live: _live,
      );
      watch.accountChanged();
    }
    final previous = preferences;
    preferences =
        Pref.liveIntimacyPreferencesFor(account.isLogin ? account.mid : 0)
            .roomFor(roomId, anchorUid)
            ?.automation ??
        const LiveTaskAutomationPreferences();
    _apply();
    if (changed || previous != preferences) _notify();
  }

  void _apply() {
    final account = Accounts.main;
    final recording = Accounts.heartbeat;
    final previous = _watchUnavailable;
    final mediaAdvancing = _mediaObservation.advancingAt(_mediaClock.elapsed);
    _watchUnavailable = Accounts.mainIdentityChangeInProgress
        ? '账号正在变化，观看与自动任务已暂停'
        : !account.isLogin
        ? '登录后可记录观看任务'
        : Pref.historyPause
        ? '已暂停记录观看'
        : !recording.isLogin
        ? '匿名观看，观看任务上报已暂停'
        : !identical(recording, account)
        ? '观看账号与任务账号不同，观看上报已暂停'
        : _areaId <= 0 || _parentAreaId <= 0
        ? '等待直播间观看信息'
        : LiveAutomationCoordinator.instance.foregroundWatchSuspended
        ? '应用退出或系统休眠，观看上报已暂停'
        : LiveAutomationCoordinator.instance.foregroundWatchDraining
        ? '正在结束上一直播间的观看上报'
        : LiveAutomationCoordinator.instance.backgroundWatchClaimed
        ? '后台任务正在独立上报观时，前台播放保持正常'
        : _playing && !_buffering && !mediaAdvancing
        ? '等待直播实际播放进度，观看上报已暂停'
        : null;
    watch.updatePlayback(
      enabled: _watchUnavailable == null,
      playing: _playing && mediaAdvancing,
      buffering: _buffering || !mediaAdvancing,
      live: _live,
    );
    // The application scheduler is the sole automatic interaction owner.
    // Legacy account preferences and enhanced UI cannot bypass room consent.
    tasks.update(
      playing: false,
      enhancementEnabled: false,
      autoLike: preferences.autoLike,
      autoDanmaku: preferences.autoDanmaku,
      defaultMessage: preferences.defaultMessage,
      danmakuMessage: preferences.danmakuMode == LiveTaskDanmakuMode.text
          ? LiveTaskDanmakuMessage.text(preferences.defaultMessage)
          : LiveTaskDanmakuMessage.emoticon(
              emoticonUnique: preferences.defaultEmoticonUnique,
              roomId: preferences.defaultEmoticonRoomId,
              anchorUid: preferences.defaultEmoticonAnchorUid,
            ),
      minIntervalSeconds: preferences.minIntervalSeconds,
      maxIntervalSeconds: preferences.maxIntervalSeconds,
    );
    if (previous != _watchUnavailable) _notify();
  }

  Future<LiveTaskWriteResult> _sendAutomaticDanmaku(
    LiveTaskDanmakuMessage message,
    Object identity,
    bool Function() stillAllowed,
  ) async {
    LiveTaskWriteResult? result;
    final attempt = await danmakuSendGate.trySend(
      () async {
        result = await interaction.sendTaskDanmaku(
          taskMessage: message,
          expectedAccountIdentity: identity,
          stillAllowed: stillAllowed,
        );
        return result!.state == LiveTaskWriteState.accepted
            ? const Success(null)
            : Error(result!.message);
      },
      clearDraftOnSuccess: false,
      minimumInterval: const Duration(seconds: 30),
      stillCurrent: stillAllowed,
    );
    return attempt == null
        ? const LiveTaskWriteResult(LiveTaskWriteState.deferred)
        : result!;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _settings?.cancel();
    _accountPoll?.cancel();
    Accounts.removeMainIdentityChangeListener(_beforeMainIdentityChange);
    Accounts.removeMainIdentitySettledListener(_synchronize);
    Accounts.removeAccountRoleChangeListener(_synchronize);
    LiveAutomationCoordinator.instance.removeListener(_synchronize);
    tasks.removeListener(_notify);
    watch.status.removeListener(_notify);
    tasks.dispose();
    watch.dispose();
    LiveAutomationCoordinator.instance.retireForeground(watch.settled);
    unawaited(
      watch.settled.then(
        (_) => LiveAutomationCoordinator.instance.unregisterForeground(
          _surrenderWatch,
        ),
        onError: (Object _, StackTrace _) {
          LiveAutomationCoordinator.instance.unregisterForeground(
            _surrenderWatch,
          );
        },
      ),
    );
    interaction.dispose();
    _gateLease?.release();
    _fallbackDanmakuSendGate.dispose();
    super.dispose();
  }
}

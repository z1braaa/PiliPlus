// Testing-friendly public callbacks intentionally differ from private fields.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/live.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/services/live_intimacy_discovery.dart';
import 'package:PiliPlus/services/live_intimacy_watch_progress.dart';
import 'package:PiliPlus/services/live_intimacy_startup_gate.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/services/live_watch_reporter.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

abstract class LiveIntimacyTaskSession extends ChangeNotifier {
  List<LiveFanTask> get tasks;
  LiveIntimacyWatchProgress get watchProgress;
  String? get pauseReason;
  String get statusText;
  bool get actualPlayback;
  Future<void> start();
  Future<void> refresh();
  Future<void> close();
  void setOfficialTasks(List<LiveFanTask> value) {}
}

/// Select from saved, room-scoped choices only. Native permissions must have
/// been read successfully before this pure selection step is reached.
LiveTaskDanmakuMessage chooseLiveIntimacyEmoticon({
  required LiveIntimacyRoomPreferences preferences,
  required List<LiveTaskEmoticonOption> options,
  required int Function(int) randomInt,
}) {
  final issue = preferences.configurationIssue();
  if (issue != null) throw LiveInteractionException(issue);
  final allowed = options
      .where((option) => option.available)
      .map((option) => option.unique)
      .toSet();
  final selected = preferences.emoticons
      .where((item) => allowed.contains(item.unique))
      .toList();
  if (selected.isEmpty) {
    throw const LiveInteractionException('所选表情均不可发送，请重新配置');
  }
  return LiveTaskDanmakuMessage.emoticon(
    emoticonUnique: selected[randomInt(selected.length)].unique,
    roomId: preferences.roomId,
    anchorUid: preferences.anchorUid,
  );
}

/// This session never owns a foreground controller or a chat connection.
/// No video controller is created and no front/system volume is changed.
class LiveIntimacyAudioSession extends LiveIntimacyTaskSession {
  LiveIntimacyAudioSession({
    required this.preferences,
    required this.candidate,
    required this.watchProgress,
    required bool Function() stillAllowed,
    int Function(int)? randomInt,
  }) : _stillAllowed = stillAllowed {
    _identity = Accounts.main;
    _settlement = LiveIntimacyAudioSettlementGuard(watchProgress);
    _accountGeneration = Accounts.mainChangeGeneration;
    _watch = LiveWatchReporter(
      roomId: candidate.roomId,
      anchorUid: candidate.anchorUid,
      areaId: candidate.areaId,
      parentAreaId: candidate.parentAreaId,
    );
    _watch.status.addListener(_watchChanged);
  }

  final LiveIntimacyRoomPreferences preferences;
  final LiveIntimacyCandidate candidate;
  @override
  final LiveIntimacyWatchProgress watchProgress;
  final bool Function() _stillAllowed;
  late final Object _identity;
  late final LiveIntimacyAudioSettlementGuard _settlement;
  late final int _accountGeneration;
  late final LiveWatchReporter _watch;
  Player? _player;
  Timer? _clockTimer;
  final Stopwatch _clock = Stopwatch()..start();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _closed = false;
  bool _closing = false;
  bool _actualPlayback = false;
  bool _refreshing = false;
  Duration? _lastValidAt;
  String? _pauseReason;
  String _status = '准备独立静音音频';
  Future<void>? _closeFuture;
  Future<void>? _startFuture;
  Future<void>? _stopFuture;
  LiveIntimacyStartupGate? _startup;
  Duration? _firstEffectiveDeadline;
  int _missingWatchReads = 0;
  List<LiveFanTask> _tasks = const [];
  int _lastReportedSeconds = 0;

  @override
  List<LiveFanTask> get tasks => _tasks;
  @override
  bool get actualPlayback => _actualPlayback;
  @override
  String? get pauseReason => _pauseReason;
  @override
  String get statusText => _pauseReason ?? _status;
  bool get _allowed =>
      !_closed &&
      !_closing &&
      _stillAllowed() &&
      !Accounts.mainIdentityChangeInProgress &&
      identical(_identity, Accounts.main) &&
      _accountGeneration == Accounts.mainChangeGeneration;

  void _guard() {
    if (!_allowed) throw const LiveInteractionException('任务已取消或账号已变化');
  }

  @override
  Future<void> start() => _startFuture ??= _start();
  Future<void> _start() async {
    final startup = _startup = LiveIntimacyStartupGate();
    _firstEffectiveDeadline = _clock.elapsed + const Duration(seconds: 20);
    try {
      _guard();
      final result = await startup.run(
        LiveHttp.liveRoomInfo(
          roomId: candidate.roomId,
          qn: 80,
          onlyAudio: true,
        ),
      );
      _guard();
      if (result is! Success || result.dataOrNull == null) {
        throw const LiveInteractionException('仅音频流暂时不可用');
      }
      final info = result.dataOrNull!;
      if (info.roomId != candidate.roomId ||
          info.uid != candidate.anchorUid ||
          info.liveStatus != 1) {
        throw const LiveInteractionException('音频房间身份或开播状态已变化');
      }
      String? url;
      for (final stream in info.playurlInfo?.playurl?.stream ?? []) {
        for (final format in stream.format) {
          for (final codec in format.codec) {
            if (codec.urlInfo.isNotEmpty) {
              final location = codec.urlInfo.first;
              url = '${location.host}${codec.baseUrl}${location.extra}';
              break;
            }
          }
          if (url != null) break;
        }
        if (url != null) break;
      }
      if (url == null) throw const LiveInteractionException('官方未提供仅音频地址');
      final player = await startup.run(
        Player.create(
          configuration: const PlayerConfiguration(
            title: 'PiliPlus 后台亲密度音频',
            options: {'vid': 'no', 'volume': '0', 'mute': 'yes'},
          ),
        ),
        onAbandoned: (player) => player.dispose().timeout(
          const Duration(seconds: 5),
          onTimeout: () {},
        ),
      );
      // Cancellation may occur while native initialization awaits. Retain this
      // reference first so the local cleanup always releases the created player.
      _player = player;
      _guard();
      await startup.run(player.setVolume(0));
      await startup.run(
        player.setVideoTrack(const VideoTrack('no', null, null)),
      );
      player.setMediaHeader(
        userAgent: BrowserUa.pc,
        referer: 'https://live.bilibili.com/${candidate.roomId}',
      );
      await startup.run(player.open(Media(url), play: false));
      _guard();
      // This fork does not observe volume into PlayerState. Query the native
      // properties before play rather than trusting its default state.volume.
      if (double.tryParse(player.getProperty('volume')) != 0 ||
          player.getProperty('mute') != 'yes') {
        throw const LiveInteractionException('后台音频静音状态未确认');
      }
      _subscriptions.add(
        player.stream.error.listen((_) {
          if (!_allowed || _pauseReason != null) return;
          // Native errors may recover while media continues. Freeze reporting
          // until a fresh sample confirms progress, and let the existing media
          // deadlines decide whether this room actually needs to be paused.
          _freezePlayback();
          _status = '音频出现异常，正在核对有效播放';
          notifyListeners();
        }),
      );
      _subscriptions.add(
        player.stream.buffering.listen((value) {
          if (value) _freezePlayback();
        }),
      );
      _subscriptions.add(
        player.stream.playing.listen((value) {
          if (!value) _freezePlayback();
        }),
      );
      _lastValidAt = _clock.elapsed;
      _clockTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _sample(),
      );
      await startup.run(player.play());
      _guard();
      _status = '等待音频就绪及有效进度';
      notifyListeners();
    } catch (error) {
      _fail(
        error is LiveInteractionException ? error.message : '仅音频会话初始化失败，已暂停此房间',
      );
      await _stopMedia();
    }
  }

  bool _decoded(Player player) =>
      player.state.audioParams.sampleRate != null &&
      player.state.audioParams.sampleRate! > 0 &&
      player.state.tracks.audio.any(
        (track) => track.id != 'auto' && track.id != 'no',
      );

  void _sample() {
    final player = _player;
    if (!_allowed || player == null || _pauseReason != null) {
      _freezePlayback();
      return;
    }
    if (player.state.tracks.video.any(
      (track) => track.id != 'auto' && track.id != 'no',
    )) {
      _fail('仅音频请求返回了视频轨道，已暂停此房间');
      return;
    }
    final valid =
        player.state.playing &&
        !player.state.buffering &&
        !player.state.completed &&
        _decoded(player) &&
        double.tryParse(player.getProperty('volume')) == 0 &&
        player.getProperty('mute') == 'yes';
    final delta = watchProgress.sample(
      position: player.state.position,
      monotonicClock: _clock.elapsed,
      validPlayback: valid,
    );
    _actualPlayback = valid && delta > Duration.zero;
    if (_actualPlayback) {
      _lastValidAt = _clock.elapsed;
      _firstEffectiveDeadline = null;
    } else if (_firstEffectiveDeadline != null &&
        _clock.elapsed >= _firstEffectiveDeadline!) {
      _fail('后台仅音频在20秒内无有效播放，已暂停此房间观时');
      return;
    }
    _watch.updatePlayback(
      enabled: _allowed,
      playing: _actualPlayback,
      buffering: !_actualPlayback,
      live: true,
    );
    _status = _actualPlayback ? '独立静音音频正在执行任务' : '等待音频有效播放';
    if (_lastValidAt != null &&
        _clock.elapsed - _lastValidAt! > const Duration(seconds: 45)) {
      _fail('仅音频持续断流或无法确认解码，已暂停此房间');
      return;
    }
    notifyListeners();
  }

  @override
  void setOfficialTasks(List<LiveFanTask> value) {
    if (_closed || _closing) return;
    _tasks = List.unmodifiable(value);
    final issue = _settlement.verifyFreshRead(
      value,
      watchProgress.effectiveDuration,
    );
    if (issue != null) _fail(issue);
  }

  void _watchChanged() {
    if (_closed || _closing) return;
    final total = _watch.status.value.reportedSeconds;
    final delta = total - _lastReportedSeconds;
    if (delta > 0) watchProgress.reportedSeconds += delta;
    _lastReportedSeconds = total;
    final state = _watch.status.value.state;
    if (state == LiveWatchState.unsupported || state == LiveWatchState.error) {
      _fail(_watch.status.value.message);
    } else {
      notifyListeners();
    }
  }

  @override
  Future<void> refresh() async {
    if (!_allowed || _refreshing || _pauseReason != null) return;
    _refreshing = true;
    try {
      // Only read; this call cannot reset a durable unresolved interaction.
      if (!_allowed) return;
      final watches = tasks.where((task) => task.jumpType == 'watchLive');
      if (watches.length != 1) {
        _missingWatchReads++;
        if (_missingWatchReads >= 3) {
          _fail('观看任务阶段仍未确认，稍后重新核对此房间');
        }
      } else {
        _missingWatchReads = 0;
      }
    } finally {
      _refreshing = false;
    }
  }

  void _freezePlayback() {
    if (_closed) return;
    _actualPlayback = false;
    watchProgress.freeze();
    _watch.updatePlayback(
      enabled: false,
      playing: false,
      buffering: true,
      live: true,
    );
  }

  void _fail(String reason) {
    if (_closed || _closing || _pauseReason != null) return;
    _pauseReason = reason;
    _freezePlayback();
    notifyListeners();
  }

  Future<void> _stopMedia() => _stopFuture ??= _stopMediaBody();
  Future<void> _stopMediaBody() async {
    _clockTimer?.cancel();
    _freezePlayback();
    await _watch.settled;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    final player = _player;
    _player = null;
    if (player != null) {
      await player.dispose().timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    }
  }

  @override
  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    if (_closed) return;
    _closing = true;
    _startup?.cancel();
    _freezePlayback();
    await _startFuture;
    await _stopMedia();
    _closed = true;
    _watch.status.removeListener(_watchChanged);
    _watch.dispose();
    super.dispose();
  }
}

import 'package:PiliPlus/services/live_interaction_service.dart';

enum LiveIntimacySyncState { pending, synchronized, failed, paused, offline }

/// Local decoded playback and official task settlement are different records.
/// A new session cannot know the server's already accumulated round fraction.
class LiveIntimacyWatchProgress {
  Duration effectiveDuration = Duration.zero;
  int reportedSeconds = 0;
  int? completedRounds;
  int? dailyRounds;
  int? thresholdSeconds;
  int? officialSeconds;
  DateTime? lastSynchronizedAt;
  LiveIntimacySyncState syncState = LiveIntimacySyncState.pending;
  String? syncError;
  bool restoredFromCache = false;
  bool periodConfirmed = false;
  String? get period => _period;
  Duration? _roundEstimate;
  String? _period;
  bool _cycleUncertain = false;
  Duration? _lastPosition;
  Duration? _lastClock;
  bool _previousValid = false;
  bool _disposed = false;

  int? get currentRoundEstimateSeconds => _roundEstimate?.inSeconds;
  bool get waitingConfirmation =>
      thresholdSeconds != null &&
      _roundEstimate != null &&
      _roundEstimate!.inSeconds >= thresholdSeconds!;
  double? get progressValue {
    final threshold = thresholdSeconds;
    final seconds = officialSeconds ?? currentRoundEstimateSeconds;
    if (threshold == null || threshold <= 0 || seconds == null) return null;
    return (seconds / threshold).clamp(0.0, 1.0);
  }

  /// Only unambiguous task definitions yield a threshold. Reward text does not.
  static int? thresholdFor(LiveFanTask task) {
    if (task.jumpType != 'watchLive') return null;
    final match = RegExp(
      r'^观看直播满\s*([1-9]\d*)\s*(秒|分钟|小时)$',
    ).firstMatch(task.name.trim());
    if (match == null) return null;
    final amount = int.tryParse(match[1]!);
    if (amount == null) return null;
    final multiplier = switch (match[2]) {
      '分钟' => 60,
      '小时' => 3600,
      _ => 1,
    };
    final seconds = amount * multiplier;
    return seconds <= 86400 ? seconds : null;
  }

  void synchronize(
    List<LiveFanTask> tasks,
    DateTime at, {
    bool confirmedUnnumberedReset = false,
  }) {
    if (_disposed) return;
    final matches = tasks.where((task) => task.jumpType == 'watchLive');
    if (matches.length != 1) {
      thresholdSeconds = null;
      _roundEstimate = null;
      periodConfirmed = false;
      restoredFromCache = false;
      syncState = LiveIntimacySyncState.pending;
      syncError = '观时任务尚未确认';
      return;
    }
    final task = matches.single;
    final previous = completedRounds;
    final currentRounds = task.dailyRewardProgress ? task.currentCount : null;
    final threshold = thresholdFor(task);
    final periodChanged =
        _period != null && task.period.isNotEmpty && _period != task.period;
    final countReset =
        previous != null && currentRounds != null && currentRounds < previous;
    final definitionChanged =
        thresholdSeconds != null && threshold != thresholdSeconds;
    if (periodChanged || confirmedUnnumberedReset) {
      _cycleUncertain = false;
      _roundEstimate = null;
      effectiveDuration = Duration.zero;
      reportedSeconds = 0;
      officialSeconds = null;
      freeze();
    } else if (countReset || definitionChanged) {
      // A server correction or missing period is not proof of a new cycle.
      // Preserve the current ledger while the official identity is unresolved.
      _roundEstimate = null;
      if (countReset && task.period.isEmpty) _cycleUncertain = true;
    } else if (previous != null &&
        currentRounds != null &&
        currentRounds > previous) {
      // The observation establishes a new approximate origin, not an official
      // current-round second count. The interface must label this estimate.
      _roundEstimate = Duration.zero;
    }
    completedRounds = currentRounds;
    dailyRounds = task.dailyRewardProgress ? task.targetCount : null;
    thresholdSeconds = threshold;
    if (task.period.isNotEmpty) _period = task.period;
    if (task.period.isNotEmpty) _cycleUncertain = false;
    periodConfirmed = !_cycleUncertain;
    restoredFromCache = false;
    syncState = periodConfirmed
        ? LiveIntimacySyncState.synchronized
        : LiveIntimacySyncState.pending;
    syncError = periodConfirmed ? null : '官方进度发生校正，任务周期待核对';
    lastSynchronizedAt = at;
  }

  void synchronizationFailed(String reason) {
    syncState = LiveIntimacySyncState.failed;
    syncError = reason;
  }

  Map<String, Object?> toJson() => {
    'schema': 1,
    'effective_ms': effectiveDuration.inMilliseconds,
    'reported_seconds': reportedSeconds,
    'completed_rounds': completedRounds,
    'daily_rounds': dailyRounds,
    'threshold_seconds': thresholdSeconds,
    'official_seconds': officialSeconds,
    'period': _period,
    'cycle_uncertain': _cycleUncertain,
    'round_estimate_ms': _roundEstimate?.inMilliseconds,
    'last_synchronized_at': lastSynchronizedAt?.toUtc().toIso8601String(),
  };

  void restore(Object? value) {
    if (value is! Map || value['schema'] != 1) return;
    int? nonnegative(String key) {
      final number = liveInt(value[key]);
      return number != null && number >= 0 ? number : null;
    }

    effectiveDuration = Duration(
      milliseconds: nonnegative('effective_ms') ?? 0,
    );
    reportedSeconds = nonnegative('reported_seconds') ?? 0;
    completedRounds = nonnegative('completed_rounds');
    dailyRounds = nonnegative('daily_rounds');
    thresholdSeconds = nonnegative('threshold_seconds');
    officialSeconds = nonnegative('official_seconds');
    _period = value['period'] is String ? value['period'] as String : null;
    _cycleUncertain = value['cycle_uncertain'] == true;
    final estimate = nonnegative('round_estimate_ms');
    _roundEstimate = estimate == null ? null : Duration(milliseconds: estimate);
    lastSynchronizedAt = DateTime.tryParse('${value['last_synchronized_at']}');
    restoredFromCache = true;
    periodConfirmed = false;
    syncState = LiveIntimacySyncState.pending;
    freeze();
  }

  /// Called at a bounded cadence with the actual native playback position.
  /// Long gaps (including sleep) and seeks never turn into counted watch time.
  Duration sample({
    required Duration position,
    required Duration monotonicClock,
    required bool validPlayback,
  }) {
    if (_disposed) return Duration.zero;
    final previousPosition = _lastPosition;
    final previousClock = _lastClock;
    final previouslyValid = _previousValid;
    _lastPosition = position;
    _lastClock = monotonicClock;
    _previousValid = validPlayback;
    if (!validPlayback ||
        !previouslyValid ||
        previousPosition == null ||
        previousClock == null) {
      return Duration.zero;
    }
    final media = position - previousPosition;
    final elapsed = monotonicClock - previousClock;
    if (elapsed <= Duration.zero ||
        elapsed > const Duration(seconds: 3) ||
        media <= Duration.zero ||
        media > elapsed + const Duration(seconds: 1)) {
      return Duration.zero;
    }
    final credited = media < elapsed ? media : elapsed;
    effectiveDuration += credited;
    if (_roundEstimate != null) _roundEstimate = _roundEstimate! + credited;
    return credited;
  }

  void freeze() {
    _lastPosition = null;
    _lastClock = null;
    _previousValid = false;
  }

  void dispose() {
    _disposed = true;
    freeze();
  }
}

/// All three official flags must be present and affirmative. Quotas, HTTP
/// success, local budgets and a missing task can never stand in for completion.
bool liveIntimacyTasksCompleted(List<LiveFanTask> tasks) =>
    const ['like', 'sendDanmu', 'watchLive'].every((type) {
      final matches = tasks.where((task) => task.jumpType == type);
      return matches.length == 1 && matches.single.completed == true;
    });

bool liveIntimacyTaskCompleted(List<LiveFanTask> tasks, String type) {
  final matches = tasks.where((task) => task.jumpType == type);
  return matches.length == 1 && matches.single.completed == true;
}

/// A room-specific settlement gate. Passing a transport heartbeat does not
/// prove this room will credit audio, so a full effective threshold plus a
/// bounded official settlement window must be followed by a fresh task read.
class LiveIntimacyAudioSettlementGuard {
  LiveIntimacyAudioSettlementGuard(LiveIntimacyWatchProgress progress)
    : _rounds = progress.completedRounds,
      _threshold = progress.thresholdSeconds,
      _period = progress._period,
      _effectiveAtRound = progress.effectiveDuration;

  int? _rounds;
  int? _threshold;
  String? _period;
  Duration _effectiveAtRound;
  static const settlementWait = Duration(seconds: 90);

  String? verifyFreshRead(List<LiveFanTask> tasks, Duration effectiveDuration) {
    final watches = tasks.where((task) => task.jumpType == 'watchLive');
    if (watches.length != 1) return null;
    final task = watches.single;
    final threshold = LiveIntimacyWatchProgress.thresholdFor(task);
    final current = task.currentCount;
    if (threshold == null ||
        current == null ||
        task.completed != false ||
        !task.dailyRewardProgress) {
      return null;
    }
    final newPeriod =
        _period != null && task.period.isNotEmpty && task.period != _period;
    if (_rounds == null ||
        _threshold != threshold ||
        current != _rounds ||
        newPeriod) {
      _rounds = current;
      _threshold = threshold;
      _effectiveAtRound = effectiveDuration;
      _period = task.period;
      return null;
    }
    _period = task.period;
    final elapsed = effectiveDuration - _effectiveAtRound;
    if (elapsed >= Duration(seconds: threshold) + settlementWait) {
      return '仅音频有效观时已覆盖一轮及结算等待，官方轮数仍未增长；已暂停此房间';
    }
    return null;
  }
}

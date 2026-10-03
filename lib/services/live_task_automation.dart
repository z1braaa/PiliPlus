// Public injection arguments deliberately differ from private field names.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:math' as math;

import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

export 'package:PiliPlus/models_new/live/interactions/live_interaction.dart'
    show
        LiveFanTask,
        LiveFanTaskSnapshot,
        LiveTaskDanmakuMessage,
        LiveTaskEmoticonOption,
        LiveTaskWriteResult,
        LiveTaskWriteState;

typedef LiveTaskLikeSender = Future<LiveTaskWriteResult> Function(
  int count,
  Object accountIdentity,
  bool Function() stillAllowed,
);
typedef LiveTaskDanmakuSender = Future<LiveTaskWriteResult> Function(
  LiveTaskDanmakuMessage message,
  Object accountIdentity,
  bool Function() stillAllowed,
);
typedef LiveTaskDanmakuSelector = Future<LiveTaskDanmakuMessage?> Function(
  Object accountIdentity,
  bool Function() stillAllowed,
);

enum LiveTaskAutomationState {
  idle,
  loading,
  waiting,
  sending,
  verifying,
  completed,
  paused,
}

/// Owned by a media task session, never by a fan-panel widget. Actual playback
/// and the scheduler's current consent/identity guard gate every interaction.
class LiveTaskAutomationService extends ChangeNotifier {
  factory LiveTaskAutomationService.production({
    required int roomId,
    required int anchorUid,
    LiveInteractionService? taskService,
    LiveTaskDanmakuSender? sendDanmaku,
    LiveTaskDanmakuSelector? chooseDanmaku,
    bool Function()? mayRun,
  }) {
    final service =
        taskService ??
        LiveInteractionService(roomId: roomId, anchorUid: anchorUid);
    final automation = LiveTaskAutomationService.testing(
      roomId: roomId,
      anchorUid: anchorUid,
      loadTasks: service.loadFanTasks,
      sendLike: (count, identity, allowed) => service.sendTaskLikes(
        clickTime: count,
        expectedAccountIdentity: identity,
        stillAllowed: allowed,
      ),
      sendDanmaku:
          sendDanmaku ??
          (message, identity, allowed) => service.sendTaskDanmaku(
            taskMessage: message,
            expectedAccountIdentity: identity,
            stillAllowed: allowed,
          ),
      accountIdentity: () => Accounts.main,
      accountUid: () => Accounts.main.mid,
      accountGeneration: () => Accounts.mainChangeGeneration,
      isLoggedIn: () => Accounts.main.isLogin,
      journal: _HiveTaskJournal(),
      chooseDanmaku: chooseDanmaku,
      mayRun: mayRun,
    );
    automation
      .._productionService = taskService == null ? service : null
      .._accountListener = automation._beforeAccountChange;
    Accounts.addMainIdentityChangeListener(automation._accountListener!);
    return automation;
  }

  LiveTaskAutomationService.testing({
    required this.roomId,
    required this.anchorUid,
    required Future<LiveFanTaskSnapshot> Function() loadTasks,
    required LiveTaskLikeSender sendLike,
    required LiveTaskDanmakuSender sendDanmaku,
    required Object Function() accountIdentity,
    required int Function() accountUid,
    required int Function() accountGeneration,
    required bool Function() isLoggedIn,
    DateTime Function()? now,
    int Function(int upperBound)? randomInt,
    LiveInteractionJournal? journal,
    LiveTaskDanmakuSelector? chooseDanmaku,
    bool Function()? mayRun,
    bool paceLikes = true,
  }) : _loadTasks = loadTasks,
       _sendLike = sendLike,
       _sendDanmaku = sendDanmaku,
       _identity = accountIdentity,
       _uid = accountUid,
       _accountGeneration = accountGeneration,
       _isLoggedIn = isLoggedIn,
       _now = now ?? DateTime.now,
       _randomInt = randomInt ?? math.Random().nextInt,
       _journal = journal ?? _MemoryTaskJournal(),
       _chooseDanmaku = chooseDanmaku,
       _mayRun = mayRun ?? (() => true),
       _paceLikes = paceLikes;

  final int roomId;
  final int anchorUid;
  final Future<LiveFanTaskSnapshot> Function() _loadTasks;
  final LiveTaskLikeSender _sendLike;
  final LiveTaskDanmakuSender _sendDanmaku;
  final Object Function() _identity;
  final int Function() _uid;
  final int Function() _accountGeneration;
  final bool Function() _isLoggedIn;
  final DateTime Function() _now;
  final int Function(int upperBound) _randomInt;
  final LiveInteractionJournal _journal;
  final LiveTaskDanmakuSelector? _chooseDanmaku;
  final bool Function() _mayRun;
  final bool _paceLikes;
  _LikePreparation? _likePreparation;
  Timer? _likeTimer;
  final Map<String, _TaskBudget> _budgets = {};
  static final Set<String> _activeWrites = {};
  LiveInteractionService? _productionService;
  Future<void> Function()? _accountListener;
  Timer? _timer;
  Future<void>? _operation;
  bool _disposed = false;
  bool _busy = false;
  bool _restart = false;
  bool _retryConfigurationOnNextRead = false;
  bool _playing = false;
  bool _enhancementEnabled = false;
  bool _autoLike = false;
  bool _autoDanmaku = false;
  LiveTaskDanmakuMessage _defaultMessage = const LiveTaskDanmakuMessage.text(
    '',
  );
  int _minInterval = 30;
  int _maxInterval = 60;
  int _epoch = 0;
  Object? _boundIdentity;
  int? _boundUid;
  int? _boundAccountGeneration;
  DateTime? _nextDanmakuAt;
  _TaskBudget? _verification;
  LiveTaskAutomationState _state = LiveTaskAutomationState.idle;
  String _statusText = '自动任务已关闭';
  String? _error;
  List<LiveFanTask> _tasks = const [];

  LiveTaskAutomationState get state => _state;
  String get statusText => _statusText;
  String? get error => _error;
  bool get pending => _busy;
  Future<void> get settled => _operation ?? Future<void>.value();
  List<LiveFanTask> get tasks => _tasks;
  Object? get accountIdentity => _boundIdentity;

  bool get _eligible =>
      !_disposed &&
      _playing &&
      _enhancementEnabled &&
      (_autoLike || _autoDanmaku) &&
      _isLoggedIn() &&
      _uid() > 0 &&
      _mayRun();

  bool get _sameAccount =>
      identical(_boundIdentity, _identity()) &&
      _boundUid == _uid() &&
      _boundAccountGeneration == _accountGeneration();

  void update({
    required bool playing,
    required bool enhancementEnabled,
    required bool autoLike,
    required bool autoDanmaku,
    required String defaultMessage,
    LiveTaskDanmakuMessage? danmakuMessage,
    int minIntervalSeconds = 30,
    int maxIntervalSeconds = 60,
  }) {
    if (_disposed) return;
    final minInterval = minIntervalSeconds.clamp(10, 3600);
    final maxInterval = maxIntervalSeconds.clamp(minInterval, 3600);
    final identity = _identity();
    final message =
        danmakuMessage ?? LiveTaskDanmakuMessage.text(defaultMessage);
    final identityChanged = !_sameAccount;
    final resetMessageDelay =
        identityChanged ||
        autoDanmaku != _autoDanmaku ||
        message != _defaultMessage ||
        minInterval != _minInterval ||
        maxInterval != _maxInterval;
    final changed =
        identityChanged ||
        playing != _playing ||
        enhancementEnabled != _enhancementEnabled ||
        autoLike != _autoLike ||
        autoDanmaku != _autoDanmaku ||
        message != _defaultMessage ||
        minInterval != _minInterval ||
        maxInterval != _maxInterval;
    if (!changed) return;
    if (message != _defaultMessage) _retryConfigurationOnNextRead = true;
    ++_epoch;
    _cancelLikePreparation();
    _timer?.cancel();
    _timer = null;
    _playing = playing;
    _enhancementEnabled = enhancementEnabled;
    _autoLike = autoLike;
    _autoDanmaku = autoDanmaku;
    _defaultMessage = message;
    _minInterval = minInterval;
    _maxInterval = maxInterval;
    _boundIdentity = identity;
    _boundUid = _uid();
    _boundAccountGeneration = _accountGeneration();
    if (identityChanged) {
      _tasks = const [];
      _verification = null;
      _nextDanmakuAt = null;
    }
    if (resetMessageDelay) _nextDanmakuAt = null;
    if (!_eligible) {
      _showInactive();
      return;
    }
    _nextDanmakuAt ??= _now().add(_randomDelay());
    if (_busy) {
      _restart = true;
    } else {
      _schedule(Duration.zero);
    }
  }

  void stop() {
    if (_disposed) return;
    ++_epoch;
    _cancelLikePreparation();
    _playing = false;
    _timer?.cancel();
    _timer = null;
    _showInactive();
  }

  Future<void> _beforeAccountChange() async {
    ++_epoch;
    _cancelLikePreparation();
    _timer?.cancel();
    _timer = null;
    _boundAccountGeneration = null;
    _tasks = const [];
    _show(LiveTaskAutomationState.paused, '账号正在变化，自动操作暂停');
  }

  void _showInactive() {
    if (!_enhancementEnabled || (!_autoLike && !_autoDanmaku)) {
      _show(LiveTaskAutomationState.idle, '自动任务已关闭');
    } else if (!_isLoggedIn() || _uid() <= 0) {
      _show(LiveTaskAutomationState.paused, '登录后可自动完成当前直播间任务');
    } else {
      _show(LiveTaskAutomationState.paused, '等待当前直播继续播放');
    }
  }

  void _show(LiveTaskAutomationState state, String text, [String? error]) {
    if (_disposed) return;
    _state = state;
    _statusText = text;
    _error = error;
    notifyListeners();
  }

  Duration _randomDelay() => Duration(
    seconds: _minInterval + _randomInt(_maxInterval - _minInterval + 1),
  );

  void _cancelLikePreparation() {
    _likeTimer?.cancel();
    _likeTimer = null;
    _likePreparation = null;
  }

  int _writeCount(LiveFanTask task) {
    final budget = _budget(task);
    return task.jumpType == 'like' &&
            !task.dailyRewardProgress &&
            !task.completionOnly
        ? math.min(
            budget.countMappingConfirmed ? 5 : 1,
            math.min(task.remainingCount!, budget.allowance),
          )
        : 1;
  }

  bool _likePrepared(LiveFanTask task, int epoch) {
    if (!_paceLikes) return true;
    final clicks = _writeCount(task) * task.actionsPerProgress!;
    final key = _key(task);
    var preparation = _likePreparation;
    if (preparation == null ||
        preparation.key != key ||
        preparation.clicks != clicks ||
        preparation.observed != task.currentCount) {
      _cancelLikePreparation();
      preparation = _likePreparation = _LikePreparation(
        key,
        clicks,
        task.currentCount,
      );
      void accumulate() {
        if (!_validRun(epoch) || !identical(_likePreparation, preparation)) {
          _cancelLikePreparation();
          return;
        }
        _likeTimer = Timer(Duration(seconds: 1 + _randomInt(3)), () {
          if (!_validRun(epoch) || !identical(_likePreparation, preparation)) {
            _cancelLikePreparation();
            return;
          }
          ++preparation!.accumulated;
          if (preparation.accumulated >= preparation.clicks) {
            _likeTimer = null;
            if (_busy) {
              _restart = true;
            } else {
              _schedule(Duration.zero);
            }
          } else {
            accumulate();
          }
        });
      }

      accumulate();
    }
    return preparation.accumulated >= preparation.clicks;
  }

  void _schedule(Duration delay) {
    if (!_eligible || !_sameAccount) return;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(_operation = _tick());
    });
  }

  /// A manual refresh only reads. It cannot reset an unresolved write budget.
  Future<void> refreshTasks() async {
    if (_disposed || !_enhancementEnabled || !_isLoggedIn()) return;
    if (_busy) {
      _restart = true;
      return;
    }
    _timer?.cancel();
    _timer = null;
    await (_operation = _tick(readOnly: true));
  }

  String get _scope => '$_boundUid:$roomId:$anchorUid:';

  String _period(LiveFanTask task) =>
      task.period.isEmpty ? 'unknown-period' : task.period;

  String _key(LiveFanTask task) =>
      '$_scope${_period(task)}:'
      '${task.id.isEmpty ? task.jumpType : task.id}:${task.jumpType}'
      '${task.completionOnly ? ':lighting' : ''}';

  _TaskBudget _budget(LiveFanTask task) => _budgets.putIfAbsent(
    _key(task),
    () => _TaskBudget(
      key: _key(task),
      type: task.jumpType,
      period: _period(task),
      initialRemaining: task.remainingCount ?? 0,
      current: task.currentCount ?? 0,
      target: task.targetCount ?? 0,
      actionsPerProgress: task.actionsPerProgress ?? 1,
      dailyRewardProgress: task.dailyRewardProgress,
      completionOnly: task.completionOnly,
    ),
  );

  Future<void> _restoreBudgets(int epoch) async {
    final scope = _scope;
    {
      final index = await _journal.read('${scope}index');
      if (_disposed || epoch != _epoch || !_sameAccount) return;
      if (index != null && index['keys'] is! List) {
        throw const LiveInteractionException('本地任务记录无法核对，自动操作暂停');
      }
      final keys = index?['keys'] as List? ?? const [];
      if (keys.length > 500) {
        throw const LiveInteractionException('本地任务记录超出核对范围，自动操作暂停');
      }
      if (keys.any((key) => key is! String || !key.startsWith(scope))) {
        throw const LiveInteractionException('本地任务记录无法核对，自动操作暂停');
      }
      for (final key in keys) {
        final record = await _journal.read(key as String);
        if (_disposed || epoch != _epoch || !_sameAccount) return;
        if (record != null) _budgets[key] = _TaskBudget.restore(key, record);
      }
    }
    for (final task in _tasks) {
      if (!{'like', 'sendDanmu'}.contains(task.jumpType)) continue;
      final key = _key(task);
      if (!_budgets.containsKey(key) &&
          task.completed != true &&
          (task.remainingCount == null ||
              task.actionsPerProgress == null ||
              (task.targetCount ?? 0) > 10000)) {
        continue;
      }
      final budget = _budgets[key] ?? _budget(task);
      if (budget.serverCompleted &&
          task.completed == false &&
          task.currentCount != null &&
          (budget.target == 0 || task.currentCount! < budget.highestObserved)) {
        // Only server completion followed by a reset count establishes another
        // cycle. Local midnight alone can never reset this durable budget.
        _budgets[key] = _TaskBudget(
          key: key,
          type: task.jumpType,
          period: _period(task),
          initialRemaining: task.remainingCount ?? 0,
          current: task.currentCount!,
          target: task.targetCount ?? 0,
          actionsPerProgress: task.actionsPerProgress ?? 1,
          dailyRewardProgress: task.dailyRewardProgress,
          completionOnly: task.completionOnly,
        );
        await _persist(_budgets[key]!);
        if (_disposed || epoch != _epoch || !_sameAccount) return;
      } else if (task.completed == true && !budget.serverCompleted) {
        budget
          ..serverCompleted = true
          ..highestObserved = math.max(
            budget.highestObserved,
            task.currentCount ?? task.targetCount ?? budget.highestObserved,
          );
        await _persist(budget);
        if (_disposed || epoch != _epoch || !_sameAccount) return;
      }
    }
    if (_retryConfigurationOnNextRead) {
      for (final budget in _budgets.values.where(
        (budget) =>
            budget.key.startsWith(scope) &&
            budget.retryOnMessageChange &&
            budget.pendingCount == 0,
      )) {
        budget
          ..halted = null
          ..retryOnMessageChange = false;
        await _persist(budget);
        if (_disposed || epoch != _epoch || !_sameAccount) return;
      }
      _retryConfigurationOnNextRead = false;
    }
    if (_verification case final previous?) {
      _verification = _budgets[previous.key] ?? previous;
    }
    _verification ??= _budgets.values
        .where(
          (budget) =>
              budget.key.startsWith(scope) &&
              budget.pendingCount > 0 &&
              !budget.retired,
        )
        .firstOrNull;
  }

  Future<void> _persist(_TaskBudget budget) async {
    final scope = budget.key.split(':').take(3).join(':');
    final currentKeys = _tasks.map(_key).toSet();
    await _journal.write('$scope:index', {
      'keys': _budgets.entries
          .where(
            (entry) =>
                entry.key.startsWith('$scope:') &&
                (entry.value.period == 'unknown-period' ||
                    currentKeys.contains(entry.key) ||
                    (entry.value.pendingCount > 0 && !entry.value.retired)),
          )
          .map((entry) => entry.key)
          .toList(),
    });
    await _journal.write(budget.key, budget.record);
  }

  bool _validRun(int epoch) =>
      !_disposed && epoch == _epoch && _eligible && _sameAccount;

  Future<void> _tick({bool readOnly = false}) async {
    if (_disposed || _busy || (!readOnly && !_eligible)) return;
    if (!_sameAccount) {
      _show(LiveTaskAutomationState.paused, '账号已变化，等待重新读取偏好与任务');
      return;
    }
    _busy = true;
    final epoch = _epoch;
    final identity = _boundIdentity!;
    String? writeScope;
    try {
      // Serialize the read as well: a snapshot begun before another instance's
      // write must not later masquerade as a newly reset task cycle.
      writeScope = _scope;
      if (!_activeWrites.add(writeScope)) {
        writeScope = null;
        _show(LiveTaskAutomationState.waiting, '等待当前房间的另一任务操作结束');
        _schedule(const Duration(seconds: 5));
        return;
      }
      _show(LiveTaskAutomationState.loading, '正在读取当前直播间亲密度任务');
      final snapshot = await _loadTasks();
      if (_disposed || epoch != _epoch || !_sameAccount) return;
      if (snapshot.roomId != roomId ||
          snapshot.anchorUid != anchorUid ||
          snapshot.accountUid != _boundUid ||
          !identical(snapshot.accountIdentity, identity)) {
        _show(LiveTaskAutomationState.paused, '任务所属账号或直播间不一致，自动操作暂停');
        return;
      }
      _tasks = List.unmodifiable(snapshot.tasks);
      if (snapshot.joined != true) {
        _show(
          LiveTaskAutomationState.paused,
          snapshot.joined == false ? '当前直播间尚未加入粉丝团' : '粉丝团身份尚未确认，自动操作暂停',
        );
        _schedule(const Duration(seconds: 30));
        return;
      }
      await _restoreBudgets(epoch);
      if (_disposed || epoch != _epoch || !_sameAccount) return;
      if (await _verifyPending(epoch)) return;
      if (!_validRun(epoch)) {
        if (epoch == _epoch) _showInactive();
        return;
      }
      final candidates = <LiveFanTask>[];
      final notices = <String>[];
      for (final type in ['like', 'sendDanmu']) {
        if (type == 'like' ? !_autoLike : !_autoDanmaku) continue;
        final matches = _tasks.where((task) => task.jumpType == type).toList();
        final label = type == 'like' ? '点赞' : '弹幕';
        if (matches.isEmpty) {
          notices.add('当前没有$label任务');
          continue;
        }
        if (matches.length != 1) {
          notices.add('$label任务有多个定义，自动操作暂停');
          continue;
        }
        final task = matches.single;
        if (task.completed == true) continue;
        final remaining = task.remainingCount;
        if (task.completed == null ||
            remaining == null ||
            task.actionsPerProgress == null) {
          notices.add('$label任务的数量或完成状态尚未确认，自动操作暂停');
          continue;
        }
        if (remaining == 0) {
          notices.add('$label数量已满足，等待官方确认完成');
          continue;
        }
        if (task.targetCount! > 10000 ||
            task.actionsPerProgress! <= 0 ||
            task.actionsPerProgress! > 1000) {
          notices.add('$label任务数量异常，自动操作暂停');
          continue;
        }
        final budget = _budget(task);
        if (task.targetCount != budget.target ||
            task.actionsPerProgress != budget.actionsPerProgress ||
            task.dailyRewardProgress != budget.dailyRewardProgress ||
            task.completionOnly != budget.completionOnly ||
            (task.currentCount != null &&
                task.currentCount! < budget.highestObserved)) {
          budget.halted = '$label任务目标或进度发生变化，自动操作暂停';
        }
        budget.highestObserved = math.max(
          budget.highestObserved,
          task.currentCount ?? 0,
        );
        if (budget.halted != null) {
          notices.add(budget.halted!);
          continue;
        }
        if (budget.allowance <= 0) {
          notices.add('$label已用完本次任务发送预算，等待官方状态核对');
          continue;
        }
        if (type == 'sendDanmu' && _defaultMessage.isEmpty) {
          notices.add('请先设置默认弹幕（文字或表情）；自动弹幕尚未发送');
          continue;
        }
        candidates.add(task);
      }
      if (candidates.isEmpty) {
        _cancelLikePreparation();
        _show(
          notices.isEmpty
              ? LiveTaskAutomationState.completed
              : LiveTaskAutomationState.paused,
          notices.isEmpty ? '已确认所选亲密度任务完成' : notices.join('；'),
        );
        _schedule(const Duration(seconds: 30));
        return;
      }
      final like = candidates
          .where((task) => task.jumpType == 'like')
          .firstOrNull;
      final danmaku = candidates
          .where((task) => task.jumpType == 'sendDanmu')
          .firstOrNull;
      final now = _now();
      if (like == null) _cancelLikePreparation();
      _nextDanmakuAt ??= now.add(_randomDelay());
      final likeReady = like != null && !readOnly && _likePrepared(like, epoch);
      // Slow click accumulation never starves a due message in the same room.
      final chosen = danmaku != null && !now.isBefore(_nextDanmakuAt!)
          ? danmaku
          : likeReady
          ? like
          : null;
      if (readOnly || chosen == null) {
        _show(
          LiveTaskAutomationState.waiting,
          notices.isEmpty
              ? like != null
                    ? '按1～3秒节奏累计任务点赞；弹幕按独立间隔执行'
                    : '按随机间隔等待下一条任务弹幕'
              : notices.join('；'),
        );
        final untilMessage = _nextDanmakuAt!.difference(now);
        final delay = !_paceLikes
            ? like != null
                  ? const Duration(seconds: 1)
                  : untilMessage
            : danmaku != null && untilMessage < const Duration(seconds: 10)
            ? untilMessage
            : const Duration(seconds: 10);
        _schedule(delay.isNegative ? Duration.zero : delay);
        return;
      }
      final budget = _budget(chosen);
      // Daily limits count reward rounds. A like task "点赞30次" sends one
      // confirmed 30-click round and verifies one server progress increment.
      final count = _writeCount(chosen);
      final periodKey = _key(chosen);
      bool allowed() => _validRun(epoch) && _key(chosen) == periodKey;
      if (!allowed()) return;
      var message = _defaultMessage;
      if (chosen.jumpType == 'sendDanmu' && _chooseDanmaku != null) {
        final selected = await _chooseDanmaku(identity, allowed);
        if (!allowed()) return;
        if (selected == null || selected.isEmpty) {
          throw const LiveInteractionException('当前配置没有可发送的任务表情，自动弹幕已暂停');
        }
        message = selected;
      }
      budget
        ..sent += count
        ..pendingCount = count
        ..beforeWriteCount = chosen.currentCount ?? 0
        ..verificationChecks = 0;
      _verification = budget;
      // Durable before the write: reopening/restarting can only reconcile an
      // interrupted request, never submit another copy from the same budget.
      await _persist(budget);
      if (!allowed()) {
        budget
          ..sent -= count
          ..pendingCount = 0;
        if (identical(_verification, budget)) _verification = null;
        await _persist(budget);
        return;
      }
      _show(
        LiveTaskAutomationState.sending,
        chosen.jumpType == 'like' ? '正在完成点赞任务' : '正在发送默认任务弹幕',
      );
      LiveTaskWriteResult result;
      try {
        result = chosen.jumpType == 'like'
            ? await _sendLike(
                count * chosen.actionsPerProgress!,
                identity,
                allowed,
              )
            : await _sendDanmaku(message, identity, allowed);
      } catch (_) {
        result = const LiveTaskWriteResult(
          LiveTaskWriteState.unknown,
          '互动结果未知，正在只读核对任务；不会自动重发',
        );
      }
      if (chosen.jumpType == 'sendDanmu') {
        _nextDanmakuAt = _now().add(_randomDelay());
      } else {
        _cancelLikePreparation();
      }
      switch (result.state) {
        case LiveTaskWriteState.accepted:
        case LiveTaskWriteState.unknown:
          budget.unknown = result.state == LiveTaskWriteState.unknown;
          if (chosen.completionOnly && !budget.unknown) {
            // No numerical server progress exists in the lighting phase.
            // Accepted writes consume the title quota; every next write still
            // begins with a fresh is_done read. Unknown writes remain frozen.
            budget.pendingCount = 0;
            if (identical(_verification, budget)) _verification = null;
          }
          await _persist(budget);
          if (_validRun(epoch)) {
            _show(
              LiveTaskAutomationState.verifying,
              budget.unknown ? '互动结果未知，仅核对任务；不会自动重发' : '互动已提交，正在核对官方任务进度',
            );
            _schedule(const Duration(seconds: 5));
          }
        case LiveTaskWriteState.deferred:
        case LiveTaskWriteState.notSubmitted:
        case LiveTaskWriteState.rejected:
          budget
            ..sent -= count
            ..pendingCount = 0;
          if (identical(_verification, budget)) _verification = null;
          if (result.state == LiveTaskWriteState.rejected ||
              (result.state == LiveTaskWriteState.notSubmitted &&
                  _validRun(epoch))) {
            budget
              ..retryOnMessageChange =
                  result.state == LiveTaskWriteState.notSubmitted &&
                  chosen.jumpType == 'sendDanmu'
              ..halted = result.message.isEmpty
                  ? '互动未提交或被拒绝，自动操作暂停'
                  : result.message;
          }
          await _persist(budget);
          if (_validRun(epoch)) {
            _show(
              result.state == LiveTaskWriteState.deferred
                  ? LiveTaskAutomationState.waiting
                  : LiveTaskAutomationState.paused,
              result.state == LiveTaskWriteState.deferred
                  ? '等待当前手动弹幕发送结束'
                  : budget.halted!,
            );
            _schedule(
              Duration(
                seconds: result.state == LiveTaskWriteState.deferred ? 5 : 30,
              ),
            );
          }
      }
    } catch (error) {
      if (!_disposed && epoch == _epoch && _sameAccount) {
        _show(
          LiveTaskAutomationState.paused,
          error is LiveInteractionException
              ? error.message
              : '官方任务或本地记录暂时无法核对，自动操作暂停',
          '请稍后只读刷新任务',
        );
        _schedule(const Duration(seconds: 30));
      }
    } finally {
      if (writeScope != null) _activeWrites.remove(writeScope);
      _busy = false;
      if (!_disposed) notifyListeners();
      if (_restart && _eligible && _sameAccount) {
        _restart = false;
        _schedule(Duration.zero);
      }
    }
  }

  /// No subsequent write until the submitted count is reflected by the server.
  Future<bool> _verifyPending(int epoch) async {
    final budget = _verification;
    if (budget == null) return false;
    final matches = _tasks.where((task) => _key(task) == budget.key).toList();
    if (matches.isEmpty) {
      // An official transition from a lighting quota to daily rewards confirms
      // that the former phase ended. Its quota must not poison the daily one.
      final completedLightingPhase =
          budget.completionOnly &&
          _tasks.any(
            (task) => task.jumpType == budget.type && task.dailyRewardProgress,
          );
      // Otherwise only a different explicit server period can retire it.
      final newPeriod = _tasks.any(
        (task) =>
            task.jumpType == budget.type &&
            task.period.isNotEmpty &&
            _period(task) != budget.period,
      );
      if (completedLightingPhase || newPeriod) {
        budget.retired = true;
        await _persist(budget);
        _verification = null;
        return false;
      }
    }
    final task = matches.length == 1 ? matches.single : null;
    final observed = task?.currentCount;
    if (task?.completed == true ||
        (observed != null &&
            observed >= budget.beforeWriteCount + budget.pendingCount)) {
      if (observed != null) {
        budget.highestObserved = math.max(budget.highestObserved, observed);
        if (observed == budget.beforeWriteCount + budget.pendingCount) {
          budget.countMappingConfirmed = true;
        }
      }
      budget
        ..pendingCount = 0
        ..halted = null;
      _verification = null;
      await _persist(budget);
      return false;
    }
    budget.verificationChecks = math.min(budget.verificationChecks + 1, 9999);
    final halted = budget.verificationChecks >= 3;
    await _persist(budget);
    if (_disposed || epoch != _epoch || !_sameAccount) return true;
    _show(
      halted
          ? LiveTaskAutomationState.paused
          : LiveTaskAutomationState.verifying,
      halted
          ? '官方任务进度尚未增长，已停止自动发送；仅继续只读核对'
          : budget.unknown
          ? '互动结果未知，仅核对任务；不会自动重发'
          : '等待官方任务进度更新',
    );
    _schedule(Duration(seconds: halted ? 30 : 5));
    return true;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_epoch;
    _cancelLikePreparation();
    _timer?.cancel();
    _timer = null;
    if (_accountListener case final listener?) {
      Accounts.removeMainIdentityChangeListener(listener);
    }
    _productionService?.dispose();
    super.dispose();
  }
}

class _LikePreparation {
  _LikePreparation(this.key, this.clicks, this.observed);
  final String key;
  final int clicks;
  final int? observed;
  int accumulated = 0;
}

class _TaskBudget {
  final String key;
  final String type;
  final String period;
  final int initialRemaining;
  final int target;
  final int actionsPerProgress;
  final bool dailyRewardProgress;
  final bool completionOnly;
  int highestObserved;
  int sent = 0;
  int pendingCount = 0;
  int beforeWriteCount = 0;
  int verificationChecks = 0;
  bool countMappingConfirmed = false;
  bool unknown = false;
  String? halted;
  bool serverCompleted = false;
  bool retired = false;
  bool retryOnMessageChange = false;
  _TaskBudget({
    required this.key,
    required this.type,
    required this.period,
    required this.initialRemaining,
    required int current,
    required this.target,
    required this.actionsPerProgress,
    required this.dailyRewardProgress,
    required this.completionOnly,
  }) : highestObserved = current;
  int get allowance => initialRemaining - sent;

  Map<String, dynamic> get record => {
    'schema': 2,
    'actions_per_progress': actionsPerProgress,
    'daily_reward_progress': dailyRewardProgress,
    'completion_only': completionOnly,
    'type': type,
    'period': period,
    'initial_remaining': initialRemaining,
    'target': target,
    'highest_observed': highestObserved,
    'sent': sent,
    'pending_count': pendingCount,
    'before_write_count': beforeWriteCount,
    'verification_checks': verificationChecks,
    'count_mapping_confirmed': countMappingConfirmed,
    'server_completed': serverCompleted,
    'retired': retired,
    // Never store credentials or the user's default/public message.
    'unknown': unknown,
    'halted': halted,
    'retry_on_message_change': retryOnMessageChange,
  };

  factory _TaskBudget.restore(String key, Map<String, dynamic> record) {
    int value(String name) {
      final parsed = liveInt(record[name]);
      if (parsed == null || parsed < 0 || parsed > 10000) {
        throw const LiveInteractionException('本地任务记录无法核对，自动操作暂停');
      }
      return parsed;
    }

    final type = record['type'];
    final period = record['period'];
    if (!{1, 2}.contains(record['schema']) ||
        !{'like', 'sendDanmu'}.contains(type) ||
        period is! String) {
      throw const LiveInteractionException('本地任务记录无法核对，自动操作暂停');
    }
    final initial = value('initial_remaining');
    final target = value('target');
    final sent = value('sent');
    final pending = value('pending_count');
    final before = value('before_write_count');
    final actionsPerProgress = record['schema'] == 1
        ? 1
        : value('actions_per_progress');
    final dailyRewardProgress = record['daily_reward_progress'] == true;
    final completionOnly = record['completion_only'] == true;
    if (initial > target ||
        sent > initial ||
        pending > sent ||
        before + pending > target ||
        actionsPerProgress <= 0 ||
        actionsPerProgress > 1000 ||
        pending >
            (type == 'like' && !dailyRewardProgress && !completionOnly
                ? 5
                : 1)) {
      throw const LiveInteractionException('本地任务记录无法核对，自动操作暂停');
    }
    return _TaskBudget(
        key: key,
        type: type as String,
        period: period,
        initialRemaining: initial,
        current: value('highest_observed'),
        target: target,
        actionsPerProgress: actionsPerProgress,
        dailyRewardProgress: dailyRewardProgress,
        completionOnly: completionOnly,
      )
      ..sent = sent
      ..pendingCount = pending
      ..beforeWriteCount = before
      ..verificationChecks = value('verification_checks')
      ..countMappingConfirmed = record['count_mapping_confirmed'] == true
      ..serverCompleted = record['server_completed'] == true
      ..retired = record['retired'] == true
      ..retryOnMessageChange = record['retry_on_message_change'] == true
      ..unknown = true
      ..halted = record['halted'] as String?;
  }
}

class _MemoryTaskJournal implements LiveInteractionJournal {
  final Map<String, Map<String, dynamic>> _records = {};
  @override
  Future<Map<String, dynamic>?> read(String key) async => _records[key];
  @override
  Future<void> write(String key, Map<String, dynamic> record) async {
    _records[key] = Map.of(record);
  }
}

class _HiveTaskJournal implements LiveInteractionJournal {
  static Future<Box<dynamic>>? _box;
  Future<Box<dynamic>> get box =>
      _box ??= Hive.openBox<dynamic>('liveTaskAutomationJournal');
  @override
  Future<Map<String, dynamic>?> read(String key) async {
    final storage = await box;
    if (!storage.containsKey(key)) return null;
    final value = storage.get(key);
    if (value is! Map) {
      throw const LiveInteractionException('本地任务记录无法核对，自动操作暂停');
    }
    return liveMap(value);
  }

  @override
  Future<void> write(String key, Map<String, dynamic> record) async {
    final storage = await box;
    await storage.put(key, record);
    await storage.flush();
  }
}

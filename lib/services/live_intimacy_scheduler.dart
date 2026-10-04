// Injection callbacks use public names in tests and private storage internally.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:math' as math;

import 'package:PiliPlus/services/live_automation_coordinator.dart';
import 'package:PiliPlus/services/live_intimacy_audio_session.dart';
import 'package:PiliPlus/services/live_intimacy_discovery.dart';
import 'package:PiliPlus/services/live_intimacy_watch_progress.dart';
import 'package:PiliPlus/services/live_intimacy_interaction_session.dart';
import 'package:PiliPlus/services/live_intimacy_record_store.dart';
import 'package:PiliPlus/services/live_intimacy_official_cycle.dart';
import 'package:PiliPlus/services/live_task_automation.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/saved_account_profile.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:PiliPlus/utils/live_viewer_preferences.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';

export 'package:PiliPlus/services/live_intimacy_watch_progress.dart';

class LiveIntimacyAccount {
  final int uid;
  final Object identity;
  final int generation;
  final bool loggedIn;
  final String? privacyReason;
  const LiveIntimacyAccount({
    required this.uid,
    required this.identity,
    required this.generation,
    required this.loggedIn,
    this.privacyReason,
  });
}

class LiveIntimacyRoomState {
  LiveIntimacyRoomState(this.preferences, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  LiveIntimacyRoomPreferences preferences;
  LiveIntimacyCandidate? candidate;
  List<LiveFanTask> tasks = const [];
  final watchProgress = LiveIntimacyWatchProgress();
  final officialCycle = LiveIntimacyOfficialCycle();
  bool get periodConfirmed =>
      officialCycle.confirmed &&
      (preferences.mode == LiveIntimacyRoomMode.likeOnly ||
          watchProgress.periodConfirmed);
  String? pauseReason;
  bool running = false;
  bool completed = false;
  bool interactionRunning = false;
  bool get canAdvanceInteraction =>
      interactionRunning &&
      officialFresh &&
      interactionPauseReason == null &&
      pauseReason == null &&
      (preferences.automation.autoLike && _knownPendingInteraction('like') ||
          preferences.mode == LiveIntimacyRoomMode.full &&
              preferences.automation.autoDanmaku &&
              _knownPendingInteraction('sendDanmu'));
  bool _knownPendingInteraction(String type) {
    final matches = tasks.where((task) => task.jumpType == type).toList();
    if (matches.length != 1) return false;
    final task = matches.single;
    return task.completed == false &&
        (task.remainingCount ?? 0) > 0 &&
        task.actionsPerProgress != null &&
        task.actionsPerProgress! > 0 &&
        task.actionsPerProgress! <= 1000 &&
        (task.targetCount ?? 10001) <= 10000;
  }

  bool watchRunning = false;
  String? interactionPauseReason;
  String? watchPauseReason;
  String? recordSaveError;
  String? recordRestoreError;
  bool _officialFresh = false;
  DateTime? _freshUntil;
  bool get officialFresh =>
      _officialFresh && _freshUntil != null && _now().isBefore(_freshUntil!);
  set officialFresh(bool value) {
    _officialFresh = value;
    _freshUntil = value ? _now().add(const Duration(minutes: 5)) : null;
  }

  bool? medalLighted;
  DateTime? _nextSyncAt;
  DateTime? _readRetryAt;
  bool get authorizedTasksCompleted =>
      officialFresh &&
      periodConfirmed &&
      (preferences.mode == LiveIntimacyRoomMode.likeOnly
          ? liveIntimacyTaskCompleted(tasks, 'like')
          : completed && watchProgress.periodConfirmed);
  bool get allTasksCompletedConfirmed =>
      completed &&
      officialFresh &&
      watchProgress.periodConfirmed &&
      officialCycle.confirmedFor(const ['like', 'sendDanmu', 'watchLive']);
  int _failures = 0;
  DateTime? _retryAt;
  int? get medalLevel => candidate?.medalLevel;
  bool? get live => candidate?.live;
  bool? get followed => candidate?.followed;
  bool? get medalOwned => candidate?.medalOwned;
  int get roomId => candidate?.roomId ?? preferences.roomId;
  int get anchorUid => preferences.anchorUid;
  String get anchorName => candidate?.anchorName.isNotEmpty == true
      ? candidate!.anchorName
      : preferences.anchorName;
  String get statusText =>
      pauseReason ??
      watchPauseReason ??
      interactionPauseReason ??
      recordRestoreError ??
      recordSaveError ??
      (allTasksCompletedConfirmed
          ? '今日三项任务已确认完成'
          : running
          ? '正在执行'
          : '等待执行');
}

typedef LiveIntimacySessionFactory = LiveIntimacyTaskSession Function(
  LiveIntimacyRoomPreferences configuration,
  LiveIntimacyCandidate candidate,
  LiveIntimacyWatchProgress progress,
  bool Function() stillAllowed,
);

class _PendingRecordSave {
  _PendingRecordSave(this.room, this.uid, this.record)
    : anchorUid = room.anchorUid,
      roomId = room.preferences.roomId;
  final LiveIntimacyRoomState room;
  final int uid;
  final int anchorUid;
  final int roomId;
  final Map<String, dynamic> record;
}

typedef LiveIntimacyInteractionFactory =
    LiveIntimacyInteractionSession Function(
      LiveIntimacyRoomPreferences configuration,
      Future<LiveFanTaskSnapshot> Function() readTasks,
      bool Function() stillAllowed,
    );

/// A single application-level owner. Foreground playback only supplies a
/// priority hint; it never supplies authorization or the background clock.
class LiveIntimacyScheduler extends ChangeNotifier {
  factory LiveIntimacyScheduler.production() {
    final value = LiveIntimacyScheduler.testing(
      account: _productionAccount,
      readPreferences: Pref.liveIntimacyPreferencesFor,
      writePreferences: Pref.saveLiveIntimacyPreferencesFor,
      discovery: LiveIntimacyDiscovery.production(),
      createSession: (configuration, candidate, progress, allowed) =>
          LiveIntimacyAudioSession(
            preferences: configuration,
            candidate: candidate,
            watchProgress: progress,
            stillAllowed: allowed,
          ),
      loadEmoticons: (room) async {
        final interaction = LiveInteractionService(
          roomId: room.roomId,
          anchorUid: room.anchorUid,
        );
        try {
          return await interaction.loadTaskEmoticons();
        } finally {
          interaction.dispose();
        }
      },
      readTasks: (room) async {
        final interaction = LiveInteractionService(
          roomId: room.roomId,
          anchorUid: room.anchorUid,
        );
        try {
          return await interaction.loadFanTasks();
        } finally {
          interaction.dispose();
        }
      },
      coordinator: LiveAutomationCoordinator.instance,
      recordStore: HiveLiveIntimacyRecordStore(),
      createInteraction: (configuration, read, allowed) =>
          LiveIntimacyRoomInteractionSession(
            preferences: configuration,
            readTasks: read,
            stillAllowed: allowed,
          ),
    ).._production = true;
    return value;
  }

  LiveIntimacyScheduler.testing({
    required LiveIntimacyAccount Function() account,
    required LiveIntimacyPreferences Function(int) readPreferences,
    required Future<void> Function(int, LiveIntimacyPreferences)
    writePreferences,
    required LiveIntimacyDiscoverySource discovery,
    required LiveIntimacySessionFactory createSession,
    required Future<List<LiveTaskEmoticonOption>> Function(
      LiveIntimacyRoomPreferences,
    )
    loadEmoticons,
    Future<LiveFanTaskSnapshot> Function(LiveIntimacyRoomPreferences)?
    readTasks,
    LiveAutomationCoordinator? coordinator,
    DateTime Function()? now,
    this.automaticTimers = true,
    LiveIntimacyRecordStore? recordStore,
    LiveIntimacyInteractionFactory? createInteraction,
    int Function(int)? randomInt,
  }) : _account = account,
       _readPreferences = readPreferences,
       _writePreferences = writePreferences,
       _discovery = discovery,
       _createSession = createSession,
       _loadEmoticons = loadEmoticons,
       _readTasks = readTasks,
       _coordinator = coordinator ?? LiveAutomationCoordinator(),
       _now = now ?? DateTime.now,
       _records = recordStore ?? MemoryLiveIntimacyRecordStore(),
       _createInteraction = createInteraction,
       _randomInt = randomInt ?? math.Random().nextInt;

  static final instance = LiveIntimacyScheduler.production();
  final LiveIntimacyAccount Function() _account;
  final LiveIntimacyPreferences Function(int) _readPreferences;
  final Future<void> Function(int, LiveIntimacyPreferences) _writePreferences;
  final LiveIntimacyDiscoverySource _discovery;
  final LiveIntimacySessionFactory _createSession;
  final Future<List<LiveTaskEmoticonOption>> Function(
    LiveIntimacyRoomPreferences,
  )
  _loadEmoticons;
  final Future<LiveFanTaskSnapshot> Function(LiveIntimacyRoomPreferences)?
  _readTasks;
  final LiveAutomationCoordinator _coordinator;
  final DateTime Function() _now;
  final bool automaticTimers;
  final LiveIntimacyRecordStore _records;
  final LiveIntimacyInteractionFactory? _createInteraction;
  final int Function(int) _randomInt;
  final Map<int, LiveIntimacyInteractionSession> _interactions = {};
  final Map<int, Future<LiveFanTaskSnapshot>> _taskReads = {};
  final Set<String> _restoredRecords = {};
  final Map<String, Future<void>> _recordReads = {};
  final Map<int, LiveFanTaskSnapshot> _snapshots = {};
  final Map<String, Future<void>> _recordWrites = {};
  final Map<String, _PendingRecordSave> _pendingRecordSaves = {};
  final Set<int> _clearingAccounts = {};
  final Map<int, Future<void>> _accountClears = {};
  Timer? _interactionTimer;
  bool _interactionBusy = false;
  DateTime? _nextLikeAt;
  DateTime? _nextDanmakuAt;
  DateTime? _observedDanmakuAt;
  int? _lastLikeAnchor;
  int? _lastDanmakuAnchor;
  DateTime? _lastDiscoveryAt;
  List<LiveIntimacyCandidate> _found = const [];
  LiveIntimacyRoomState? _interactionRoom;
  DateTime? _lastPersistAt;
  bool _production = false;
  bool _started = false;
  bool _disposed = false;
  bool _busy = false;
  bool _restart = false;
  int _epoch = 0;
  LiveIntimacyAccount? _bound;
  LiveIntimacyPreferences _preferences = const LiveIntimacyPreferences();
  final Map<int, LiveIntimacyRoomState> _states = {};
  LiveIntimacyRoomState? _current;
  LiveIntimacyTaskSession? _session;
  int? _sessionAccountUid;
  Object? _watchOwner;
  List<LiveIntimacyRoomState> _queue = const [];
  String _status = '后台亲密度任务已关闭';
  String? _suspendedReason;
  bool _discoveryReliable = false;
  int? _foregroundRoom;
  int? _foregroundAnchor;
  Timer? _timer;
  Timer? _identityPoll;
  StreamSubscription<dynamic>? _settings;
  Future<void>? _shutdownFuture;
  final Set<Future<void>> _closingSessions = {};
  final Set<Future<void>> _closingInteractions = {};
  bool _notifierDisposed = false;
  Future<void>? _tickOperation;
  Future<void>? _manualRefresh;

  LiveIntimacyPreferences get preferences => _preferences;
  List<LiveIntimacyRoomState> get rooms => List.unmodifiable(_states.values);
  List<LiveIntimacyRoomState> get queue => _queue;
  LiveIntimacyRoomState? get currentRoom => _current;
  LiveIntimacyRoomState? get currentInteractionRoom =>
      _interactionRoom?.canAdvanceInteraction == true ? _interactionRoom : null;
  List<LiveIntimacyRoomState> get interactionQueue => List.unmodifiable(
    _sortedStates().where(_interactionEligible),
  );
  bool get discoveryReliable => _discoveryReliable;
  bool get discoveryComplete =>
      _discoveryReliable &&
      (_discovery is! LiveIntimacyDiscoveryDiagnostics ||
          (_discovery as LiveIntimacyDiscoveryDiagnostics).complete);
  String? get suspendedReason => _suspendedReason ?? _account().privacyReason;
  String? get persistenceError =>
      rooms.any((room) => room.recordRestoreError != null)
      ? '部分本地观时记录尚未恢复，请重试'
      : _pendingRecordSaves.values.any(
          (save) => save.uid == accountUid && save.room.recordSaveError != null,
        )
      ? '部分观时记录尚未保存，请重试；停止和切房不受影响'
      : null;
  int get pendingRecordSaveCount => _pendingRecordSaves.values
      .where(
        (save) => save.uid == accountUid && save.room.recordSaveError != null,
      )
      .length;
  String get statusText =>
      _inactiveReason == null &&
          _session == null &&
          rooms.any((room) => room.canAdvanceInteraction)
      ? '正在执行互动任务；当前没有运行中的观时任务'
      : _status;
  int get accountUid => _account().loggedIn ? _account().uid : 0;
  int get accountGeneration => _account().generation;
  bool get isLoggedIn => _account().loggedIn;
  bool get ownsWatchReporter =>
      _watchOwner != null && _coordinator.owns(_watchOwner!);
  LiveIntimacyRoomState? stateFor(int roomId, int anchorUid) {
    final state = _states[anchorUid];
    return state != null &&
            (state.roomId == roomId || state.preferences.roomId == roomId)
        ? state
        : null;
  }

  static LiveIntimacyAccount _productionAccount() {
    final owner = Accounts.main;
    final recording = Accounts.heartbeat;
    final reason = Accounts.mainIdentityChangeInProgress
        ? '账号正在变化，后台亲密度已暂停'
        : !owner.isLogin
        ? '登录后可启用后台亲密度'
        : owner is LoginAccount &&
              owner.profile.loginState == SavedAccountLoginState.expired
        ? '当前账号登录已失效，请重新登录'
        : Pref.historyPause
        ? '已暂停记录观看，请调整设置后继续'
        : !recording.isLogin
        ? '匿名观看与亲密度任务冲突，请调整设置后继续'
        : !identical(owner, recording)
        ? '观看账号与任务账号不同，后台亲密度已暂停'
        : null;
    return LiveIntimacyAccount(
      uid: owner.isLogin ? owner.mid : 0,
      identity: owner,
      generation: Accounts.mainChangeGeneration,
      loggedIn: owner.isLogin,
      privacyReason: reason,
    );
  }

  bool _sameAccount(LiveIntimacyAccount left, LiveIntimacyAccount right) =>
      left.uid == right.uid &&
      left.generation == right.generation &&
      identical(left.identity, right.identity) &&
      left.loggedIn == right.loggedIn;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    if (automaticTimers) {
      _interactionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        unawaited(_interactionPulse());
      });
    }
    if (_production) {
      _settings = GStorage.setting.watch().listen((_) => _synchronize());
      Accounts.addMainIdentityChangeListener(_beforeIdentityChange);
      Accounts.addMainIdentitySettledListener(_synchronize);
      Accounts.addAccountRoleChangeListener(_synchronize);
      _identityPoll = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _synchronize(),
      );
    }
    _synchronize();
  }

  Future<void> _beforeIdentityChange() async {
    _invalidate();
    _discoveryReliable = false;
    _status = '账号正在变化，旧账号任务已取消';
    await _stopInteractions();
    await _stopCurrent();
    await _tickOperation;
    _notify();
  }

  void _synchronize() {
    if (_disposed) return;
    final account = _account();
    final identityChanged = _bound == null || !_sameAccount(_bound!, account);
    final next = _readPreferences(account.loggedIn ? account.uid : 0);
    final changed =
        identityChanged ||
        next != _preferences ||
        account.privacyReason != _bound?.privacyReason;
    if (!changed) return;
    _invalidate();
    if (identityChanged) {
      unawaited(_persistAll());
      unawaited(_stopInteractions());
      _restoredRecords.clear();
      _taskReads.clear();
      _snapshots.clear();
      _nextLikeAt = null;
      _nextDanmakuAt = null;
      _observedDanmakuAt = null;
      _lastLikeAnchor = null;
      _lastDanmakuAnchor = null;
      for (final state in _states.values) {
        state.watchProgress.dispose();
      }
      _states.clear();
    }
    _bound = account;
    _preferences = next;
    _syncStates();
    final restoreEpoch = _epoch;
    unawaited(() async {
      for (final state in _states.values.toList()) {
        await _restoreRecord(state, account, restoreEpoch);
      }
      if (!_disposed &&
          restoreEpoch == _epoch &&
          _sameAccount(account, _account())) {
        _notify();
      }
    }());
    _discoveryReliable = false;
    _lastDiscoveryAt = null;
    unawaited(
      _stopCurrent().then((_) {
        if (!_disposed) {
          _notify();
          _schedule(Duration.zero);
        }
      }),
    );
    _status = _inactiveReason ?? '正在核对后台任务房间';
    _notify();
  }

  String? get _readInactiveReason {
    final account = _account();
    if (_suspendedReason != null) return _suspendedReason;
    if (!account.loggedIn || account.uid <= 0) return '登录后可启用后台亲密度';
    if (account.privacyReason != null) return account.privacyReason;
    if (_clearingAccounts.contains(account.uid)) return '正在清除此账号的任务记录，任务已暂停';
    return null;
  }

  String? get _inactiveReason =>
      _readInactiveReason ?? (!_preferences.enabled ? '后台亲密度任务已关闭' : null);

  void _syncStates() {
    final selected = <int>{};
    for (final room in _preferences.rooms) {
      if (!selected.add(room.anchorUid)) continue;
      final state = _states.putIfAbsent(
        room.anchorUid,
        () => LiveIntimacyRoomState(room, now: _now),
      );
      if (state.preferences != room) {
        state
          ..pauseReason = null
          .._retryAt = null
          .._failures = 0;
      }
      state.preferences = room;
    }
    _states.removeWhere((uid, state) {
      if (selected.contains(uid)) return false;
      state.watchProgress.dispose();
      return true;
    });
  }

  void _invalidate() {
    ++_epoch;
    unawaited(_stopInteractions());
    _timer?.cancel();
    _timer = null;
    _discovery.cancel();
    _lastDiscoveryAt = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _schedule(Duration delay) {
    if (_disposed || !_started || !automaticTimers) return;
    if (_busy) {
      _restart = true;
      return;
    }
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(_tick());
    });
  }

  void updateForeground({int? roomId, int? anchorUid, bool playing = true}) {
    if (_disposed) return;
    final room = playing ? roomId : null;
    final anchor = playing ? anchorUid : null;
    if (_foregroundRoom == room && _foregroundAnchor == anchor) return;
    _foregroundRoom = room;
    _foregroundAnchor = anchor;
    _lastLikeAnchor = null;
    _lastDanmakuAnchor = null;
    final preferred = _states[anchor];
    if (preferred != null &&
        preferred != _current &&
        preferred.roomId == room &&
        preferred.preferences.authorized &&
        preferred.candidate?.eligible == true &&
        preferred.pauseReason == null &&
        (preferred._retryAt == null || !_now().isBefore(preferred._retryAt!)) &&
        !preferred.completed &&
        preferred.preferences.mode == LiveIntimacyRoomMode.full &&
        !liveIntimacyTaskCompleted(preferred.tasks, 'watchLive') &&
        preferred.preferences.configurationIssue() == null) {
      _invalidate();
      unawaited(_stopCurrent().then((_) => _schedule(Duration.zero)));
    }
    _schedule(Duration.zero);
  }

  Future<void> suspend([String reason = '系统休眠，后台亲密度已暂停']) async {
    if (_disposed) return;
    _suspendedReason = reason;
    _invalidate();
    _status = reason;
    await _stopInteractions();
    await _stopCurrent();
    await _tickOperation;
    _notify();
  }

  void resume() {
    if (_disposed || _suspendedReason == null) return;
    _suspendedReason = null;
    _invalidate();
    _discoveryReliable = false;
    _schedule(Duration.zero);
  }

  Future<void> savePreferences(LiveIntimacyPreferences value) async {
    // Changing the application switch cannot create a room authorization.
    final normalized = LiveIntimacyPreferences.fromJson(value.toJson());
    final rooms = normalized.rooms
        .map(
          (room) =>
              room.authorized &&
                  !_preferences.rooms.any(
                    (old) =>
                        old.authorized &&
                        old.anchorUid == room.anchorUid &&
                        old.roomId == room.roomId,
                  )
              ? room.copyWith(authorized: false)
              : room,
        )
        .toList();
    await _store(normalized.copyWith(rooms: rooms));
  }

  Future<void> saveRoomPreferences(LiveIntimacyRoomPreferences room) async {
    final old = _preferences.rooms
        .where((entry) => entry.anchorUid == room.anchorUid)
        .firstOrNull;
    final safe = room.copyWith(
      roomId: old?.roomId ?? room.roomId,
      authorized: old?.authorized == true && old!.mode == room.mode,
    );
    await _store(
      _preferences.copyWith(
        rooms: [
          ..._preferences.rooms.where(
            (entry) => entry.anchorUid != room.anchorUid,
          ),
          safe,
        ],
      ),
    );
  }

  Future<String?> authorizeRoom(
    LiveIntimacyRoomPreferences room,
    bool enabled,
  ) async {
    final account = _account();
    final authorizationEpoch = _epoch;
    bool authorizationCurrent() =>
        !_disposed &&
        authorizationEpoch == _epoch &&
        _sameAccount(account, _account()) &&
        _foregroundRoom == room.roomId &&
        _foregroundAnchor == room.anchorUid;
    if (!account.loggedIn || account.uid <= 0) return '请先登录有效账号';
    if (enabled &&
        (_foregroundRoom != room.roomId ||
            _foregroundAnchor != room.anchorUid)) {
      return '请在此直播间手动开启授权';
    }
    if (!enabled) {
      await _store(
        _preferences.copyWith(
          rooms: [
            ..._preferences.rooms.where(
              (entry) => entry.anchorUid != room.anchorUid,
            ),
            room.copyWith(authorized: false),
          ],
        ),
      );
      return null;
    }
    final issue = room.configurationIssue();
    if (issue != null) return issue;
    try {
      final candidate = await _discovery.recheck(room);
      if (!authorizationCurrent()) return '账号、配置或当前房间已变化，请重新授权';
      if (!candidate.followed || !candidate.medalOwned) return '需已关注主播并拥有粉丝勋章';
      var canonical = room.copyWith(roomId: candidate.roomId);
      if (canonical.mode == LiveIntimacyRoomMode.full &&
          canonical.automation.danmakuMode == LiveTaskDanmakuMode.emoticon) {
        final options = await _loadEmoticons(canonical);
        if (!authorizationCurrent()) return '账号、配置或当前房间已变化，请重新授权';
        final unavailable = canonical.configurationIssue(
          availableEmoticons: options
              .where((option) => option.available)
              .map((option) => option.unique),
        );
        if (unavailable != null) return unavailable;
      }
      // This explicit operation alone can turn a room authorization on.
      canonical = canonical.copyWith(authorized: true);
      await _store(
        _preferences.copyWith(
          rooms: [
            ..._preferences.rooms.where(
              (entry) => entry.anchorUid != room.anchorUid,
            ),
            canonical,
          ],
        ),
      );
      return null;
    } catch (error) {
      return error is LiveInteractionException
          ? error.message
          : '资格或表情权限暂时无法确认';
    }
  }

  Future<void> removeRoom(int roomId, int anchorUid) => _store(
    _preferences.copyWith(
      rooms: _preferences.rooms
          .where(
            (room) => !(room.anchorUid == anchorUid && room.roomId == roomId),
          )
          .toList(),
    ),
  );

  Future<void> _store(LiveIntimacyPreferences value) async {
    if (_disposed) return;
    final account = _account();
    if (!account.loggedIn ||
        account.uid <= 0 ||
        _bound == null ||
        !_sameAccount(account, _bound!)) {
      return;
    }
    _invalidate();
    _preferences = value;
    _syncStates();
    _discoveryReliable = false;
    _status = _inactiveReason ?? '配置已保存，正在核对任务';
    final stopped = _stopCurrent();
    final stoppedInteractions = _stopInteractions();
    _notify();
    try {
      await _writePreferences(account.uid, value);
    } finally {
      // Stopping begins before preference storage. Its failure cannot leave
      // unobserved cleanup futures or retain the background watch claim.
      await Future.wait([stopped, stoppedInteractions]);
    }
    if (!_disposed && _sameAccount(account, _account())) {
      _schedule(Duration.zero);
    }
  }

  /// A UI refresh reads state; it never resets budgets or directly submits an
  /// interaction. The independently enabled timer performs later execution.
  Future<void> refresh() {
    final pending = _manualRefresh;
    if (pending != null) return pending;
    late final Future<void> operation;
    operation =
        () async {
          _synchronize();
          await _tickOperation;
          if (_disposed) return;
          _synchronize();
          _lastDiscoveryAt = null;
          await _tick(readOnly: true);
        }().whenComplete(() {
          if (identical(_manualRefresh, operation)) _manualRefresh = null;
        });
    _manualRefresh = operation;
    return operation;
  }

  @visibleForTesting
  Future<void> tickForTesting() async {
    if (!_started) start();
    _synchronize();
    await _tick();
  }

  @visibleForTesting
  Future<void> interactionTickForTesting() => _interactionPulse();

  bool _valid(int epoch, LiveIntimacyAccount account) =>
      _validRead(epoch, account) && _preferences.enabled;

  bool _validRead(int epoch, LiveIntimacyAccount account) =>
      !_disposed &&
      epoch == _epoch &&
      _sameAccount(account, _account()) &&
      _readInactiveReason == null;

  bool _roomAllowed(
    int epoch,
    LiveIntimacyAccount account,
    LiveIntimacyRoomState room,
    Object owner,
  ) {
    if (!_valid(epoch, account) ||
        !_discoveryReliable ||
        !_coordinator.owns(owner)) {
      return false;
    }
    // Read persisted switches at the final dispatch boundary. Settings events
    // and the identity fallback timer are not safety gates for a pending write.
    final latest = _readPreferences(account.uid);
    final configured = latest.rooms
        .where((entry) => entry.anchorUid == room.anchorUid)
        .firstOrNull;
    return latest.enabled &&
        configured?.authorized == true &&
        configured!.configurationIssue() == null &&
        configured == room.preferences &&
        room.candidate?.eligible == true &&
        !room.officialCycle.uncertain &&
        room.pauseReason == null &&
        room.watchPauseReason == null &&
        configured.mode == LiveIntimacyRoomMode.full &&
        _watchPending(room.tasks);
  }

  List<LiveIntimacyRoomState> _candidates() {
    final now = _now();
    final result =
        _states.values
            .where(
              (state) =>
                  state.preferences.authorized &&
                  state.preferences.configurationIssue() == null &&
                  state.candidate?.eligible == true &&
                  !state.officialCycle.uncertain &&
                  state.pauseReason == null &&
                  state.preferences.mode == LiveIntimacyRoomMode.full &&
                  _watchPending(state.tasks) &&
                  (state._retryAt == null || !now.isBefore(state._retryAt!)),
            )
            .toList()
          ..sort((left, right) {
            final leftPriority =
                left.roomId == _foregroundRoom &&
                left.anchorUid == _foregroundAnchor;
            final rightPriority =
                right.roomId == _foregroundRoom &&
                right.anchorUid == _foregroundAnchor;
            if (leftPriority != rightPriority) return leftPriority ? -1 : 1;
            final levels = (left.medalLevel ?? 0).compareTo(
              right.medalLevel ?? 0,
            );
            if (levels != 0) {
              return _preferences.sort == LiveIntimacySort.medalHighToLow
                  ? -levels
                  : levels;
            }
            return left.anchorUid.compareTo(right.anchorUid);
          });
    return result;
  }

  bool _watchPending(List<LiveFanTask> tasks) {
    final watches = tasks
        .where((task) => task.jumpType == 'watchLive')
        .toList();
    return watches.length == 1 && watches.single.completed == false;
  }

  List<LiveIntimacyRoomState> _sortedStates() {
    final result = _states.values.toList()
      ..sort((left, right) {
        final leftPriority =
            left.roomId == _foregroundRoom &&
            left.anchorUid == _foregroundAnchor;
        final rightPriority =
            right.roomId == _foregroundRoom &&
            right.anchorUid == _foregroundAnchor;
        if (leftPriority != rightPriority) return leftPriority ? -1 : 1;
        final levels = (left.medalLevel ?? 0).compareTo(right.medalLevel ?? 0);
        if (levels != 0) {
          return _preferences.sort == LiveIntimacySort.medalHighToLow
              ? -levels
              : levels;
        }
        return left.anchorUid.compareTo(right.anchorUid);
      });
    return result;
  }

  bool _interactionEligible(LiveIntimacyRoomState room) =>
      room.preferences.authorized &&
      room.preferences.configurationIssue() == null &&
      room.candidate?.eligible == true &&
      !room.officialCycle.uncertain &&
      room.pauseReason == null &&
      (!liveIntimacyTaskCompleted(room.tasks, 'like') ||
          (room.preferences.mode == LiveIntimacyRoomMode.full &&
              !liveIntimacyTaskCompleted(room.tasks, 'sendDanmu')));

  bool _interactionAllowed(
    int epoch,
    LiveIntimacyAccount account,
    LiveIntimacyRoomState room,
  ) {
    if (!_valid(epoch, account) || !_discoveryReliable) return false;
    final latest = _readPreferences(account.uid);
    final configured = latest.roomFor(room.preferences.roomId, room.anchorUid);
    return latest.enabled &&
        configured?.authorized == true &&
        configured == room.preferences &&
        configured!.configurationIssue() == null &&
        room.candidate?.eligible == true &&
        !room.officialCycle.uncertain &&
        room.pauseReason == null;
  }

  Future<void> _restoreRecord(
    LiveIntimacyRoomState room,
    LiveIntimacyAccount account,
    int epoch,
  ) {
    final key = '${account.uid}:${room.anchorUid}:${room.preferences.roomId}';
    final pending = _recordReads[key];
    if (pending != null) return pending;
    if (_restoredRecords.contains(key)) return Future.value();
    late final Future<void> operation;
    operation = Future<void>.microtask(() async {
      try {
        var unsaved = _pendingRecordSaves[key];
        final stored = await (unsaved != null
            ? Future<Map<String, dynamic>?>.value(unsaved.record)
            : _records.read(
                account.uid,
                room.anchorUid,
                room.preferences.roomId,
              ));
        // A→B→A while storage remains unavailable must resume A's latest
        // in-memory ledger, rather than overwrite it with an older disk copy.
        unsaved = _pendingRecordSaves[key] ?? unsaved;
        final record = unsaved?.record ?? stored;
        if (_disposed ||
            epoch != _epoch ||
            !_sameAccount(account, _account())) {
          return;
        }
        if (record != null) {
          room.watchProgress.restore(record['watch']);
          room.officialCycle.restore(record['cycle']);
          room.tasks = List.unmodifiable(
            liveMaps(record['tasks']).map(liveIntimacyTaskFromRecord),
          );
          room
            ..completed = liveIntimacyTasksCompleted(room.tasks)
            ..officialFresh = false
            ..recordSaveError = unsaved?.room.recordSaveError;
        }
        room.recordRestoreError = null;
        _restoredRecords.add(key);
      } catch (_) {
        if (!_disposed &&
            epoch == _epoch &&
            _sameAccount(account, _account())) {
          room
            ..recordRestoreError = '本地观时记录读取失败，此房间等待恢复后继续'
            ..officialFresh = false;
          _notify();
        }
      } finally {
        if (identical(_recordReads[key], operation)) _recordReads.remove(key);
      }
    });
    _recordReads[key] = operation;
    return operation;
  }

  Future<void> _persistRoom(LiveIntimacyRoomState room, int uid) async {
    if (uid <= 0 ||
        _clearingAccounts.contains(uid) ||
        room.recordRestoreError != null) {
      return;
    }
    final record = <String, dynamic>{
      'schema': 1,
      'watch': room.watchProgress.toJson(),
      'tasks': room.tasks.map(liveIntimacyTaskRecord).toList(),
      'cycle': room.officialCycle.toJson(),
    };
    final pending = _PendingRecordSave(room, uid, record);
    final key = '$uid:${pending.anchorUid}:${pending.roomId}';
    _pendingRecordSaves[key] = pending;
    await _saveRecord(key, pending);
  }

  Future<void> _saveRecord(String key, _PendingRecordSave pending) async {
    final previous = _recordWrites[key];
    final write = () async {
      await previous;
      // A failed older write can be superseded by a later captured snapshot.
      if (_clearingAccounts.contains(pending.uid) ||
          !identical(_pendingRecordSaves[key], pending)) {
        return;
      }
      try {
        await _records.write(
          pending.uid,
          pending.anchorUid,
          pending.roomId,
          pending.record,
        );
        if (identical(_pendingRecordSaves[key], pending)) {
          _pendingRecordSaves.remove(key);
          pending.room.recordSaveError = null;
          final current = _states[pending.anchorUid];
          if (_bound?.uid == pending.uid &&
              current?.preferences.roomId == pending.roomId) {
            current!.recordSaveError = null;
          }
        }
      } catch (_) {
        // Local persistence failure must not block reporter release, account
        // changes or other room actions. Keep the exact captured UID snapshot
        // for a bounded explicit/periodic retry; do not call it synchronized.
        pending.room.recordSaveError = '本地观时记录保存失败，尚未保存的记录等待重试';
      }
      _notify();
    }();
    _recordWrites[key] = write;
    try {
      await write;
    } finally {
      if (identical(_recordWrites[key], write)) {
        _recordWrites.remove(key);
      }
    }
  }

  Future<void> retryRecordSaves() async {
    final account = _account();
    for (final room in _states.values.toList()) {
      if (room.recordRestoreError != null &&
          !_clearingAccounts.contains(account.uid)) {
        await _restoreRecord(room, account, _epoch);
      }
    }
    final pending = Map.of(_pendingRecordSaves);
    await Future.wait(
      pending.entries.map((entry) => _saveRecord(entry.key, entry.value)),
    );
    _schedule(Duration.zero);
    _notify();
  }

  Future<void> _persistAll() async {
    final uid = _bound?.uid ?? 0;
    await Future.wait(_states.values.map((room) => _persistRoom(room, uid)));
    await retryRecordSaves();
  }

  Future<LiveFanTaskSnapshot> _synchronizeRoom(
    LiveIntimacyRoomState room,
    int epoch,
    LiveIntimacyAccount account, {
    bool force = false,
    bool readOnly = false,
  }) {
    bool valid() =>
        readOnly ? _validRead(epoch, account) : _valid(epoch, account);
    final pending = _taskReads[room.anchorUid];
    if (pending != null) return pending;
    if (room._readRetryAt != null && _now().isBefore(room._readRetryAt!)) {
      return Future.error(
        LiveInteractionException(
          room.watchProgress.syncError ?? '官方任务暂时无法核对，请稍后重试',
        ),
      );
    }
    final cached = _snapshots[room.anchorUid];
    if (!force &&
        cached != null &&
        room._nextSyncAt != null &&
        _now().isBefore(room._nextSyncAt!)) {
      return Future.value(cached);
    }
    late final Future<LiveFanTaskSnapshot> operation;
    operation = () async {
      try {
        if (_readTasks == null) {
          throw const LiveInteractionException('官方任务读取不可用');
        }
        final snapshot = await _readTasks(
          room.preferences.copyWith(roomId: room.roomId),
        );
        if (!valid()) {
          throw const LiveInteractionException('任务已取消或账号已变化');
        }
        if (snapshot.roomId != room.roomId ||
            snapshot.anchorUid != room.anchorUid ||
            snapshot.accountUid != account.uid ||
            !identical(snapshot.accountIdentity, account.identity)) {
          throw const LiveInteractionException('任务所属账号或房间尚未确认');
        }
        if (snapshot.joined != true) {
          throw const LiveInteractionException('粉丝勋章身份尚未确认');
        }
        if (snapshot.tasks.isEmpty) {
          throw const LiveInteractionException('官方任务列表为空，不能确认任务状态');
        }
        room
          ..tasks = List.unmodifiable(snapshot.tasks)
          ..completed = liveIntimacyTasksCompleted(snapshot.tasks)
          ..medalLighted = snapshot.medalLighted
          ..officialFresh = true
          .._readRetryAt = null
          ..pauseReason = readOnly
              ? room.preferences.configurationIssue() ??
                    (room.candidate?.eligible != true ? room.pauseReason : null)
              : null;
        final resetTypes = room.officialCycle.synchronize(
          room.tasks,
          room.preferences.mode == LiveIntimacyRoomMode.likeOnly
              ? const ['like']
              : const ['like', 'sendDanmu', 'watchLive'],
          observation: Object(),
        );
        if (room.preferences.mode == LiveIntimacyRoomMode.likeOnly &&
            !room.tasks.any((task) => task.jumpType == 'watchLive')) {
          room.watchProgress
            ..lastSynchronizedAt = _now()
            ..syncState = LiveIntimacySyncState.synchronized
            ..syncError = null
            ..restoredFromCache = false
            ..periodConfirmed = room.officialCycle.confirmed;
        } else {
          room.watchProgress.synchronize(
            room.tasks,
            _now(),
            confirmedUnnumberedReset: resetTypes.contains('watchLive'),
          );
        }
        if (room.officialCycle.uncertain) {
          room.pauseReason = '官方任务进度发生校正，任务周期待核对';
          room.watchProgress
            ..syncState = LiveIntimacySyncState.pending
            ..syncError = room.pauseReason;
        }
        if (room.preferences.mode == LiveIntimacyRoomMode.full &&
            !liveIntimacyTaskCompleted(room.tasks, 'watchLive') &&
            !_watchPending(room.tasks)) {
          room.watchPauseReason = '观时任务阶段或完成状态尚未确认';
        } else if (room.watchPauseReason == '观时任务阶段或完成状态尚未确认') {
          room.watchPauseReason = null;
        }
        room._nextSyncAt = _now().add(
          room == _current
              ? const Duration(seconds: 30)
              : Duration(
                  seconds:
                      300 +
                      (_states.keys.toList()..sort()).indexOf(room.anchorUid) %
                          30,
                ),
        );
        final certified = LiveFanTaskSnapshot(
          roomId: snapshot.roomId,
          anchorUid: snapshot.anchorUid,
          accountUid: snapshot.accountUid,
          accountIdentity: snapshot.accountIdentity,
          joined: snapshot.joined,
          medalLighted: snapshot.medalLighted,
          tasks: snapshot.tasks,
          confirmedLocalCycles: room.officialCycle.confirmedLocalCycles,
        );
        _snapshots[room.anchorUid] = certified;
        if (room == _current) _session?.setOfficialTasks(room.tasks);
        await _persistRoom(room, account.uid);
        if (valid()) _notify();
        return certified;
      } catch (error) {
        if (valid()) {
          room.officialCycle.interruptConfirmation();
          room.officialFresh = false;
          room.watchProgress.synchronizationFailed(
            error is LiveInteractionException ? error.message : '官方任务同步失败',
          );
          room._nextSyncAt = _now().add(const Duration(seconds: 30));
          room._readRetryAt = room._nextSyncAt;
          _notify();
        }
        rethrow;
      } finally {
        if (identical(_taskReads[room.anchorUid], operation)) {
          _taskReads.remove(room.anchorUid);
        }
      }
    }();
    _taskReads[room.anchorUid] = operation;
    return operation;
  }

  Future<void> _stopInteractions() async {
    final sessions = _interactions.values.toList();
    _interactions.clear();
    _interactionRoom = null;
    for (final room in _states.values) {
      room.interactionRunning = false;
    }
    if (sessions.isEmpty) {
      await Future.wait(_closingInteractions.toList());
      return;
    }
    final closing = Future.wait(sessions.map((session) => session.close()));
    final settled = closing.then((_) => _persistAll());
    _closingInteractions.add(settled);
    try {
      await settled;
    } finally {
      _closingInteractions.remove(settled);
    }
  }

  LiveIntimacyRoomState? _rotate(
    List<LiveIntimacyRoomState> rooms,
    int? lastAnchor,
  ) {
    if (rooms.isEmpty) return null;
    final index = rooms.indexWhere((room) => room.anchorUid == lastAnchor);
    return rooms[(index + 1) % rooms.length];
  }

  Future<void> _interactionPulse() async {
    if (_disposed ||
        !_started ||
        _interactionBusy ||
        _inactiveReason != null ||
        !_discoveryReliable ||
        _createInteraction == null ||
        _closingInteractions.isNotEmpty) {
      return;
    }
    _interactionBusy = true;
    final account = _account();
    final epoch = _epoch;
    try {
      final candidates = _sortedStates().where(_interactionEligible).toList();
      for (final uid in _interactions.keys.toList()) {
        if (!candidates.any((room) => room.anchorUid == uid)) {
          final session = _interactions.remove(uid)!;
          _states[uid]?.interactionRunning = false;
          if (_interactionRoom?.anchorUid == uid) {
            _interactionRoom = null;
          }
          await session.close();
        }
      }
      for (final room in candidates) {
        if (!_valid(epoch, account)) return;
        _interactions.putIfAbsent(room.anchorUid, () {
          final session = _createInteraction(
            room.preferences.copyWith(roomId: room.roomId),
            () => _synchronizeRoom(room, epoch, account, force: true),
            () => _interactionAllowed(epoch, account, room),
          );
          session.addListener(() {
            if (!_valid(epoch, account)) return;
            room.interactionPauseReason = session.pauseReason;
            room.interactionRunning =
                session.pauseReason == null && _interactionEligible(room);
            _notify();
          });
          return session;
        });
        room.interactionRunning =
            _interactions[room.anchorUid]!.pauseReason == null;
      }
      if (!_valid(epoch, account)) return;
      final now = _now();
      _nextLikeAt ??= now.add(Duration(seconds: 1 + _randomInt(3)));
      _nextDanmakuAt ??= now.add(Duration(seconds: 30 + _randomInt(31)));
      final attemptedAt = _coordinator.lastDanmakuAttemptAt(
        account.identity,
        account.uid,
      );
      if (attemptedAt != null && attemptedAt != _observedDanmakuAt) {
        _observedDanmakuAt = attemptedAt;
        _nextDanmakuAt = attemptedAt.add(
          Duration(seconds: 30 + _randomInt(31)),
        );
      }
      if (!now.isBefore(_nextLikeAt!)) {
        final room = _rotate(
          candidates
              .where((room) => !liveIntimacyTaskCompleted(room.tasks, 'like'))
              .toList(),
          _lastLikeAnchor,
        );
        _nextLikeAt = now.add(Duration(seconds: 1 + _randomInt(3)));
        if (room != null) {
          _lastLikeAnchor = room.anchorUid;
          _interactionRoom = room;
          room.interactionRunning = true;
          await _interactions[room.anchorUid]!.tick(like: true);
        }
      }
      if (!_valid(epoch, account)) return;
      if (!now.isBefore(_nextDanmakuAt!)) {
        final room = _rotate(
          candidates
              .where(
                (room) =>
                    room.preferences.mode == LiveIntimacyRoomMode.full &&
                    !liveIntimacyTaskCompleted(room.tasks, 'sendDanmu'),
              )
              .toList(),
          _lastDanmakuAnchor,
        );
        _nextDanmakuAt = _now().add(Duration(seconds: 30 + _randomInt(31)));
        if (room != null) {
          _lastDanmakuAnchor = room.anchorUid;
          _interactionRoom = room;
          room.interactionRunning = true;
          await _interactions[room.anchorUid]!.tick(danmaku: true);
        }
      }
      if (_lastPersistAt == null ||
          now.difference(_lastPersistAt!) >= const Duration(seconds: 15)) {
        _lastPersistAt = now;
        await _persistAll();
      }
    } finally {
      _interactionBusy = false;
      _notify();
    }
  }

  Future<void> clearAccountData(int uid) {
    if (uid <= 0) return Future.value();
    final existing = _accountClears[uid];
    if (existing != null) return existing;
    // Establish the deletion boundary before any await. Neither a pulse nor a
    // manual retry may create another write while existing writes drain.
    _clearingAccounts.add(uid);
    _pendingRecordSaves.removeWhere((_, save) => save.uid == uid);
    late final Future<void> operation;
    operation = Future<void>(() async {
      try {
        if (_bound?.uid == uid) {
          _invalidate();
          await _stopInteractions();
          await _stopCurrent();
          await _tickOperation;
        }
        await _writePreferences(uid, const LiveIntimacyPreferences());
        await Future.wait(
          _recordWrites.entries
              .where((entry) => entry.key.startsWith('$uid:'))
              .map((entry) => entry.value)
              .toList(),
        );
        await _records.clearAccount(uid);
        if (_production) {
          await LiveTaskAutomationService.clearAccountJournal(uid);
        }
        if (_bound?.uid == uid) {
          for (final room in _states.values) {
            room.watchProgress.dispose();
          }
          _states.clear();
          _snapshots.clear();
          _restoredRecords.clear();
          _preferences = const LiveIntimacyPreferences();
          _synchronize();
          _notify();
        }
      } finally {
        _clearingAccounts.remove(uid);
        if (identical(_accountClears[uid], operation)) {
          _accountClears.remove(uid);
        }
        if (!_disposed && _bound?.uid == uid && _account().uid == uid) {
          _status = _inactiveReason ?? '正在核对后台任务房间';
          _notify();
          _schedule(Duration.zero);
        }
      }
    });
    _accountClears[uid] = operation;
    return operation;
  }

  Future<void> _tick({bool readOnly = false}) {
    if (_disposed || _busy || !_started) return Future<void>.value();
    final operation = _tickBody(readOnly: readOnly);
    _tickOperation = operation;
    return operation.whenComplete(() {
      if (identical(_tickOperation, operation)) _tickOperation = null;
    });
  }

  Future<void> _tickBody({required bool readOnly}) async {
    if (_disposed || _busy || !_started) return;
    final inactive = readOnly ? _readInactiveReason : _inactiveReason;
    if (inactive != null) {
      _status = inactive;
      await _stopCurrent();
      await _stopInteractions();
      for (final room in _states.values) {
        room.watchProgress.freeze();
        room.watchProgress.syncState = LiveIntimacySyncState.paused;
      }
      _queue = const [];
      _notify();
      return;
    }
    _busy = true;
    final epoch = _epoch;
    final account = _account();
    bool valid() =>
        readOnly ? _validRead(epoch, account) : _valid(epoch, account);
    try {
      for (final state in _states.values) {
        await _restoreRecord(state, account, epoch);
      }
      final shouldDiscover =
          _lastDiscoveryAt == null ||
          _now().difference(_lastDiscoveryAt!) >= const Duration(seconds: 60);
      final found = shouldDiscover
          ? await _discovery.discover(_preferences.rooms)
          : _found;
      if (shouldDiscover) {
        _found = found;
        _lastDiscoveryAt = _now();
      }
      if (!valid()) return;
      _discoveryReliable = true;
      for (final state in _states.values) {
        state.candidate = found
            .where((item) => item.anchorUid == state.anchorUid)
            .firstOrNull;
        if (readOnly &&
            state.preferences.authorized &&
            state.candidate == null) {
          try {
            state.candidate = await _discovery.recheck(state.preferences);
          } catch (error) {
            if (!valid()) return;
            state
              ..officialFresh = false
              ..pauseReason = error is LiveInteractionException
                  ? error.message
                  : '直播间资格暂时无法核对';
            continue;
          }
          if (!valid()) return;
        }
        final candidate = state.candidate;
        state.pauseReason = !state.preferences.authorized
            ? '此房间尚未授权'
            : state.preferences.configurationIssue() ??
                  (candidate == null
                      ? '资格尚未确认'
                      : !candidate.followed
                      ? '未关注该主播'
                      : !candidate.medalOwned
                      ? '未拥有该主播粉丝勋章'
                      : !candidate.live
                      ? '主播尚未开播'
                      : state.recordRestoreError ??
                            (state.officialCycle.uncertain
                                ? '官方任务进度发生校正，任务周期待核对'
                                : state._retryAt != null &&
                                      _now().isBefore(state._retryAt!)
                                ? state.pauseReason
                                : null));
        if (candidate?.live == false) {
          state.watchProgress.syncState = LiveIntimacySyncState.offline;
        }
      }
      // A single room read is shared by watch, interaction and every UI.
      if (_readTasks != null) {
        for (final state in _states.values) {
          if (!state.preferences.authorized ||
              (readOnly
                  ? state.candidate == null
                  : state.candidate?.eligible != true) ||
              state.recordRestoreError != null ||
              (!readOnly && state.preferences.configurationIssue() != null)) {
            continue;
          }
          if (state._retryAt != null && !_now().isBefore(state._retryAt!)) {
            state
              ..watchPauseReason = null
              .._retryAt = null;
          }
          final due =
              state._nextSyncAt == null || !_now().isBefore(state._nextSyncAt!);
          if (!due && !readOnly) continue;
          try {
            await _synchronizeRoom(
              state,
              epoch,
              account,
              force: true,
              readOnly: readOnly,
            );
            if (!valid()) return;
          } catch (error) {
            if (!valid()) return;
            state.pauseReason = error is LiveInteractionException
                ? error.message
                : '官方任务暂时无法核对';
          }
        }
      }
      final active = _session;
      if (!readOnly && active != null) {
        await active.refresh();
        if (!_valid(epoch, account)) return;
        _copySessionState();
      }
      final candidates = _candidates();
      _queue = List.unmodifiable(candidates.where((room) => room != _current));
      if (readOnly) {
        _notify();
        return;
      }
      final selected = candidates.firstOrNull;
      if (selected == null) {
        await _stopCurrent();
        _status = '等待已授权且任务未完成的主播开播';
        return;
      }
      if (identical(selected, _current) &&
          _session != null &&
          _session!.pauseReason == null) {
        _status = _session!.statusText;
        return;
      }
      await _stopCurrent();
      if (!_valid(epoch, account)) return;
      // A fresh authoritative check catches changes after list discovery.
      LiveIntimacyCandidate candidate;
      try {
        candidate = await _discovery.recheck(selected.preferences);
      } catch (error) {
        if (_valid(epoch, account)) {
          _pauseRoom(
            selected,
            error is LiveInteractionException ? error.message : '直播间资格暂时无法核对',
          );
        }
        return;
      }
      if (!_valid(epoch, account)) return;
      selected.candidate = candidate;
      if (!candidate.eligible ||
          candidate.areaId <= 0 ||
          candidate.parentAreaId <= 0) {
        _pauseRoom(selected, '开播、关注、勋章或观看信息已变化');
        return;
      }
      if (candidate.roomId != selected.preferences.roomId) {
        // Keep canonical identity within this login before any future write.
        final canonical = selected.preferences.copyWith(
          roomId: candidate.roomId,
        );
        _preferences = _preferences.copyWith(
          rooms: _preferences.rooms
              .map(
                (room) =>
                    room.anchorUid == canonical.anchorUid ? canonical : room,
              )
              .toList(),
        );
        selected.preferences = canonical;
        await _writePreferences(account.uid, _preferences);
        if (!_valid(epoch, account)) return;
      }
      if (selected.preferences.mode == LiveIntimacyRoomMode.full &&
          selected.preferences.automation.danmakuMode ==
              LiveTaskDanmakuMode.emoticon) {
        List<LiveTaskEmoticonOption> options;
        try {
          options = await _loadEmoticons(selected.preferences);
        } catch (_) {
          if (_valid(epoch, account)) _pauseRoom(selected, '表情发送权限暂时无法确认');
          return;
        }
        if (!_valid(epoch, account)) return;
        final issue = selected.preferences.configurationIssue(
          availableEmoticons: options
              .where((option) => option.available)
              .map((option) => option.unique),
        );
        if (issue != null) {
          _pauseRoom(selected, issue);
          return;
        }
      }
      if (selected.watchProgress.lastSynchronizedAt == null ||
          _now().difference(selected.watchProgress.lastSynchronizedAt!) >
              const Duration(seconds: 1)) {
        try {
          await _synchronizeRoom(selected, epoch, account, force: true);
        } catch (_) {
          return;
        }
        if (!_valid(epoch, account) || !_watchPending(selected.tasks)) return;
      }
      final owner = Object();
      _watchOwner = owner;
      if (!await _coordinator.claim(owner, account.uid)) {
        if (identical(_watchOwner, owner)) _watchOwner = null;
        if (!_valid(epoch, account)) return;
        _status = '等待观看上报所有权释放';
        return;
      }
      if (!_valid(epoch, account)) {
        await _coordinator.release(owner);
        return;
      }
      selected
        ..pauseReason = null
        ..running = true;
      _current = selected;
      final session = _createSession(
        selected.preferences,
        candidate,
        selected.watchProgress,
        () => _roomAllowed(epoch, account, selected, owner),
      );
      _session = session;
      _sessionAccountUid = account.uid;
      session.setOfficialTasks(selected.tasks);
      selected._nextSyncAt = _now().add(const Duration(seconds: 30));
      session.addListener(_sessionChanged);
      _queue = List.unmodifiable(candidates.where((room) => room != selected));
      _status =
          '正在启动${selected.anchorName.isEmpty ? selected.roomId : selected.anchorName}的静音音频';
      _notify();
      await session.start();
      if (!_valid(epoch, account)) {
        await _stopCurrent();
        await _stopInteractions();
        return;
      }
      _copySessionState();
      if (session.pauseReason != null) {
        _pauseRoom(selected, session.pauseReason!, watchOnly: true);
        await _stopCurrent();
        _restart = true;
      }
    } catch (error) {
      if (_valid(epoch, account)) {
        _discoveryReliable = false;
        _status = error is LiveInteractionException
            ? error.message
            : '房间资格暂时无法核对，后台任务已暂停';
        await _stopCurrent();
      }
    } finally {
      _busy = false;
      _notify();
      if (!_disposed && _preferences.enabled) {
        final soon = _restart;
        _restart = false;
        _schedule(soon ? Duration.zero : const Duration(seconds: 5));
      }
    }
  }

  void _copySessionState() {
    final state = _current;
    final session = _session;
    if (state == null || session == null) return;
    state.watchRunning = session.actualPlayback;
    if (_createInteraction == null && session.tasks.isNotEmpty) {
      state.tasks = List.unmodifiable(session.tasks);
      state.completed = liveIntimacyTasksCompleted(state.tasks);
    }
    if (session.pauseReason != null) {
      state.watchPauseReason = session.pauseReason;
    }
    _status = session.statusText;
  }

  void _sessionChanged() {
    if (_disposed) return;
    _copySessionState();
    final room = _current;
    if (room != null &&
        (liveIntimacyTaskCompleted(room.tasks, 'watchLive') ||
            _session?.pauseReason != null)) {
      if (room.watchPauseReason != null) {
        _pauseRoom(room, room.watchPauseReason!, watchOnly: true);
      }
      _schedule(Duration.zero);
    }
    _notify();
  }

  void _pauseRoom(
    LiveIntimacyRoomState room,
    String reason, {
    bool watchOnly = false,
  }) {
    if (room.watchPauseReason == reason &&
        room._retryAt != null &&
        _now().isBefore(room._retryAt!)) {
      return;
    }
    if (watchOnly) {
      room.watchPauseReason = reason;
    } else {
      room.pauseReason = reason;
    }
    room._failures = (room._failures + 1).clamp(1, 6);
    room._retryAt = _now().add(
      Duration(seconds: 60 * (1 << (room._failures - 1))),
    );
    _status = '$reason；继续核对其他房间';
    _restart = true;
  }

  Future<void> _stopCurrent() async {
    final session = _session;
    final room = _current;
    final owner = _watchOwner;
    final uid = _sessionAccountUid;
    _session = null;
    _current = null;
    _watchOwner = null;
    _sessionAccountUid = null;
    if (room != null) {
      room
        ..running = false
        ..watchRunning = false
        ..watchProgress.freeze();
    }
    if (session == null && owner == null) {
      await Future.wait(_closingSessions.toList());
      return;
    }
    if (session != null) session.removeListener(_sessionChanged);
    Future<void> closeDetached() async {
      try {
        if (session != null) await session.close();
      } finally {
        try {
          if (room != null) await _persistRoom(room, uid ?? _bound?.uid ?? 0);
        } finally {
          if (owner != null) await _coordinator.release(owner);
        }
      }
    }

    final closing = closeDetached();
    _closingSessions.add(closing);
    try {
      await closing;
    } finally {
      _closingSessions.remove(closing);
    }
  }

  Future<void> shutdown() => _shutdownFuture ??= _shutdown();

  Future<void> _shutdown() async {
    if (_disposed) return;
    _disposed = true;
    _suspendedReason = '应用已退出，后台亲密度任务已停止';
    _invalidate();
    _identityPoll?.cancel();
    _interactionTimer?.cancel();
    await _settings?.cancel();
    if (_production) {
      Accounts.removeMainIdentityChangeListener(_beforeIdentityChange);
      Accounts.removeMainIdentitySettledListener(_synchronize);
      Accounts.removeAccountRoleChangeListener(_synchronize);
    }
    await _stopInteractions();
    await _stopCurrent();
    await _tickOperation;
    await _persistAll();
    for (final state in _states.values) {
      state.watchProgress.dispose();
    }
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
  }

  @override
  void dispose() {
    unawaited(shutdown());
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
  }
}

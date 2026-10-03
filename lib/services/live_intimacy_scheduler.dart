// Injection callbacks use public names in tests and private storage internally.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:PiliPlus/services/live_automation_coordinator.dart';
import 'package:PiliPlus/services/live_intimacy_audio_session.dart';
import 'package:PiliPlus/services/live_intimacy_discovery.dart';
import 'package:PiliPlus/services/live_intimacy_watch_progress.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
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
  LiveIntimacyRoomState(this.preferences);
  LiveIntimacyRoomPreferences preferences;
  LiveIntimacyCandidate? candidate;
  List<LiveFanTask> tasks = const [];
  final watchProgress = LiveIntimacyWatchProgress();
  String? pauseReason;
  bool running = false;
  bool completed = false;
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
      (completed
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
  }) : _account = account,
       _readPreferences = readPreferences,
       _writePreferences = writePreferences,
       _discovery = discovery,
       _createSession = createSession,
       _loadEmoticons = loadEmoticons,
       _readTasks = readTasks,
       _coordinator = coordinator ?? LiveAutomationCoordinator(),
       _now = now ?? DateTime.now;

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
  bool _notifierDisposed = false;
  Future<void>? _tickOperation;

  LiveIntimacyPreferences get preferences => _preferences;
  List<LiveIntimacyRoomState> get rooms => List.unmodifiable(_states.values);
  List<LiveIntimacyRoomState> get queue => _queue;
  LiveIntimacyRoomState? get currentRoom => _current;
  String get statusText => _status;
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
      for (final state in _states.values) {
        state.watchProgress.dispose();
      }
      _states.clear();
    }
    _bound = account;
    _preferences = next;
    _syncStates();
    _discoveryReliable = false;
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

  String? get _inactiveReason {
    final account = _account();
    if (_suspendedReason != null) return _suspendedReason;
    if (!account.loggedIn || account.uid <= 0) return '登录后可启用后台亲密度';
    if (account.privacyReason != null) return account.privacyReason;
    if (!_preferences.enabled) return '后台亲密度任务已关闭';
    return null;
  }

  void _syncStates() {
    final selected = <int>{};
    for (final room in _preferences.rooms) {
      if (!selected.add(room.anchorUid)) continue;
      final state = _states.putIfAbsent(
        room.anchorUid,
        () => LiveIntimacyRoomState(room),
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
    _timer?.cancel();
    _timer = null;
    _discovery.cancel();
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
    final preferred = _states[anchor];
    if (preferred != null &&
        preferred != _current &&
        preferred.roomId == room &&
        preferred.preferences.authorized &&
        preferred.candidate?.eligible == true &&
        preferred.pauseReason == null &&
        (preferred._retryAt == null || !_now().isBefore(preferred._retryAt!)) &&
        !preferred.completed &&
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
      authorized: old?.authorized == true,
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
      if (canonical.automation.danmakuMode == LiveTaskDanmakuMode.emoticon) {
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
    _notify();
    await _writePreferences(account.uid, value);
    await stopped;
    if (!_disposed && _sameAccount(account, _account())) {
      _schedule(Duration.zero);
    }
  }

  /// A UI refresh reads state; it never resets budgets or directly submits an
  /// interaction. The independently enabled timer performs later execution.
  Future<void> refresh() async {
    _synchronize();
    if (_busy) {
      _restart = true;
      return;
    }
    await _tick(readOnly: true);
  }

  @visibleForTesting
  Future<void> tickForTesting() async {
    if (!_started) start();
    _synchronize();
    await _tick();
  }

  bool _valid(int epoch, LiveIntimacyAccount account) =>
      !_disposed &&
      epoch == _epoch &&
      _sameAccount(account, _account()) &&
      _inactiveReason == null;

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
        room.pauseReason == null &&
        !room.completed;
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
                  !state.completed &&
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
    final inactive = _inactiveReason;
    if (inactive != null) {
      _status = inactive;
      await _stopCurrent();
      _queue = const [];
      _notify();
      return;
    }
    _busy = true;
    final epoch = _epoch;
    final account = _account();
    try {
      final found = await _discovery.discover(_preferences.rooms);
      if (!_valid(epoch, account)) return;
      _discoveryReliable = true;
      for (final state in _states.values) {
        state.candidate = found
            .where((item) => item.anchorUid == state.anchorUid)
            .firstOrNull;
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
                      : state._retryAt != null &&
                            _now().isBefore(state._retryAt!)
                      ? state.pauseReason
                      : null);
      }
      // Completed is a cache, not a permanent exclusion. Only fresh server
      // state can establish a new daily cycle or an already completed room.
      if (_readTasks != null) {
        for (final state in _states.values) {
          if (!state.preferences.authorized ||
              state.candidate?.eligible != true ||
              state.preferences.configurationIssue() != null) {
            continue;
          }
          try {
            final canonical = state.preferences.copyWith(roomId: state.roomId);
            final snapshot = await _readTasks(canonical);
            if (!_valid(epoch, account)) return;
            if (snapshot.roomId != state.roomId ||
                snapshot.anchorUid != state.anchorUid ||
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
            state.tasks = List.unmodifiable(snapshot.tasks);
            state.completed = liveIntimacyTasksCompleted(state.tasks);
            state.watchProgress.synchronize(state.tasks, _now());
          } catch (error) {
            if (!_valid(epoch, account)) return;
            _pauseRoom(
              state,
              error is LiveInteractionException ? error.message : '官方任务暂时无法核对',
            );
          }
        }
      }
      final active = _session;
      if (active != null) {
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
      if (selected.preferences.automation.danmakuMode ==
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
      session.addListener(_sessionChanged);
      _queue = List.unmodifiable(candidates.where((room) => room != selected));
      _status =
          '正在启动${selected.anchorName.isEmpty ? selected.roomId : selected.anchorName}的静音音频';
      _notify();
      await session.start();
      if (!_valid(epoch, account)) {
        await _stopCurrent();
        return;
      }
      _copySessionState();
      if (session.pauseReason != null) {
        _pauseRoom(selected, session.pauseReason!);
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
      if (!_disposed) {
        final soon = _restart;
        _restart = false;
        _schedule(soon ? Duration.zero : const Duration(seconds: 60));
      }
    }
  }

  void _copySessionState() {
    final state = _current;
    final session = _session;
    if (state == null || session == null) return;
    state.tasks = List.unmodifiable(session.tasks);
    state.completed = liveIntimacyTasksCompleted(state.tasks);
    if (session.pauseReason != null) state.pauseReason = session.pauseReason;
    _status = session.statusText;
  }

  void _sessionChanged() {
    if (_disposed) return;
    _copySessionState();
    final room = _current;
    if (room != null && (room.completed || _session?.pauseReason != null)) {
      if (!room.completed && room.pauseReason != null) {
        _pauseRoom(room, room.pauseReason!);
      }
      _schedule(Duration.zero);
    }
    _notify();
  }

  void _pauseRoom(LiveIntimacyRoomState room, String reason) {
    if (room.pauseReason == reason &&
        room._retryAt != null &&
        _now().isBefore(room._retryAt!)) {
      return;
    }
    room.pauseReason = reason;
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
    _session = null;
    _current = null;
    _watchOwner = null;
    if (room != null) room.running = false;
    if (session == null && owner == null) {
      await Future.wait(_closingSessions.toList());
      return;
    }
    if (session != null) session.removeListener(_sessionChanged);
    Future<void> closeDetached() async {
      if (session != null) await session.close();
      if (owner != null) await _coordinator.release(owner);
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
    await _settings?.cancel();
    if (_production) {
      Accounts.removeMainIdentityChangeListener(_beforeIdentityChange);
      Accounts.removeMainIdentitySettledListener(_synchronize);
      Accounts.removeAccountRoleChangeListener(_synchronize);
    }
    await _stopCurrent();
    await _tickOperation;
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

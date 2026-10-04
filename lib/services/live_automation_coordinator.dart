import 'dart:async';
import 'dart:collection';

import 'package:PiliPlus/pages/live_room/live_danmaku_send_gate.dart';
import 'package:flutter/foundation.dart';

/// The background watch owner is installed before foreground reporters drain.
/// A newly created foreground session sees the claim immediately as well.
class LiveAutomationCoordinator extends ChangeNotifier {
  LiveAutomationCoordinator();
  static final instance = LiveAutomationCoordinator();

  Object? _owner;
  int? _uid;
  int _epoch = 0;
  Future<bool>? _claimSettled;
  bool _foregroundSuspended = false;
  final Set<Future<void> Function()> _foregroundSurrenders = {};
  final Set<Future<void>> _retiringForeground = {};
  final Map<Object, Map<(int, int), _GateEntry>> _gates = HashMap.identity();
  final Expando<Map<int, LiveDanmakuAccountGate>> _accountGates = Expando();

  LiveDanmakuAccountGate _accountGate(Object identity, int uid) {
    final gates = _accountGates[identity] ??= <int, LiveDanmakuAccountGate>{};
    return gates.putIfAbsent(uid, LiveDanmakuAccountGate.new);
  }

  DateTime? lastDanmakuAttemptAt(Object identity, int uid) =>
      _accountGate(identity, uid).lastAttemptAt;

  bool get backgroundWatchClaimed => _owner != null;
  bool get foregroundWatchSuspended => _foregroundSuspended;
  bool get foregroundWatchDraining => _retiringForeground.isNotEmpty;
  void retireForeground(Future<void> settled) {
    _retiringForeground.add(settled);
    notifyListeners();
    void drained() {
      if (_retiringForeground.remove(settled)) notifyListeners();
    }

    unawaited(
      settled.then(
        (_) => drained(),
        onError: (Object _, StackTrace _) => drained(),
      ),
    );
  }

  void setForegroundSuspended(bool value) {
    if (_foregroundSuspended == value) return;
    _foregroundSuspended = value;
    notifyListeners();
  }

  Future<void> drainForeground() => Future.wait([
    ..._retiringForeground,
    ..._foregroundSurrenders.toList().map((surrender) => surrender()),
  ]);
  bool owns(Object owner) => identical(_owner, owner);

  void registerForeground(Future<void> Function() surrender) =>
      _foregroundSurrenders.add(surrender);
  void unregisterForeground(Future<void> Function() surrender) =>
      _foregroundSurrenders.remove(surrender);

  Future<bool> claim(Object owner, int accountUid) async {
    if (accountUid <= 0) return false;
    if (_owner != null) {
      if (!owns(owner) || _uid != accountUid) return false;
      final epoch = _epoch;
      final settled = await (_claimSettled ?? Future.value(false));
      return settled && epoch == _epoch && owns(owner) && _uid == accountUid;
    }
    final epoch = ++_epoch;
    final result = Completer<bool>();
    _claimSettled = result.future;
    _owner = owner;
    _uid = accountUid;
    notifyListeners();
    try {
      await drainForeground();
    } catch (_) {
      if (epoch == _epoch && owns(owner)) {
        _owner = null;
        _uid = null;
        ++_epoch;
        notifyListeners();
      }
      result.complete(false);
      return false;
    }
    final accepted = epoch == _epoch && owns(owner) && _uid == accountUid;
    result.complete(accepted);
    return accepted;
  }

  /// Call only after the background reporter has stopped and settled.
  Future<void> release(Object owner) async {
    if (!owns(owner)) return;
    _owner = null;
    _uid = null;
    _claimSettled = null;
    ++_epoch;
    notifyListeners();
  }

  LiveDanmakuGateLease acquireDanmakuGate(
    Object accountIdentity,
    int accountUid,
    int roomId,
  ) {
    final entries = _gates.putIfAbsent(accountIdentity, () => {});
    final key = (accountUid, roomId);
    final entry = entries.putIfAbsent(key, () {
      final created = _GateEntry(_accountGate(accountIdentity, accountUid));
      void cleanLater() {
        if (created.cleanupScheduled) return;
        created.cleanupScheduled = true;
        scheduleMicrotask(() {
          created.cleanupScheduled = false;
          if (created.references != 0 || created.gate.pending) return;
          if (!identical(entries[key], created)) return;
          entries.remove(key);
          if (entries.isEmpty) _gates.remove(accountIdentity);
          created.gate.removeListener(cleanLater);
          created.gate.dispose();
        });
      }

      created.cleanLater = cleanLater;
      created.gate.addListener(cleanLater);
      return created;
    });
    ++entry.references;
    // A pending request retains the gate after its final media owner leaves.
    // A replacement session must acquire the same pending lock.
    return LiveDanmakuGateLease._(entry.gate, () {
      --entry.references;
      entry.cleanLater();
    });
  }
}

class LiveDanmakuGateLease {
  LiveDanmakuGateLease._(this.gate, this._release);
  final LiveDanmakuSendGate gate;
  final VoidCallback _release;
  bool _released = false;
  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

class _GateEntry {
  _GateEntry(LiveDanmakuAccountGate account)
    : gate = LiveDanmakuSendGate(accountGate: account);
  final LiveDanmakuSendGate gate;
  int references = 0;
  bool cleanupScheduled = false;
  late final VoidCallback cleanLater;
}

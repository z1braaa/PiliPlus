import 'package:PiliPlus/http/loading_state.dart';
import 'package:flutter/foundation.dart';

typedef LiveDanmakuSendAttempt = ({
  LoadingState<void> response,
  int draftRevision,
});

/// Shared dispatch lock and attempt clock. Draft revisions stay room scoped.
class LiveDanmakuAccountGate {
  bool pending = false;
  DateTime? lastAttemptAt;
}

/// One in-flight live message per room, across route and inline composers.
/// A successful response only clears the draft generation that was submitted.
class LiveDanmakuSendGate extends ChangeNotifier {
  LiveDanmakuSendGate({DateTime Function()? now, this.accountGate})
    : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  final LiveDanmakuAccountGate? accountGate;
  DateTime? _lastAttemptAt;
  bool _pending = false;
  bool _disposed = false;
  int _draftRevision = 0;
  int _successSerial = 0;
  int? _successfulRevision;

  bool get pending => _pending;
  int get draftRevision => _draftRevision;
  int get successSerial => _successSerial;
  int? get successfulRevision => _successfulRevision;
  DateTime? get lastAttemptAt => _lastAttemptAt;

  void markDraftChanged() {
    ++_draftRevision;
    if (!_disposed) notifyListeners();
  }

  Future<LiveDanmakuSendAttempt?> trySend(
    Future<LoadingState<void>> Function() request, {
    required bool clearDraftOnSuccess,
    void Function(int revision)? onDraftSuccess,
    Duration minimumInterval = Duration.zero,
    bool Function()? stillCurrent,
  }) async {
    if (_pending || _disposed || accountGate?.pending == true) return null;
    final last = accountGate?.lastAttemptAt ?? _lastAttemptAt;
    if (last case final previous?) {
      if (_now().difference(previous) < minimumInterval) return null;
    }
    if (stillCurrent?.call() == false) return null;
    _pending = true;
    accountGate?.pending = true;
    final revision = _draftRevision;
    if (!_disposed) notifyListeners();
    try {
      if (_disposed || stillCurrent?.call() == false) return null;
      _lastAttemptAt = _now();
      accountGate?.lastAttemptAt = _lastAttemptAt;
      final response = await request();
      if (_disposed) return null;
      if (response.isSuccess &&
          clearDraftOnSuccess &&
          stillCurrent?.call() != false) {
        _successfulRevision = revision;
        ++_successSerial;
        onDraftSuccess?.call(revision);
      }
      return (response: response, draftRevision: revision);
    } finally {
      _pending = false;
      accountGate?.pending = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

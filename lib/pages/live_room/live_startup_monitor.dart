/// A bounded startup observation, separate from native open commands. Playback
/// intent or an HTTP success alone does not prove usable media. The owner feeds
/// fresh native position, buffering and decoding observations after its source
/// has opened, and cancels this monitor on pause, replacement or disposal.
enum LiveStartupPhase {
  requestingSource,
  preparingPlayer,
  waitingMedia,
  progressing,
  retrying,
  failed,
  cancelled,
}

enum LiveStartupDecision { waiting, progressing, retry, failed }

class LiveStartupMonitor {
  LiveStartupMonitor({
    required this.window,
    required this.maxRetries,
    DateTime Function()? now,
  }) : assert(window > Duration.zero),
       assert(maxRetries >= 0),
       _now = now ?? DateTime.now;

  final Duration window;
  final int maxRetries;
  final DateTime Function() _now;
  late DateTime _started;
  Duration? _previousPosition;
  int _retries = 0;
  bool _active = false;
  bool _sourceReady = false;
  LiveStartupPhase phase = LiveStartupPhase.cancelled;
  LiveStartupPhase? failureAt;
  int get retries => _retries;
  bool get active => _active;

  void begin() {
    _retries = 0;
    failureAt = null;
    _beginAttempt();
  }

  void _beginAttempt() {
    _started = _now();
    _previousPosition = null;
    _sourceReady = false;
    _active = true;
    phase = LiveStartupPhase.requestingSource;
  }

  void sourceSelected() {
    if (_active) phase = LiveStartupPhase.preparingPlayer;
  }

  void sourceReady(Duration position) {
    if (!_active) return;
    _sourceReady = true;
    _previousPosition = position;
    phase = LiveStartupPhase.waitingMedia;
  }

  LiveStartupDecision observe({
    required Duration position,
    required bool playing,
    required bool buffering,
    required bool decoded,
  }) {
    if (!_active) {
      return phase == LiveStartupPhase.progressing
          ? LiveStartupDecision.progressing
          : LiveStartupDecision.waiting;
    }
    final previous = _previousPosition;
    _previousPosition = position;
    if (_sourceReady &&
        playing &&
        !buffering &&
        decoded &&
        previous != null &&
        position > previous) {
      phase = LiveStartupPhase.progressing;
      _active = false;
      return LiveStartupDecision.progressing;
    }
    final elapsed = _now().difference(_started);
    if (elapsed.isNegative || elapsed < window) {
      return LiveStartupDecision.waiting;
    }
    if (_retries < maxRetries) {
      _retries++;
      _beginAttempt();
      phase = LiveStartupPhase.retrying;
      return LiveStartupDecision.retry;
    }
    failureAt = phase;
    _active = false;
    phase = LiveStartupPhase.failed;
    return LiveStartupDecision.failed;
  }

  void cancel() {
    _active = false;
    _sourceReady = false;
    _previousPosition = null;
    phase = LiveStartupPhase.cancelled;
  }
}

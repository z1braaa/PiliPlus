import 'dart:async';

import 'package:PiliPlus/services/live_interaction_service.dart';

/// One bounded startup deadline, including suspended native futures. Cancel
/// resolves the caller immediately; a late resource is retired separately.
class LiveIntimacyStartupGate {
  LiveIntimacyStartupGate({this.timeout = const Duration(seconds: 20)});
  final Duration timeout;
  final Stopwatch _clock = Stopwatch()..start();
  final Set<void Function()> _cancellations = {};
  bool _canceled = false;

  Future<T> run<T>(Future<T> work, {FutureOr<void> Function(T)? onAbandoned}) {
    final winner = Completer<T>();
    void cancel() {
      if (!winner.isCompleted) {
        winner.completeError(const LiveInteractionException('后台音频启动已取消'));
      }
    }

    final remaining = timeout - _clock.elapsed;
    final timer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      if (!winner.isCompleted) {
        winner.completeError(
          const LiveInteractionException('后台仅音频在20秒内未就绪，已暂停此房间观时'),
        );
      }
    });
    _cancellations.add(cancel);
    if (_canceled) cancel();
    work.then(
      (value) {
        if (!winner.isCompleted) {
          winner.complete(value);
        } else if (onAbandoned != null) {
          unawaited(
            Future<void>(() async {
              await onAbandoned(value);
            }).catchError((Object _) {}),
          );
        }
      },
      onError: (Object error, StackTrace trace) {
        if (!winner.isCompleted) winner.completeError(error, trace);
      },
    );
    return winner.future.whenComplete(() {
      timer.cancel();
      _cancellations.remove(cancel);
    });
  }

  void cancel() {
    _canceled = true;
    for (final cancel in _cancellations.toList()) {
      cancel();
    }
  }
}

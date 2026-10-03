import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/live_automation_coordinator.dart';
import 'package:PiliPlus/services/live_intimacy_scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Window minimization and frontend pause do not suspend background audio.
/// Native power notifications are separate from Flutter visibility callbacks.
class LiveIntimacyLifecycle with WidgetsBindingObserver {
  LiveIntimacyLifecycle._();
  static final instance = LiveIntimacyLifecycle._();
  static const _channel = MethodChannel('piliplus/live_intimacy_lifecycle');
  bool _initialized = false;
  bool _detached = false;
  Future<void>? _shutdown;

  void initialize() {
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isMacOS) {
      _channel.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'willSleep':
            await suspend();
          case 'didWake':
            resume();
          case 'terminate':
            await shutdownForExit();
        }
      });
    }
    LiveIntimacyScheduler.instance.start();
  }

  Future<void> suspend() async {
    LiveAutomationCoordinator.instance.setForegroundSuspended(true);
    await Future.wait([
      LiveAutomationCoordinator.instance.drainForeground(),
      LiveIntimacyScheduler.instance.suspend(),
    ]);
  }

  void resume() {
    if (_shutdown != null) return;
    LiveAutomationCoordinator.instance.setForegroundSuspended(false);
    LiveIntimacyScheduler.instance.resume();
  }

  Future<void> shutdown() => _shutdown ??= _stop();

  /// A failed or stalled stop must not prevent an explicitly requested exit.
  /// The process exit itself is the final boundary for native media and writes.
  Future<void> shutdownForExit() async {
    try {
      await shutdown().timeout(const Duration(seconds: 5));
    } on Object {
      // Continue the caller's exit; do not expose account or request details.
    }
  }

  Future<void> _stop() async {
    LiveAutomationCoordinator.instance.setForegroundSuspended(true);
    await Future.wait([
      LiveAutomationCoordinator.instance.drainForeground(),
      LiveIntimacyScheduler.instance.shutdown(),
    ]);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _detached = true;
      unawaited(suspend());
    } else if (state == AppLifecycleState.resumed && _detached) {
      _detached = false;
      resume();
    }
  }
}

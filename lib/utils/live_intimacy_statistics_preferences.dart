// Public callback names keep tests independent from production storage.
// ignore_for_file: prefer_initializing_formals
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter/foundation.dart';

/// Presentation consent is separate from the task scheduler and room grants.
class LiveIntimacyStatisticsPreferences extends ChangeNotifier {
  LiveIntimacyStatisticsPreferences({
    required bool Function(int uid) read,
    required Future<void> Function(int uid, bool enabled) write,
  }) : _read = read,
       _write = write;

  static const storagePrefix = 'liveIntimacyStatisticsDisplay';
  static String storageKey(int uid) => '$storagePrefix:$uid';
  static final instance = LiveIntimacyStatisticsPreferences(
    read: (uid) =>
        GStorage.setting.get(storageKey(uid), defaultValue: false) == true,
    write: (uid, enabled) async {
      await GStorage.setting.put(storageKey(uid), enabled);
      await GStorage.setting.flush();
    },
  );

  final bool Function(int uid) _read;
  final Future<void> Function(int uid, bool enabled) _write;

  bool enabledFor(int uid) => uid > 0 && _read(uid);

  Future<void> setEnabled(int uid, bool enabled) async {
    if (uid <= 0) return;
    await _write(uid, enabled);
    notifyListeners();
  }

  Future<void> clearFor(int uid) => setEnabled(uid, false);
}

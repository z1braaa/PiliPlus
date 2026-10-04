import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:hive_ce/hive.dart';

/// Only current room ledgers are stored. No cookies, URLs or message contents.
abstract class LiveIntimacyRecordStore {
  Future<Map<String, dynamic>?> read(int uid, int anchorUid, int roomId);
  Future<void> write(
    int uid,
    int anchorUid,
    int roomId,
    Map<String, dynamic> data,
  );
  Future<void> clearAccount(int uid);
}

class HiveLiveIntimacyRecordStore implements LiveIntimacyRecordStore {
  static Future<Box<dynamic>>? _opening;
  Future<Box<dynamic>> get _box {
    final active = _opening;
    if (active != null) return active;
    late final Future<Box<dynamic>> opening;
    opening = Hive.openBox<dynamic>('liveIntimacyCurrentRecords').then(
      (box) => box,
      onError: (Object error, StackTrace stack) {
        if (identical(_opening, opening)) _opening = null;
        Error.throwWithStackTrace(error, stack);
      },
    );
    _opening = opening;
    return opening;
  }

  String _key(int uid, int anchor, int room) => '$uid:$anchor:$room';

  @override
  Future<Map<String, dynamic>?> read(int uid, int anchorUid, int roomId) async {
    final value = (await _box).get(_key(uid, anchorUid, roomId));
    return value is Map ? liveMap(value) : null;
  }

  @override
  Future<void> write(
    int uid,
    int anchorUid,
    int roomId,
    Map<String, dynamic> data,
  ) async {
    final box = await _box;
    await box.put(_key(uid, anchorUid, roomId), data);
    await box.flush();
  }

  @override
  Future<void> clearAccount(int uid) async {
    final box = await _box;
    await box.deleteAll(
      box.keys.where((key) => '$key'.startsWith('$uid:')).toList(),
    );
    await box.flush();
  }
}

class MemoryLiveIntimacyRecordStore implements LiveIntimacyRecordStore {
  final records = <String, Map<String, dynamic>>{};
  String _key(int uid, int anchor, int room) => '$uid:$anchor:$room';
  @override
  Future<Map<String, dynamic>?> read(
    int uid,
    int anchorUid,
    int roomId,
  ) async => records[_key(uid, anchorUid, roomId)];
  @override
  Future<void> write(
    int uid,
    int anchorUid,
    int roomId,
    Map<String, dynamic> data,
  ) async {
    records[_key(uid, anchorUid, roomId)] = Map.of(data);
  }

  @override
  Future<void> clearAccount(int uid) async =>
      records.removeWhere((key, _) => key.startsWith('$uid:'));
}

Map<String, dynamic> liveIntimacyTaskRecord(LiveFanTask task) => {
  'name': task.name,
  'description': task.description,
  'jump_type': task.jumpType,
  'completed': task.completed,
  'id': task.id,
  'progress_text': task.progressText,
  'current_count': task.currentCount,
  'target_count': task.targetCount,
  'actions_per_progress': task.actionsPerProgress,
  'daily_reward_progress': task.dailyRewardProgress,
  'completion_only': task.completionOnly,
  'period': task.period,
};

LiveFanTask liveIntimacyTaskFromRecord(Map<String, dynamic> value) =>
    LiveFanTask(
      name: '${value['name'] ?? ''}',
      description: '${value['description'] ?? ''}',
      jumpType: '${value['jump_type'] ?? ''}',
      completed: liveBool(value['completed']),
      id: '${value['id'] ?? ''}',
      progressText: '${value['progress_text'] ?? ''}',
      currentCount: liveInt(value['current_count']),
      targetCount: liveInt(value['target_count']),
      actionsPerProgress: liveInt(value['actions_per_progress']),
      dailyRewardProgress: value['daily_reward_progress'] == true,
      completionOnly: value['completion_only'] == true,
      period: '${value['period'] ?? ''}',
    );

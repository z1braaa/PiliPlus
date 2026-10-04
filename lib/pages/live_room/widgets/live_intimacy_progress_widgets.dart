import 'package:PiliPlus/pages/live_room/widgets/live_intimacy_controls.dart';
import 'package:PiliPlus/services/live_intimacy_scheduler.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:material_ui/material_ui.dart';

String liveIntimacyTaskSummary(List<LiveFanTask> tasks) {
  final names = {'like': '点赞', 'sendDanmu': '弹幕', 'watchLive': '观时'};
  return names.entries
      .map((entry) {
        final matches = tasks.where((task) => task.jumpType == entry.key);
        if (matches.length != 1) return '${entry.value}：待确认';
        final task = matches.single;
        final progress = task.currentCount != null && task.targetCount != null
            ? '${task.currentCount}/${task.targetCount}'
            : task.progressText;
        return '${entry.value}：${task.completed == true
            ? "已完成"
            : progress.isNotEmpty
            ? progress
            : "待确认"}';
      })
      .join(' · ');
}

Widget liveIntimacyProgressView(LiveIntimacyRoomState room) {
  final progress = room.watchProgress;
  return LiveIntimacyWatchProgressView(
    effectiveDuration: progress.effectiveDuration,
    completedRounds: progress.completedRounds,
    dailyRounds: progress.dailyRounds,
    thresholdSeconds: progress.thresholdSeconds,
    officialSeconds: progress.officialSeconds,
    currentRoundEstimateSeconds: progress.currentRoundEstimateSeconds,
    waitingConfirmation: progress.waitingConfirmation,
    progressValue: progress.progressValue,
  );
}

String liveIntimacyRoomStatusSummary(LiveIntimacyRoomState room) => [
  if (room.pauseReason != null) room.pauseReason!,
  if (room.interactionPauseReason != null) '互动：${room.interactionPauseReason}',
  if (room.watchPauseReason != null) '观时：${room.watchPauseReason}',
  if (room.recordSaveError != null) room.recordSaveError!,
  if (room.recordRestoreError != null) room.recordRestoreError!,
  if (!room.officialFresh || !room.periodConfirmed) '官方进度或周期待核对，保留本地记录',
  if (room.allTasksCompletedConfirmed) '三项任务均已由官方确认完成',
  if (room.authorizedTasksCompleted && !room.allTasksCompletedConfirmed)
    '已授权的点赞任务已完成',
  if (room.watchRunning) '独立音频有效观时中',
  if (room.canAdvanceInteraction) '正在执行互动任务',
  if (room.officialFresh &&
      room.periodConfirmed &&
      !room.authorizedTasksCompleted &&
      !room.watchRunning &&
      !room.canAdvanceInteraction &&
      room.pauseReason == null &&
      room.interactionPauseReason == null &&
      room.watchPauseReason == null)
    '等待任务调度',
].join('\n');

class LiveIntimacyRecordSaveWarning extends StatelessWidget {
  const LiveIntimacyRecordSaveWarning({super.key, required this.scheduler});
  final LiveIntimacyScheduler scheduler;

  @override
  Widget build(BuildContext context) {
    final error = scheduler.persistenceError;
    if (error == null) return const SizedBox.shrink();
    final restoreCount = scheduler.rooms
        .where((room) => room.recordRestoreError != null)
        .length;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.save_outlined),
        title: Text(error),
        subtitle: Text(
          '本地记录：${scheduler.pendingRecordSaveCount}个房间待保存，$restoreCount个房间待恢复；官方同步状态单独显示。',
        ),
        trailing: TextButton(
          onPressed: scheduler.retryRecordSaves,
          child: const Text('重试记录'),
        ),
      ),
    );
  }
}

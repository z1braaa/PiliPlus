import 'package:PiliPlus/services/live_intimacy_scheduler.dart';

enum LiveIntimacyOverviewState { disabled, paused, running, completed, waiting }

/// Counts use account room grants, never the dynamic page's Live(n) list.
class LiveIntimacyStatistics {
  LiveIntimacyStatistics.fromScheduler(LiveIntimacyScheduler scheduler) {
    rooms = scheduler.rooms
        .where((room) => room.preferences.authorized)
        .toList();
    total = rooms.length;
    completed = rooms
        .where((room) => room.officialFresh && room.authorizedTasksCompleted)
        .length;
    allThreeCompleted = rooms
        .where((room) => room.allTasksCompletedConfirmed)
        .length;
    unknown = rooms
        .where((room) => !room.officialFresh || !room.periodConfirmed)
        .length;
    issues = rooms.where(hasIssue).length;
    live = scheduler.discoveryComplete
        ? rooms
              .where(
                (room) =>
                    room.live == true &&
                    room.followed == true &&
                    room.medalOwned == true,
              )
              .length
        : null;
    final advancing = rooms.any(
      (room) => room.watchRunning || room.canAdvanceInteraction,
    );
    state = !scheduler.preferences.enabled
        ? LiveIntimacyOverviewState.disabled
        : scheduler.suspendedReason != null
        ? LiveIntimacyOverviewState.paused
        : advancing
        ? LiveIntimacyOverviewState.running
        : total > 0 && completed == total && unknown == 0
        ? LiveIntimacyOverviewState.completed
        : issues > 0
        ? LiveIntimacyOverviewState.paused
        : LiveIntimacyOverviewState.waiting;
  }

  late final List<LiveIntimacyRoomState> rooms;
  late final int total;
  late final int completed;
  late final int allThreeCompleted;
  late final int unknown;
  late final int issues;
  late final int? live;
  late final LiveIntimacyOverviewState state;

  String get label => switch (state) {
    LiveIntimacyOverviewState.disabled => '已停用',
    LiveIntimacyOverviewState.paused => '已暂停',
    LiveIntimacyOverviewState.running => '运行中',
    LiveIntimacyOverviewState.completed => '授权任务完成',
    LiveIntimacyOverviewState.waiting => '待机',
  };

  static bool hasIssue(LiveIntimacyRoomState room) =>
      (room.pauseReason != null && room.pauseReason != '主播尚未开播') ||
      room.interactionPauseReason != null ||
      room.watchPauseReason != null ||
      room.watchProgress.syncError != null ||
      room.recordSaveError != null ||
      room.recordRestoreError != null;

  static String compact(int number) => number > 99 ? '99+' : '$number';
  String get ratio => '${compact(completed)}/${compact(total)}';
}

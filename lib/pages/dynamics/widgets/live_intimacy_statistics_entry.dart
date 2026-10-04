import 'package:PiliPlus/pages/setting/pages/live_intimacy_statistics.dart';
import 'package:PiliPlus/services/live_intimacy_scheduler.dart';
import 'package:PiliPlus/services/live_intimacy_statistics.dart';
import 'package:PiliPlus/utils/live_intimacy_statistics_preferences.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:material_ui/material_ui.dart';

class LiveIntimacyStatisticsEntry extends StatelessWidget {
  const LiveIntimacyStatisticsEntry({
    super.key,
    required this.expandSetting,
    this.isTop = false,
    this.scheduler,
    this.display,
    this.onOpen,
  });
  final bool expandSetting;
  final bool isTop;
  final LiveIntimacyScheduler? scheduler;
  final LiveIntimacyStatisticsPreferences? display;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    if (!expandSetting) return const SizedBox.shrink();
    final scheduler = this.scheduler ?? LiveIntimacyScheduler.instance;
    final display = this.display ?? LiveIntimacyStatisticsPreferences.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([scheduler, display]),
      builder: (context, _) {
        if (!display.enabledFor(scheduler.accountUid)) {
          return const SizedBox.shrink();
        }
        final summary = LiveIntimacyStatistics.fromScheduler(scheduler);
        final color = Theme.of(context).colorScheme;
        final icon = switch (summary.state) {
          LiveIntimacyOverviewState.disabled => Icons.power_settings_new,
          LiveIntimacyOverviewState.paused => Icons.pause_circle_outline,
          LiveIntimacyOverviewState.running => Icons.play_circle_outline,
          LiveIntimacyOverviewState.completed => Icons.check_circle_outline,
          LiveIntimacyOverviewState.waiting => Icons.hourglass_empty,
        };
        String name(LiveIntimacyRoomState? room) =>
            room?.anchorName.isNotEmpty == true
            ? room!.anchorName
            : room == null
            ? '暂无'
            : '${room.roomId}';
        final syncTimes =
            summary.rooms
                .map((room) => room.watchProgress.lastSynchronizedAt)
                .whereType<DateTime>()
                .toList()
              ..sort();
        final full = summary.rooms
            .where(
              (room) =>
                  room.preferences.mode == LiveIntimacyRoomMode.full &&
                  room.officialFresh &&
                  room.authorizedTasksCompleted,
            )
            .length;
        final restoreCount = scheduler.rooms
            .where((room) => room.recordRestoreError != null)
            .length;
        final saveIssue = scheduler.persistenceError == null
            ? ''
            : '\n本地记录待保存 ${scheduler.pendingRecordSaveCount}个房间 · 待恢复 $restoreCount个房间';
        final tooltip =
            '账号 ${scheduler.accountUid} · 亲密度任务 · ${summary.label}\n授权任务完成 ${summary.completed}/${summary.total}（完整 $full，仅点赞 ${summary.completed - full}）\n三项官方全部完成 ${summary.allThreeCompleted}\n观时：${name(scheduler.currentRoom)}\n互动：${name(scheduler.currentInteractionRoom)}\n异常房间 ${summary.issues} · 待核对 ${summary.unknown}\n${syncTimes.isEmpty ? '尚未成功同步' : '最近成功同步 ${syncTimes.last.toLocal().toString().split('.').first}'}$saveIssue';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Tooltip(
            message: tooltip,
            child: Semantics(
              label: tooltip,
              button: true,
              child: SizedBox(
                width: isTop ? 60 : 64,
                height: isTop ? 72 : 56,
                child: InkWell(
                  key: const ValueKey('dynamic-live-intimacy-statistics-entry'),
                  borderRadius: BorderRadius.circular(12),
                  onTap:
                      onOpen ??
                      () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => LiveIntimacyStatisticsPage(
                            scheduler: scheduler,
                            display: display,
                          ),
                        ),
                      ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final style = Theme.of(context).textTheme.labelSmall;
                      final scaler = MediaQuery.textScalerOf(context);
                      var label =
                          summary.ratio + (summary.unknown > 0 ? ' ?' : '');
                      final measure = TextPainter(
                        text: TextSpan(text: label, style: style),
                        textDirection: Directionality.of(context),
                        textScaler: scaler,
                      )..layout();
                      if (measure.width > constraints.maxWidth - 4) {
                        label = '统计';
                      }
                      measure.dispose();
                      final badgeFits =
                          scaler.scale(12) <= 16 && summary.issues < 100;
                      final statusIcon = Icon(
                        icon,
                        size: 22,
                        color:
                            summary.state == LiveIntimacyOverviewState.disabled
                            ? color.outline
                            : color.primary,
                      );
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          summary.issues > 0
                              ? Badge(
                                  label: badgeFits
                                      ? Text('${summary.issues}')
                                      : null,
                                  child: statusIcon,
                                )
                              : statusIcon,
                          const SizedBox(height: 2),
                          Text(
                            label,
                            style: style,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

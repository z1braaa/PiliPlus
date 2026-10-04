import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/pages/live_room/widgets/live_intimacy_progress_widgets.dart';
import 'package:PiliPlus/services/live_intimacy_scheduler.dart';
import 'package:PiliPlus/services/live_intimacy_statistics.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:PiliPlus/utils/live_intimacy_statistics_preferences.dart';
import 'package:material_ui/material_ui.dart';

enum _RoomFilter { all, unfinished, running, issues }

class LiveIntimacyStatisticsPage extends StatefulWidget {
  const LiveIntimacyStatisticsPage({super.key, this.scheduler, this.display});
  final LiveIntimacyScheduler? scheduler;
  final LiveIntimacyStatisticsPreferences? display;
  @override
  State<LiveIntimacyStatisticsPage> createState() =>
      _LiveIntimacyStatisticsPageState();
}

class _LiveIntimacyStatisticsPageState
    extends State<LiveIntimacyStatisticsPage> {
  _RoomFilter _filter = _RoomFilter.all;
  late final scheduler = widget.scheduler ?? LiveIntimacyScheduler.instance;
  late final display =
      widget.display ?? LiveIntimacyStatisticsPreferences.instance;

  @override
  Widget build(BuildContext context) {
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('亲密度任务统计'),
        actions: [
          IconButton(
            tooltip: '核对开播与官方任务',
            onPressed: scheduler.refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([scheduler, display]),
        builder: (context, _) {
          final uid = scheduler.accountUid;
          if (uid <= 0) return const Center(child: Text('登录后查看当前账号的任务统计'));
          if (!display.enabledFor(uid)) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('亲密度任务统计展示已关闭'),
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('展示开关不影响后台任务或已保存记录。'),
                  ),
                  FilledButton(
                    onPressed: () {
                      if (scheduler.accountUid == uid) {
                        display.setEnabled(uid, true);
                      }
                    },
                    child: const Text('开启统计展示'),
                  ),
                ],
              ),
            );
          }
          final summary = LiveIntimacyStatistics.fromScheduler(scheduler);
          final rooms = summary.rooms
              .where(
                (room) => switch (_filter) {
                  _RoomFilter.all => true,
                  _RoomFilter.unfinished =>
                    !room.officialFresh || !room.authorizedTasksCompleted,
                  _RoomFilter.running =>
                    room.watchRunning || room.canAdvanceInteraction,
                  _RoomFilter.issues => LiveIntimacyStatistics.hasIssue(room),
                },
              )
              .toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '当前账号 $uid · ${summary.label}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          _Count(label: '已授权', value: '${summary.total}'),
                          _Count(
                            label: '符合条件且开播',
                            value: summary.live == null
                                ? '待确认'
                                : '${summary.live}',
                          ),
                          _Count(
                            label: '授权任务完成',
                            value: '${summary.completed}/${summary.total}',
                          ),
                          _Count(
                            label: '三项全部完成',
                            value: '${summary.allThreeCompleted}',
                          ),
                          _Count(label: '待核对', value: '${summary.unknown}'),
                          _Count(label: '异常房间', value: '${summary.issues}'),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text('观时：${_name(scheduler.currentRoom)}'),
                      Text('互动：${_name(scheduler.currentInteractionRoom)}'),
                      const SizedBox(height: 8),
                      Text(scheduler.statusText),
                      const SizedBox(height: 8),
                      const Text('当前官方任务周期 · 本地有效观时约每秒更新。点赞模式的完成不代表三项全部完成。'),
                    ],
                  ),
                ),
              ),
              LiveIntimacyRecordSaveWarning(scheduler: scheduler),
              Wrap(
                spacing: 8,
                children: [
                  for (final filter in _RoomFilter.values)
                    ChoiceChip(
                      label: Text(switch (filter) {
                        _RoomFilter.all => '全部',
                        _RoomFilter.unfinished => '未完成',
                        _RoomFilter.running => '执行中',
                        _RoomFilter.issues => '异常',
                      }),
                      selected: _filter == filter,
                      onSelected: (_) => setState(() => _filter = filter),
                    ),
                ],
              ),
              if (rooms.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    summary.total == 0 ? '暂无已授权房间，请先在直播间配置并手动授权。' : '此筛选下暂无房间。',
                  ),
                ),
              for (final room in rooms) _StatisticsRoomCard(room: room),
            ],
          );
        },
      ),
    );
  }

  String _name(LiveIntimacyRoomState? room) => room == null
      ? '暂无目标'
      : room.anchorName.isEmpty
      ? '房间 ${room.roomId}'
      : room.anchorName;
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Chip(label: Text('$label $value'));
}

class _StatisticsRoomCard extends StatelessWidget {
  const _StatisticsRoomCard({required this.room});
  final LiveIntimacyRoomState room;

  @override
  Widget build(BuildContext context) {
    final progress = room.watchProgress;
    final at = progress.lastSynchronizedAt?.toLocal();
    final synchronized = at == null
        ? '尚未成功同步'
        : '最后成功同步 ${at.toString().split('.').first}';
    final issues = <String>{
      if (room.pauseReason != null) room.pauseReason!,
      if (room.interactionPauseReason != null) room.interactionPauseReason!,
      if (room.watchPauseReason != null) room.watchPauseReason!,
      if (progress.syncError != null) progress.syncError!,
      if (room.recordSaveError != null) room.recordSaveError!,
      if (room.recordRestoreError != null) room.recordRestoreError!,
    };
    return Card(
      child: ExpansionTile(
        key: PageStorageKey(room.preferences.key),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        leading: Icon(
          room.watchRunning
              ? Icons.headphones
              : room.canAdvanceInteraction
              ? Icons.chat_bubble_outline
              : room.officialFresh && room.authorizedTasksCompleted
              ? Icons.check_circle_outline
              : Icons.workspace_premium_outlined,
        ),
        title: Text(
          room.anchorName.isEmpty ? '房间 ${room.roomId}' : room.anchorName,
        ),
        subtitle: Text(
          [
            room.preferences.mode == LiveIntimacyRoomMode.likeOnly
                ? '仅自动点赞'
                : '完整任务',
            room.live == false
                ? '下播'
                : room.live == true
                ? '开播'
                : '开播待确认',
            if (!room.officialFresh || !room.periodConfirmed) '官方进度或周期待核对',
            if (room.allTasksCompletedConfirmed) '官方三项全部完成',
            if (room.officialFresh &&
                room.authorizedTasksCompleted &&
                !room.allTasksCompletedConfirmed)
              '已授权的点赞任务完成',
            if (room.watchRunning) '观时中',
            if (room.canAdvanceInteraction) '互动中',
          ].join(' · '),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('房间 ${room.roomId} · 勋章 Lv.${room.medalLevel ?? "待确认"}'),
                const SizedBox(height: 8),
                Text(
                  '${room.officialFresh && room.periodConfirmed ? "官方任务" : "缓存任务（待核对）"}：${liveIntimacyTaskSummary(room.tasks)}',
                ),
                liveIntimacyProgressView(room),
                Text(
                  synchronized +
                      (room.officialFresh && room.periodConfirmed
                          ? ' · 已同步'
                          : ' · 待核对／缓存'),
                ),
                Text('上报接受 ${progress.reportedSeconds}秒，不等同于官方结算'),
                for (final issue in issues)
                  Text(
                    issue,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

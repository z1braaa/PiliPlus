import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/pages/live_room/widgets/live_intimacy_controls.dart';
import 'package:PiliPlus/services/live_intimacy_scheduler.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class LiveIntimacySettingsPage extends StatelessWidget {
  const LiveIntimacySettingsPage({super.key, this.scheduler});
  final LiveIntimacyScheduler? scheduler;

  @override
  Widget build(BuildContext context) {
    final scheduler = this.scheduler ?? LiveIntimacyScheduler.instance;
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('后台亲密度任务'),
        actions: [
          IconButton(
            tooltip: '刷新开播与任务状态',
            onPressed: scheduler.refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: scheduler,
        builder: (context, _) {
          final account = Accounts.main;
          final generation = Accounts.mainChangeGeneration;
          bool currentAccount() =>
              identical(account, Accounts.main) &&
              generation == Accounts.mainChangeGeneration &&
              !Accounts.mainIdentityChangeInProgress;
          final preferences = scheduler.preferences;
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            children: [
              SwitchListTile(
                key: const ValueKey('live-intimacy-master-switch'),
                title: const Text('后台亲密度任务'),
                subtitle: const Text('独立静音播放音频，依次完成已授权房间的点赞、弹幕和观时'),
                value: preferences.enabled,
                onChanged: scheduler.isLoggedIn
                    ? (value) {
                        if (currentAccount()) {
                          scheduler.savePreferences(
                            preferences.copyWith(enabled: value),
                          );
                        }
                      }
                    : null,
              ),
              if (!scheduler.isLoggedIn)
                ListTile(
                  title: const Text('登录后才能配置后台任务'),
                  trailing: TextButton(
                    onPressed: () => Get.toNamed('/loginPage'),
                    child: const Text('登录'),
                  ),
                ),
              ListTile(
                title: const Text('勋章等级顺序'),
                subtitle: const Text('符合条件且未完成的当前直播间优先'),
                trailing: DropdownButton<LiveIntimacySort>(
                  key: const ValueKey('live-intimacy-sort'),
                  value: preferences.sort,
                  items: const [
                    DropdownMenuItem(
                      value: LiveIntimacySort.medalHighToLow,
                      child: Text('高→低'),
                    ),
                    DropdownMenuItem(
                      value: LiveIntimacySort.medalLowToHigh,
                      child: Text('低→高'),
                    ),
                  ],
                  onChanged: scheduler.isLoggedIn
                      ? (value) {
                          if (currentAccount() && value != null) {
                            scheduler.savePreferences(
                              preferences.copyWith(sort: value),
                            );
                          }
                        }
                      : null,
                ),
              ),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text(
                    scheduler.statusText,
                    key: const ValueKey('live-intimacy-queue-status'),
                  ),
                  subtitle: const Text('应用仍运行时继续；真正退出或系统休眠时暂停。'),
                ),
              ),
              if (scheduler.currentRoom case final room?) ...[
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('正在执行'),
                ),
                _RoomStatusCard(room: room),
              ],
              const Padding(padding: EdgeInsets.all(12), child: Text('等待队列')),
              if (scheduler.queue.isEmpty)
                const ListTile(title: Text('暂无等待中的合格房间')),
              for (final room in scheduler.queue) _RoomStatusCard(room: room),
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('房间配置与授权'),
              ),
              if (scheduler.rooms.isEmpty)
                const ListTile(title: Text('进入直播间，在“此房间亲密度任务”中配置并手动授权。')),
              for (final room in scheduler.rooms)
                Card(
                  child: Column(
                    children: [
                      _RoomStatusCard(room: room, card: false),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () {
                              if (currentAccount()) {
                                Get.toNamed(
                                  '/liveRoom',
                                  arguments: room.roomId,
                                );
                              }
                            },
                            child: const Text('前往配置'),
                          ),
                          if (room.preferences.authorized)
                            TextButton(
                              onPressed: () {
                                if (currentAccount()) {
                                  scheduler.authorizeRoom(
                                    room.preferences,
                                    false,
                                  );
                                }
                              },
                              child: const Text('停用授权'),
                            ),
                          PopupMenuButton<String>(
                            tooltip: '更多房间操作',
                            onSelected: (value) {
                              if (currentAccount() && value == 'delete') {
                                scheduler.removeRoom(
                                  room.preferences.roomId,
                                  room.preferences.anchorUid,
                                );
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('删除房间配置'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _RoomStatusCard extends StatelessWidget {
  const _RoomStatusCard({required this.room, this.card = true});
  final LiveIntimacyRoomState room;
  final bool card;

  @override
  Widget build(BuildContext context) {
    final preferences = room.preferences;
    final child = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: Icon(
            room.completed
                ? Icons.check_circle_outline
                : room.running
                ? Icons.headphones
                : Icons.workspace_premium_outlined,
          ),
          title: Text(
            room.anchorName.isEmpty
                ? '主播 UID ${preferences.anchorUid}'
                : room.anchorName,
          ),
          subtitle: Text(
            [
              '房间 ${room.roomId} · 勋章 Lv.${room.medalLevel ?? "待同步"}',
              preferences.authorized ? '已授权' : '未授权',
              if (room.pauseReason != null) room.pauseReason!,
              if (room.completed) '三项任务均已由官方确认完成',
            ].join('\n'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(liveIntimacyTaskSummary(room.tasks)),
        ),
        liveIntimacyProgressView(room),
      ],
    );
    return card ? Card(child: child) : child;
  }
}

String liveIntimacyTaskSummary(List<LiveFanTask> tasks) {
  final names = {'like': '点赞', 'sendDanmu': '弹幕', 'watchLive': '观时'};
  return names.entries
      .map((entry) {
        final matches = tasks.where((task) => task.jumpType == entry.key);
        if (matches.isEmpty) return '${entry.value}：待确认';
        final task = matches.first;
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

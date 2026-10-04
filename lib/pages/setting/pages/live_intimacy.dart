import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/pages/live_room/widgets/live_intimacy_progress_widgets.dart';
import 'package:PiliPlus/pages/setting/pages/live_intimacy_statistics.dart';
import 'package:PiliPlus/services/live_intimacy_scheduler.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:PiliPlus/utils/live_intimacy_statistics_preferences.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

export 'package:PiliPlus/pages/live_room/widgets/live_intimacy_progress_widgets.dart';

class LiveIntimacySettingsPage extends StatelessWidget {
  const LiveIntimacySettingsPage({super.key, this.scheduler, this.display});
  final LiveIntimacyScheduler? scheduler;
  final LiveIntimacyStatisticsPreferences? display;

  @override
  Widget build(BuildContext context) {
    final scheduler = this.scheduler ?? LiveIntimacyScheduler.instance;
    final display = this.display ?? LiveIntimacyStatisticsPreferences.instance;
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
        animation: Listenable.merge([scheduler, display]),
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
                subtitle: const Text('互动轮流推进，观时逐房进行；独立静音播放音频'),
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
              SwitchListTile(
                key: const ValueKey('live-intimacy-statistics-display-switch'),
                title: const Text('显示亲密度任务统计'),
                subtitle: const Text('动态入口同时需开启“动态页展开正在直播UP列表”；隐藏统计不停止任务'),
                value: display.enabledFor(scheduler.accountUid),
                onChanged: scheduler.isLoggedIn
                    ? (value) {
                        if (currentAccount()) {
                          display.setEnabled(scheduler.accountUid, value);
                        }
                      }
                    : null,
              ),
              if (display.enabledFor(scheduler.accountUid))
                ListTile(
                  key: const ValueKey('live-intimacy-statistics-open'),
                  leading: const Icon(Icons.insights_outlined),
                  title: const Text('打开实时任务统计'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    if (currentAccount()) {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => LiveIntimacyStatisticsPage(
                            scheduler: scheduler,
                            display: display,
                          ),
                        ),
                      );
                    }
                  },
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
              LiveIntimacyRecordSaveWarning(scheduler: scheduler),
              if (scheduler.currentRoom case final room?) ...[
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('当前观时房间'),
                ),
                _RoomStatusCard(room: room),
              ],
              if (scheduler.currentInteractionRoom case final room?) ...[
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('当前互动房间'),
                ),
                _RoomStatusCard(room: room),
              ],
              const Padding(padding: EdgeInsets.all(12), child: Text('等待队列')),
              if (scheduler.queue.isEmpty)
                const ListTile(title: Text('暂无等待中的合格房间')),
              for (final room in scheduler.queue) _RoomStatusCard(room: room),
              if (scheduler.interactionQueue.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('互动轮转队列'),
                ),
                for (final room in scheduler.interactionQueue)
                  _RoomStatusCard(room: room),
              ],
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
            room.allTasksCompletedConfirmed
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
              preferences.mode == LiveIntimacyRoomMode.likeOnly
                  ? '仅自动点赞'
                  : '完整任务',
              if (room.pauseReason != null) room.pauseReason!,
              if (room.watchPauseReason != null) '观时：${room.watchPauseReason!}',
              if (room.interactionPauseReason != null)
                '互动：${room.interactionPauseReason!}',
              if (!room.officialFresh || !room.periodConfirmed) '官方进度或周期待核对',
              if (room.allTasksCompletedConfirmed) '三项任务均已由官方确认完成',
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

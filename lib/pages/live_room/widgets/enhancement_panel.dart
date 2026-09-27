import 'package:PiliPlus/pages/live_room/controller.dart';
import 'package:PiliPlus/pages/live_room/contribution_rank/view.dart';
import 'package:PiliPlus/pages/live_room/superchat/superchat_panel.dart';
import 'package:PiliPlus/pages/live_room/widgets/chat_panel.dart';
import 'package:PiliPlus/pages/live_room/widgets/interaction_focus_boundary.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// Owns UI tabs only. The room's player and message subscription stay outside.
class LiveEnhancementPanel extends StatefulWidget {
  const LiveEnhancementPanel({
    super.key,
    required this.controller,
    required this.interactions,
    required this.input,
  });

  final LiveRoomController controller;
  final Widget interactions;
  final Widget input;

  @override
  State<LiveEnhancementPanel> createState() => LiveEnhancementPanelState();
}

class LiveEnhancementPanelState extends State<LiveEnhancementPanel>
    with SingleTickerProviderStateMixin {
  late final _tabs = TabController(length: 5, vsync: this);
  int _index = 0;

  void showInteractions() => _tabs.animateTo(3);
  bool get showingInteractions => _index == 3;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_onTab);
  }

  void _onTab() {
    if (_index != _tabs.index) setState(() => _index = _tabs.index);
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTab);
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return LiveInteractionFocusBoundary(
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          children: [
            Obx(
              () => Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '弹幕连接：${controller.messageConnectionState.value.label}',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: '重新连接弹幕',
                      onPressed: controller.retryLiveMessages,
                      icon: const Icon(Icons.sync, size: 18),
                    ),
                  ],
                ),
              ),
            ),
            TabBar(
              controller: _tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: const [
                Tab(text: '聊天'),
                Tab(text: 'SC'),
                Tab(text: '榜单'),
                Tab(text: '礼物 / 粉丝团'),
                Tab(text: '房间'),
              ],
            ),
            Expanded(
              child: switch (_index) {
                0 => LiveRoomChatPanel(
                  liveRoomController: controller,
                  isPP: false,
                ),
                1 =>
                  controller.showSuperChat
                      ? Column(
                          children: [
                            Obx(
                              () => controller.superChatCapacityReached.value
                                  ? const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: Text('SC 记录达到本房间会话上限，请离开后重新进入。'),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                            Expanded(
                              child: SuperChatPanel(controller: controller),
                            ),
                          ],
                        )
                      : const Center(child: Text('SC 接收展示已在设置中关闭')),
                2 => Obx(() {
                  final ruid = controller.ruid;
                  // roomInfoH5 makes the anchor resolution reactive.
                  final resolvedUid =
                      controller.roomInfoH5.value?.roomInfo?.uid;
                  final anchor = ruid ?? resolvedUid;
                  return anchor == null
                      ? const Center(child: Text('主播信息尚未加载'))
                      : ContributionRankPanel(
                          ruid: anchor,
                          roomId: controller.roomId,
                        );
                }),
                3 => widget.interactions,
                _ => _RoomInformation(controller: controller),
              },
            ),
            if (_index == 0) widget.input,
          ],
        ),
      ),
    );
  }
}

/// Narrow/fullscreen UI deliberately omits a second chat/SC instance. Those
/// lists own room scroll controllers and remain in the original room shell.
class LiveEnhancementDrawer extends StatelessWidget {
  const LiveEnhancementDrawer({
    super.key,
    required this.controller,
    required this.interactions,
    required this.onShowRank,
  });
  final LiveRoomController controller;
  final Widget interactions;
  final VoidCallback onShowRank;

  @override
  Widget build(BuildContext context) => LiveInteractionFocusBoundary(
    child: DefaultTabController(
      length: 2,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          children: [
            Row(
              children: [
                const SizedBox(width: 12),
                const Expanded(child: Text('直播互动')),
                TextButton(onPressed: onShowRank, child: const Text('榜单')),
                IconButton(
                  tooltip: '关闭面板',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const TabBar(
              tabs: [
                Tab(text: '礼物 / 粉丝团'),
                Tab(text: '房间'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  interactions,
                  _RoomInformation(controller: controller),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _RoomInformation extends StatelessWidget {
  const _RoomInformation({required this.controller});
  final LiveRoomController controller;

  @override
  Widget build(BuildContext context) => Obx(() {
    final info = controller.roomInfoH5.value;
    final anchor = info?.anchorInfo?.baseInfo?.uname;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          info?.roomInfo?.title ?? '房间信息加载中',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        Text('主播：${anchor ?? "尚未加载"}'),
        const SizedBox(height: 8),
        SelectableText('房间：${controller.roomId}'),
        const SizedBox(height: 8),
        controller.watchedWidget,
        const SizedBox(height: 8),
        controller.timeWidget,
        const SizedBox(height: 16),
        const Text('此版本暂不支持房间公告和特殊活动。'),
      ],
    );
  });
}

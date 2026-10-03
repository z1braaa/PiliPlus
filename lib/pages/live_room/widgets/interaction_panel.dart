import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/models/common/image_type.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/services/live_task_automation.dart';
import 'package:PiliPlus/utils/live_viewer_preferences.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:material_ui/material_ui.dart';

/// Kept by the room page, so hiding UI never turns an uncertain write into a
/// new request. The service additionally journals pending writes across exits.
class LiveInteractionSession extends ChangeNotifier {
  LiveInteractionSession({required this.service, required this.isEnabled});

  final LiveInteractionService service;
  final ValueGetter<bool> isEnabled;
  LiveInteractionSnapshot? snapshot;
  LiveActionResult? result;
  String? error;
  bool loading = false;
  bool preparing = false;
  bool _disposed = false;
  int _readGeneration = 0;
  Object? _snapshotAccountIdentity;
  final _confirmationGenerations = Map<LiveGiftConfirmation, int>.identity();

  bool get blocked =>
      preparing ||
      result?.state == LiveActionState.submitting ||
      result?.state == LiveActionState.unknown;

  bool get snapshotMatchesCurrentAccount =>
      snapshot != null &&
      _snapshotAccountIdentity != null &&
      identical(_snapshotAccountIdentity, service.accountIdentity);

  bool get snapshotAccountChanged =>
      _snapshotAccountIdentity != null &&
      !identical(_snapshotAccountIdentity, service.accountIdentity);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _clearChangedAccount(Object identity) {
    if (!_disposed && !identical(identity, service.accountIdentity)) {
      snapshot = null;
      result = null;
      error = null;
      _snapshotAccountIdentity = null;
    }
  }

  void hide({bool notify = true}) {
    ++_readGeneration;
    _confirmationGenerations.clear();
    service.invalidateApprovals();
    loading = false;
    // Submitted writes continue to settle; no cancellation/retry is claimed.
    if (notify) _notify();
  }

  Future<void> load() async {
    if (_disposed || !isEnabled() || loading) return;
    final identity = service.accountIdentity;
    if (_snapshotAccountIdentity case final previous?) {
      _clearChangedAccount(previous);
    }
    final generation = ++_readGeneration;
    loading = true;
    error = null;
    _notify();
    try {
      final next = await service.loadPanel();
      if (_disposed || generation != _readGeneration || !isEnabled()) return;
      if (!identical(identity, service.accountIdentity)) {
        _clearChangedAccount(identity);
        return;
      }
      snapshot = next;
      _snapshotAccountIdentity = identity;
      // lastAction is scoped by the service to the freshly loaded account.
      result = service.lastAction;
    } catch (e) {
      if (!_disposed && generation == _readGeneration) error = _errorText(e);
    } finally {
      if (!_disposed && generation == _readGeneration) {
        loading = false;
        _notify();
      }
    }
  }

  Future<LiveGiftConfirmation?> prepare(
    Future<LiveGiftConfirmation> Function() action,
  ) async {
    if (_disposed || !isEnabled() || blocked) return null;
    preparing = true;
    final identity = service.accountIdentity;
    final generation = _readGeneration;
    error = null;
    _notify();
    try {
      final confirmation = await action();
      if (!_disposed &&
          isEnabled() &&
          generation == _readGeneration &&
          identical(identity, service.accountIdentity)) {
        _confirmationGenerations[confirmation] = generation;
        return confirmation;
      }
      return null;
    } catch (e) {
      if (!_disposed && generation == _readGeneration) error = _errorText(e);
      return null;
    } finally {
      preparing = false;
      _clearChangedAccount(identity);
      _notify();
    }
  }

  Future<void> submit(LiveGiftConfirmation confirmation) async {
    final generation = _confirmationGenerations.remove(confirmation);
    if (_disposed || !isEnabled() || blocked || generation != _readGeneration) {
      return;
    }
    preparing = true; // Locks the button before the first asynchronous step.
    final identity = service.accountIdentity;
    error = null;
    _notify();
    try {
      final settled = await service.submitGift(confirmation);
      if (!_disposed && identical(identity, service.accountIdentity)) {
        result = settled;
      }
    } catch (e) {
      if (!_disposed && identical(identity, service.accountIdentity)) {
        error = _errorText(e);
        result = service.lastAction ?? result;
      }
    } finally {
      preparing = false;
      _clearChangedAccount(identity);
      _notify();
    }
    await load();
  }

  Future<void> reconcile() async {
    final pending = result;
    if (_disposed || preparing || pending == null || !isEnabled()) return;
    preparing = true;
    final identity = service.accountIdentity;
    _notify();
    try {
      final settled = await service.reconcile(pending);
      if (!_disposed && identical(identity, service.accountIdentity)) {
        result = settled;
      }
    } catch (e) {
      if (!_disposed && identical(identity, service.accountIdentity)) {
        error = _errorText(e);
      }
    } finally {
      preparing = false;
      _clearChangedAccount(identity);
      _notify();
    }
    await load();
  }

  Future<void> medal(Future<LiveActionResult> Function() action) async {
    if (_disposed || !isEnabled() || blocked) return;
    preparing = true;
    final identity = service.accountIdentity;
    _notify();
    try {
      final settled = await action();
      if (!_disposed && identical(identity, service.accountIdentity)) {
        result = settled;
      }
    } catch (e) {
      if (!_disposed && identical(identity, service.accountIdentity)) {
        error = _errorText(e);
      }
    } finally {
      preparing = false;
      _clearChangedAccount(identity);
      _notify();
    }
    await load();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_readGeneration;
    service.dispose();
    super.dispose();
  }
}

String _errorText(Object error) => error is LiveInteractionException
    ? error.toString()
    : '请求未完成，请刷新状态。已提交操作请先只读核对，不要重复发送。';

class LiveInteractionPanel extends StatefulWidget {
  const LiveInteractionPanel({
    super.key,
    required this.session,
    required this.anchorName,
    required this.onLogin,
    required this.onRecharge,
    required this.onOpenGuard,
    this.initialTab = 0,
    this.quickGift,
    this.quickQuantity = 1,
    this.taskAutomation,
    this.automationPreferences = const LiveTaskAutomationPreferences(),
    this.onAutomationPreferencesChanged,
    this.watchStatusText,
    this.onWatchRetry,
    this.watchCanRetry = true,
    this.intimacyControls,
    this.intimacyTasks,
    this.intimacyUpdates,
  });

  final LiveInteractionSession session;
  final String anchorName;
  final VoidCallback onLogin;
  final Future<void> Function() onRecharge;
  final Future<void> Function() onOpenGuard;
  final int initialTab;
  final LiveGift? quickGift;
  final int quickQuantity;
  final LiveTaskAutomationService? taskAutomation;
  final LiveTaskAutomationPreferences automationPreferences;
  final ValueChanged<LiveTaskAutomationPreferences>?
  onAutomationPreferencesChanged;
  final String? watchStatusText;
  final VoidCallback? onWatchRetry;
  final bool watchCanRetry;
  final Widget? intimacyControls;
  final ValueGetter<List<LiveFanTask>?>? intimacyTasks;
  final Listenable? intimacyUpdates;

  @override
  State<LiveInteractionPanel> createState() => _LiveInteractionPanelState();
}

class _LiveInteractionPanelState extends State<LiveInteractionPanel> {
  late int _tab = widget.initialTab.clamp(0, 3).toInt();
  final _quantity = TextEditingController(text: '1');
  ModalRoute<dynamic>? _confirmationRoute;

  @override
  void initState() {
    super.initState();
    _quantity.text = '${widget.quickQuantity}';
    widget.session.addListener(_cancelDisabledConfirmation);
    if (widget.session.snapshot == null) widget.session.load();
    if (widget.quickGift case final gift?) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _gift(gift);
      });
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_cancelDisabledConfirmation);
    widget.session.hide(notify: false);
    final route = _confirmationRoute;
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
    _quantity.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LiveInteractionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session == widget.session) {
      if (widget.session.snapshotAccountChanged) {
        final current = widget.session;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && widget.session == current) current.load();
        });
      }
      return;
    }
    oldWidget.session.removeListener(_cancelDisabledConfirmation);
    oldWidget.session.hide(notify: false);
    final route = _confirmationRoute;
    _confirmationRoute = null;
    if (route != null && route.isActive) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => route.navigator?.removeRoute(route),
      );
    }
    widget.session.addListener(_cancelDisabledConfirmation);
    final current = widget.session;
    if (current.snapshot == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.session == current) current.load();
      });
    }
  }

  void _cancelDisabledConfirmation() {
    final route = _confirmationRoute;
    if (!widget.session.isEnabled() && route != null) {
      _confirmationRoute = null;
      if (route.isActive) route.navigator?.removeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.session,
      widget.taskAutomation,
      widget.intimacyUpdates,
    ]),
    builder: (context, _) {
      final session = widget.session;
      final data = session.snapshotAccountChanged ? null : session.snapshot;
      return NestedScrollView(
        headerSliverBuilder: (_, _) => [
          SliverToBoxAdapter(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '接收主播：${widget.anchorName}\n房间 ${session.service.roomId}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: '只读刷新目录和状态',
                        onPressed: session.loading ? null : session.load,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                ),
                if (session.loading || session.preparing)
                  const LinearProgressIndicator(),
                if (session.error case final error?)
                  _Notice(error, isError: true),
                if (session.result case final result?) _result(result),
                if (data != null && !data.loggedIn)
                  ListTile(
                    title: const Text('登录后可查看背包、粉丝状态并送礼'),
                    trailing: TextButton(
                      onPressed: widget.onLogin,
                      child: const Text('登录'),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      for (final entry
                          in (_tab < 2
                              ? const [(0, '礼物'), (1, '背包')]
                              : const [(2, '粉丝团'), (3, '大航海')]))
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(entry.$2),
                            selected: _tab == entry.$1,
                            onSelected: (_) => setState(() => _tab = entry.$1),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_tab < 2)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _quantity,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: const InputDecoration(
                              labelText: '数量',
                              helperText: '提交前重新核对商品和金额',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: data?.loggedIn == true
                              ? () async {
                                  await widget.onRecharge();
                                  if (mounted) widget.session.load();
                                }
                              : null,
                          icon: const Icon(Icons.battery_charging_full),
                          label: const Text('充值'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        body: data == null
            ? Center(
                child: Text(session.loading ? '正在读取官方状态' : '状态未加载，请刷新'),
              )
            : switch (_tab) {
                0 => _gifts(data),
                1 => _bag(data),
                2 => _fans(data),
                _ => _guard(data),
              },
      );
    },
  );

  Widget _result(LiveActionResult result) {
    final label = switch (result.state) {
      LiveActionState.notSubmitted => '未提交',
      LiveActionState.submitting => '提交中',
      LiveActionState.succeeded => '服务端已确认',
      LiveActionState.failed => '未完成',
      LiveActionState.unknown => '结果未知，请勿重复发送',
    };
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(result.message),
            if (result.receiptId case final receipt?) Text('回执：$receipt'),
            if (result.state == LiveActionState.unknown)
              TextButton.icon(
                onPressed: widget.session.preparing
                    ? null
                    : widget.session.reconcile,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('只读核对，不重复提交'),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _errors(LiveInteractionSnapshot data) => data.errors.entries
      .map((e) => _Notice('${e.key}：${e.value}', isError: true))
      .toList();

  Widget _gifts(LiveInteractionSnapshot data) => CustomScrollView(
    slivers: [
      SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (data.wallet case final wallet?)
              _Notice(
                '官方余额：电池 ${wallet.gold == null ? "未知" : liveBatteryAmount(wallet.gold!)}；银瓜子 ${wallet.silver ?? "未知"}。币种以商品当前价格为准。',
              ),
            const _Notice(
              '充值在官方页面办理。若页面要求登录，请返回 PiliPlus 刷新登录后重试；返回后不能凭页面关闭判断充值成功。',
            ),
            ..._errors(data),
            if (data.gifts.isEmpty) const _Notice('本房间没有可用礼物目录，不能提交送礼。'),
          ],
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
        sliver: SliverLayoutBuilder(
          builder: (context, constraints) => SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 145,
              mainAxisExtent: 166,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final gift = data.gifts[index];
                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Column(
                      children: [
                        Expanded(
                          child: gift.imageUrl.isEmpty
                              ? const Icon(Icons.card_giftcard, size: 42)
                              : Image.network(
                                  gift.imageUrl,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, _, _) =>
                                      const Icon(Icons.card_giftcard, size: 42),
                                ),
                        ),
                        Text(
                          gift.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          gift.priceKnown
                              ? '${gift.displayPrice} ${gift.coinLabel}'
                              : '价格未知',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        SizedBox(
                          height: 32,
                          child: TextButton(
                            onPressed:
                                data.loggedIn &&
                                    gift.sendable &&
                                    !widget.session.blocked
                                ? () => _gift(gift)
                                : null,
                            child: const Text('投喂'),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
              childCount: data.gifts.length,
            ),
          ),
        ),
      ),
    ],
  );

  Widget _bag(LiveInteractionSnapshot data) => CustomScrollView(
    slivers: [
      SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ..._errors(data),
            if (!data.loggedIn)
              const _Notice('请先登录。')
            else if (data.bag.isEmpty)
              const _Notice('背包暂无礼物；读取异常时会单独显示，不能视为库存为零。'),
          ],
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 145,
            mainAxisExtent: 170,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final item = data.bag[index];
              return Card(
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    children: [
                      Expanded(
                        child: item.gift.imageUrl.isEmpty
                            ? const Icon(Icons.inventory_2_outlined, size: 42)
                            : Image.network(
                                item.gift.imageUrl,
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) => const Icon(
                                  Icons.inventory_2_outlined,
                                  size: 42,
                                ),
                              ),
                      ),
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '库存 ${item.quantity}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      Text(
                        item.expiresAt == null
                            ? '有效期未知'
                            : '至 ${item.expiresAt!.toLocal().toString().split(' ').first}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      SizedBox(
                        height: 32,
                        child: TextButton(
                          onPressed:
                              item.available &&
                                  data.loggedIn &&
                                  !widget.session.blocked
                              ? () => _gift(item.gift, bag: item)
                              : null,
                          child: const Text('赠送'),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
            childCount: data.bag.length,
          ),
        ),
      ),
    ],
  );

  Widget _fans(LiveInteractionSnapshot data) {
    final status = data.fanStatus;
    final refreshedTasks = widget.taskAutomation?.tasks;
    final tasks =
        widget.intimacyTasks?.call() ??
        (refreshedTasks != null && refreshedTasks.isNotEmpty
            ? refreshedTasks
            : status?.tasks ?? const <LiveFanTask>[]);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      children: [
        ..._errors(data),
        if (status == null) ...[
          Card(
            child: ListTile(
              leading: const Icon(Icons.workspace_premium_outlined),
              title: Text('${widget.anchorName}的粉丝团'),
              subtitle: Text(
                data.loggedIn
                    ? '成员与灯牌状态暂未取得，请稍后只读刷新。'
                    : '访客可浏览此面板；成员等级、勋章与灯牌状态登录后读取。',
              ),
            ),
          ),
          const _Notice('粉丝团和灯牌状态未取得，不能推断为未加入或未点亮。'),
        ] else ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.anchorName}的${status.name.isEmpty ? "粉丝团" : status.name}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '粉丝团：${_state(status.joined, "已加入", "未加入")}  ·  灯牌：${_state(status.isLighted, "已点亮", "未点亮")}',
                  ),
                  Text(
                    '勋章 Lv.${status.level ?? "未知"}  ·  亲密度 ${status.intimacy ?? "未知"} / ${status.nextIntimacy ?? "未知"}',
                  ),
                  if (status.intimacy != null &&
                      status.nextIntimacy != null &&
                      status.nextIntimacy! > 0) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: (status.intimacy! / status.nextIntimacy!).clamp(
                        0.0,
                        1.0,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (status.joined != true)
            _fanButton(
              '加入粉丝团',
              LiveGiftPurpose.joinFanClub,
              status.joinGift,
              data.loggedIn && status.joined == false,
            ),
          if (status.joined == true && status.isLighted != true)
            _fanButton(
              '点亮灯牌',
              LiveGiftPurpose.lightMedal,
              status.lightGift,
              data.loggedIn && status.isLighted == false,
            ),
        ],
        const SizedBox(height: 12),
        Text('亲密度任务', style: Theme.of(context).textTheme.titleMedium),
        if (tasks.isEmpty) const _Notice('当前没有可展示的任务；每日规则以官方页面为准。'),
        for (final task in tasks)
          Card(
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.favorite_border),
              title: Text(task.name),
              subtitle: Text(
                [
                  task.description,
                  if (task.currentCount != null && task.targetCount != null)
                    '进度 ${task.currentCount} / ${task.targetCount}'
                  else if (task.progressText.isNotEmpty)
                    task.progressText,
                  if ((task.jumpType == 'like' ||
                          task.jumpType == 'sendDanmu') &&
                      task.remainingCount == null)
                    '数量尚未确认，自动操作暂停',
                ].where((text) => text.isNotEmpty).join('\n'),
              ),
              trailing: Text(_state(task.completed, '已完成', '待完成')),
            ),
          ),
        if (widget.watchStatusText != null)
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: Text(widget.intimacyControls == null ? '观看时长' : '正常观看上报'),
            subtitle: Text(widget.watchStatusText!),
            trailing: widget.watchCanRetry && widget.onWatchRetry != null
                ? IconButton(
                    tooltip: '重试观看上报',
                    icon: const Icon(Icons.refresh),
                    onPressed: widget.onWatchRetry,
                  )
                : null,
          ),
        if (widget.intimacyControls case final controls?)
          controls
        else if (widget.taskAutomation case final automation?)
          LiveTaskAutomationControls(
            key: ValueKey('live-task-automation:${data.accountUid}'),
            service: automation,
            preferences: widget.automationPreferences,
            loggedIn: widget.session.service.isLoggedIn,
            snapshotReady: widget.session.snapshotMatchesCurrentAccount,
            onChanged: widget.onAutomationPreferencesChanged,
            roomId: widget.session.service.roomId,
            anchorUid: widget.session.service.anchorUid,
            loadEmoticons: widget.session.service.loadTaskEmoticons,
          ),
        const SizedBox(height: 12),
        Text('勋章佩戴与摘下', style: Theme.of(context).textTheme.titleMedium),
        if (data.medals.isEmpty) const _Notice('未取得可佩戴勋章。'),
        for (final medal in data.medals)
          Card(
            child: ListTile(
              title: Text('${medal.name} · Lv.${medal.level}'),
              subtitle: Text(
                '${medal.wearing ? "佩戴中" : "未佩戴"}；'
                '灯牌：${_state(medal.isLighted, "亮", "未点亮")}\n'
                '主播 UID：${medal.targetUid}'
                '${medal.targetUid == widget.session.service.anchorUid ? "" : "\n属于其他主播，本面板仅办理当前直播间勋章"}',
              ),
              trailing: TextButton(
                onPressed:
                    data.loggedIn &&
                        !widget.session.blocked &&
                        medal.targetUid == widget.session.service.anchorUid
                    ? () => _medal(medal)
                    : null,
                child: Text(medal.wearing ? '摘下' : '佩戴'),
              ),
            ),
          ),
      ],
    );
  }

  Widget _guard(LiveInteractionSnapshot data) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text('大航海', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 12),
      if (data.guardStatus case final status?) ...[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '大航海只读响应（字段含义待登录核实）',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text('身份状态码：${status.activeState ?? "未提供"}'),
                for (final tier in status.tiers)
                  Text(
                    '${tier.label}（档位代码 ${tier.type}）· 状态码 ${tier.status ?? "未提供"}'
                    '${tier.expiresAt == null ? "" : " · 到期字段 ${tier.expiresAt!.toLocal().toString().split(" ").first}"}',
                  ),
                const Text('这些只读字段不能证明本次付款或开通成功。'),
              ],
            ),
          ),
        ),
      ] else
        const _Notice('大航海身份尚未取得；返回官方页面后可只读刷新，但不能凭页面关闭判断开通成功。'),
      const Text('舰长、提督、总督的档位、权益、期限和最终价格以当前主播的哔哩哔哩官方页面为准。'),
      const SizedBox(height: 16),
      const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('付款前请在官方页面核对主播、档位、期限、金额及连续包月条款。返回此页只会刷新身份状态，不视为支付成功。'),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: data.loggedIn
            ? () async {
                await widget.onOpenGuard();
                if (mounted) widget.session.load();
              }
            : null,
        icon: const Icon(Icons.sailing_outlined),
        label: const Text('在应用内打开官方大航海'),
      ),
      if (!data.loggedIn)
        const _Notice('请先在 PiliPlus 登录。')
      else
        const _Notice('若官方页面仍要求登录，请返回 PiliPlus 刷新登录后重试。'),
    ],
  );

  String _state(bool? value, String yes, String no) => value == null
      ? '未知'
      : value
      ? yes
      : no;

  Widget _fanButton(
    String label,
    LiveGiftPurpose purpose,
    LiveGift? gift,
    bool available,
  ) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          gift == null
              ? '当前入团 / 点亮规则未取得，暂不能办理。'
              : '按当前官方规则赠送 ${gift.name} × 1，价格会在确认前重新读取。',
        ),
        FilledButton(
          onPressed: available && gift != null && !widget.session.blocked
              ? () => _fanAction(purpose)
              : null,
          child: Text(label),
        ),
      ],
    ),
  );

  Future<void> _gift(LiveGift gift, {LiveBagItem? bag}) async {
    final count = int.tryParse(_quantity.text);
    if (count == null ||
        count < 1 ||
        count > gift.maxQuantity ||
        (bag != null && count > bag.quantity)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '请输入有效数量（1–${bag == null ? gift.maxQuantity : bag.quantity}）。',
          ),
        ),
      );
      return;
    }
    final confirmation = await widget.session.prepare(
      () => widget.session.service.prepareGift(gift, count, bagItem: bag),
    );
    if (confirmation != null && mounted) await _confirmGift(confirmation);
  }

  Future<void> _fanAction(LiveGiftPurpose purpose) async {
    final confirmation = await widget.session.prepare(
      () => widget.session.service.prepareFanAction(purpose),
    );
    if (confirmation != null && mounted) await _confirmGift(confirmation);
  }

  Future<void> _confirmGift(LiveGiftConfirmation confirmation) async {
    final action = switch (confirmation.purpose) {
      LiveGiftPurpose.gift => '送礼',
      LiveGiftPurpose.joinFanClub => '赠礼并加入粉丝团',
      LiveGiftPurpose.lightMedal => '赠礼并点亮灯牌',
    };
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        _confirmationRoute = ModalRoute.of(dialogContext);
        return AlertDialog(
          title: Text('确认$action'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('主播：${widget.anchorName}'),
                Text(
                  '房间：${confirmation.roomId}；主播 UID：${confirmation.anchorUid}',
                ),
                Text('付款账号 UID：${confirmation.accountUid}'),
                Text('礼物：${confirmation.gift.name} × ${confirmation.quantity}'),
                Text(
                  confirmation.bagItem != null
                      ? '使用背包库存，不消耗瓜子'
                      : '合计：${confirmation.displayTotalPrice} ${confirmation.coinLabel}',
                ),
                const SizedBox(height: 12),
                const Text('点击确认后向官方提交一次。超时或断线会保留未知结果，只读核对不会重复扣款。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认提交'),
            ),
          ],
        );
      },
    );
    _confirmationRoute = null;
    if (confirmed == true && mounted && widget.session.isEnabled()) {
      await widget.session.submit(confirmation);
    }
  }

  Future<void> _medal(LiveMedal medal) async {
    final identity = widget.session.service.accountIdentity;
    final expiresAt = DateTime.now().add(const Duration(seconds: 45));
    final action = medal.wearing ? '摘下' : '佩戴';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        _confirmationRoute = ModalRoute.of(dialogContext);
        return AlertDialog(
          title: Text('确认$action勋章'),
          content: Text(
            '${medal.name} · Lv.${medal.level}\n主播 UID：${medal.targetUid}\n此操作不等于加入粉丝团或点亮灯牌。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认'),
            ),
          ],
        );
      },
    );
    _confirmationRoute = null;
    if (confirmed == true && mounted && widget.session.isEnabled()) {
      if (DateTime.now().isAfter(expiresAt)) return;
      await widget.session.medal(
        () => medal.wearing
            ? widget.session.service.takeOffMedal(
                expectedAccountIdentity: identity,
              )
            : widget.session.service.wearMedal(
                medal,
                expectedAccountIdentity: identity,
              ),
      );
    }
  }
}

/// Editing this panel changes preferences only; the playback session owns work.
class LiveTaskAutomationControls extends StatefulWidget {
  const LiveTaskAutomationControls({
    super.key,
    required this.service,
    required this.preferences,
    required this.loggedIn,
    required this.onChanged,
    this.snapshotReady = true,
    this.roomId = 0,
    this.anchorUid = 0,
    this.loadEmoticons,
  });

  final LiveTaskAutomationService service;
  final LiveTaskAutomationPreferences preferences;
  final bool loggedIn;
  final bool snapshotReady;
  final ValueChanged<LiveTaskAutomationPreferences>? onChanged;
  final int roomId;
  final int anchorUid;
  final Future<List<LiveTaskEmoticonOption>> Function()? loadEmoticons;

  @override
  State<LiveTaskAutomationControls> createState() =>
      _LiveTaskAutomationControlsState();
}

class _LiveTaskAutomationControlsState
    extends State<LiveTaskAutomationControls> {
  ModalRoute<dynamic>? _settingsRoute;
  bool get _editable =>
      widget.loggedIn && widget.snapshotReady && widget.onChanged != null;

  void _closeEditor() {
    final route = _settingsRoute;
    _settingsRoute = null;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
  }

  @override
  void didUpdateWidget(covariant LiveTaskAutomationControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_editable ||
        !identical(oldWidget.service, widget.service) ||
        oldWidget.roomId != widget.roomId ||
        oldWidget.anchorUid != widget.anchorUid) {
      _closeEditor();
    }
  }

  @override
  void dispose() {
    _closeEditor();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.service,
    builder: (context, _) {
      final preferences = widget.preferences;
      final usingEmoticon =
          preferences.danmakuMode == LiveTaskDanmakuMode.emoticon;
      final hasEmoticon = preferences.defaultEmoticonUnique.isNotEmpty;
      final matchesRoom =
          preferences.defaultEmoticonRoomId == widget.roomId &&
          preferences.defaultEmoticonAnchorUid == widget.anchorUid &&
          widget.roomId > 0 &&
          widget.anchorUid > 0;
      return Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                '自动完成亲密度任务',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            SwitchListTile(
              key: const ValueKey('live-auto-like'),
              title: const Text('自动点赞'),
              subtitle: const Text('按剩余点赞数量执行，完成后停止'),
              value: preferences.autoLike,
              onChanged: _editable
                  ? (value) => widget.onChanged!(
                      preferences.copyWith(autoLike: value),
                    )
                  : null,
            ),
            SwitchListTile(
              key: const ValueKey('live-auto-danmaku'),
              title: const Text('自动弹幕'),
              subtitle: Text(
                usingEmoticon
                    ? !hasEmoticon
                          ? '选择默认表情后执行；当前等待设置'
                          : !matchesRoom
                          ? '表情与当前直播间不匹配，自动操作暂停'
                          : '发送前核对表情权限，完成后停止'
                    : preferences.defaultMessage.trim().isEmpty
                    ? '设置默认弹幕后执行；当前等待设置'
                    : '按剩余弹幕数量执行，完成后停止',
              ),
              value: preferences.autoDanmaku,
              onChanged: _editable
                  ? (value) => widget.onChanged!(
                      preferences.copyWith(autoDanmaku: value),
                    )
                  : null,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SegmentedButton<LiveTaskDanmakuMode>(
                segments: const [
                  ButtonSegment(
                    value: LiveTaskDanmakuMode.text,
                    label: Text('文字', key: ValueKey('live-danmaku-mode-text')),
                    icon: Icon(Icons.text_fields),
                  ),
                  ButtonSegment(
                    value: LiveTaskDanmakuMode.emoticon,
                    label: Text(
                      '表情',
                      key: ValueKey('live-danmaku-mode-emoticon'),
                    ),
                    icon: Icon(Icons.emoji_emotions_outlined),
                  ),
                ],
                selected: {preferences.danmakuMode},
                onSelectionChanged: _editable
                    ? (values) => widget.onChanged!(
                        preferences.copyWith(danmakuMode: values.single),
                      )
                    : null,
              ),
            ),
            ListTile(
              key: ValueKey(
                usingEmoticon
                    ? 'live-default-emoticon'
                    : 'live-default-danmaku',
              ),
              title: Text(usingEmoticon ? '默认发送表情' : '默认发送弹幕'),
              subtitle: Text(
                usingEmoticon
                    ? !hasEmoticon
                          ? '请选择当前主播的可用表情'
                          : !matchesRoom
                          ? '已保存表情属于其他直播间，请重新选择'
                          : '${preferences.defaultEmoticonName.isEmpty ? "已选表情" : preferences.defaultEmoticonName} · 发送前核对可用状态'
                    : preferences.defaultMessage.isEmpty
                    ? '尚未设置'
                    : preferences.defaultMessage,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.edit_outlined),
              onTap: _editable
                  ? usingEmoticon
                        ? widget.loadEmoticons != null &&
                                  widget.roomId > 0 &&
                                  widget.anchorUid > 0
                              ? _editEmoticon
                              : null
                        : _editMessage
                  : null,
            ),
            ListTile(
              key: const ValueKey('live-danmaku-interval'),
              title: const Text('弹幕随机间隔'),
              subtitle: Text(
                '${preferences.minIntervalSeconds}–${preferences.maxIntervalSeconds} 秒',
              ),
              trailing: const Icon(Icons.edit_outlined),
              onTap: _editable ? _editInterval : null,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    !widget.loggedIn
                        ? '登录后可开启自动任务。'
                        : !widget.snapshotReady
                        ? '账号任务状态正在刷新，自动操作暂停。'
                        : widget.service.statusText,
                    key: const ValueKey('live-task-automation-status'),
                  ),
                  if (widget.loggedIn && widget.snapshotReady)
                    if (widget.service.error case final error?) ...[
                      const SizedBox(height: 4),
                      Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  const SizedBox(height: 8),
                  const Text(
                    '设置按账号记住，只在当前直播实际播放时执行。后台或小窗继续播放时也会继续；关闭此面板保留设置。',
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );

  Future<void> _editEmoticon() async {
    final loader = widget.loadEmoticons;
    if (!_editable || loader == null) return;
    final service = widget.service;
    final identity = service.accountIdentity;
    final roomId = widget.roomId;
    final anchorUid = widget.anchorUid;
    final route = DialogRoute<LiveTaskEmoticonOption>(
      context: context,
      builder: (context) => _LiveTaskEmoticonPicker(load: loader),
    );
    LiveTaskEmoticonOption? value;
    try {
      _settingsRoute = route;
      value = await Navigator.of(context, rootNavigator: true).push(route);
      await route.completed;
    } finally {
      if (identical(_settingsRoute, route)) _settingsRoute = null;
    }
    if (mounted &&
        _editable &&
        identical(service, widget.service) &&
        identical(identity, service.accountIdentity) &&
        roomId == widget.roomId &&
        anchorUid == widget.anchorUid &&
        value != null &&
        value.available &&
        value.unique.isNotEmpty) {
      widget.onChanged!(
        widget.preferences.copyWith(
          danmakuMode: LiveTaskDanmakuMode.emoticon,
          defaultEmoticonUnique: value.unique,
          defaultEmoticonName: value.label,
          defaultEmoticonRoomId: roomId,
          defaultEmoticonAnchorUid: anchorUid,
        ),
      );
    }
  }

  Future<void> _editMessage() async {
    final controller = TextEditingController(
      text: widget.preferences.defaultMessage,
    );
    String? value;
    try {
      final route = DialogRoute<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('默认发送弹幕'),
          content: TextField(
            key: const ValueKey('live-default-danmaku-editor'),
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '填写要自动发送的内容',
              helperText: '清空后自动弹幕会等待设置。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      _settingsRoute = route;
      value = await Navigator.of(context, rootNavigator: true).push(route);
      await route.completed;
    } finally {
      _settingsRoute = null;
      controller.dispose();
    }
    if (mounted && _editable && value != null) {
      widget.onChanged!(widget.preferences.copyWith(defaultMessage: value));
    }
  }

  Future<void> _editInterval() async {
    final minimum = TextEditingController(
      text: '${widget.preferences.minIntervalSeconds}',
    );
    final maximum = TextEditingController(
      text: '${widget.preferences.maxIntervalSeconds}',
    );
    final form = GlobalKey<FormState>();
    (int, int)? value;
    String? validate(String? text) {
      final seconds = int.tryParse(text ?? '');
      if (seconds == null ||
          seconds < LiveTaskAutomationPreferences.minimumIntervalSeconds ||
          seconds > LiveTaskAutomationPreferences.maximumIntervalSeconds) {
        return '请输入 10–3600 秒';
      }
      return null;
    }

    try {
      final route = DialogRoute<(int, int)>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('弹幕随机间隔'),
          scrollable: true,
          content: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  key: const ValueKey('live-interval-minimum'),
                  controller: minimum,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: '最短间隔（秒）'),
                  validator: validate,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('live-interval-maximum'),
                  controller: maximum,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: '最长间隔（秒）'),
                  validator: (text) {
                    final error = validate(text);
                    if (error != null) return error;
                    final low = int.tryParse(minimum.text);
                    final high = int.parse(text!);
                    return low != null && low > high ? '最长间隔不能小于最短间隔' : null;
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) {
                  Navigator.of(context).pop((
                    int.parse(minimum.text),
                    int.parse(maximum.text),
                  ));
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      );
      _settingsRoute = route;
      value = await Navigator.of(context, rootNavigator: true).push(route);
      await route.completed;
    } finally {
      _settingsRoute = null;
      minimum.dispose();
      maximum.dispose();
    }
    if (mounted && _editable && value != null) {
      widget.onChanged!(
        widget.preferences.copyWith(
          minIntervalSeconds: value.$1,
          maxIntervalSeconds: value.$2,
        ),
      );
    }
  }
}

class _LiveTaskEmoticonPicker extends StatefulWidget {
  const _LiveTaskEmoticonPicker({required this.load});
  final Future<List<LiveTaskEmoticonOption>> Function() load;

  @override
  State<_LiveTaskEmoticonPicker> createState() =>
      _LiveTaskEmoticonPickerState();
}

class _LiveTaskEmoticonPickerState extends State<_LiveTaskEmoticonPicker> {
  late Future<List<LiveTaskEmoticonOption>> _options = widget.load();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('选择默认发送表情'),
    content: SizedBox(
      width: 360,
      height: 360,
      child: FutureBuilder<List<LiveTaskEmoticonOption>>(
        future: _options,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final loaded = snapshot.data ?? const <LiveTaskEmoticonOption>[];
          final options = [
            ...loaded.where((option) => option.isFanClub),
            ...loaded.where((option) => !option.isFanClub),
          ];
          if (snapshot.hasError || options.isEmpty) {
            return Center(
              child: TextButton.icon(
                key: const ValueKey('live-emoticon-retry'),
                onPressed: () {
                  final next = widget.load();
                  setState(() {
                    _options = next;
                  });
                },
                icon: const Icon(Icons.refresh),
                label: Text(
                  snapshot.hasError ? '表情加载失败，请重试' : '当前没有可选表情，点击刷新',
                ),
              ),
            );
          }
          return ListView(
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('优先显示主播粉丝团表情；发送前会再次核对可用权限。'),
              ),
              for (final option in options)
                ListTile(
                  key: ValueKey('live-emoticon-option:${option.unique}'),
                  leading: option.url.isNotEmpty
                      ? NetworkImgLayer(
                          src: option.url,
                          width: 36,
                          height: 36,
                          fit: BoxFit.contain,
                          type: ImageType.emote,
                        )
                      : const Icon(Icons.emoji_emotions_outlined),
                  title: Text(option.label),
                  subtitle: Text(option.packageName),
                  trailing: option.available ? null : const Text('不可发送'),
                  enabled: option.available && option.unique.isNotEmpty,
                  onTap: option.available && option.unique.isNotEmpty
                      ? () => Navigator.of(context).pop(option)
                      : null,
                ),
            ],
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
    ],
  );
}

class _Notice extends StatelessWidget {
  const _Notice(this.message, {this.isError = false});
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(
      message,
      style: TextStyle(
        color: isError ? Theme.of(context).colorScheme.error : null,
        fontSize: 12,
      ),
    ),
  );
}

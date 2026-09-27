import 'package:PiliPlus/services/live_interaction_service.dart';
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
  });

  final LiveInteractionSession session;
  final String anchorName;
  final VoidCallback onLogin;

  @override
  State<LiveInteractionPanel> createState() => _LiveInteractionPanelState();
}

class _LiveInteractionPanelState extends State<LiveInteractionPanel> {
  int _tab = 0;
  final _quantity = TextEditingController(text: '1');
  ModalRoute<dynamic>? _confirmationRoute;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_cancelDisabledConfirmation);
    if (widget.session.snapshot == null) widget.session.load();
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
    if (oldWidget.session == widget.session) return;
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
    animation: widget.session,
    builder: (context, _) {
      final session = widget.session;
      final data = session.snapshot;
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
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Wrap(
                    spacing: 6,
                    children: [
                      for (final entry in const [
                        '礼物',
                        '背包',
                        '粉丝团 / 灯牌',
                      ].indexed)
                        ChoiceChip(
                          label: Text(entry.$2),
                          selected: _tab == entry.$1,
                          onSelected: (_) => setState(() => _tab = entry.$1),
                        ),
                    ],
                  ),
                ),
                if (_tab != 2)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    child: TextField(
                      controller: _quantity,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: '数量',
                        helperText: '每次操作都会重新核对并要求确认',
                        isDense: true,
                      ),
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
                _ => _fans(data),
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

  Widget _gifts(LiveInteractionSnapshot data) => ListView(
    padding: const EdgeInsets.only(bottom: 16),
    children: [
      if (data.wallet case final wallet?)
        _Notice(
          '余额（金瓜子）：${wallet.gold ?? "未知"}；银瓜子：${wallet.silver ?? "未知"}',
        ),
      ..._errors(data),
      if (data.gifts.isEmpty) const _Notice('本房间没有可用礼物目录，不能提交送礼。'),
      for (final gift in data.gifts)
        ListTile(
          title: Text(gift.name),
          subtitle: Text(
            '${gift.priceKnown ? "${gift.price} ${gift.coinLabel} / 个" : "价格未知"}'
            '${gift.description.isEmpty ? "" : "\n${gift.description}"}'
            '${gift.unavailableReason == null ? "" : "\n${gift.unavailableReason}"}',
          ),
          trailing: TextButton(
            onPressed: data.loggedIn && gift.sendable && !widget.session.blocked
                ? () => _gift(gift)
                : null,
            child: const Text('送礼'),
          ),
        ),
    ],
  );

  Widget _bag(LiveInteractionSnapshot data) => ListView(
    padding: const EdgeInsets.only(bottom: 16),
    children: [
      ..._errors(data),
      if (!data.loggedIn)
        const _Notice('请先登录。')
      else if (data.bag.isEmpty)
        const _Notice('背包暂无礼物；读取异常时会单独显示，不能视为库存为零。'),
      for (final item in data.bag)
        ListTile(
          title: Text('${item.name} × ${item.quantity}'),
          subtitle: Text(
            '有效期：${item.expiresAt?.toLocal().toString() ?? "服务端未提供"}'
            '${item.available ? "" : "\n已过期或不可用于此房间"}',
          ),
          trailing: TextButton(
            onPressed:
                item.available && data.loggedIn && !widget.session.blocked
                ? () => _gift(item.gift, bag: item)
                : null,
            child: const Text('赠送'),
          ),
        ),
    ],
  );

  Widget _fans(LiveInteractionSnapshot data) {
    final status = data.fanStatus;
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        ..._errors(data),
        if (status == null)
          const _Notice('粉丝团和灯牌状态未取得，不能推断为未加入或未点亮。')
        else ...[
          ListTile(
            title: Text(
              '${status.name.isEmpty ? "粉丝团" : status.name} · Lv.${status.level ?? "未知"}',
            ),
            subtitle: Text(
              '入团：${_state(status.joined, "已加入", "未加入")}\n'
              '灯牌：${_state(status.isLighted, "已点亮", "未点亮")}\n'
              '亲密度：${status.intimacy ?? "未知"} / ${status.nextIntimacy ?? "未知"}',
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
          for (final task in status.tasks)
            ListTile(
              dense: true,
              title: Text(task.name),
              subtitle: Text(task.description),
              trailing: Text(_state(task.completed, '已完成', '待完成')),
            ),
        ],
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text('勋章佩戴与摘下', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        if (data.medals.isEmpty) const _Notice('未取得可佩戴勋章。'),
        for (final medal in data.medals)
          ListTile(
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
      ],
    );
  }

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
                      : '合计：${confirmation.totalPrice} ${confirmation.coinLabel}',
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

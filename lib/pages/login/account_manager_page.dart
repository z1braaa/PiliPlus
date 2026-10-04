import 'dart:async';

import 'package:PiliPlus/common/widgets/scaffold/simple_scaffold.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/pages/login/controller.dart';
import 'package:PiliPlus/services/live_intimacy_scheduler.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/saved_account_profile.dart';
import 'package:PiliPlus/utils/live_intimacy_statistics_preferences.dart';
import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// This view never exposes saved tokens/cookies. Account roles remain available
/// through the existing advanced dialog.
class SavedAccountManagerPage extends StatefulWidget {
  const SavedAccountManagerPage({super.key});

  @override
  State<SavedAccountManagerPage> createState() =>
      _SavedAccountManagerPageState();
}

class _SavedAccountManagerPageState extends State<SavedAccountManagerPage> {
  StreamSubscription<dynamic>? _accountChanges;
  bool _busy = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _accountChanges = Accounts.account.watch().listen((event) {
      _refreshView();
      if (!event.deleted &&
          event.value is LoginAccount &&
          (event.value as LoginAccount).profile.name.isEmpty) {
        unawaited(_checkProfiles());
      }
    });
    Accounts.addAccountRoleChangeListener(_refreshView);
    Accounts.addMainIdentitySettledListener(_refreshView);
    unawaited(_checkProfiles());
  }

  @override
  void dispose() {
    _accountChanges?.cancel();
    Accounts.removeAccountRoleChangeListener(_refreshView);
    Accounts.removeMainIdentitySettledListener(_refreshView);
    super.dispose();
  }

  void _refreshView() {
    if (mounted) setState(() {});
  }

  Future<void> _checkProfiles() async {
    if (_checking) return;
    if (mounted) setState(() => _checking = true);
    try {
      for (final account in Accounts.account.values.toList()) {
        if (!mounted) return;
        try {
          final res = await Request()
              .get(
                Api.userInfo,
                options: Options(extra: {'account': account}),
              )
              .timeout(const Duration(seconds: 15));
          if (!mounted) return;
          final body = res.data;
          final data = body is Map ? body['data'] : null;
          if (body is Map &&
              body['code'] == 0 &&
              data is Map &&
              data['isLogin'] == true &&
              data['mid'] == account.mid) {
            await Accounts.updateSavedProfile(
              account,
              account.profile.copyWith(
                name: data['uname'] is String ? data['uname'] as String : null,
                avatar: data['face'] is String ? data['face'] as String : null,
                loginState: SavedAccountLoginState.verified,
                checkedAt: DateTime.now(),
                checkFailed: false,
              ),
            );
          } else if (body is Map &&
              (body['code'] == -101 ||
                  (body['code'] == 0 &&
                      data is Map &&
                      data['isLogin'] == false))) {
            await Accounts.updateSavedProfile(
              account,
              account.profile.copyWith(
                loginState: SavedAccountLoginState.expired,
                checkedAt: DateTime.now(),
                checkFailed: false,
              ),
            );
          } else {
            await Accounts.updateSavedProfile(
              account,
              account.profile.copyWith(checkFailed: true),
            );
          }
        } catch (_) {
          await Accounts.updateSavedProfile(
            account,
            account.profile.copyWith(checkFailed: true),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
    } catch (_) {
      SmartDialog.showToast('操作未完成，请检查网络或重新登录后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _switch(Account account) => _run(
    () async {
      await Accounts.selectCurrentAccount(account);
      if (Accounts.main.isLogin &&
          Accounts.heartbeat.mid != Accounts.main.mid) {
        SmartDialog.showToast('当前记录观看使用独立或匿名账号，后台任务将暂停；可在高级账号用途中调整');
      }
    },
  );

  Future<void> _remove(LoginAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除本机账号？'),
        content: Text(
          '将移除UID ${account.mid}的本机登录信息。后台任务配置、房间授权和当前周期观时记录会保留，重新登录后可恢复。\n\n这不会注销哔哩哔哩账号。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除登录'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(() => Accounts.deleteAll({account}));
    }
  }

  Future<void> _clearTaskData(LoginAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除该账号的本机任务数据？'),
        content: Text(
          '将停止UID ${account.mid}的后台任务，并清除该账号的任务开关、房间授权、自动弹幕内容、当前周期观时记录和统计显示偏好。\n\n尚未确认结果的操作会保留防重复保护，直到核对完成。保留登录信息，不影响其他账号，也不会删除平台上的勋章、亲密度或观看记录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除任务数据'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(() async {
        await LiveIntimacyScheduler.instance.clearAccountData(account.mid);
        await LiveIntimacyStatisticsPreferences.instance.clearFor(account.mid);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = Accounts.account.values.toList();
    final disabled = _busy || Accounts.mainIdentityChangeInProgress;
    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('账号管理'),
        actions: [
          IconButton(
            tooltip: _checking ? '正在核对登录状态' : '核对登录状态',
            onPressed: _checking ? null : _checkProfiles,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('后台任务只由当前账号运行。切换账号会保存并暂停旧账号任务。'),
              ),
              FilledButton.icon(
                onPressed: disabled ? null : () => Get.toNamed('/loginPage'),
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('添加账号'),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.person_outline),
                  ),
                  title: const Text('匿名账号'),
                  subtitle: const Text('UID 0 · 不执行后台亲密度任务'),
                  trailing: !Accounts.main.isLogin
                      ? const Text('当前')
                      : TextButton(
                          onPressed: disabled
                              ? null
                              : () => _switch(AnonymousAccount()),
                          child: const Text('切换'),
                        ),
                ),
              ),
              for (final account in accounts)
                SavedAccountCard(
                  key: ValueKey('saved-account-${account.mid}'),
                  uid: account.mid,
                  profile: account.profile,
                  current: Accounts.main.mid == account.mid,
                  onSelect: disabled ? null : () => _switch(account),
                  onRelogin: disabled
                      ? null
                      : () =>
                            Get.toNamed('/loginPage?reauthUid=${account.mid}'),
                  onRemove: disabled ? null : () => _remove(account),
                  onClearTaskData: disabled
                      ? null
                      : () => _clearTaskData(account),
                ),
              if (accounts.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('尚未保存登录账号。添加成功后，可在此选择当前账号。'),
                ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.manage_accounts_outlined),
                title: const Text('高级账号用途'),
                subtitle: Text(
                  '${AccountType.values.where((role) => role != AccountType.main).map((role) => '${role.title}：${Accounts.followsMain(role)
                      ? '跟随主账号'
                      : Accounts.get(role).isLogin
                      ? 'UID ${Accounts.get(role).mid}'
                      : '匿名'}').join(' · ')}\n跟随关系跨匿名切换和重启保留；独立和匿名用途保持原设置。身份冲突时后台任务暂停。',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: disabled
                    ? null
                    : () => LoginPageController.accountUsageDialog(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Account presentation can be tested without accessing any saved credential.
class SavedAccountCard extends StatelessWidget {
  const SavedAccountCard({
    super.key,
    required this.uid,
    required this.profile,
    required this.current,
    this.onSelect,
    this.onRelogin,
    this.onRemove,
    this.onClearTaskData,
  });

  final int uid;
  final SavedAccountProfile profile;
  final bool current;
  final VoidCallback? onSelect;
  final VoidCallback? onRelogin;
  final VoidCallback? onRemove;
  final VoidCallback? onClearTaskData;

  @override
  Widget build(BuildContext context) {
    final expired = profile.loginState == SavedAccountLoginState.expired;
    final checked = profile.checkedAt?.toLocal();
    final checkedLabel = checked == null
        ? ''
        : '\n上次核对 ${checked.month}/${checked.day} ${checked.hour.toString().padLeft(2, '0')}:${checked.minute.toString().padLeft(2, '0')}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: CircleAvatar(
                foregroundImage: profile.avatar.isEmpty
                    ? null
                    : NetworkImage(profile.avatar),
                child: const Icon(Icons.person_outline),
              ),
              title: Text(
                profile.name.isEmpty ? '账号 $uid' : profile.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('UID $uid · ${profile.statusLabel}$checkedLabel'),
              trailing: current ? const Text('当前') : null,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  if (!current)
                    TextButton.icon(
                      onPressed: expired ? null : onSelect,
                      icon: const Icon(Icons.switch_account_outlined, size: 18),
                      label: const Text('切换'),
                    ),
                  TextButton.icon(
                    onPressed: onRelogin,
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('重新登录'),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '账号操作',
                    enabled: onRemove != null || onClearTaskData != null,
                    onSelected: (value) {
                      if (value == 'remove') onRemove?.call();
                      if (value == 'clear') onClearTaskData?.call();
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'remove',
                        child: Text('移除本机登录'),
                      ),
                      const PopupMenuItem(
                        value: 'clear',
                        child: Text('清除该账号任务数据'),
                      ),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Icon(Icons.more_horiz),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

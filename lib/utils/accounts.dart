import 'dart:async';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/pages/mine/controller.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/login_utils.dart';
import 'package:hive_ce/hive.dart';

/// Tracks completion independently of account-object equality. A superseded
/// operation cannot clear a newer transition, even when the same object returns.
/// Kept independent of account storage and network for deterministic validation.
class MainAccountTransitionCoordinator {
  int _generation = 0;
  int? _activeGeneration;
  final Set<void Function()> _settledListeners = {};
  final Set<void Function()> _roleListeners = {};

  int get generation => _generation;
  bool get inProgress => _activeGeneration != null;
  bool isCurrent(int generation) => generation == _generation;

  int begin() => _activeGeneration = ++_generation;

  void complete(int generation) {
    if (_activeGeneration != generation) return;
    _activeGeneration = null;
    _notify(_settledListeners);
  }

  Future<T> run<T>(Future<T> Function(int generation) operation) async {
    final generation = begin();
    try {
      return await operation(generation);
    } finally {
      complete(generation);
    }
  }

  void addSettledListener(void Function() listener) =>
      _settledListeners.add(listener);
  void removeSettledListener(void Function() listener) =>
      _settledListeners.remove(listener);
  void addRoleListener(void Function() listener) =>
      _roleListeners.add(listener);
  void removeRoleListener(void Function() listener) =>
      _roleListeners.remove(listener);
  void rolesChanged() => _notify(_roleListeners);

  static void _notify(Set<void Function()> listeners) {
    for (final listener in listeners.toList()) {
      try {
        listener();
      } catch (error, stack) {
        // A UI listener cannot prevent another listener from cancelling work or
        // replace the account-operation result with its own exception.
        Zone.current.handleUncaughtError(error, stack);
      }
    }
  }
}

abstract final class Accounts {
  /// An active media session can be stopped before its owning main account
  /// changes. Kept as a callback to avoid coupling account storage to UI.
  static Future<void> Function()? beforeMainIdentityChange;
  static final Set<Future<void> Function()> _mainIdentityChangeListeners = {};
  static final _transitions = MainAccountTransitionCoordinator();
  static int get mainChangeGeneration => _transitions.generation;
  static bool get mainIdentityChangeInProgress => _transitions.inProgress;

  static void addMainIdentitySettledListener(void Function() listener) =>
      _transitions.addSettledListener(listener);
  static void removeMainIdentitySettledListener(void Function() listener) =>
      _transitions.removeSettledListener(listener);
  static void addAccountRoleChangeListener(void Function() listener) =>
      _transitions.addRoleListener(listener);
  static void removeAccountRoleChangeListener(void Function() listener) =>
      _transitions.removeRoleListener(listener);

  static void addMainIdentityChangeListener(Future<void> Function() listener) =>
      _mainIdentityChangeListeners.add(listener);

  static void removeMainIdentityChangeListener(
    Future<void> Function() listener,
  ) => _mainIdentityChangeListeners.remove(listener);

  static Future<void> _beforeMainChange() async {
    await beforeMainIdentityChange?.call();
    for (final listener in _mainIdentityChangeListeners.toList()) {
      await listener();
    }
  }

  static late final Box<LoginAccount> account;
  static final List<Account> accountMode = List.filled(
    AccountType.values.length,
    AnonymousAccount(),
  );
  static bool get mainEqVideo => main == video;
  static Account get main => accountMode[AccountType.main.index];
  static Account get video => accountMode[AccountType.video.index];
  static Account get heartbeat => accountMode[AccountType.heartbeat.index];
  static bool mainIdentityChanged(Account previous, Account next) =>
      !identical(previous, next);
  static Account get history {
    final heartbeat = Accounts.heartbeat;
    if (heartbeat is AnonymousAccount) {
      return Accounts.main;
    }
    return heartbeat;
  }
  // static set main(Account account) => set(AccountType.main, account);

  static Future<void> init() async {
    account = await Hive.openBox(
      'account',
      compactionStrategy: (int entries, int deletedEntries) {
        return deletedEntries > 2;
      },
    );
  }

  static Future<void> refresh() {
    for (final a in account.values) {
      for (final t in a.type) {
        accountMode[t.index] = a;
      }
    }
    _transitions.rolesChanged();
    return Future.wait(
      (accountMode.toSet()..removeWhere((i) => i.activated)).map(
        Request.buvidActive,
      ),
    );
  }

  static Future<void> clear() => _transitions.run((generation) async {
    final previousMain = main;
    if (previousMain.isLogin) {
      await _beforeMainChange();
      if (!_transitions.isCurrent(generation)) return;
      await LoginUtils.clearWebCookiesBeforeMainSwitch(previousMain);
      if (!_transitions.isCurrent(generation)) return;
    }
    await account.clear();
    if (!_transitions.isCurrent(generation)) return;
    for (int i = 0; i < AccountType.values.length; i++) {
      accountMode[i] = AnonymousAccount();
    }
    _transitions.rolesChanged();
    await AnonymousAccount().delete();
    if (!_transitions.isCurrent(generation)) return;
    Request.buvidActive(AnonymousAccount());
    await LoginUtils.clearWebCookiesOnAccountReset();
  });

  static Future<void> deleteAll(Set<Account> accounts) async {
    final previousMain = Accounts.main;
    final isLoginMain = previousMain.isLogin;
    bool containsIdentity(Account target) =>
        accounts.any((account) => identical(account, target));
    final changingMain = isLoginMain && containsIdentity(previousMain);
    final generation = changingMain ? _transitions.begin() : null;
    try {
      if (changingMain) {
        await _beforeMainChange();
        if (!_transitions.isCurrent(generation!)) return;
        await LoginUtils.clearWebCookiesBeforeMainSwitch(previousMain);
        if (!_transitions.isCurrent(generation)) return;
      }
      var changed = false;
      for (int i = 0; i < AccountType.values.length; i++) {
        if (containsIdentity(accountMode[i])) {
          accountMode[i] = AnonymousAccount();
          changed = true;
        }
      }
      if (changed) _transitions.rolesChanged();
      await Future.wait(accounts.map((i) => i.delete()));
      if (generation != null && !_transitions.isCurrent(generation)) return;
      if (isLoginMain && !Accounts.main.isLogin) {
        await LoginUtils.onLogoutMain(Accounts.main);
      }
    } finally {
      if (generation != null) _transitions.complete(generation);
    }
  }

  static Future<void> set(AccountType key, Account account) async {
    final previousMain = key == AccountType.main ? main : null;
    final changingMain =
        previousMain != null && mainIdentityChanged(previousMain, account);
    // Choosing the original account during a pending switch supersedes it too;
    // object equality is not enough to identify the latest user choice.
    final mainGeneration =
        key == AccountType.main &&
            (changingMain || mainIdentityChangeInProgress)
        ? _transitions.begin()
        : null;
    try {
      if (changingMain) {
        await _beforeMainChange();
        if (!_transitions.isCurrent(mainGeneration!)) return;
        await LoginUtils.clearWebCookiesBeforeMainSwitch(previousMain);
        if (!_transitions.isCurrent(mainGeneration)) return;
      }
      final oldAccount = accountMode[key.index]..type.remove(key);
      accountMode[key.index] = account..type.add(key);
      _transitions.rolesChanged();
      if (key == AccountType.main) {
        await LoginUtils.syncSelectedMainWebCookies(account);
        if (mainGeneration != null && !_transitions.isCurrent(mainGeneration)) {
          return;
        }
      }
      await Future.wait([?account.onChange(), ?oldAccount.onChange()]);
      if (key == AccountType.main &&
          (mainGeneration != null && !_transitions.isCurrent(mainGeneration) ||
              !identical(main, account))) {
        return;
      }
      if (!account.activated) await Request.buvidActive(account);
      if (key == AccountType.main &&
          (mainGeneration != null && !_transitions.isCurrent(mainGeneration) ||
              !identical(main, account))) {
        return;
      }
      switch (key) {
        case AccountType.main:
          await (account.isLogin
              ? LoginUtils.onLoginMain(account)
              : LoginUtils.onLogoutMain(account));
          break;
        case AccountType.heartbeat:
          MineController.anonymity.value = !account.isLogin;
          break;
        default:
          break;
      }
    } finally {
      if (mainGeneration != null) _transitions.complete(mainGeneration);
    }
  }

  @pragma("vm:prefer-inline")
  static Account get(AccountType key) {
    return accountMode[key.index];
  }
}

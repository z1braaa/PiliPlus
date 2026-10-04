import 'dart:async';

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/pages/mine/controller.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/saved_account_profile.dart';
import 'package:PiliPlus/utils/login_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
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

/// A normal account selection only follows roles currently using the old main
/// login. Explicit anonymous roles and roles using another UID are preserved.
Set<AccountType> mainAccountFollowingRoles(List<Account> roles) {
  final previous = roles[AccountType.main.index];
  if (!previous.isLogin) return const {};
  return {
    for (final role in AccountType.values)
      if (role != AccountType.main &&
          roles[role.index].isLogin &&
          roles[role.index].mid == previous.mid)
        role,
  };
}

/// Replace network/platform effects in deterministic async account-switch
/// validation while exercising the actual role commit and Hive persistence.
class MainAccountSelectionEffects {
  const MainAccountSelectionEffects({
    required this.clearPreviousWebCookies,
    required this.syncSelectedWebCookies,
    required this.activate,
    required this.initializeMain,
  });

  final Future<void> Function(Account) clearPreviousWebCookies;
  final Future<void> Function(Account) syncSelectedWebCookies;
  final Future<void> Function(Account) activate;
  final Future<void> Function(Account) initializeMain;
}

class AccountRoleSelectionSnapshot {
  AccountRoleSelectionSnapshot._(this.generation, this.roles, this.versions);
  final int generation;
  final List<Account> roles;
  final List<int> versions;
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
  static final _roleVersions = List<int>.filled(AccountType.values.length, 0);
  static final Set<AccountType> _temporaryRoleOverrides = {};

  static Map? get _savedRoleLinks {
    final value = GStorage.setting.get(SettingBoxKey.accountRoleLinks);
    return value is Map &&
            value['schema'] == 1 &&
            value['following'] is List &&
            value['assignments'] is Map
        ? value
        : null;
  }

  static Set<AccountType> get _persistentFollowingRoles {
    final saved = _savedRoleLinks;
    if (saved == null) return mainAccountFollowingRoles(accountMode);
    return {
      for (final role in AccountType.values)
        if (role != AccountType.main &&
            (saved['following'] as List).contains(role.index))
          role,
    };
  }

  static bool followsMain(AccountType role) =>
      _persistentFollowingRoles.contains(role) &&
      !_temporaryRoleOverrides.contains(role);

  static Future<void> _saveRoleLinks(Set<AccountType> following) {
    final previousAssignments = _savedRoleLinks?['assignments'] as Map?;
    int savedUid(AccountType role) {
      if (following.contains(role)) return main.mid;
      if (_temporaryRoleOverrides.contains(role) &&
          previousAssignments != null) {
        final uid = previousAssignments['${role.index}'];
        if (uid is int) return uid;
      }
      return accountMode[role.index].mid;
    }

    return GStorage.setting.put(SettingBoxKey.accountRoleLinks, {
      'schema': 1,
      'following': following.map((role) => role.index).toList(),
      'assignments': {
        for (final role in AccountType.values) '${role.index}': savedUid(role),
      },
    });
  }

  /// Restore the persisted relationship independently of anonymous UID 0.
  /// Temporary privacy choices remain session-only and are never saved here.
  static void restoreSavedRoleAssignments() {
    _temporaryRoleOverrides.clear();
    accountMode.fillRange(0, accountMode.length, AnonymousAccount());
    for (final selected in account.values) {
      for (final role in selected.type) {
        accountMode[role.index] = selected;
      }
    }
    final saved = _savedRoleLinks;
    if (saved != null) {
      final assignments = saved['assignments'] as Map;
      for (final role in AccountType.values) {
        final uid = assignments['${role.index}'];
        accountMode[role.index] = uid is int && uid > 0
            ? account.get('$uid') ?? AnonymousAccount()
            : AnonymousAccount();
      }
      for (final role in _persistentFollowingRoles) {
        accountMode[role.index] = main;
      }
    }
    for (final role in AccountType.values) {
      ++_roleVersions[role.index];
    }
    _transitions.rolesChanged();
  }

  static final _loginSaveTails = <int, Future<void>>{};
  static final _pendingLoginReplacements =
      <int, ({LoginAccount? previous, LoginAccount replacement})>{};
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

  /// Store successful credentials without selecting a different UID. A login
  /// for an existing UID keeps its roles and replaces every retained instance.
  static Future<void> saveLoginAccount(
    LoginAccount replacement, {
    int? expectedUid,
    MainAccountSelectionEffects? effects,
  }) async {
    final uid = replacement.mid;
    if (uid <= 0 || replacement.csrf.isEmpty) {
      throw StateError('登录信息不完整，请重新登录');
    }
    if (expectedUid != null && expectedUid != uid) {
      throw StateError('本次登录的UID与待重新登录账号不一致，原账号未更改');
    }
    final prior = _loginSaveTails[uid] ?? Future<void>.value();
    final operation = prior.then(
      (_) => _saveLoginAccount(replacement, effects: effects),
    );
    final settled = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _loginSaveTails[uid] = settled;
    try {
      await operation;
    } finally {
      if (identical(_loginSaveTails[uid], settled)) _loginSaveTails.remove(uid);
    }
  }

  static Future<void> _saveLoginAccount(
    LoginAccount replacement, {
    MainAccountSelectionEffects? effects,
  }) async {
    final uid = replacement.mid;
    final previous = account.get('$uid');
    if (identical(previous, replacement)) {
      await replacement.onChange();
      return;
    }
    final changingMain = main.isLogin && main.mid == uid;
    final generation = changingMain ? _transitions.begin() : null;
    try {
      if (changingMain) {
        await _beforeMainChange();
        if (!_transitions.isCurrent(generation!)) return;
        await (effects?.clearPreviousWebCookies ??
            LoginUtils.clearWebCookiesBeforeMainSwitch)(main);
        if (!_transitions.isCurrent(generation)) return;
      }
      replacement.type.addAll(previous?.type ?? const {});
      if (previous != null) {
        replacement.profile = replacement.profile.copyWith(
          name: replacement.profile.name.isEmpty ? previous.profile.name : null,
          avatar: replacement.profile.avatar.isEmpty
              ? previous.profile.avatar
              : null,
        );
      }
      for (final role in AccountType.values) {
        if (accountMode[role.index].isLogin &&
            accountMode[role.index].mid == uid) {
          replacement.type.add(role);
        }
      }
      _pendingLoginReplacements[uid] = (
        previous: previous,
        replacement: replacement,
      );
      // Revoke the previous writer before Hive's first asynchronous put. The
      // replacement can already be visible in the box while its put is pending.
      previous?.markSuperseded();
      try {
        await replacement.onChange();
        await _alignReplacementRoles(previous, replacement);
        if (!identical(account.get('$uid'), replacement)) {
          throw StateError('登录保存未完成');
        }
      } catch (_) {
        replacement.markSuperseded();
        if (previous?.restoreAfterFailedReplacement() == true) {
          await previous!.onChange();
        } else if (identical(account.get('$uid'), replacement)) {
          await account.delete('$uid');
        }
        rethrow;
      } finally {
        _pendingLoginReplacements.remove(uid);
      }
      try {
        if (main.isLogin && main.mid == uid && !identical(main, replacement)) {
          // The UID may have become main while an initially independent login
          // was saving. Use the same stop/commit/initialize identity lifecycle.
          await applyAccountRoleSelection(
            {
              for (final role in AccountType.values)
                if (accountMode[role.index].isLogin &&
                    accountMode[role.index].mid == uid)
                  role: replacement,
            },
            snapshot: captureRoleSelection(),
            effects: effects,
            preserveFollowing: true,
          );
        } else {
          for (var index = 0; index < accountMode.length; index++) {
            if (accountMode[index].isLogin && accountMode[index].mid == uid) {
              accountMode[index] = replacement;
              ++_roleVersions[index];
            }
          }
          _transitions.rolesChanged();
        }
      } finally {
        await _alignReplacementRoles(previous, replacement);
      }
    } finally {
      if (generation != null) _transitions.complete(generation);
    }
  }

  static Future<void> _alignReplacementRoles(
    LoginAccount? previous,
    LoginAccount replacement,
  ) async {
    final roles = {
      ...previous?.type ?? replacement.type,
      for (final role in AccountType.values)
        if (accountMode[role.index].isLogin &&
            accountMode[role.index].mid == replacement.mid)
          role,
    };
    if (roles.length != replacement.type.length ||
        !replacement.type.containsAll(roles)) {
      replacement.type
        ..clear()
        ..addAll(roles);
      await replacement.onChange();
    }
  }

  static Future<void> updateSavedProfile(
    LoginAccount selected,
    SavedAccountProfile profile,
  ) async {
    if (!identical(account.get('${selected.mid}'), selected)) return;
    selected.profile = profile;
    await selected.onChange();
    _transitions.rolesChanged();
  }

  static Future<void> selectCurrentAccount(
    Account selected, {
    MainAccountSelectionEffects? effects,
  }) {
    final snapshot = captureRoleSelection();
    final followers = _persistentFollowingRoles.difference(
      _temporaryRoleOverrides,
    );
    return applyAccountRoleSelection(
      {
        AccountType.main: selected,
        for (final role in followers) role: selected,
      },
      snapshot: snapshot,
      effects: effects,
      preserveFollowing: true,
    );
  }

  static AccountRoleSelectionSnapshot captureRoleSelection() =>
      AccountRoleSelectionSnapshot._(
        mainChangeGeneration,
        List<Account>.unmodifiable(accountMode),
        List<int>.unmodifiable(_roleVersions),
      );

  /// Both normal switching and the advanced dialog commit their entire role
  /// choice together, before account initialization can yield to another choice.
  static Future<void> applyAccountRoleSelection(
    Map<AccountType, Account> choices, {
    required AccountRoleSelectionSnapshot snapshot,
    MainAccountSelectionEffects? effects,
    bool preserveFollowing = false,
    Set<AccountType>? followingRoles,
  }) async {
    final previousMain = snapshot.roles[AccountType.main.index];
    if (snapshot.generation != mainChangeGeneration ||
        !identical(main, previousMain)) {
      throw StateError('当前账号已变化，请重新打开账号用途设置');
    }
    Account newest(Account candidate) {
      if (candidate is! LoginAccount) return candidate;
      final pending = _pendingLoginReplacements[candidate.mid];
      final saved = pending == null
          ? account.get('${candidate.mid}')
          : pending.previous;
      if (pending != null && saved == null) {
        throw StateError('该账号正在保存，请稍后重试');
      }
      if (saved == null) throw StateError('该账号已从本机移除，请重新登录');
      return saved;
    }

    Account target = newest(choices[AccountType.main] ?? previousMain);
    final changingMain = !identical(previousMain, target);
    final ownsTransition = changingMain || mainIdentityChangeInProgress;
    final generation = ownsTransition
        ? _transitions.begin()
        : mainChangeGeneration;
    final io =
        effects ??
        MainAccountSelectionEffects(
          clearPreviousWebCookies: LoginUtils.clearWebCookiesBeforeMainSwitch,
          syncSelectedWebCookies: LoginUtils.syncSelectedMainWebCookies,
          activate: Request.buvidActive,
          initializeMain: (account) => account.isLogin
              ? LoginUtils.onLoginMain(account)
              : LoginUtils.onLogoutMain(account),
        );
    bool current() =>
        _transitions.isCurrent(generation) && identical(main, target);
    try {
      if (changingMain) {
        await _beforeMainChange();
        if (!_transitions.isCurrent(generation)) return;
        await io.clearPreviousWebCookies(previousMain);
        if (!_transitions.isCurrent(generation)) return;
      }
      target = newest(target);

      // No awaits or notifications between these assignments: another normal
      // selection must see all following roles with their new main identity.
      final desired = {
        for (final entry in choices.entries)
          if (entry.key == AccountType.main ||
              (_roleVersions[entry.key.index] ==
                      snapshot.versions[entry.key.index] &&
                  identical(
                    accountMode[entry.key.index],
                    snapshot.roles[entry.key.index],
                  )))
            entry.key: entry.key == AccountType.main
                ? target
                : newest(entry.value),
      };
      final changed = Set<Account>.identity();
      final following = _persistentFollowingRoles;
      var heartbeatChanged = false;
      for (final entry in desired.entries) {
        final role = entry.key;
        final selected = entry.value;
        if (role != AccountType.main && !preserveFollowing) {
          final follow =
              followingRoles?.contains(role) ??
              (selected.isLogin &&
                  target.isLogin &&
                  selected.mid == target.mid);
          follow ? following.add(role) : following.remove(role);
          _temporaryRoleOverrides.remove(role);
        }
        if (identical(accountMode[role.index], selected)) continue;
        final previous = accountMode[role.index]..type.remove(role);
        accountMode[role.index] = selected..type.add(role);
        ++_roleVersions[role.index];
        changed
          ..add(previous)
          ..add(selected);
        heartbeatChanged |= role == AccountType.heartbeat;
      }
      if (heartbeatChanged) {
        MineController.anonymity.value = !heartbeat.isLogin;
      }
      final savedLinks = _saveRoleLinks(following);
      if (changed.isNotEmpty) _transitions.rolesChanged();
      await Future.wait(
        [
          savedLinks,
          ...changed
              .map((account) => account.onChange())
              .whereType<Future<void>>(),
        ],
      );
      if (!current()) return;
      if (changingMain) {
        await io.syncSelectedWebCookies(target);
        if (!current()) return;
      }
      for (final selected in changed) {
        if (accountMode.any((role) => identical(role, selected)) &&
            !selected.activated) {
          await io.activate(selected);
          if (!current()) return;
        }
      }
      if (changingMain) await io.initializeMain(target);
    } finally {
      if (ownsTransition) _transitions.complete(generation);
    }
  }

  /// Session-only privacy choices must also invalidate a pending following-role
  /// plan without changing the user's persisted advanced account settings.
  static void setTemporaryRole(AccountType role, Account selected) {
    if (role == AccountType.main) {
      throw ArgumentError('主账号必须通过身份切换流程设置');
    }
    unawaited(_saveRoleLinks(_persistentFollowingRoles));
    _temporaryRoleOverrides.add(role);
    accountMode[role.index] = selected;
    ++_roleVersions[role.index];
    _transitions.rolesChanged();
  }

  static Future<void> refresh() {
    restoreSavedRoleAssignments();
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
      ++_roleVersions[i];
    }
    _temporaryRoleOverrides.clear();
    await _saveRoleLinks({});
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
      final following = _persistentFollowingRoles;
      for (int i = 0; i < AccountType.values.length; i++) {
        if (containsIdentity(accountMode[i])) {
          accountMode[i] = AnonymousAccount();
          ++_roleVersions[i];
          changed = true;
        }
      }
      if (changed) _transitions.rolesChanged();
      await _saveRoleLinks(following);
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
      final following = _persistentFollowingRoles;
      accountMode[key.index] = account..type.add(key);
      if (key != AccountType.main) {
        _temporaryRoleOverrides.remove(key);
        account.isLogin && main.isLogin && account.mid == main.mid
            ? following.add(key)
            : following.remove(key);
      }
      final savedLinks = _saveRoleLinks(following);
      ++_roleVersions[key.index];
      _transitions.rolesChanged();
      if (key == AccountType.main) {
        await LoginUtils.syncSelectedMainWebCookies(account);
        if (mainGeneration != null && !_transitions.isCurrent(mainGeneration)) {
          return;
        }
      }
      await Future.wait([
        savedLinks,
        ?account.onChange(),
        ?oldAccount.onChange(),
      ]);
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

import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_adapter.dart';
import 'package:PiliPlus/utils/accounts/saved_account_profile.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

LoginAccount _account(int uid, {String token = 'fixture'}) => LoginAccount(
  BiliCookieJar.fromJson({'DedeUserID': '$uid', 'bili_jct': 'csrf-fixture'}),
  token,
  'refresh-fixture',
);

Future<void> _noAccountEffect(Account account) async {}

MainAccountSelectionEffects _selectionEffects({
  Future<void> Function(Account)? initialize,
  Future<void> Function(Account)? clearPrevious,
}) => MainAccountSelectionEffects(
  clearPreviousWebCookies: clearPrevious ?? _noAccountEffect,
  syncSelectedWebCookies: _noAccountEffect,
  activate: _noAccountEffect,
  initializeMain: initialize ?? _noAccountEffect,
);

class _LegacyAccountReader implements BinaryReader {
  _LegacyAccountReader(this.cookieJar);
  final dynamic cookieJar;
  final _bytes = [4, 0, 1, 2, 3].iterator;
  late final _fields = [
    cookieJar,
    'fixture',
    'refresh-fixture',
    <AccountType>[],
  ].iterator;
  @override
  int readByte() {
    _bytes.moveNext();
    return _bytes.current;
  }

  @override
  dynamic read([int? typeId]) {
    _fields.moveNext();
    return _fields.current;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StagedLoginAccount extends LoginAccount {
  _StagedLoginAccount(int uid, String token, {this.failFirstWrite = false})
    : super(
        BiliCookieJar.fromJson({
          'DedeUserID': '$uid',
          'bili_jct': 'csrf-fixture',
        }),
        token,
        'refresh-fixture',
      );

  final bool failFirstWrite;
  final written = Completer<void>();
  final release = Completer<void>();
  bool _first = true;

  @override
  Future<void> onChange() async {
    final first = _first;
    _first = false;
    await super.onChange();
    if (first) {
      written.complete();
      await release.future;
      if (failFirstWrite) throw StateError('fixture persistence failure');
    }
  }
}

void main() {
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'piliplus-accounts-test-',
    );
    Hive.init(directory.path);
    GStorage.regAdapter();
    GStorage.localCache = await Hive.openBox('localCache');
    GStorage.setting = await Hive.openBox('setting');
    GStorage.video = await Hive.openBox('video');
    Accounts.account = await Hive.openBox<LoginAccount>('account');
  });

  setUp(() async {
    Accounts.beforeMainIdentityChange = null;
    await Accounts.account.clear();
    await GStorage.setting.delete(SettingBoxKey.accountRoleLinks);
    Accounts.restoreSavedRoleAssignments();
    Accounts.accountMode.fillRange(
      0,
      AccountType.values.length,
      AnonymousAccount(),
    );
  });

  tearDown(() => Accounts.beforeMainIdentityChange = null);

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'following roles survive anonymous return and startup restoration',
    () async {
      final a = _account(100)..type.addAll(AccountType.values);
      await a.onChange();
      Accounts.accountMode.fillRange(0, AccountType.values.length, a);
      await Accounts.selectCurrentAccount(
        AnonymousAccount(),
        effects: _selectionEffects(),
      );
      expect(Accounts.accountMode.map((role) => role.mid), [0, 0, 0, 0]);
      Accounts.restoreSavedRoleAssignments();
      expect(Accounts.accountMode.map((role) => role.mid), [0, 0, 0, 0]);
      expect(Accounts.followsMain(AccountType.heartbeat), isTrue);
      await Accounts.selectCurrentAccount(a, effects: _selectionEffects());
      expect(Accounts.accountMode.map((role) => role.mid), [
        100,
        100,
        100,
        100,
      ]);
      Accounts.accountMode.fillRange(
        0,
        AccountType.values.length,
        AnonymousAccount(),
      );
      Accounts.restoreSavedRoleAssignments();
      expect(Accounts.accountMode.map((role) => role.mid), [
        100,
        100,
        100,
        100,
      ]);
    },
  );

  test('explicit anonymous and independent roles survive anonymous return and startup', () async {
    final a = _account(100)..type.addAll(AccountType.values);
    final b = _account(200);
    await a.onChange();
    await b.onChange();
    Accounts.accountMode.fillRange(0, AccountType.values.length, a);
    await Accounts.applyAccountRoleSelection(
      {
        AccountType.heartbeat: AnonymousAccount(),
        AccountType.video: b,
      },
      snapshot: Accounts.captureRoleSelection(),
      effects: _selectionEffects(),
    );
    await Accounts.selectCurrentAccount(
      AnonymousAccount(),
      effects: _selectionEffects(),
    );
    Accounts.restoreSavedRoleAssignments();
    await Accounts.selectCurrentAccount(a, effects: _selectionEffects());
    expect(Accounts.accountMode.map((role) => role.mid), [100, 0, 100, 200]);
    Accounts.restoreSavedRoleAssignments();
    expect(Accounts.accountMode.map((role) => role.mid), [100, 0, 100, 200]);
    expect(Accounts.followsMain(AccountType.heartbeat), isFalse);
    expect(Accounts.followsMain(AccountType.video), isFalse);
  });

  test('explicit anonymous choice while main is anonymous disconnects only that role', () async {
    final a = _account(100)..type.addAll(AccountType.values);
    await a.onChange();
    Accounts.accountMode.fillRange(0, AccountType.values.length, a);
    await Accounts.selectCurrentAccount(
      AnonymousAccount(),
      effects: _selectionEffects(),
    );
    await Accounts.applyAccountRoleSelection(
      {for (final role in AccountType.values) role: AnonymousAccount()},
      snapshot: Accounts.captureRoleSelection(),
      effects: _selectionEffects(),
      followingRoles: {AccountType.recommend, AccountType.video},
    );
    await Accounts.selectCurrentAccount(a, effects: _selectionEffects());
    expect(Accounts.accountMode.map((role) => role.mid), [100, 0, 100, 100]);
    Accounts.restoreSavedRoleAssignments();
    expect(Accounts.accountMode.map((role) => role.mid), [100, 0, 100, 100]);
  });

  test('temporary anonymous privacy blocks following this session but does not sever persisted link', () async {
    final a = _account(100)..type.addAll(AccountType.values);
    final b = _account(200);
    await a.onChange();
    await b.onChange();
    Accounts.accountMode.fillRange(0, AccountType.values.length, a);
    Accounts.setTemporaryRole(AccountType.heartbeat, AnonymousAccount());
    await Accounts.selectCurrentAccount(b, effects: _selectionEffects());
    expect(Accounts.accountMode.map((role) => role.mid), [200, 0, 200, 200]);
    expect(Accounts.followsMain(AccountType.heartbeat), isFalse);
    Accounts.restoreSavedRoleAssignments();
    expect(Accounts.accountMode.map((role) => role.mid), [200, 200, 200, 200]);
    expect(Accounts.followsMain(AccountType.heartbeat), isTrue);
  });

  test('restored link preferences contain UID assignments and no authentication data', () async {
    final a = _account(100)..type.addAll(AccountType.values);
    await a.onChange();
    Accounts.accountMode.fillRange(0, AccountType.values.length, a);
    await Accounts.selectCurrentAccount(
      AnonymousAccount(),
      effects: _selectionEffects(),
    );
    final data = GStorage.setting.get(SettingBoxKey.accountRoleLinks) as Map;
    expect(data.keys.toSet(), {'schema', 'following', 'assignments'});
    expect(
      (data['assignments'] as Map).values.every((value) => value is int),
      isTrue,
    );
    expect((data['following'] as List).toSet(), {1, 2, 3});
  });

  test(
    'adding a saved UID keeps the selected identity and existing entries',
    () async {
      final retained = _account(100);
      await retained.onChange();
      final added = _account(200);
      await Accounts.saveLoginAccount(added);
      expect(Accounts.main.mid, 0);
      expect(Accounts.account.length, 2);
      expect(Accounts.account.get('100'), same(retained));
      expect(Accounts.account.get('200'), same(added));
      expect(added.type, isEmpty);
    },
  );

  test(
    'same UID reauthentication preserves roles and display profile',
    () async {
      final retained = _account(100);
      retained.type.add(AccountType.recommend);
      retained.profile = const SavedAccountProfile(
        name: 'Fixture user',
        avatar: 'https://example.test/avatar',
      );
      Accounts.accountMode[AccountType.recommend.index] = retained;
      await retained.onChange();
      final replacement = _account(100, token: 'new-fixture');
      await Accounts.saveLoginAccount(replacement, expectedUid: 100);
      expect(Accounts.account.length, 1);
      expect(Accounts.account.get('100'), same(replacement));
      expect(Accounts.get(AccountType.recommend), same(replacement));
      expect(replacement.type, {AccountType.recommend});
      expect(replacement.profile.name, 'Fixture user');
      expect(replacement.profile.avatar, 'https://example.test/avatar');
      await retained.onChange();
      expect(Accounts.account.get('100')!.accessKey, 'new-fixture');
      await retained.delete();
      expect(Accounts.account.get('100'), same(replacement));
    },
  );

  test(
    'wrong UID reauthentication does not store or replace credentials',
    () async {
      final retained = _account(100);
      await retained.onChange();
      await expectLater(
        Accounts.saveLoginAccount(_account(200), expectedUid: 100),
        throwsStateError,
      );
      expect(Accounts.account.length, 1);
      expect(Accounts.account.get('100'), same(retained));
      expect(Accounts.account.containsKey('200'), isFalse);
    },
  );

  test('old late responses cannot replace credentials while initial replacement put is pending', () async {
    final old = _account(100, token: 'old-fixture');
    await old.onChange();
    final owner = _account(200)..type.add(AccountType.main);
    await owner.onChange();
    Accounts.accountMode[AccountType.main.index] = owner;
    final replacement = _StagedLoginAccount(100, 'new-fixture');
    final saving = Accounts.saveLoginAccount(replacement);
    await replacement.written.future;
    await old.onChange();
    replacement.release.complete();
    await saving;
    expect(Accounts.account.get('100'), same(replacement));
    expect(Accounts.account.get('100')!.accessKey, 'new-fixture');
    expect(Accounts.main, same(owner));
  });

  test('independent roles changed during a replacement put retain their latest assignment', () async {
    final old = _account(100)..type.add(AccountType.recommend);
    final owner = _account(200)..type.add(AccountType.main);
    final other = _account(300)..activated = true;
    for (final fixture in [old, owner, other]) {
      await fixture.onChange();
    }
    Accounts.accountMode[AccountType.main.index] = owner;
    Accounts.accountMode[AccountType.recommend.index] = old;
    final replacement = _StagedLoginAccount(100, 'new-fixture');
    final saving = Accounts.saveLoginAccount(replacement);
    await replacement.written.future;
    await Accounts.set(AccountType.recommend, other);
    replacement.release.complete();
    await saving;
    expect(Accounts.get(AccountType.recommend), same(other));
    expect(Accounts.account.get('100'), same(replacement));
    expect(replacement.type, isNot(contains(AccountType.recommend)));
    expect(other.type, contains(AccountType.recommend));
  });

  test('failed replacement put restores the saved login without losing concurrent role choices', () async {
    final old = _account(100, token: 'old-fixture')
      ..type.add(AccountType.recommend);
    final owner = _account(200)..type.add(AccountType.main);
    final other = _account(300)..activated = true;
    for (final fixture in [old, owner, other]) {
      await fixture.onChange();
    }
    Accounts.accountMode[AccountType.main.index] = owner;
    Accounts.accountMode[AccountType.recommend.index] = old;
    final replacement = _StagedLoginAccount(
      100,
      'new-fixture',
      failFirstWrite: true,
    );
    final saving = Accounts.saveLoginAccount(replacement);
    final failed = expectLater(saving, throwsStateError);
    await replacement.written.future;
    await Accounts.set(AccountType.recommend, other);
    await old.onChange();
    replacement.release.complete();
    await failed;
    expect(Accounts.account.get('100'), same(old));
    expect(Accounts.account.get('100')!.accessKey, 'old-fixture');
    expect(Accounts.get(AccountType.recommend), same(other));
    expect(old.type, isEmpty);
    await replacement.onChange();
    expect(Accounts.account.get('100'), same(old));
  });

  test(
    'same UID replacements serialize while other UIDs can save independently',
    () async {
      final old = _account(100, token: 'old-fixture');
      final owner = _account(200)..type.add(AccountType.main);
      await old.onChange();
      await owner.onChange();
      Accounts.accountMode[AccountType.main.index] = owner;
      final first = _StagedLoginAccount(100, 'first-fixture');
      final second = _StagedLoginAccount(100, 'latest-fixture');
      final firstSave = Accounts.saveLoginAccount(first);
      await first.written.future;
      final secondSave = Accounts.saveLoginAccount(second);
      final independent = _account(300);
      await Accounts.saveLoginAccount(independent);
      expect(second.written.isCompleted, isFalse);
      expect(Accounts.account.get('300'), same(independent));
      first.release.complete();
      await firstSave;
      await second.written.future;
      await old.onChange();
      await first.onChange();
      second.release.complete();
      await secondSave;
      expect(Accounts.account.get('100'), same(second));
      expect(Accounts.account.get('100')!.accessKey, 'latest-fixture');
      expect(Accounts.main, same(owner));
    },
  );

  test(
    'role switched away and back while replacing binds the latest credentials',
    () async {
      final old = _account(100)..type.add(AccountType.recommend);
      final owner = _account(200)..type.add(AccountType.main);
      final other = _account(300)..activated = true;
      for (final fixture in [old, owner, other]) {
        await fixture.onChange();
      }
      old.activated = true;
      Accounts.accountMode[AccountType.main.index] = owner;
      Accounts.accountMode[AccountType.recommend.index] = old;
      final replacement = _StagedLoginAccount(100, 'new-fixture');
      final saving = Accounts.saveLoginAccount(replacement);
      await replacement.written.future;
      await Accounts.set(AccountType.recommend, other);
      await Accounts.set(AccountType.recommend, old);
      replacement.release.complete();
      await saving;
      expect(Accounts.get(AccountType.recommend), same(replacement));
      expect(replacement.type, {AccountType.recommend});
      expect(other.type, isEmpty);
      expect(Accounts.account.get('100'), same(replacement));
    },
  );

  test('an independent UID selected as main while saving uses the identity lifecycle on commit', () async {
    final old = _account(100, token: 'old-fixture')
      ..type.add(AccountType.recommend);
    final owner = _account(200)..type.add(AccountType.main);
    await old.onChange();
    await owner.onChange();
    Accounts.accountMode[AccountType.main.index] = owner;
    Accounts.accountMode[AccountType.recommend.index] = old;
    var stopped = 0;
    Accounts.beforeMainIdentityChange = () async => ++stopped;
    final initialized = <String?>[];
    final effects = _selectionEffects(
      initialize: (selected) async {
        initialized.add(selected.accessKey);
      },
    );
    final replacement = _StagedLoginAccount(100, 'new-fixture');
    final saving = Accounts.saveLoginAccount(replacement, effects: effects);
    await replacement.written.future;
    await Accounts.selectCurrentAccount(replacement, effects: effects);
    expect(Accounts.main, same(old));
    replacement.release.complete();
    await saving;
    expect(Accounts.main, same(replacement));
    expect(Accounts.get(AccountType.recommend), same(replacement));
    expect(replacement.type, {AccountType.main, AccountType.recommend});
    expect(initialized, ['old-fixture', 'new-fixture']);
    expect(stopped, 2);
    expect(Accounts.mainIdentityChangeInProgress, isFalse);
  });

  test('failed initial login removes partial credentials without changing existing login', () async {
    final owner = _account(200)..type.add(AccountType.main);
    await owner.onChange();
    Accounts.accountMode[AccountType.main.index] = owner;
    final added = _StagedLoginAccount(100, 'new-fixture', failFirstWrite: true);
    final failed = expectLater(
      Accounts.saveLoginAccount(added),
      throwsStateError,
    );
    await added.written.future;
    added.release.complete();
    await failed;
    expect(Accounts.account.containsKey('100'), isFalse);
    expect(Accounts.main, same(owner));
    expect(Accounts.account.get('200'), same(owner));
    await added.onChange();
    expect(Accounts.account.containsKey('100'), isFalse);
  });

  test('incomplete credentials cannot alter a saved account', () async {
    final retained = _account(100);
    await retained.onChange();
    final incomplete = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '100'}),
      null,
      null,
    );
    await expectLater(
      Accounts.saveLoginAccount(incomplete),
      throwsA(isA<Error>()),
    );
    expect(Accounts.account.get('100'), same(retained));
  });

  test(
    'late profile checks cannot change a replaced or removed entry',
    () async {
      final retained = _account(100);
      await retained.onChange();
      final replacement = _account(100);
      await Accounts.saveLoginAccount(replacement);
      await Accounts.updateSavedProfile(
        retained,
        const SavedAccountProfile(name: 'Stale'),
      );
      expect(replacement.profile.name, isEmpty);
      await replacement.delete();
      await Accounts.updateSavedProfile(
        replacement,
        const SavedAccountProfile(name: 'Removed'),
      );
      expect(Accounts.account.isEmpty, isTrue);
    },
  );

  test(
    'legacy profile data is unknown; valid display metadata round-trips',
    () {
      expect(
        SavedAccountProfile.fromJson(null).loginState,
        SavedAccountLoginState.unchecked,
      );
      expect(
        SavedAccountProfile.fromJson({'state': 'future-value', 'name': 42})
            .loginState,
        SavedAccountLoginState.unchecked,
      );
      final profile = SavedAccountProfile(
        name: 'Fixture',
        avatar: 'https://example.test/avatar',
        loginState: SavedAccountLoginState.expired,
        checkedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        checkFailed: true,
      );
      final restored = SavedAccountProfile.fromJson(profile.toJson());
      expect(restored.name, profile.name);
      expect(restored.avatar, profile.avatar);
      expect(restored.loginState, profile.loginState);
      expect(restored.checkedAt, profile.checkedAt);
      expect(restored.checkFailed, isTrue);
      expect(profile.toJson().keys, isNot(contains('cookies')));
      expect(profile.toJson().keys, isNot(contains('accessKey')));
    },
  );

  test('normal selection follows old main roles and preserves explicit anonymous or other UID', () {
    final a = _account(100);
    final independent = _account(200);
    final roles = <Account>[a, a, independent, AnonymousAccount()];
    expect(mainAccountFollowingRoles(roles), {AccountType.heartbeat});
    expect(roles[AccountType.recommend.index], same(independent));
    expect(roles[AccountType.video.index].mid, 0);
  });

  test('all login roles using old main UID follow together', () {
    final a = _account(100);
    final restoredInstance = _account(100);
    expect(mainAccountFollowingRoles(<Account>[a, restoredInstance, a, a]), {
      AccountType.heartbeat,
      AccountType.recommend,
      AccountType.video,
    });
  });

  test('A to pending B to C commits following roles atomically before initialization', () async {
    final a = _account(100)..type.addAll(AccountType.values);
    final b = _account(200);
    final c = _account(300);
    for (final fixture in [a, b, c]) {
      await fixture.onChange();
    }
    Accounts.accountMode.fillRange(0, AccountType.values.length, a);
    final startedB = Completer<void>();
    final releaseB = Completer<void>();
    final effects = _selectionEffects(
      initialize: (selected) async {
        if (selected.mid == b.mid) {
          startedB.complete();
          await releaseB.future;
        }
      },
    );
    final observed = <List<int>>[];
    void observeRoles() =>
        observed.add(Accounts.accountMode.map((role) => role.mid).toList());
    Accounts.addAccountRoleChangeListener(observeRoles);
    addTearDown(() => Accounts.removeAccountRoleChangeListener(observeRoles));

    final switchB = Accounts.selectCurrentAccount(b, effects: effects);
    await startedB.future;
    expect(Accounts.accountMode.map((role) => role.mid), [200, 200, 200, 200]);
    expect(Accounts.mainIdentityChangeInProgress, isTrue);
    await Accounts.selectCurrentAccount(c, effects: effects);
    expect(Accounts.accountMode.map((role) => role.mid), [300, 300, 300, 300]);
    expect(observed, [
      [200, 200, 200, 200],
      [300, 300, 300, 300],
    ]);
    expect(Accounts.account.get('100')!.type, isEmpty);
    expect(Accounts.account.get('200')!.type, isEmpty);
    expect(Accounts.account.get('300')!.type, AccountType.values.toSet());
    expect(Accounts.mainIdentityChangeInProgress, isFalse);
    releaseB.complete();
    await switchB;
    expect(Accounts.accountMode.map((role) => role.mid), [300, 300, 300, 300]);
    expect(Accounts.account.get('300')!.type, AccountType.values.toSet());
  });

  test('explicit and temporary role changes during preflight survive an atomic selection', () async {
    final a = _account(100)..type.addAll(AccountType.values);
    final b = _account(200);
    final independent = _account(300)..activated = true;
    for (final fixture in [a, b, independent]) {
      await fixture.onChange();
    }
    Accounts.accountMode.fillRange(0, AccountType.values.length, a);
    final stopped = Completer<void>();
    final release = Completer<void>();
    Accounts.beforeMainIdentityChange = () async {
      stopped.complete();
      await release.future;
    };
    final selecting = Accounts.selectCurrentAccount(
      b,
      effects: _selectionEffects(),
    );
    await stopped.future;
    await Accounts.set(AccountType.recommend, independent);
    Accounts.setTemporaryRole(AccountType.heartbeat, AnonymousAccount());
    release.complete();
    await selecting;
    expect(Accounts.accountMode.map((role) => role.mid), [200, 0, 300, 200]);
    expect(Accounts.account.get('200')!.type, {
      AccountType.main,
      AccountType.video,
    });
    expect(Accounts.account.get('300')!.type, {AccountType.recommend});
    // Temporary anonymity retains the user's persisted heartbeat assignment.
    expect(Accounts.account.get('100')!.type, {AccountType.heartbeat});
  });

  test('explicit role choice that returns to old main during preflight is not followed', () async {
    final a = _account(100)..type.addAll(AccountType.values);
    final b = _account(200);
    for (final fixture in [a, b]) {
      await fixture.onChange();
    }
    Accounts.accountMode.fillRange(0, AccountType.values.length, a);
    final stopped = Completer<void>();
    final release = Completer<void>();
    Accounts.beforeMainIdentityChange = () async {
      stopped.complete();
      await release.future;
    };
    final selecting = Accounts.selectCurrentAccount(
      b,
      effects: _selectionEffects(),
    );
    await stopped.future;
    Accounts.setTemporaryRole(AccountType.video, AnonymousAccount());
    Accounts.setTemporaryRole(AccountType.video, a);
    release.complete();
    await selecting;
    expect(Accounts.accountMode.map((role) => role.mid), [200, 200, 200, 100]);
    expect(Accounts.account.get('100')!.type, {AccountType.video});
  });

  test('selection during web cookie synchronization also sees atomically following roles', () async {
    final a = _account(100)..type.addAll(AccountType.values);
    final b = _account(200);
    final c = _account(300);
    for (final fixture in [a, b, c]) {
      await fixture.onChange();
    }
    Accounts.accountMode.fillRange(0, AccountType.values.length, a);
    final syncingB = Completer<void>();
    final releaseB = Completer<void>();
    final effects = MainAccountSelectionEffects(
      clearPreviousWebCookies: _noAccountEffect,
      syncSelectedWebCookies: (selected) async {
        if (selected.mid == b.mid) {
          syncingB.complete();
          await releaseB.future;
        }
      },
      activate: _noAccountEffect,
      initializeMain: _noAccountEffect,
    );
    final first = Accounts.selectCurrentAccount(b, effects: effects);
    await syncingB.future;
    await Accounts.selectCurrentAccount(c, effects: effects);
    releaseB.complete();
    await first;
    expect(Accounts.accountMode.map((role) => role.mid), [300, 300, 300, 300]);
  });

  test('same UID credentials refreshed during preflight use the newest saved instance', () async {
    final a = _account(100)..type.addAll(AccountType.values);
    final b = _account(200, token: 'old-fixture');
    await a.onChange();
    await b.onChange();
    Accounts.accountMode.fillRange(0, AccountType.values.length, a);
    final stopped = Completer<void>();
    final release = Completer<void>();
    Accounts.beforeMainIdentityChange = () async {
      stopped.complete();
      await release.future;
    };
    final selecting = Accounts.selectCurrentAccount(
      b,
      effects: _selectionEffects(),
    );
    await stopped.future;
    final fresh = _account(200, token: 'fresh-fixture');
    await Accounts.saveLoginAccount(fresh);
    release.complete();
    await selecting;
    expect(Accounts.main, same(fresh));
    expect(
      Accounts.accountMode.every((account) => identical(account, fresh)),
      isTrue,
    );
    expect(Accounts.account.get('200')!.accessKey, 'fresh-fixture');
  });

  test(
    'credentials removed during preflight are not selected or recreated',
    () async {
      final a = _account(100)..type.addAll(AccountType.values);
      final b = _account(200);
      await a.onChange();
      await b.onChange();
      Accounts.accountMode.fillRange(0, AccountType.values.length, a);
      final stopped = Completer<void>();
      final release = Completer<void>();
      Accounts.beforeMainIdentityChange = () async {
        stopped.complete();
        await release.future;
      };
      final selecting = Accounts.selectCurrentAccount(
        b,
        effects: _selectionEffects(),
      );
      await stopped.future;
      await b.delete();
      release.complete();
      await expectLater(selecting, throwsStateError);
      expect(Accounts.accountMode.every((role) => identical(role, a)), isTrue);
      expect(Accounts.account.containsKey('200'), isFalse);
      expect(Accounts.mainIdentityChangeInProgress, isFalse);
    },
  );

  test('pending advanced quick selection cannot overwrite a later normal selection', () async {
    final a = _account(100)..type.addAll(AccountType.values);
    final b = _account(200);
    final c = _account(300);
    for (final fixture in [a, b, c]) {
      await fixture.onChange();
    }
    Accounts.accountMode.fillRange(0, AccountType.values.length, a);
    final startedB = Completer<void>();
    final releaseB = Completer<void>();
    final effects = _selectionEffects(
      initialize: (selected) async {
        if (identical(selected, b)) {
          startedB.complete();
          await releaseB.future;
        }
      },
    );
    final advanced = Accounts.applyAccountRoleSelection(
      {for (final role in AccountType.values) role: b},
      snapshot: Accounts.captureRoleSelection(),
      effects: effects,
    );
    await startedB.future;
    expect(Accounts.accountMode.map((role) => role.mid), [200, 200, 200, 200]);
    await Accounts.selectCurrentAccount(c, effects: effects);
    releaseB.complete();
    await advanced;
    expect(Accounts.accountMode.map((role) => role.mid), [300, 300, 300, 300]);
    expect(Accounts.account.get('200')!.type, isEmpty);
  });

  test('a stale advanced dialog cannot select old roles after the current identity changes', () async {
    final a = _account(100)..type.addAll(AccountType.values);
    final b = _account(200);
    final c = _account(300);
    for (final fixture in [a, b, c]) {
      await fixture.onChange();
    }
    Accounts.accountMode.fillRange(0, AccountType.values.length, a);
    final dialog = Accounts.captureRoleSelection();
    await Accounts.selectCurrentAccount(c, effects: _selectionEffects());
    await expectLater(
      Accounts.applyAccountRoleSelection(
        {for (final role in AccountType.values) role: b},
        snapshot: dialog,
        effects: _selectionEffects(),
      ),
      throwsStateError,
    );
    expect(Accounts.accountMode.map((role) => role.mid), [300, 300, 300, 300]);
    expect(Accounts.account.get('200')!.type, isEmpty);
  });

  test('advanced role choices preserve newer explicit changes and do not stop unchanged main media', () async {
    final a = _account(100)..type.addAll(AccountType.values);
    final b = _account(200);
    await a.onChange();
    await b.onChange();
    Accounts.accountMode.fillRange(0, AccountType.values.length, a);
    final dialog = Accounts.captureRoleSelection();
    var stopped = 0;
    Accounts.beforeMainIdentityChange = () async => ++stopped;
    Accounts.setTemporaryRole(AccountType.heartbeat, AnonymousAccount());
    await Accounts.applyAccountRoleSelection(
      {
        AccountType.main: a,
        AccountType.heartbeat: a,
        AccountType.recommend: b,
        AccountType.video: a,
      },
      snapshot: dialog,
      effects: _selectionEffects(),
    );
    expect(Accounts.accountMode.map((role) => role.mid), [100, 0, 200, 100]);
    expect(stopped, 0);
  });

  test('selecting from anonymous does not override existing anonymous or dedicated roles', () {
    final anonymous = AnonymousAccount();
    expect(
      mainAccountFollowingRoles(<Account>[
        anonymous,
        anonymous,
        _account(200),
        anonymous,
      ]),
      isEmpty,
    );
  });

  test('Hive accounts saved before profile fields still decode', () {
    final fixture = _account(100);
    final restored = LoginAccountAdapter().read(
      _LegacyAccountReader(fixture.cookieJar),
    );
    expect(restored.mid, 100);
    expect(restored.accessKey, 'fixture');
    expect(restored.profile.loginState, SavedAccountLoginState.unchecked);
  });

  test(
    'saved display profiles survive a disk reopen independently of roles',
    () async {
      final box = await Hive.openBox<LoginAccount>('profile-roundtrip');
      final fixture = _account(100)
        ..profile = SavedAccountProfile(
          name: 'Fixture',
          loginState: SavedAccountLoginState.verified,
          checkedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        );
      await box.put('100', fixture);
      await box.close();
      final reopened = await Hive.openBox<LoginAccount>('profile-roundtrip');
      final restored = reopened.get('100')!;
      expect(restored.mid, 100);
      expect(restored.profile.name, 'Fixture');
      expect(restored.profile.loginState, SavedAccountLoginState.verified);
      expect(restored.profile.checkedAt, fixture.profile.checkedAt);
      await reopened.deleteFromDisk();
    },
  );
}

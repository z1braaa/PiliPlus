import 'dart:io';

import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

LoginAccount _account(String mid) => LoginAccount(
  BiliCookieJar.fromJson({'DedeUserID': mid, 'bili_jct': 'csrf'}),
  'access-key',
  'refresh-token',
);

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('piliplus-identity-test-');
    Hive.init(tempDir.path);
    GStorage.localCache = await Hive.openBox('localCache');
    GStorage.setting = await Hive.openBox('setting');
    GStorage.video = await Hive.openBox('video');
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test(
    'main login instance changes also stop retained media and paid pages',
    () {
      final guest = AnonymousAccount();
      final retained = _account('123');
      expect(Accounts.mainIdentityChanged(guest, AnonymousAccount()), isFalse);
      expect(Accounts.mainIdentityChanged(retained, retained), isFalse);
      expect(Accounts.mainIdentityChanged(guest, _account('123')), isTrue);
      expect(Accounts.mainIdentityChanged(_account('123'), guest), isTrue);
      expect(
        Accounts.mainIdentityChanged(_account('123'), _account('123')),
        isTrue,
      );
      expect(
        Accounts.mainIdentityChanged(_account('123'), _account('456')),
        isTrue,
      );
    },
  );
}

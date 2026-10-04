import 'dart:io';

import 'package:PiliPlus/services/live_intimacy_record_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  test(
    'failed initial Hive open can recover and retry without restarting',
    () async {
      final private = await Directory.systemTemp.createTemp(
        'pili-ledger-fixture-',
      );
      final blocked = await File('${private.path}/is-a-file')
          .writeAsString('fixture');
      final store = HiveLiveIntimacyRecordStore();
      try {
        Hive.init(blocked.path);
        await expectLater(
          store.write(1, 2, 3, {
            'watch': {'effective_ms': 7000},
          }),
          throwsA(isA<FileSystemException>()),
        );
        Hive.init(private.path);
        await store.write(1, 2, 3, {
          'watch': {'effective_ms': 7000},
        });
        expect((await store.read(1, 2, 3))!['watch'], {'effective_ms': 7000});
        expect(await store.read(9, 2, 3), isNull);
      } finally {
        await Hive.close();
        await private.delete(recursive: true);
      }
    },
  );
}

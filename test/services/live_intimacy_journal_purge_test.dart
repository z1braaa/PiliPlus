import 'dart:io';

import 'package:PiliPlus/services/live_task_automation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  test('explicit account purge retains unresolved dispatch protection and isolates other uids', () async {
    final directory = await Directory.systemTemp.createTemp(
      'piliplus-task-purge-test-',
    );
    Hive.init(directory.path);
    final box = await Hive.openBox<dynamic>('liveTaskAutomationJournal');
    const pending = '1:10:1:cycle:like:like';
    const settled = '1:10:1:cycle:sendDanmu:sendDanmu';
    const another = '2:10:1:cycle:like:like';
    await box.putAll({
      pending: {'schema': 2, 'pending_count': 1, 'unknown': true},
      settled: {'schema': 2, 'pending_count': 0},
      another: {'schema': 2, 'pending_count': 0},
      '1:10:1:index': {
        'keys': [pending, settled],
      },
      '2:10:1:index': {
        'keys': [another],
      },
    });
    await LiveTaskAutomationService.clearAccountJournal(1);
    expect(box.containsKey(pending), isTrue);
    expect(box.containsKey(settled), isFalse);
    expect(box.get('1:10:1:index')['keys'], [pending]);
    expect(box.containsKey(another), isTrue);
    expect(box.get('2:10:1:index')['keys'], [another]);
    await Hive.close();
    await directory.delete(recursive: true);
  });
}

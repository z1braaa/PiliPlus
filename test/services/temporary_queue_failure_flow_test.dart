import 'dart:io';

import 'package:PiliPlus/services/temporary_queue_service.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory directory;

  setUpAll(() async {
    directory = Directory.systemTemp.createTempSync('piliplus-queue-test-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.localCache = await Hive.openBox('localCache');
  });

  tearDownAll(() async {
    await GStorage.setting.close();
    await GStorage.localCache.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'only exact terminal failure marks item and starts healthy successor',
    () {
      const current = TemporaryQueueEntry(bvid: 'BVA', cid: 1, title: 'A');
      const failed = TemporaryQueueEntry(bvid: 'BVB', cid: 2, title: 'B');
      const healthy = TemporaryQueueEntry(bvid: 'BVC', cid: 3, title: 'C');
      final queue = TemporaryQueueService.instance
        ..clearPending()
        ..markCurrent(current)
        ..addLast(failed)
        ..addLast(healthy);
      expect(queue.nextAfterCompletion()?.bvid, failed.bvid);
      final attempt = queue.attemptFor(failed)!;
      final stale = TemporaryQueueAttempt(
        token: 'older-attempt',
        accountScope: attempt.accountScope,
        playbackMid: attempt.playbackMid,
        bvid: attempt.bvid,
        cid: attempt.cid,
      );
      expect(
        queue.reportTerminalFailure(
          attempt: stale,
          bvid: failed.bvid,
          cid: failed.cid!,
          playbackMid: attempt.playbackMid,
          reason: '片源请求失败',
        ),
        isNull,
      );
      expect(queue.items.first.failureReason, isNull);
      final transition = queue.reportTerminalFailure(
        attempt: attempt,
        bvid: failed.bvid,
        cid: failed.cid!,
        playbackMid: attempt.playbackMid,
        reason: '片源请求失败',
      );
      expect(transition?.failed.bvid, failed.bvid);
      expect(transition?.next?.bvid, healthy.bvid);
      expect(transition?.nextAttempt, isNotNull);
      expect(queue.items.first.failureReason, '片源请求失败');
      expect(
        queue.reportTerminalFailure(
          attempt: attempt,
          bvid: failed.bvid,
          cid: failed.cid!,
          playbackMid: attempt.playbackMid,
          reason: '重复回调',
        ),
        isNull,
      );
      expect(queue.items.first.failureReason, '片源请求失败');

      final retry = queue.retryFailed(queue.items.first);
      expect(retry?.bvid, failed.bvid);
      expect(queue.items.first.failureReason, isNull);
      expect(queue.remove(queue.items.first), isTrue);
      expect(queue.items.map((e) => e.bvid), [healthy.bvid]);
    },
  );
}

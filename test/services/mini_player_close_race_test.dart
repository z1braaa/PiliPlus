import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/in_app_mini_player.dart';
import 'package:PiliPlus/services/temporary_queue_service.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  late Directory directory;
  final mini = InAppMiniPlayer.instance;
  final queue = TemporaryQueueService.instance;
  const first = TemporaryQueueEntry(bvid: 'BVA', cid: 1, title: 'A');
  const second = TemporaryQueueEntry(bvid: 'BVB', cid: 2, title: 'B');

  setUpAll(() async {
    directory = Directory.systemTemp.createTempSync(
      'piliplus-mini-close-test-',
    );
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.localCache = await Hive.openBox('localCache');
  });

  setUp(() {
    mini.current.value = null;
    mini.wasClosedForOwner('first');
    mini.wasClosedForOwner('second');
    queue
      ..clearCurrent()
      ..clearPending();
  });

  tearDown(() {
    mini.current.value = null;
    mini.wasClosedForOwner('first');
    mini.wasClosedForOwner('second');
    queue.clearCurrent();
  });

  tearDownAll(() async {
    await GStorage.setting.close();
    await GStorage.localCache.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'closing A clears A immediately and preserves B started during stop',
    () async {
      final oldController = _FakeController();
      final oldSession = _session('first', oldController);
      mini.current.value = oldSession;
      queue.markCurrent(first, ownerToken: oldSession);

      final closing = mini.close(oldSession);

      expect(mini.current.value, isNull);
      expect(queue.current, isNull);
      expect(oldController.player.stopCalls, 1);
      expect(oldController.releaseCalls, 0);
      expect(oldController.removeListenerCalls, 1);

      final newController = _FakeController();
      final newSession = _session('second', newController);
      mini.current.value = newSession;
      queue.markCurrent(second, ownerToken: newSession);
      oldController.player.finishStop.complete();
      await closing;

      expect(mini.current.value, same(newSession));
      expect(queue.current?.samePart(second), isTrue);
      expect(oldController.releaseCalls, 1);
      expect(newController.player.stopCalls, 0);
      expect(newController.releaseCalls, 0);
      expect(newController.removeListenerCalls, 0);
    },
  );

  test(
    'a failed old stop releases A without clearing a newer cursor',
    () async {
      final oldController = _FakeController();
      final oldSession = _session('first', oldController);
      mini.current.value = oldSession;
      queue.markCurrent(first, ownerToken: oldSession);
      final closing = mini.close(oldSession);
      final result = expectLater(closing, throwsStateError);

      queue.markCurrent(second, ownerToken: Object());
      oldController.player.finishStop.completeError(StateError('stop failed'));
      await result;

      expect(mini.current.value, isNull);
      expect(queue.current?.samePart(second), isTrue);
      expect(oldController.releaseCalls, 1);
    },
  );

  test(
    'an old close callback cannot close or release the newer mini',
    () async {
      final oldController = _FakeController();
      final newController = _FakeController();
      final oldSession = _session('first', oldController);
      final newSession = _session('second', newController);
      mini.current.value = newSession;
      queue.markCurrent(second, ownerToken: newSession);

      await mini.close(oldSession);

      expect(mini.current.value, same(newSession));
      expect(queue.current?.samePart(second), isTrue);
      expect(oldController.player.stopCalls, 0);
      expect(oldController.releaseCalls, 0);
      expect(newController.player.stopCalls, 0);
      expect(newController.releaseCalls, 0);
      expect(newController.removeListenerCalls, 0);
    },
  );

  test('an old restore callback cannot hide or adopt the newer mini', () {
    final oldController = _FakeController();
    final newController = _FakeController();
    final oldSession = _session('first', oldController);
    final newSession = _session('second', newController);
    mini.current.value = newSession;
    queue.markCurrent(second, ownerToken: newSession);

    mini.restore(oldSession);

    expect(mini.current.value, same(newSession));
    expect(queue.current?.samePart(second), isTrue);
    expect(mini.adoptByPage(ownerKey: 'first', routeName: '/videoV'), isFalse);
    expect(oldController.releaseCalls, 0);
    expect(newController.releaseCalls, 0);
    expect(newController.removeListenerCalls, 0);
  });
}

MiniPlayback _session(String owner, _FakeController controller) => MiniPlayback(
  ownerKey: owner,
  routeName: '/videoV',
  routeArguments: const {},
  ownerRoute: null,
  controller: controller,
);

/// Only native stop is held at a deterministic asynchronous boundary. These
/// tests exercise the production mini-player/queue services, not native media.
class _FakePlayer implements Player {
  final finishStop = Completer<void>();
  int stopCalls = 0;

  @override
  Future<void> stop({bool open = false, bool synchronized = true}) {
    stopCalls++;
    return finishStop.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeController implements PlPlayerController {
  final player = _FakePlayer();
  int releaseCalls = 0;
  int removeListenerCalls = 0;

  @override
  Player get videoPlayerController => player;

  @override
  void releaseFromInAppMiniPlayer() => releaseCalls++;

  @override
  void removeStatusLister(ValueChanged<PlayerStatus> listener) =>
      removeListenerCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

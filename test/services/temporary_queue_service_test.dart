import 'package:PiliPlus/services/temporary_queue_service.dart';
import 'package:flutter_test/flutter_test.dart';

TemporaryQueueEntry item(String bvid, int cid) => TemporaryQueueEntry(
  bvid: bvid,
  cid: cid,
  title: '$bvid-P$cid',
);

void main() {
  test('next and last move an existing pending item without duplicates', () {
    final state = TemporaryQueueState()
      ..markCurrent(item('A', 1))
      ..add(item('B', 2), next: false)
      ..add(item('C', 3), next: false)
      ..add(item('D', 4), next: true);
    expect(state.items.map((e) => e.bvid), ['D', 'B', 'C']);

    final moved = state.add(item('B', 2), next: false);
    expect(moved.moved, isTrue);
    expect(state.items.map((e) => e.bvid), ['D', 'C', 'B']);

    final alreadyPlaying = state.add(item('A', 1), next: true);
    expect(alreadyPlaying.alreadyPlaying, isTrue);
    expect(state.items.map((e) => e.bvid), ['D', 'C', 'B']);
  });

  test('different parts remain distinct and unknown cid is not a wildcard', () {
    final first = item('BV1', 101);
    final second = item('BV1', 202);
    const unknown = TemporaryQueueEntry(
      bvid: 'BV1',
      cid: null,
      title: 'unresolved',
    );
    final state = TemporaryQueueState()
      ..add(first, next: false)
      ..add(second, next: false)
      ..add(unknown, next: false);
    expect(state.items.length, 3);
    expect(state.indexOf(first), 0);
    expect(state.indexOf(second), 1);
    expect(state.indexOf(unknown), 2);
    expect(unknown.samePart(second), isFalse);
  });

  test(
    'current is ephemeral; completion peeks, accepted playback consumes',
    () {
      final state = TemporaryQueueState()..markCurrent(item('A', 1));
      expect(state.items, isEmpty);
      expect(state.visibleItems.map((e) => e.bvid), ['A']);
      state
        ..add(item('B', 2), next: true)
        ..add(item('C', 3), next: false);
      expect(state.advance()?.bvid, 'B');
      expect(state.items.map((e) => e.bvid), ['B', 'C']);
      expect(state.visibleItems.map((e) => e.bvid), ['B', 'C']);
      state.markCurrent(item('B', 2));
      expect(state.items.map((e) => e.bvid), ['C']);
      expect(state.visibleItems.map((e) => e.bvid), ['B', 'C']);
    },
  );

  test('drag reorder changes pending sequence without touching current', () {
    final state = TemporaryQueueState()..markCurrent(item('A', 1));
    for (final value in ['B', 'C', 'D']) {
      state.add(item(value, 1), next: false);
    }
    expect(state.reorder(2, 0), isTrue);
    expect(state.items.map((e) => e.bvid), ['D', 'B', 'C']);
    expect(state.current?.bvid, 'A');
  });

  test('old route disposal cannot clear a newer part cursor', () {
    final state = TemporaryQueueState()
      ..markCurrent(item('BV1', 101))
      ..markCurrent(item('BV1', 202));
    expect(state.clearCurrentIfMatches(item('BV1', 101)), isFalse);
    expect(state.current?.cid, 202);
    expect(state.clearCurrentIfMatches(item('BV1', 202)), isTrue);
    expect(state.current, isNull);
  });

  test('old route cannot clear a newer owner of the same video part', () {
    final oldOwner = Object();
    final newOwner = Object();
    final state = TemporaryQueueState()
      ..markCurrent(item('BV1', 101), ownerToken: oldOwner)
      ..markCurrent(item('BV1', 101), ownerToken: newOwner);
    expect(
      state.clearCurrentIfMatches(item('BV1', 101), ownerToken: oldOwner),
      isFalse,
    );
    expect(state.current?.cid, 101);
    expect(
      state.clearCurrentIfMatches(item('BV1', 101), ownerToken: newOwner),
      isTrue,
    );
    expect(state.current, isNull);
  });

  test(
    'mini-player adoption transfers cursor ownership before new route exit',
    () {
      final oldOwner = Object();
      final restoredOwner = Object();
      final unrelatedOwner = Object();
      final playing = item('BV1', 101);
      final state = TemporaryQueueState()
        ..markCurrent(playing, ownerToken: oldOwner);
      expect(
        state.transferCurrentOwner(
          item('BV2', 202),
          newOwnerToken: unrelatedOwner,
        ),
        isFalse,
      );
      expect(state.currentOwner, same(oldOwner));
      expect(
        state.transferCurrentOwner(playing, newOwnerToken: restoredOwner),
        isTrue,
      );
      expect(
        state.clearCurrentIfMatches(playing, ownerToken: oldOwner),
        isFalse,
      );
      expect(state.current?.bvid, 'BV1');
      expect(
        state.clearCurrentIfMatches(playing, ownerToken: restoredOwner),
        isTrue,
      );
      expect(state.current, isNull);
    },
  );

  test('terminal failure stays visible and advances to next playable item', () {
    final state = TemporaryQueueState()
      ..markCurrent(item('A', 1))
      ..add(item('B', 2), next: false)
      ..add(item('C', 3), next: false);
    final failed = state.markFailed(item('A', 1), '片源请求失败');
    expect(failed.failureReason, '片源请求失败');
    expect(state.firstPlayable?.bvid, 'B');
    expect(state.visibleItems.map((e) => e.bvid), ['A', 'B', 'C']);
    expect(state.retryFailed(failed)?.failureReason, isNull);
    expect(state.firstPlayable?.bvid, 'A');
  });

  test(
    'failure evidence must match account, video, part and attempt token',
    () {
      const attempt = TemporaryQueueAttempt(
        token: 'attempt-7',
        accountScope: 'uid:42',
        playbackMid: 42,
        bvid: 'BV1',
        cid: 101,
      );
      expect(
        attempt.matches(
          token: 'attempt-7',
          accountScope: 'uid:42',
          playbackMid: 42,
          bvid: 'BV1',
          cid: 101,
        ),
        isTrue,
      );
      expect(
        attempt.matches(
          token: 'attempt-6',
          accountScope: 'uid:42',
          playbackMid: 42,
          bvid: 'BV1',
          cid: 101,
        ),
        isFalse,
      );
      expect(
        attempt.matches(
          token: 'attempt-7',
          accountScope: 'guest',
          playbackMid: 42,
          bvid: 'BV1',
          cid: 101,
        ),
        isFalse,
      );
      expect(
        attempt.matches(
          token: 'attempt-7',
          accountScope: 'uid:42',
          playbackMid: 43,
          bvid: 'BV1',
          cid: 101,
        ),
        isFalse,
      );
      expect(
        attempt.matches(
          token: 'attempt-7',
          accountScope: 'uid:42',
          playbackMid: 42,
          bvid: 'BV1',
          cid: 202,
        ),
        isFalse,
      );
    },
  );

  test('legacy item without cid waits for explicit resolved retry', () {
    const unresolved = TemporaryQueueEntry(
      bvid: 'BV1',
      cid: null,
      title: 'video',
      failureReason: '缺少分 P 信息，请手动重试',
    );
    final state = TemporaryQueueState()
      ..add(unresolved, next: false)
      ..add(item('BV2', 2), next: false)
      ..markFailed(unresolved, unresolved.failureReason!);
    expect(state.firstPlayable?.bvid, 'BV2');
    final retried = state.retryFailed(unresolved, resolved: item('BV1', 1));
    expect(retried?.cid, 1);
    expect(state.firstPlayable?.bvid, 'BV1');
    expect(state.items.where((entry) => entry.bvid == 'BV1').length, 1);
  });
}

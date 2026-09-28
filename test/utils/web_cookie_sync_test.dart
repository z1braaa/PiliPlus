import 'dart:async';

import 'package:PiliPlus/utils/web_cookie_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('A to B to C serializes replacement and skips obsolete B', () async {
    final a = Object();
    final b = Object();
    final c = Object();
    Object current = a;
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final events = <String>[];
    final sync = WebCookieSync<Object>(
      current: () => current,
      replace: (account) async {
        events.add(
          account == a
              ? 'A'
              : account == b
              ? 'B'
              : 'C',
        );
        if (identical(account, a)) {
          firstStarted.complete();
          await releaseFirst.future;
        }
      },
      merge: (_) async {},
      clear: () async => events.add('clear'),
    );

    final first = sync.replaceIfCurrent(a);
    await firstStarted.future;
    current = b;
    final second = sync.replaceIfCurrent(b);
    current = c;
    final third = sync.replaceIfCurrent(c);
    releaseFirst.complete();
    await Future.wait([first, second, third]);

    expect(events, ['A', 'clear', 'C']);
  });

  test(
    'paid-page barrier clears an account changed during sync and fails closed',
    () async {
      final a = Object();
      final b = Object();
      Object current = a;
      final started = Completer<void>();
      final finish = Completer<void>();
      final events = <String>[];
      final sync = WebCookieSync<Object>(
        current: () => current,
        replace: (account) async {
          events.add(identical(account, a) ? 'A' : 'B');
          if (identical(account, a)) {
            started.complete();
            await finish.future;
          }
        },
        merge: (_) async {},
        clear: () async => events.add('clear'),
      );

      final attempt = sync.prepare(a);
      await started.future;
      current = b;
      final next = sync.prepare(b);
      finish.complete();
      await expectLater(attempt, throwsStateError);
      await next;
      expect(events, ['A', 'clear', 'B']);
    },
  );

  test(
    'failed replacement cannot authorize paid page or poison later sync',
    () async {
      final a = Object();
      Object current = a;
      var attempts = 0;
      final sync = WebCookieSync<Object>(
        current: () => current,
        replace: (_) async {
          attempts++;
          if (attempts == 1) throw StateError('cookie write failed');
        },
        merge: (_) async {},
        clear: () async {},
      );

      await expectLater(sync.prepare(a), throwsStateError);
      await sync.prepare(a);
      expect(attempts, 2);
    },
  );

  test('old-account logout cannot clear a newer browser session', () async {
    final a = Object();
    final b = Object();
    Object current = b;
    var clears = 0;
    final sync = WebCookieSync<Object>(
      current: () => current,
      replace: (_) async {},
      merge: (_) async {},
      clear: () async => clears++,
    );
    await sync.clearIfCurrent(a);
    expect(clears, 0);
    await sync.clearIfCurrent(b);
    expect(clears, 1);
  });
}

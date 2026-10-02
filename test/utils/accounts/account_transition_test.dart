import 'dart:async';

import 'package:PiliPlus/utils/accounts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Completion is explicit, after work and with progress cleared',
    () async {
      final coordinator = MainAccountTransitionCoordinator();
      final work = Completer<void>();
      final observed = <bool>[];
      coordinator.addSettledListener(
        () => observed.add(coordinator.inProgress),
      );
      final operation = coordinator.run((generation) async {
        expect(coordinator.inProgress, isTrue);
        expect(coordinator.isCurrent(generation), isTrue);
        await work.future;
      });
      expect(coordinator.inProgress, isTrue);
      expect(observed, isEmpty);
      work.complete();
      await operation;
      expect(coordinator.inProgress, isFalse);
      expect(observed, [false]);
    },
  );

  test(
    'A failed async transition completes and preserves its exception',
    () async {
      final coordinator = MainAccountTransitionCoordinator();
      var notifications = 0;
      coordinator.addSettledListener(() => ++notifications);
      final failure = StateError('fixture failure');
      await expectLater(
        coordinator.run<void>((_) => Future<void>.error(failure)),
        throwsA(same(failure)),
      );
      expect(coordinator.inProgress, isFalse);
      expect(notifications, 1);
    },
  );

  test('A synchronous failure also completes its transition', () async {
    final coordinator = MainAccountTransitionCoordinator();
    var notifications = 0;
    coordinator.addSettledListener(() => ++notifications);
    await expectLater(
      coordinator.run<void>((_) {
        throw StateError('fixture synchronous failure');
      }),
      throwsStateError,
    );
    expect(coordinator.inProgress, isFalse);
    expect(notifications, 1);
  });

  test(
    'Old finally cannot clear or notify while a newer transition runs',
    () async {
      final coordinator = MainAccountTransitionCoordinator();
      final first = Completer<void>();
      final second = Completer<void>();
      var notifications = 0;
      coordinator.addSettledListener(() => ++notifications);
      final oldOperation = coordinator.run((_) => first.future);
      final oldGeneration = coordinator.generation;
      final newOperation = coordinator.run((_) => second.future);
      expect(coordinator.generation, greaterThan(oldGeneration));
      expect(coordinator.isCurrent(oldGeneration), isFalse);
      first.complete();
      await oldOperation;
      expect(coordinator.inProgress, isTrue);
      expect(notifications, 0);
      second.complete();
      await newOperation;
      expect(coordinator.inProgress, isFalse);
      expect(notifications, 1);
    },
  );

  test(
    'Old late completion cannot notify twice after newest operation settles',
    () async {
      final coordinator = MainAccountTransitionCoordinator();
      final first = Completer<void>();
      final second = Completer<void>();
      var notifications = 0;
      coordinator.addSettledListener(() => ++notifications);
      final oldOperation = coordinator.run((_) => first.future);
      final newOperation = coordinator.run((_) => second.future);
      second.complete();
      await newOperation;
      expect(coordinator.inProgress, isFalse);
      expect(notifications, 1);
      first.complete();
      await oldOperation;
      expect(notifications, 1);
    },
  );

  test('Choosing original identity supersedes a pending switch', () async {
    final coordinator = MainAccountTransitionCoordinator();
    final a = Object();
    final b = Object();
    var selected = a;
    final oldWait = Completer<void>();
    final oldOperation = coordinator.run((generation) async {
      await oldWait.future;
      if (coordinator.isCurrent(generation)) selected = b;
    });
    await coordinator.run((generation) async {
      if (coordinator.isCurrent(generation)) selected = a;
    });
    oldWait.complete();
    await oldOperation;
    expect(selected, same(a));
    expect(coordinator.inProgress, isFalse);
  });

  test(
    'Role listeners notify immediately, independently from main completion',
    () {
      final coordinator = MainAccountTransitionCoordinator();
      var roles = 0;
      var settled = 0;
      coordinator
        ..addRoleListener(() => ++roles)
        ..addSettledListener(() => ++settled)
        ..rolesChanged();
      expect(roles, 1);
      expect(settled, 0);
      final generation = coordinator.begin();
      coordinator.rolesChanged();
      expect(roles, 2);
      expect(coordinator.inProgress, isTrue);
      coordinator.complete(generation);
      expect(settled, 1);
    },
  );

  test('Listener registrations deduplicate and remove cleanly', () {
    final coordinator = MainAccountTransitionCoordinator();
    var roles = 0;
    var settled = 0;
    void onRole() => ++roles;
    void onSettled() => ++settled;
    coordinator
      ..addRoleListener(onRole)
      ..addRoleListener(onRole)
      ..addSettledListener(onSettled)
      ..addSettledListener(onSettled)
      ..rolesChanged();
    coordinator.complete(coordinator.begin());
    expect(roles, 1);
    expect(settled, 1);
    coordinator
      ..removeRoleListener(onRole)
      ..removeSettledListener(onSettled)
      ..rolesChanged();
    coordinator.complete(coordinator.begin());
    expect(roles, 1);
    expect(settled, 1);
  });

  test(
    'Listener exception does not replace operation result or stop others',
    () async {
      final coordinator = MainAccountTransitionCoordinator();
      final errors = <Object>[];
      var otherListenerRan = false;
      final completed = Completer<void>();
      runZonedGuarded(() {
        coordinator
          ..addSettledListener(
            () => throw StateError('fixture UI failure'),
          )
          ..addSettledListener(() => otherListenerRan = true);
        coordinator.run((_) async => 123).then((result) {
          expect(result, 123);
          completed.complete();
        });
      }, (error, _) => errors.add(error));
      await completed.future;
      expect(errors, hasLength(1));
      expect(otherListenerRan, isTrue);
      expect(coordinator.inProgress, isFalse);
    },
  );
}

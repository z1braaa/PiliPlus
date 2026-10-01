import 'dart:async';

import 'package:PiliPlus/common/widgets/playback_route_observer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final destination in [
    '/videoV',
    '/videoV?cid=42',
    '/liveRoom',
    '/audio',
  ]) {
    testWidgets('entering $destination never minimizes the previous video', (
      tester,
    ) async {
      final harness = _NavigationHarness();
      await harness.mount(tester);
      final video = await harness.push(tester, '/videoV');
      harness.decisions.clear();

      await harness.push(tester, destination);

      expect(harness.decisionFor(video, 'push-next'), isFalse);
      expect(
        harness.observer.canCreateMiniPlayer(ownerRoute: video),
        isFalse,
      );
    });
  }

  testWidgets('returning from video B to video A never minimizes B', (
    tester,
  ) async {
    final harness = _NavigationHarness();
    await harness.mount(tester);
    final first = await harness.push(tester, '/videoV');
    final second = await harness.push(tester, '/videoV');
    harness.decisions.clear();

    harness.navigator.currentState!.pop();
    await tester.pumpAndSettle();

    expect(harness.decisionFor(second, 'pop-invoked'), isFalse);
    expect(harness.decisionFor(first, 'pop-next'), isFalse);
    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: second, isPop: true),
      isFalse,
    );
  });

  testWidgets('covering playback with an ordinary page may create a mini', (
    tester,
  ) async {
    final harness = _NavigationHarness();
    await harness.mount(tester);
    final video = await harness.push(tester, '/videoV');
    harness.decisions.clear();

    await harness.push(tester, '/member');

    expect(harness.decisionFor(video, 'push-next'), isTrue);
    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: video),
      isTrue,
    );

    harness.navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(harness.decisionFor(video, 'pop-next'), isFalse);
    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: video),
      isFalse,
    );
  });

  testWidgets('popping playback to home allows a mini before and after pop', (
    tester,
  ) async {
    final harness = _NavigationHarness();
    await harness.mount(tester);
    final video = await harness.push(tester, '/videoV');
    harness.decisions.clear();

    harness.navigator.currentState!.pop();
    await tester.pumpAndSettle();

    expect(harness.decisionFor(video, 'pop-invoked'), isTrue);
    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: video, isPop: true),
      isTrue,
    );
  });

  testWidgets('dialogs and the still-visible playback page are not exits', (
    tester,
  ) async {
    final harness = _NavigationHarness();
    await harness.mount(tester);
    final video = await harness.push(tester, '/videoV');
    harness.decisions.clear();
    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: video),
      isFalse,
    );

    unawaited(
      showDialog<void>(
        context: harness.navigator.currentContext!,
        builder: (_) => const AlertDialog(content: Text('Video options')),
      ),
    );
    await tester.pumpAndSettle();
    expect(harness.decisions, isEmpty);
    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: video),
      isFalse,
    );

    harness.navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(harness.decisions, isEmpty);
    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: video),
      isFalse,
    );
  });

  testWidgets(
    'an intervening ordinary page does not hide a media destination',
    (
      tester,
    ) async {
      final harness = _NavigationHarness();
      await harness.mount(tester);
      final video = await harness.push(tester, '/videoV');
      await harness.push(tester, '/temporaryQueue');
      expect(
        harness.observer.canCreateMiniPlayer(ownerRoute: video),
        isTrue,
      );

      await harness.push(tester, '/videoV');
      expect(
        harness.observer.canCreateMiniPlayer(ownerRoute: video),
        isFalse,
      );
    },
  );

  testWidgets('replacement uses the destination actually on the stack', (
    tester,
  ) async {
    final harness = _NavigationHarness();
    await harness.mount(tester);
    final video = await harness.push(tester, '/videoV');
    final ordinary = await harness.push(tester, '/member');
    final live = harness.route('/liveRoom');

    harness.navigator.currentState!.replace(oldRoute: ordinary, newRoute: live);
    await tester.pumpAndSettle();
    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: video),
      isFalse,
    );

    harness.decisions.clear();
    harness.navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(harness.decisionFor(live, 'pop-invoked'), isFalse);
    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: live, isPop: true),
      isFalse,
    );
  });

  testWidgets('removing a covered media route updates the pop destination', (
    tester,
  ) async {
    final harness = _NavigationHarness();
    await harness.mount(tester);
    final first = await harness.push(tester, '/videoV');
    final second = await harness.push(tester, '/videoV');

    harness.navigator.currentState!.removeRoute(first);
    await tester.pumpAndSettle();
    harness.decisions.clear();
    harness.navigator.currentState!.pop();
    await tester.pumpAndSettle();

    expect(harness.decisionFor(second, 'pop-invoked'), isTrue);
    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: second, isPop: true),
      isTrue,
    );
    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: first),
      isFalse,
    );
  });

  testWidgets('popUntil distinguishes intermediate media and final exit', (
    tester,
  ) async {
    final harness = _NavigationHarness();
    await harness.mount(tester);
    final first = await harness.push(tester, '/videoV');
    final second = await harness.push(tester, '/videoV');
    harness.decisions.clear();

    harness.navigator.currentState!.popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();

    expect(harness.decisionFor(second, 'pop-invoked'), isFalse);
    expect(harness.decisionFor(first, 'pop-invoked'), isTrue);
    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: first, isPop: true),
      isTrue,
    );

    final next = await harness.push(tester, '/videoV');
    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: next),
      isFalse,
    );
  });

  testWidgets('an absent or unrelated owner cannot create a mini', (
    tester,
  ) async {
    final harness = _NavigationHarness();
    await harness.mount(tester);
    await harness.push(tester, '/videoV');
    final unrelated = harness.route('/videoV');

    expect(harness.observer.canCreateMiniPlayer(ownerRoute: null), isFalse);
    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: unrelated),
      isFalse,
    );
    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: unrelated, isPop: true),
      isFalse,
    );
  });

  testWidgets('a popped owner cannot reappear after another media opens', (
    tester,
  ) async {
    final harness = _NavigationHarness();
    await harness.mount(tester);
    final video = await harness.push(tester, '/videoV');
    harness.navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: video, isPop: true),
      isTrue,
    );

    await harness.push(tester, '/liveRoom');

    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: video, isPop: true),
      isFalse,
    );
    harness.navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(
      harness.observer.canCreateMiniPlayer(ownerRoute: video, isPop: true),
      isFalse,
      reason: 'Returning home must not revive an earlier popped video owner.',
    );
  });
}

class _NavigationHarness {
  final navigator = GlobalKey<NavigatorState>();
  final observer = PlaybackRouteObserver<PageRoute<dynamic>>();
  final decisions = <_NavigationDecision>[];

  MaterialPageRoute<void> route(String name) => MaterialPageRoute<void>(
    settings: RouteSettings(name: name),
    builder: (_) => _RouteProbe(observer: observer, decisions: decisions),
  );

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [observer],
        onGenerateRoute: (settings) => route(settings.name ?? '/'),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<MaterialPageRoute<void>> push(WidgetTester tester, String name) async {
    final next = route(name);
    unawaited(navigator.currentState!.push<void>(next));
    await tester.pumpAndSettle();
    return next;
  }

  bool decisionFor(Route<dynamic> owner, String event) => decisions
      .singleWhere(
        (decision) =>
            identical(decision.owner, owner) && decision.event == event,
      )
      .allowed;
}

class _NavigationDecision {
  const _NavigationDecision(this.owner, this.event, this.allowed);

  final Route<dynamic> owner;
  final String event;
  final bool allowed;
}

class _RouteProbe extends StatefulWidget {
  const _RouteProbe({required this.observer, required this.decisions});

  final PlaybackRouteObserver<PageRoute<dynamic>> observer;
  final List<_NavigationDecision> decisions;

  @override
  State<_RouteProbe> createState() => _RouteProbeState();
}

class _RouteProbeState extends State<_RouteProbe> with RouteAware {
  PageRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context)! as PageRoute<dynamic>;
    if (identical(route, _route)) return;
    widget.observer.unsubscribe(this);
    _route = route;
    widget.observer.subscribe(this, route);
  }

  void _record(String event, {bool isPop = false}) {
    widget.decisions.add(
      _NavigationDecision(
        _route!,
        event,
        widget.observer.canCreateMiniPlayer(ownerRoute: _route, isPop: isPop),
      ),
    );
  }

  @override
  void didPushNext() => _record('push-next');

  @override
  void didPopNext() => _record('pop-next');

  @override
  void dispose() {
    widget.observer.unsubscribe(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _record('pop-invoked', isPop: true);
    },
    child: Scaffold(body: Text(_route?.settings.name ?? '/')),
  );
}

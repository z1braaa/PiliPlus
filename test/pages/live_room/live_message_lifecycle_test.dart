// Test steps deliberately keep setup and actions on separate lines.
// ignore_for_file: cascade_invocations

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:PiliPlus/models_new/live/live_superchat/item.dart';
import 'package:PiliPlus/models_new/live/live_superchat/user_info.dart';
import 'package:PiliPlus/pages/live_room/live_message_session.dart';
import 'package:PiliPlus/pages/live_room/superchat/superchat_timeline.dart';
import 'package:PiliPlus/tcp/live.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

SuperChatItem _sc(int id, {int ts = 100, int end = 200, int room = 6}) =>
    SuperChatItem(
      id: id,
      uid: 10,
      price: 30,
      backgroundImage: 'https://example.test/sc.png',
      backgroundColor: '#EDF5FF',
      backgroundBottomColor: '#2A60B2',
      backgroundPriceColor: '#7497CD',
      messageFontColor: '#FFFFFF',
      startSime: ts,
      endTime: end,
      message: 'test',
      token: '',
      ts: ts,
      userInfo: UserInfo(
        face: '',
        faceFrame: null,
        uname: 'user',
        nameColor: '#666666',
      ),
      roomid: room,
    );

Uint8List _packet(int operation, Object body, {int protocol = 1}) {
  final payload = utf8.encode(jsonEncode(body));
  return (BytesBuilder()
        ..add(
          PackageHeader(
            protocolVer: protocol,
            operationCode: operation,
            seq: 1,
          ).toBytes(payload.length),
        )
        ..add(payload))
      .toBytes();
}

class _Sink extends Fake implements WebSocketSink {
  final List<dynamic> sent = [];
  int closed = 0;
  @override
  void add(dynamic data) => sent.add(data);
  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closed++;
  }
}

class _Socket extends Fake implements WebSocketChannel {
  final input = StreamController<dynamic>();
  final output = _Sink();
  final Completer<void> readiness = Completer<void>();
  _Socket({bool ready = true}) {
    if (ready) readiness.complete();
  }
  @override
  Future<void> get ready => readiness.future;
  @override
  Stream<dynamic> get stream => input.stream;
  @override
  WebSocketSink get sink => output;
}

void main() {
  group('SC room timeline', () {
    test('server ID deduplicates snapshot and live message', () {
      final timeline = SuperChatTimeline(6);
      expect(timeline.merge(_sc(1), 110), SuperChatMerge.inserted);
      expect(timeline.merge(_sc(1), 110), SuperChatMerge.ignored);
      expect(timeline.visible(persistent: false).map((e) => e.id), [1]);
    });
    test('late older snapshot cannot overwrite current event', () {
      final timeline = SuperChatTimeline(6)..merge(_sc(1, ts: 120), 130);
      expect(timeline.merge(_sc(1, ts: 100), 130), SuperChatMerge.ignored);
      expect(timeline.visible(persistent: true).single.ts, 120);
    });
    test('newer revision updates same identity once', () {
      final timeline = SuperChatTimeline(6)..merge(_sc(1), 110);
      expect(timeline.merge(_sc(1, ts: 120), 130), SuperChatMerge.updated);
      expect(timeline.visible(persistent: true), hasLength(1));
    });
    test('delete before add or late reconnect snapshot wins', () {
      final timeline = SuperChatTimeline(6)..delete([1]);
      expect(
        timeline.merge(_sc(1, ts: 300, end: 400), 310),
        SuperChatMerge.ignored,
      );
      expect(timeline.visible(persistent: true), isEmpty);
    });
    test(
      'server deletion marks shared reference and removes persistent item',
      () {
        final item = _sc(1);
        final timeline = SuperChatTimeline(6)..merge(item, 110);
        timeline.delete([1, 1]);
        expect(item.deleted, isTrue);
        expect(timeline.visible(persistent: true), isEmpty);
      },
    );
    test('unrendered items expire on room clock', () {
      final timeline = SuperChatTimeline(6)..merge(_sc(1), 110);
      expect(timeline.expire(200), isTrue);
      expect(timeline.visible(persistent: false), isEmpty);
      expect(timeline.visible(persistent: true).single.expired, isTrue);
      expect(timeline.expire(201), isFalse);
    });
    test('snapshot already expired appears only as persistent history', () {
      final timeline = SuperChatTimeline(6)..merge(_sc(1), 250);
      expect(timeline.visible(persistent: false), isEmpty);
      expect(timeline.visible(persistent: true).single.expired, isTrue);
    });
    test('wrong room and missing server ID are rejected', () {
      final timeline = SuperChatTimeline(6);
      expect(timeline.merge(_sc(1, room: 7), 110), SuperChatMerge.ignored);
      expect(timeline.merge(_sc(0), 110), SuperChatMerge.ignored);
    });
    test('identity budget fails closed without evicting tombstones', () {
      final timeline = SuperChatTimeline(6, identityLimit: 2);
      timeline.delete([1]);
      timeline.merge(_sc(2), 110);
      expect(timeline.merge(_sc(3), 110), SuperChatMerge.ignored);
      expect(timeline.saturated, isTrue);
      expect(
        timeline.merge(_sc(1, ts: 500, end: 600), 510),
        SuperChatMerge.ignored,
      );
      timeline.delete([2, 3]);
      expect(timeline.visible(persistent: true), isEmpty);
    });
    test('same timestamp field changes are conservatively ignored', () {
      final timeline = SuperChatTimeline(6)..merge(_sc(1), 110);
      expect(timeline.merge(_sc(1, end: 500), 110), SuperChatMerge.ignored);
      expect(timeline.visible(persistent: true).single.endTime, 200);
    });
    test('history sorts and has bounded visible entries', () {
      final timeline = SuperChatTimeline(6, limit: 2);
      for (final id in [2, 1, 3]) {
        timeline.merge(_sc(id, ts: id), 0);
      }
      expect(timeline.visible(persistent: true).map((e) => e.id), [3, 2]);
    });
    test(
      'fullscreen copy retains image and lifecycle without sharing mutation',
      () {
        final original = _sc(1)
          ..expired = true
          ..deleted = true;
        final copy = original.copyWith(endTime: 150);
        expect(copy.backgroundImage, original.backgroundImage);
        expect(copy.expired, isTrue);
        expect(copy.deleted, isTrue);
        copy.expired = false;
        expect(original.expired, isTrue);
      },
    );
  });

  group('bounded room message session', () {
    testWidgets('successful connection and repeat start are one attempt', (
      tester,
    ) async {
      var connects = 0;
      final states = <LiveMessageConnectionState>[];
      final session = LiveMessageSession(
        connect: (_) async {
          connects++;
          return true;
        },
        disconnect: () {},
        onState: states.add,
      );
      session.start();
      session.start();
      await tester.pump();
      expect(connects, 1);
      expect(states.last, LiveMessageConnectionState.connected);
      session.dispose();
    });
    testWidgets('failed token/auth has finite exponential retries', (
      tester,
    ) async {
      var connects = 0;
      final states = <LiveMessageConnectionState>[];
      final session = LiveMessageSession(
        connect: (_) async {
          connects++;
          return false;
        },
        disconnect: () {},
        onState: states.add,
      );
      session.start();
      await tester.pump();
      for (final seconds in [1, 2, 4, 8, 15]) {
        await tester.pump(Duration(seconds: seconds));
      }
      expect(connects, 6);
      expect(states.last, LiveMessageConnectionState.stopped);
      expect(session.running, isFalse);
      await tester.pump(const Duration(minutes: 5));
      expect(connects, 6);
      session.dispose();
    });
    testWidgets('pause cancels backoff and cannot reconnect', (tester) async {
      var connects = 0;
      final session = LiveMessageSession(
        connect: (_) async {
          connects++;
          return false;
        },
        disconnect: () {},
        onState: (_) {},
      );
      session.start();
      await tester.pump();
      session.stop();
      await tester.pump(const Duration(minutes: 1));
      expect(connects, 1);
      session.dispose();
    });
    testWidgets('late token/connection after room restart stays invalid', (
      tester,
    ) async {
      final pending = <Completer<bool>>[];
      final epochs = <int>[];
      final states = <LiveMessageConnectionState>[];
      final session = LiveMessageSession(
        connect: (epoch) {
          epochs.add(epoch);
          final completer = Completer<bool>();
          pending.add(completer);
          return completer.future;
        },
        disconnect: () {},
        onState: states.add,
      );
      session.start();
      session.start(restart: true);
      expect(session.isCurrent(epochs.first), isFalse);
      pending.first.complete(true);
      await tester.pump();
      expect(states.last, LiveMessageConnectionState.connecting);
      pending.last.complete(true);
      await tester.pump();
      expect(states.last, LiveMessageConnectionState.connected);
      session.connectionLost(epochs.first);
      expect(states.last, LiveMessageConnectionState.connected);
      session.dispose();
    });
    testWidgets('rapid authenticate/disconnect still exhausts retry budget', (
      tester,
    ) async {
      var connects = 0;
      final session = LiveMessageSession(
        connect: (_) async {
          connects++;
          return true;
        },
        disconnect: () {},
        onState: (_) {},
        retryDelays: const [Duration(seconds: 1)],
      );
      session.start();
      await tester.pump();
      session.connectionLost(session.generation);
      await tester.pump(const Duration(seconds: 1));
      session.connectionLost(session.generation);
      expect(connects, 2);
      expect(session.running, isFalse);
      session.dispose();
    });
    testWidgets('stable period resets outage retry budget', (tester) async {
      var connects = 0;
      final session = LiveMessageSession(
        connect: (_) async {
          connects++;
          return true;
        },
        disconnect: () {},
        onState: (_) {},
        retryDelays: const [Duration(seconds: 1)],
      );
      session.start();
      await tester.pump();
      session.connectionLost(session.generation);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 60));
      session.connectionLost(session.generation);
      await tester.pump(const Duration(seconds: 1));
      expect(connects, 3);
      expect(session.running, isTrue);
      session.dispose();
    });
    testWidgets('request timeout invalidates work even if it later completes', (
      tester,
    ) async {
      final pending = Completer<bool>();
      final states = <LiveMessageConnectionState>[];
      final session = LiveMessageSession(
        connect: (_) => pending.future,
        disconnect: () {},
        onState: states.add,
        retryDelays: const [],
        attemptTimeout: const Duration(seconds: 2),
      );
      session.start();
      await tester.pump(const Duration(seconds: 2));
      expect(states.last, LiveMessageConnectionState.stopped);
      pending.complete(true);
      await tester.pump();
      expect(states.last, LiveMessageConnectionState.stopped);
      session.dispose();
    });
  });

  group('message transport', () {
    test('header rejects short and out-of-range frames', () {
      for (var length = 0; length < 16; length++) {
        expect(PackageHeaderRes.fromBytesData(Uint8List(length)), isNull);
      }
      final oversized = const PackageHeader(
        protocolVer: 1,
        operationCode: 5,
        seq: 1,
      ).toBytes(99);
      expect(PackageHeaderRes.fromBytesData(oversized), isNull);
      final bad = Uint8List(16);
      ByteData.sublistView(bad).setUint32(0, 0);
      expect(PackageHeaderRes.fromBytesData(bad), isNull);
    });
    testWidgets('auth acknowledgement gates events and handles concatenation', (
      tester,
    ) async {
      final socket = _Socket();
      final events = <dynamic>[];
      var lost = 0;
      final stream = LiveMessageStream(
        streamToken: 'private-token',
        roomId: 6,
        uid: 0,
        servers: ['wss://example.test/sub'],
        socketFactory: (_) => socket,
        onDisconnected: () => lost++,
      );
      stream.addEventListener(events.add);
      final result = stream.init();
      await tester.pump();
      socket.input.add(_packet(5, {'cmd': 'before-auth'}));
      socket.input.add(_packet(8, {'code': 0}));
      socket.input.add(
        (BytesBuilder()
              ..add(_packet(5, {'cmd': 'one'}))
              ..add(_packet(5, {'cmd': 'two'})))
            .toBytes(),
      );
      await tester.pump();
      expect(await result, isTrue);
      expect(events.map((e) => e['cmd']), ['one', 'two']);
      expect(socket.output.sent.length, 2); // auth + immediate heartbeat
      stream.close();
      await tester.pump();
      expect(lost, 0);
      unawaited(socket.input.close());
      await tester.pump();
    });
    testWidgets('compressed packets retain packet boundaries', (tester) async {
      final socket = _Socket();
      final events = <dynamic>[];
      final stream = LiveMessageStream(
        streamToken: 'token',
        roomId: 6,
        uid: 0,
        servers: ['wss://example.test/sub'],
        socketFactory: (_) => socket,
      );
      stream.addEventListener(events.add);
      final result = stream.init();
      await tester.pump();
      socket.input.add(_packet(8, {'code': 0}));
      await tester.pump();
      expect(await result, isTrue);
      final payload = ZLibEncoder().convert(
        (BytesBuilder()
              ..add(_packet(5, {'cmd': 'compressed-one'}))
              ..add(_packet(5, {'cmd': 'compressed-two'})))
            .toBytes(),
      );
      socket.input.add(
        (BytesBuilder()
              ..add(
                const PackageHeader(
                  protocolVer: 2,
                  operationCode: 5,
                  seq: 1,
                ).toBytes(payload.length),
              )
              ..add(payload)
              ..add(_packet(5, {'cmd': 'after'})))
            .toBytes(),
      );
      await tester.pump();
      expect(events.map((e) => e['cmd']), [
        'compressed-one',
        'compressed-two',
        'after',
      ]);
      stream.close();
      unawaited(socket.input.close());
      await tester.pump();
    });
    testWidgets('auth rejection disconnects once and emits no message', (
      tester,
    ) async {
      final socket = _Socket();
      var lost = 0;
      final events = <dynamic>[];
      final stream = LiveMessageStream(
        streamToken: 'token',
        roomId: 6,
        uid: 0,
        servers: ['wss://example.test/sub'],
        socketFactory: (_) => socket,
        onDisconnected: () => lost++,
      );
      stream.addEventListener(events.add);
      final result = stream.init();
      await tester.pump();
      socket.input.add(_packet(8, {'code': -101}));
      await tester.pump();
      expect(await result, isFalse);
      expect(lost, 1);
      expect(events, isEmpty);
      stream.close();
      unawaited(socket.input.close());
      await tester.pump();
      expect(lost, 1);
    });
    testWidgets('ready timeout closes socket and ignores late readiness', (
      tester,
    ) async {
      final socket = _Socket(ready: false);
      var lost = 0;
      final stream = LiveMessageStream(
        streamToken: 'token',
        roomId: 6,
        uid: 0,
        servers: ['wss://example.test/sub'],
        socketFactory: (_) => socket,
        onDisconnected: () => lost++,
        connectTimeout: const Duration(seconds: 1),
      );
      final result = stream.init();
      await tester.pump(const Duration(seconds: 1));
      expect(await result, isFalse);
      expect(socket.output.closed, 1);
      expect(lost, 1);
      socket.readiness.complete();
      await tester.pump();
      expect(socket.output.sent, isEmpty);
      stream.close();
      unawaited(socket.input.close());
      await tester.pump();
    });
    testWidgets(
      'intentional close during connect cancels late socket and events',
      (tester) async {
        final socket = _Socket(ready: false);
        var lost = 0;
        final stream = LiveMessageStream(
          streamToken: 'token',
          roomId: 6,
          uid: 0,
          servers: ['wss://example.test/sub'],
          socketFactory: (_) => socket,
          onDisconnected: () => lost++,
        );
        final result = stream.init();
        stream.close();
        socket.readiness.complete();
        await tester.pump();
        expect(await result, isFalse);
        expect(lost, 0);
        expect(socket.output.sent, isEmpty);
        unawaited(socket.input.close());
        await tester.pump();
      },
    );
    testWidgets('missing auth acknowledgement has finite deadline', (
      tester,
    ) async {
      final socket = _Socket();
      var lost = 0;
      final stream = LiveMessageStream(
        streamToken: 'token',
        roomId: 6,
        uid: 0,
        servers: ['wss://example.test/sub'],
        socketFactory: (_) => socket,
        onDisconnected: () => lost++,
        authTimeout: const Duration(seconds: 2),
      );
      final result = stream.init();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(await result, isFalse);
      expect(lost, 1);
      stream.close();
      unawaited(socket.input.close());
      await tester.pump();
    });
    testWidgets('server closure requests one reconnect', (tester) async {
      final socket = _Socket();
      var lost = 0;
      final stream = LiveMessageStream(
        streamToken: 'token',
        roomId: 6,
        uid: 0,
        servers: ['wss://example.test/sub'],
        socketFactory: (_) => socket,
        onDisconnected: () => lost++,
      );
      final result = stream.init();
      await tester.pump();
      socket.input.add(_packet(8, {'code': 0}));
      await tester.pump();
      expect(await result, isTrue);
      unawaited(socket.input.close());
      await tester.pump();
      await tester.pump();
      expect(lost, 1);
      stream.close();
      expect(lost, 1);
    });
    testWidgets('missing heartbeat reply closes bounded connection', (
      tester,
    ) async {
      final socket = _Socket();
      var lost = 0;
      var seconds = 0;
      final stream = LiveMessageStream(
        streamToken: 'token',
        roomId: 6,
        uid: 0,
        servers: ['wss://example.test/sub'],
        socketFactory: (_) => socket,
        onDisconnected: () => lost++,
        clock: () => DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
      );
      final result = stream.init();
      await tester.pump();
      socket.input.add(_packet(8, {'code': 0}));
      await tester.pump();
      expect(await result, isTrue);
      seconds = 90;
      await tester.pump(const Duration(seconds: 90));
      expect(lost, 1);
      stream.close();
      unawaited(socket.input.close());
      await tester.pump();
    });
  });
}

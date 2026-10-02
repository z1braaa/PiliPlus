// Every Object() is a distinct login instance, including equal-UID logins.
// ignore_for_file: prefer_const_constructors, cascade_invocations
import 'dart:async';
import 'dart:typed_data';

import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Journal implements LiveInteractionJournal {
  @override
  Future<Map<String, dynamic>?> read(String key) async => null;
  @override
  Future<void> write(String key, Map<String, dynamic> record) async {}
}

class _Transport implements LiveTaskInteractionTransport {
  int gets = 0;
  int posts = 0;
  String? path;
  Map<String, dynamic>? body;
  LiveInteractionAccount? actor;
  bool failPost = false;
  bool cancelBeforeDispatch = false;
  Map<String, dynamic> readData = {
    'level': 1,
    'task_info': [
      {'title': '点赞', 'sub_title': '0/3次', 'is_done': 0, 'jump_type': 'like'},
    ],
  };
  Map<String, dynamic> writeResponse = {'code': 0};
  @override
  Future<Map<String, dynamic>> get(
    String path,
    Map<String, dynamic> query,
    LiveInteractionAccount account,
    CancelToken token,
  ) async {
    gets++;
    expect(path, endsWith('/GetActivatedMedalInfo'));
    expect(query['target_id'], 20);
    expect(query['room_id'], 6);
    actor = account;
    return {'code': 0, 'data': readData};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
    LiveInteractionAccount account,
  ) async {
    posts++;
    this.path = path;
    this.body = body;
    actor = account;
    if (failPost) throw TimeoutException('response lost');
    return writeResponse;
  }

  @override
  Future<Map<String, dynamic>> postTask(
    String path,
    Map<String, dynamic> body,
    LiveInteractionAccount account,
    bool Function() stillAllowed,
  ) {
    if (cancelBeforeDispatch || !stillAllowed()) {
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: path),
        reason: 'live_task_guard',
      );
    }
    return post(path, body, account);
  }
}

class _Adapter implements HttpClientAdapter {
  int dispatched = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    dispatched++;
    return ResponseBody.fromString(
      '{"code":0}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _Transport transport;
  late LiveInteractionAccount account;
  late LiveInteractionService service;
  late Future<Map<String, Object>> Function(Map<String, Object>) signer;
  setUp(() {
    transport = _Transport();
    account = LiveInteractionAccount(
      uid: 10,
      loggedIn: true,
      identity: Object(),
      csrf: 'fixture-main-token',
      generation: 1,
    );
    signer = (params) async => {
      ...params,
      'w_rid': 'fixture-signature',
      'wts': 1,
    };
    service = LiveInteractionService.testing(
      roomId: 6,
      anchorUid: 20,
      transport: transport,
      journal: _Journal(),
      account: () => account,
      sign: (params) => signer(params),
    );
  });
  tearDown(() => service.dispose());

  test(
    'task-only read makes one request and retains exact owning identity',
    () async {
      final snapshot = await service.loadFanTasks();
      expect(transport.gets, 1);
      expect(transport.posts, 0);
      expect(snapshot.accountIdentity, same(account.identity));
      expect(snapshot.accountUid, 10);
      expect(snapshot.joined, isTrue);
      expect(snapshot.tasks.single.remainingCount, 3);
    },
  );
  test(
    'missing task list remains unavailable rather than an empty completed set',
    () async {
      transport.readData = {'level': 1};
      await expectLater(
        service.loadFanTasks(),
        throwsA(isA<LiveInteractionException>()),
      );
      expect(transport.posts, 0);
    },
  );
  test('signed like UID, CSRF and transport identity all belong to main task actor', () async {
    final result = await service.sendTaskLikes(
      clickTime: 3,
      expectedAccountIdentity: account.identity,
    );
    expect(result.state, LiveTaskWriteState.accepted);
    expect(transport.posts, 1);
    expect(transport.actor?.identity, same(account.identity));
    expect(transport.body?['uid'], 10);
    expect(transport.body?['csrf'], 'fixture-main-token');
    expect(transport.body?['w_rid'], 'fixture-signature');
    expect(transport.body?['click_time'], 3);
  });
  test('plain task message uses signed query and cannot contain a manual reply target', () async {
    final result = await service.sendTaskDanmaku(
      message: '默认弹幕',
      expectedAccountIdentity: account.identity,
    );
    expect(result.state, LiveTaskWriteState.accepted);
    final uri = Uri.parse(transport.path!);
    expect(uri.path, '/msg/send');
    expect(uri.queryParameters['w_rid'], 'fixture-signature');
    expect(transport.body?['msg'], '默认弹幕');
    expect(transport.body?['roomid'], 6);
    expect(transport.body?['reply_mid'], 0);
    expect(transport.body?['csrf_token'], 'fixture-main-token');
  });
  test(
    'timeout and malformed response are unknown and never retry POST',
    () async {
      transport.failPost = true;
      final timedOut = await service.sendTaskLikes(
        clickTime: 1,
        expectedAccountIdentity: account.identity,
      );
      expect(timedOut.state, LiveTaskWriteState.unknown);
      expect(transport.posts, 1);
      transport.failPost = false;
      transport.writeResponse = {};
      final incomplete = await service.sendTaskLikes(
        clickTime: 1,
        expectedAccountIdentity: account.identity,
      );
      expect(incomplete.state, LiveTaskWriteState.unknown);
      expect(transport.posts, 2);
    },
  );
  test(
    'same UID re-login while signing invalidates actor before dispatch',
    () async {
      final wait = Completer<Map<String, Object>>();
      signer = (_) => wait.future;
      final oldIdentity = account.identity;
      final sending = service.sendTaskLikes(
        clickTime: 1,
        expectedAccountIdentity: oldIdentity,
      );
      account = LiveInteractionAccount(
        uid: 10,
        loggedIn: true,
        identity: Object(),
        csrf: 'new-fixture',
        generation: 2,
      );
      wait.complete({'w_rid': 'fixture'});
      expect((await sending).state, LiveTaskWriteState.notSubmitted);
      expect(transport.posts, 0);
    },
  );
  test(
    'preferences/playback invalidated while signing prevent any POST',
    () async {
      final wait = Completer<Map<String, Object>>();
      signer = (_) => wait.future;
      var allowed = true;
      final sending = service.sendTaskDanmaku(
        message: '默认',
        expectedAccountIdentity: account.identity,
        stillAllowed: () => allowed,
      );
      allowed = false;
      wait.complete({'w_rid': 'fixture'});
      expect((await sending).state, LiveTaskWriteState.notSubmitted);
      expect(transport.posts, 0);
    },
  );
  test(
    'final transport guard cancellation is notSubmitted, not an unknown write',
    () async {
      transport.cancelBeforeDispatch = true;
      final result = await service.sendTaskLikes(
        clickTime: 1,
        expectedAccountIdentity: account.identity,
      );
      expect(result.state, LiveTaskWriteState.notSubmitted);
      expect(transport.posts, 0);
    },
  );
  test(
    'dispatch interceptor rechecks after asynchronous cookie loading',
    () async {
      final cookies = Completer<void>();
      final cookieStarted = Completer<void>();
      var allowed = true;
      final adapter = _Adapter();
      final client = Dio()..httpClientAdapter = adapter;
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            cookieStarted.complete();
            await cookies.future;
            handler.next(options);
          },
        ),
      );
      client.interceptors.add(liveTaskDispatchGuard());
      final sending = client.post<dynamic>(
        'https://api.live.bilibili.com/msg/send',
        options: Options(extra: {'liveTaskStillAllowed': () => allowed}),
      );
      final checked = expectLater(
        sending,
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      await cookieStarted.future;
      allowed = false;
      cookies.complete();
      await checked;
      expect(adapter.dispatched, 0);
      client.close();
    },
  );
  test('an identity-change generation cancels a signed write before identity assignment', () async {
    final wait = Completer<Map<String, Object>>();
    signer = (_) => wait.future;
    final identity = account.identity;
    final sending = service.sendTaskLikes(
      clickTime: 1,
      expectedAccountIdentity: identity,
    );
    account = LiveInteractionAccount(
      uid: 10,
      loggedIn: true,
      identity: identity,
      csrf: 'fixture-main-token',
      generation: 2,
    );
    wait.complete({'w_rid': 'fixture'});
    expect((await sending).state, LiveTaskWriteState.notSubmitted);
    expect(transport.posts, 0);
  });
}

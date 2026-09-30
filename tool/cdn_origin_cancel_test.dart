// Deterministic cancellation checks: fake upstream futures use no external I/O.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Standalone Dart checks also run outside Flutter package resolution.
// ignore: avoid_relative_lib_imports
import '../lib/http/cdn_origin_policy.dart';
// ignore: avoid_relative_lib_imports
import '../lib/http/cdn_playback_proxy.dart';
// ignore: avoid_relative_lib_imports
import '../lib/utils/cdn_startup_trace.dart';

void check(bool result, String reason) {
  if (!result) throw StateError(reason);
}

final class Plan {
  Plan({
    this.openDelay = Duration.zero,
    this.headerDelay = Duration.zero,
    this.lateError = false,
  });
  final Duration openDelay;
  final Duration headerDelay;
  final bool lateError;
  final Uint8List bytes = Uint8List.fromList(
    List.generate(64 * 1024, (i) => i % 251),
  );
  int aborts = 0;
  int responsesDisposed = 0;
  int opens = 0;
}

final class Headers implements HttpHeaders {
  final Map<String, String> values = {};
  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class Response extends Stream<List<int>> implements HttpClientResponse {
  Response(this.plan, bool ranged) : statusCode = ranged ? 206 : 200 {
    if (ranged) {
      headers.set(
        'content-range',
        'bytes 0-${plan.bytes.length - 1}/${plan.bytes.length}',
      );
    }
    headers
      ..set('etag', '"stable"')
      ..set('last-modified', 'Mon, 28 Sep 2026 00:00:00 GMT');
    controller = StreamController<List<int>>(
      onCancel: () {
        plan.responsesDisposed++;
      },
    );
    controller.add(plan.bytes);
    unawaited(controller.close());
  }
  final Plan plan;
  @override
  final int statusCode;
  @override
  final Headers headers = Headers();
  late final StreamController<List<int>> controller;
  @override
  int get contentLength => plan.bytes.length;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => controller.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class Request implements HttpClientRequest {
  Request(this.plan);
  final Plan plan;
  @override
  final Headers headers = Headers();
  @override
  bool followRedirects = false;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    plan.aborts++;
  }

  @override
  Future<HttpClientResponse> close() async {
    await Future<void>.delayed(plan.headerDelay);
    if (plan.lateError) {
      throw const SocketException('synthetic late response failure');
    }
    return Response(plan, headers.value('range') != null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class Client implements HttpClient {
  Client(this.plan);
  final Plan plan;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    plan.opens++;
    await Future<void>.delayed(plan.openDelay);
    if (plan.lateError && plan.openDelay > Duration.zero) {
      throw const SocketException('synthetic late open failure');
    }
    return Request(plan);
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter) return null;
    return super.noSuchMethod(invocation);
  }
}

Future<void> cancelCase(
  String name,
  Plan worker, {
  required bool checkPassthroughCounter,
}) async {
  // The consumer is a real loopback client created outside the override zone.
  final consumer = HttpClient();
  final parent = Plan();
  var clients = 0;
  await HttpOverrides.runZoned(() async {
    final proxy = await CdnPlaybackProxy.start(
      concurrency: 2,
      autoSelect: true,
      adaptive: true,
      parallel: false,
      enableDiagnostics: true,
      timeout: const Duration(seconds: 10),
      allowOrigin: (_) => true,
      originResolver: (uris) => [CdnOrigin(uris.single, mainland: true)],
      isBaselineOrigin: (_) => true,
    );
    final url = proxy.register(
      'http://127.0.0.1/upgcxcode/test/video.m4s',
      track: CdnStartupTrack.video,
    );
    final watch = Stopwatch()..start();
    try {
      final response = await (await consumer.getUrl(Uri.parse(url))).close();
      final data = BytesBuilder();
      await for (final bytes in response) {
        data.add(bytes);
      }
      check(
        response.statusCode == 200 && data.length == parent.bytes.length,
        'fallback content/status',
      );
      final events = proxy.diagnostics['request_events'] as List;
      final cancellation = events.singleWhere(
        (e) =>
            e['event'] == 'cancel' &&
            e['kind'] == 'origin_idle_timeout' &&
            e['phase'] == 'stream' &&
            e['request_id'] is int,
      );
      final release = events.singleWhere(
        (e) =>
            e['event'] == 'request_released' &&
            e['request_id'] == cancellation['request_id'],
      );
      final opened = events.singleWhere(
        (e) =>
            e['event'] == 'request_open' &&
            e['request_id'] == cancellation['request_id'],
      );
      final fallback = events.singleWhere(
        (e) =>
            e['event'] == 'request_created' &&
            e['phase'] == 'fallback' &&
            e['parent_id'] == cancellation['parent_id'],
      );
      final idleMs = (cancellation['t_ms'] as int) - (opened['t_ms'] as int);
      final releaseMs =
          (release['t_ms'] as int) - (cancellation['t_ms'] as int);
      final fallbackMs =
          (fallback['t_ms'] as int) - (cancellation['t_ms'] as int);
      // Print timing before asserting so the original implementation can be
      // compared independently of its missing passthrough byte counter.
      stdout.writeln(
        jsonEncode({
          'case': name,
          'response_elapsed_ms': watch.elapsedMilliseconds,
          'origin_idle_ms': idleMs,
          'cancel_to_release_ms': releaseMs,
          'cancel_to_fallback_ms': fallbackMs,
          'passthrough_counter_checked': checkPassthroughCounter,
        }),
      );
      check(
        watch.elapsedMilliseconds >= 2700 && watch.elapsedMilliseconds < 3700,
        'did not fallback promptly after 3s idle cancel',
      );
      check(
        idleMs >= 2700 && idleMs < 3300,
        'idle cancellation did not occur near 3s',
      );
      check(
        releaseMs >= 0 && releaseMs < 500,
        'cancelled origin slot was not released within 500ms',
      );
      check(
        fallbackMs >= 0 && fallbackMs < 500,
        'fallback did not begin within 500ms of cancellation',
      );
      check(
        proxy.diagnostics['active_origin_requests'] == 0,
        'cancelled origin retained slot',
      );
      if (checkPassthroughCounter) {
        check(
          proxy.diagnostics['observed_upstream_body_bytes'] ==
              parent.bytes.length,
          'passthrough bytes omitted',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      check(
        worker.aborts > 0 || worker.lateError,
        'late request was not aborted',
      );
      if (worker.headerDelay > Duration.zero && !worker.lateError) {
        check(worker.responsesDisposed > 0, 'late response was not disposed');
      }
      stdout.writeln(jsonEncode({'case': name, 'status': 'passed'}));
    } finally {
      await proxy.close();
      consumer.close(force: true);
    }
  }, createHttpClient: (_) => Client(clients++ == 0 ? parent : worker));
}

Future<void> main(List<String> args) async {
  final checkPassthroughCounter = !args.contains('--skip-passthrough-counter');
  final errors = <Object>[];
  final completed = Completer<void>();
  runZonedGuarded(
    () async {
      try {
        await cancelCase(
          'late_open_request_aborted',
          Plan(openDelay: const Duration(seconds: 4)),
          checkPassthroughCounter: checkPassthroughCounter,
        );
        await cancelCase(
          'late_headers_response_disposed',
          Plan(headerDelay: const Duration(seconds: 4)),
          checkPassthroughCounter: checkPassthroughCounter,
        );
        await cancelCase(
          'late_open_error_observed',
          Plan(openDelay: const Duration(seconds: 4), lateError: true),
          checkPassthroughCounter: checkPassthroughCounter,
        );
        await cancelCase(
          'late_header_error_observed',
          Plan(headerDelay: const Duration(seconds: 4), lateError: true),
          checkPassthroughCounter: checkPassthroughCounter,
        );
        check(errors.isEmpty, 'unobserved late error escaped');
        stdout.writeln(jsonEncode({'passed': 4, 'total': 4}));
        completed.complete();
      } catch (error, stack) {
        completed.completeError(error, stack);
      }
    },
    (error, stack) {
      errors.add(error);
    },
  );
  await completed.future;
}

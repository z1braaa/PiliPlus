import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

// This transport is also exercised without Flutter package resolution.
// ignore: always_use_package_imports
import 'cdn_origin_policy.dart';
// Keep transport timing available to standalone Dart protocol checks.
// ignore: always_use_package_imports
import '../utils/cdn_startup_trace.dart';

/// A bounded, session-local Range transport for DASH media. This is independent
/// of Flutter so the HTTP contract can be tested against a deterministic origin.
/// Inspired by Bilibili-thread-ripper; no browser/Electron code is executed.
final class CdnPlaybackProxy {
  CdnPlaybackProxy._(
    this._server,
    this.concurrency,
    this.chunkSize,
    this.timeout,
    this._allowOrigin,
    this._originResolver,
    this._trace,
    this.autoSelect,
    this.adaptive,
    this.parallel,
    this.durationSeconds,
  );

  static Future<CdnPlaybackProxy> start({
    int concurrency = 8,
    int chunkSize = 1024 * 1024,
    Duration timeout = const Duration(seconds: 10),
    bool Function(Uri)? allowOrigin,
    CdnOriginResolver? originResolver,
    CdnStartupTrace? trace,
    bool autoSelect = false,
    bool adaptive = false,
    bool parallel = true,
    double? durationSeconds,
  }) async {
    if (concurrency < 1 ||
        concurrency > 32 ||
        chunkSize < 64 * 1024 ||
        chunkSize > 4 * 1024 * 1024 ||
        timeout <= Duration.zero) {
      throw ArgumentError('Invalid CDN transport limits');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = CdnPlaybackProxy._(
      server,
      concurrency,
      chunkSize,
      timeout,
      allowOrigin ?? CdnOriginPolicy.isMedia,
      originResolver ??
          (autoSelect ? CdnOriginPolicy.measured : CdnOriginPolicy.resolve),
      trace,
      autoSelect,
      adaptive,
      parallel,
      durationSeconds != null && durationSeconds.isFinite && durationSeconds > 0
          ? durationSeconds
          : null,
    );
    server.listen((request) {
      unawaited(
        proxy._handle(request).catchError((Object _) {
          // Malformed headers or a disconnect during an early rejection must not
          // escape the server callback and become an unhandled application error.
          request.response.deadline = Duration.zero;
        }),
      );
    }, onError: (Object _) {});
    return proxy;
  }

  final HttpServer _server;
  final int concurrency;
  final bool autoSelect;
  final bool adaptive;
  final bool parallel;
  final double? durationSeconds;
  final int chunkSize;
  final Duration timeout;
  final bool Function(Uri) _allowOrigin;
  final CdnOriginResolver _originResolver;
  final CdnStartupTrace? _trace;
  static const _maxBufferedBytes = 64 * 1024 * 1024;
  static const _startupChunkSize = 64 * 1024;
  int _bufferedBytes = 0;
  final Map<String, _Media> _media = {};
  final Set<_Transfer> _transfers = {};
  final List<Completer<void>> _waiters = [];
  final Queue<_SlotWaiter> _urgentWaiters = Queue();
  final Queue<_SlotWaiter> _normalWaiters = Queue();
  final Queue<_SlotWaiter> _backgroundWaiters = Queue();
  final Set<_Transfer> _backgroundTransfers = {};
  int _inFlight = 0;
  int _normalInFlight = 0;
  int _nextRequestId = 0;
  bool _closed = false;
  int _observedUpstreamBytes = 0;
  int _upstreamRequests = 0;
  final List<Map<String, Object?>> _rangeFailures = [];
  final List<Map<String, Object>> _failures = [];
  void _failure(Uri origin, String phase, Object error) {
    if (_failures.length >= 20) return;
    const messages = {
      'CDN range metadata mismatch',
      'CDN range length mismatch',
      'CDN range truncated',
      'CDN resource identity mismatch',
      'CDN request cancelled',
      'CDN range too long',
      'All CDN origins failed for this range',
    };
    _failures.add({
      'host': origin.host,
      'phase': phase,
      'kind': error is HttpException && messages.contains(error.message)
          ? error.message
          : '${error.runtimeType}',
    });
  }

  Map<String, Object> get diagnostics => {
    'observed_upstream_body_bytes': _observedUpstreamBytes,
    'upstream_requests': _upstreamRequests,
    'failures': _failures,
    'range_failures': _rangeFailures,
    'selected_hosts': _media.values
        .map((m) => m.preferred?.uri.host)
        .whereType<String>()
        .toSet()
        .toList(),
  };

  /// Retains the exact signed origin URL in memory; it is never exposed through
  /// the loopback URL. Unrecognized media stays on the existing native path.
  String register(
    String url, {
    Iterable<String> alternatives = const [],
    Map<String, String> headers = const {},
    CdnStartupTrack track = CdnStartupTrack.unknown,
  }) {
    if (_closed) return url;
    final originals = <Uri>[];
    for (final value in [url, ...alternatives]) {
      final uri = Uri.tryParse(value);
      if (uri != null &&
          _allowOrigin(uri) &&
          (originals.isEmpty || uri.path == originals.first.path) &&
          !originals.contains(uri)) {
        originals.add(uri);
      }
      if (originals.length == 4) break;
    }
    if (originals.isEmpty || _media.length >= 8) return url;
    final seen = <Uri>{};
    final origins = _originResolver(List.unmodifiable(originals))
        .where(
          (origin) =>
              _allowOrigin(origin.uri) &&
              origin.uri.path == originals.first.path &&
              seen.add(origin.uri),
        )
        .take(40)
        .toList();
    if (origins.isEmpty) return url;
    final orderedOrigins = [
      ...origins.where((origin) => origin.mainland),
      ...origins.where((origin) => !origin.mainland),
    ];
    final random = Random.secure();
    final token = base64Url.encode(
      List.generate(24, (_) => random.nextInt(256)),
    );
    final safeHeaders = <String, String>{};
    for (final entry in headers.entries) {
      final name = entry.key.toLowerCase();
      if (const ['user-agent', 'referer', 'origin'].contains(name)) {
        safeHeaders[name] = entry.value;
      }
    }
    _media['/$token'] = _Media(
      originals.first,
      safeHeaders,
      orderedOrigins,
      track,
    );
    return 'http://127.0.0.1:${_server.port}/$token';
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final transfer in _transfers.toList()) {
      transfer.cancel();
    }
    for (final transfer in _backgroundTransfers.toList()) {
      transfer.cancel();
    }
    for (final media in _media.values) {
      media.close();
    }
    _media.clear();
    _wakeWaiters();
    await _server.close(force: true);
  }

  void _wakeWaiters() {
    _drainSlotWaiters();
    for (final waiter in _waiters.toList()) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiters.clear();
  }

  int get _normalLimit => max(1, concurrency - 1);

  void _drainSlotWaiters() {
    for (final queue in [
      _urgentWaiters,
      _normalWaiters,
      _backgroundWaiters,
    ]) {
      final count = queue.length;
      for (var index = 0; index < count; index++) {
        final waiter = queue.removeFirst();
        if (waiter.transfer.cancelled) {
          waiter.completer.complete();
        } else {
          queue.addLast(waiter);
        }
      }
    }
    while (_inFlight < concurrency) {
      _SlotWaiter? waiter;
      if (_urgentWaiters.isNotEmpty) {
        waiter = _urgentWaiters.removeFirst();
      } else if (_normalInFlight < _normalLimit && _normalWaiters.isNotEmpty) {
        waiter = _normalWaiters.removeFirst();
      } else if (_backgroundWaiters.isNotEmpty) {
        waiter = _backgroundWaiters.removeFirst();
      }
      if (waiter == null) break;
      if (waiter.transfer.cancelled) {
        waiter.completer.complete();
        continue;
      }
      _inFlight++;
      waiter.transfer.activeSlots++;
      if (!waiter.urgent && !waiter.transfer.background) _normalInFlight++;
      waiter.granted = true;
      if (!waiter.transfer.reportedSlot) {
        waiter.transfer.reportedSlot = true;
        _trace?.mark(
          CdnStartupStage.originSlotGranted,
          track: waiter.transfer.track,
          requestId: waiter.transfer.requestId,
        );
      }
      waiter.completer.complete();
    }
  }

  void _preemptBackground() {
    for (final transfer in _backgroundTransfers.toList()) {
      if (!transfer.cancelled && transfer.activeSlots > 0) {
        transfer
          ..preempted = true
          ..cancel();
        return;
      }
    }
  }

  Future<T> _slot<T>(
    _Transfer transfer,
    Future<T> Function() action, {
    bool urgent = false,
  }) async {
    transfer.pendingWork++;
    var reserved = false;
    try {
      transfer.check();
      if (_inFlight < concurrency &&
          _urgentWaiters.isEmpty &&
          (urgent ||
              (transfer.background
                  ? _normalWaiters.isEmpty
                  : _normalInFlight < _normalLimit))) {
        _inFlight++;
        transfer.activeSlots++;
        if (!urgent && !transfer.background) _normalInFlight++;
        reserved = true;
        if (!transfer.reportedSlot) {
          transfer.reportedSlot = true;
          _trace?.mark(
            CdnStartupStage.originSlotGranted,
            track: transfer.track,
            requestId: transfer.requestId,
          );
        }
      } else {
        final waiter = _SlotWaiter(transfer, urgent);
        (urgent
                ? _urgentWaiters
                : transfer.background
                ? _backgroundWaiters
                : _normalWaiters)
            .add(waiter);
        if (!transfer.reportedQueue && !transfer.reportedSlot) {
          transfer.reportedQueue = true;
          _trace?.mark(
            CdnStartupStage.originQueueEnter,
            track: transfer.track,
            requestId: transfer.requestId,
          );
        }
        if (!transfer.background &&
            _inFlight >= concurrency &&
            (urgent || _normalInFlight < _normalLimit)) {
          _preemptBackground();
        }
        _drainSlotWaiters();
        await waiter.completer.future;
        reserved = waiter.granted;
      }
      transfer.check();
      return await action();
    } finally {
      if (reserved) {
        _inFlight--;
        transfer.activeSlots--;
        if (!urgent && !transfer.background) _normalInFlight--;
        _wakeWaiters();
      }
      transfer.pendingWork--;
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final output = request.response;
    // Native playback supplies no browser Origin. Require the exact loopback
    // authority as well as an unguessable registered token (no open URL proxy).
    if (_closed ||
        request.headers.value(HttpHeaders.hostHeader) !=
            '127.0.0.1:${_server.port}' ||
        request.headers.value('origin') != null ||
        request.uri.hasQuery ||
        !_media.containsKey(request.uri.path)) {
      output.statusCode = HttpStatus.notFound;
      await output.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      output.statusCode = HttpStatus.methodNotAllowed;
      output.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await output.close();
      return;
    }
    final rawRange = request.headers.value(HttpHeaders.rangeHeader);
    if (rawRange != null &&
        !RegExp(r'^bytes=(\d+-\d*|-\d+)$').hasMatch(rawRange)) {
      output.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await output.close();
      return;
    }
    // Bounds memory even if a native player issues overlapping seeks.
    if (_transfers.length >= 8) {
      output.statusCode = HttpStatus.serviceUnavailable;
      await output.close();
      return;
    }
    // Detach before any CDN work. HttpResponse.done does not reliably observe
    // a peer disconnect until close(); a socket read subscription does, including
    // cancellation while a CDN probe is still waiting for its first byte.
    final media = _media[request.uri.path]!;
    final transfer = _Transfer(timeout, _wakeWaiters, media, ++_nextRequestId);
    _transfers.add(transfer);
    _trace?.mark(
      CdnStartupStage.proxyRequest,
      track: media.track,
      requestId: transfer.requestId,
    );
    var reply = _MediaResponse.pending(timeout);
    try {
      final socket = await output.detachSocket(writeHeaders: false);
      transfer.attach(socket);
      reply = _MediaResponse(socket, timeout);
      transfer.check();
      if ((autoSelect || adaptive) &&
          (adaptive || !parallel) &&
          request.method == 'GET') {
        try {
          await _serveMeasuredStream(transfer, media, rawRange, reply);
          transfer.markOutputComplete();
          await reply.close();
          transfer.finish();
        } catch (_) {
          transfer.check();
          if (reply.started) rethrow;
          await _passthrough(transfer, media, request, reply);
        }
        return;
      }
      _Plan plan;
      try {
        plan = await _prepare(transfer, media);
        _trace?.mark(
          CdnStartupStage.candidateReady,
          track: media.track,
          requestId: transfer.requestId,
        );
      } catch (_) {
        transfer.check();
        // No response body has been sent: reissue the player's original request
        // as one stream. Never append a full response to partially emitted data.
        await _passthrough(transfer, media, request, reply);
        return;
      }
      final probe = plan.reference;
      final total = probe.total;
      final range = _range(rawRange, total);
      if (range == null) {
        reply.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        reply.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        transfer.markOutputComplete();
        await reply.close();
        transfer.finish();
        return;
      }
      final (start, end) = range;
      _ensureCurrent(transfer, plan);
      _BufferedChunk? first;
      if (request.method == 'GET') {
        if (!autoSelect && concurrency >= 4) _warmPeers(transfer, plan);
        try {
          // Startup bytes cannot wait behind speculative data from another
          // track: mpv may need both initial headers before draining either.
          first = _BufferedChunk(
            start == 0 && probe.bytes.length > 1
                ? _Chunk(
                    Uint8List.sublistView(
                      probe.bytes,
                      0,
                      min(end + 1, probe.bytes.length),
                    ),
                    min(end, probe.end),
                    probe.total,
                    probe.contentType,
                    probe.etag,
                    probe.modified,
                  )
                : await _chunk(
                    transfer,
                    plan,
                    start,
                    min<int>(
                      end,
                      start + min<int>(chunkSize, _startupChunkSize) - 1,
                    ),
                    true,
                  ),
            _BufferedChunk._noop,
          );
          _trace?.mark(
            CdnStartupStage.firstRangeValidated,
            track: media.track,
            requestId: transfer.requestId,
          );
        } catch (_) {
          transfer.check();
          await _passthrough(transfer, media, request, reply);
          return;
        }
      }
      reply
        ..statusCode = rawRange == null
            ? HttpStatus.ok
            : HttpStatus.partialContent
        ..contentLength = end - start + 1;
      reply.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      reply.headers.set(
        HttpHeaders.contentTypeHeader,
        probe.contentType ?? 'application/octet-stream',
      );
      reply.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      // ETags are CDN-specific. Do not expose one origin's validator as if it
      // identified bytes subsequently served by other origins.
      if (rawRange != null) {
        reply.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$total',
        );
      }
      if (first != null) {
        try {
          _ensureCurrent(transfer, plan);
          reply.add(first.chunk!.bytes);
          await reply.flush();
          _trace?.mark(
            CdnStartupStage.proxyFirstFlush,
            track: media.track,
            requestId: transfer.requestId,
          );
        } finally {
          first.release();
        }
        await _drainChunks(transfer, plan, reply, first.chunk!.end + 1, end);
      }
      transfer.markOutputComplete();
      await reply.close();
      transfer.finish();
    } catch (_) {
      if (!reply.started) {
        reply
          ..statusCode = HttpStatus.badGateway
          ..contentLength = 0;
        try {
          await reply.close();
        } catch (_) {}
      }
      // cancel() destroys the socket after a committed failure; the client
      // receives a truncated Content-Length response, never substituted bytes.
    } finally {
      transfer.cancel();
      _transfers.remove(transfer);
    }
  }

  Future<void> _drainChunks(
    _Transfer transfer,
    _Plan plan,
    _MediaResponse reply,
    int next,
    int end,
  ) async {
    final pending = Queue<Future<_BufferedChunk>>();
    void enqueue() {
      if (next > end) return;
      final chunkEnd = min<int>(
        end,
        next + (adaptive ? min<int>(chunkSize, 512 * 1024) : chunkSize) - 1,
      );
      pending.add(
        _buffered(
          transfer,
          plan,
          next,
          chunkEnd,
          urgent: plan.media.track == CdnStartupTrack.audio,
        ),
      );
      next = chunkEnd + 1;
    }

    // Leave room for the other DASH track even at the largest settings.
    var window = min(
      parallel ? (adaptive ? 1 : concurrency) : 1,
      max(1, _maxBufferedBytes ~/ 2 ~/ chunkSize),
    );
    for (var i = 0; i < window; i++) {
      enqueue();
    }
    if (!autoSelect && concurrency < 4) _warmPeers(transfer, plan);
    var completed = 0;
    var lastRate = 0.0;
    var epochBytes = 0;
    final epoch = Stopwatch()..start();
    try {
      while (pending.isNotEmpty) {
        transfer.check();
        final item = await pending.removeFirst();
        try {
          item.check();
          _ensureCurrent(transfer, plan);
          epochBytes += item.chunk!.bytes.length;
          reply.add(item.chunk!.bytes);
          await reply.flush();
        } finally {
          item.release();
        }
        // A sliding window keeps other connections busy as soon as the
        // next ordered piece is consumed; no whole-batch barrier.
        completed++;
        if (adaptive && parallel && completed >= window * 2) {
          final rate = epochBytes / max(0.001, epoch.elapsedMicroseconds / 1e6);
          // Trial increases must earn their extra sockets in ordered useful
          // output. Plateau/loss returns to the preceding smaller window.
          if (lastRate > 0 && rate < lastRate * 1.1 && window > 1) {
            window = max(1, window ~/ 2);
            plan.rampFinished = true;
          } else if (!plan.rampFinished &&
              rate <
                  (durationSeconds == null
                      ? 4 * 1024 * 1024
                      : max(
                          128 * 1024,
                          plan.reference.total / durationSeconds! * 3,
                        ))) {
            window = min(min(concurrency, 8), window * 2);
          }
          lastRate = rate;
          epochBytes = 0;
          completed = 0;
          epoch.reset();
        }
        while (pending.length < window && next <= end) {
          enqueue();
        }
      }
    } finally {
      for (final future in pending) {
        unawaited(future.then((item) => item.release()));
      }
    }
  }

  static (int, int)? _range(String? value, int total) {
    if (total <= 0) return null;
    if (value == null) return (0, total - 1);
    final parts = value.substring(6).split('-');
    if (parts[0].isEmpty) {
      final suffix = int.tryParse(parts[1]);
      if (suffix == null || suffix <= 0) return null;
      return (max(0, total - suffix), total - 1);
    }
    final start = int.tryParse(parts[0]);
    final requestedEnd = parts[1].isEmpty ? total - 1 : int.tryParse(parts[1]);
    if (start == null ||
        requestedEnd == null ||
        start >= total ||
        requestedEnd < start) {
      return null;
    }
    return (start, min(requestedEnd, total - 1));
  }

  Future<HttpClientResponse> _open(
    _Transfer transfer,
    _Media media,
    String method,
    String? range, {
    Uri? origin,
    bool mainland = false,
  }) async {
    var uri = origin ?? media.uri;
    for (var redirects = 0; redirects <= 3; redirects++) {
      transfer.check();
      _upstreamRequests++;
      final request = await transfer.client
          .openUrl(method, uri)
          .timeout(timeout);
      request.followRedirects = false;
      media.headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      final response = await request.close().timeout(
        timeout,
        onTimeout: () {
          request.abort();
          throw TimeoutException('CDN response timed out');
        },
      );
      if (!const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        return response;
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.listen((_) {}).cancel();
      if (location == null || redirects == 3) {
        throw const HttpException('Invalid CDN redirect');
      }
      uri = uri.resolve(location);
      if (!_allowOrigin(uri) ||
          (mainland &&
              !media.origins.any(
                (candidate) =>
                    candidate.mainland &&
                    candidate.uri.host == uri.host &&
                    candidate.uri.port == uri.port,
              ))) {
        throw const HttpException('Unsupported CDN redirect');
      }
    }
    throw const HttpException('Too many CDN redirects');
  }

  Future<_Chunk> _readChunk(
    _Transfer transfer,
    _Media media,
    CdnOrigin origin,
    int start,
    int end, [
    _Chunk? expected,
    bool urgent = false,
  ]) => _slot(transfer, () async {
    final response = await _open(
      transfer,
      media,
      'GET',
      'bytes=$start-$end',
      origin: origin.uri,
      mainland: origin.mainland,
    );
    if (!transfer.reportedHeaders) {
      transfer.reportedHeaders = true;
      _trace?.mark(
        CdnStartupStage.originHeaders,
        track: media.track,
        requestId: transfer.requestId,
      );
    }
    final contentRange =
        response.headers.value(HttpHeaders.contentRangeHeader) ?? '';
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(contentRange);
    final actualStart = match == null ? null : int.tryParse(match[1]!);
    final actualEnd = match == null ? null : int.tryParse(match[2]!);
    final total = match == null ? null : int.tryParse(match[3]!);
    final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
    final etag = response.headers.value(HttpHeaders.etagHeader);
    final modified = response.headers.value(HttpHeaders.lastModifiedHeader);
    if (response.statusCode != HttpStatus.partialContent ||
        actualStart != start ||
        (actualEnd != end &&
            !(expected == null &&
                actualEnd == (total ?? 0) - 1 &&
                actualEnd! < end)) ||
        total == null ||
        total <= (actualEnd ?? end) ||
        (encoding != null && encoding != 'identity') ||
        (expected != null &&
            (total != expected.total ||
                etag != expected.etag ||
                modified != expected.modified))) {
      if (_rangeFailures.length < 12) {
        _rangeFailures.add({
          'host': origin.uri.host,
          'http': response.statusCode,
          'start': start,
          'end': end,
          'actual_start': actualStart,
          'actual_end': actualEnd,
          'total': total,
          'expected_total': expected?.total,
          'etag_equal': expected == null || etag == expected.etag,
          'modified_equal': expected == null || modified == expected.modified,
          'encoding_identity': encoding == null || encoding == 'identity',
        });
      }
      await response.listen((_) {}).cancel();
      throw const HttpException('CDN range metadata mismatch');
    }
    final bytes = BytesBuilder(copy: false);
    final length = actualEnd! - start + 1;
    if (response.contentLength != -1 && response.contentLength != length) {
      await response.listen((_) {}).cancel();
      throw const HttpException('CDN range length mismatch');
    }
    final deadline = DateTime.now().add(timeout);
    await for (final data in response.timeout(timeout)) {
      _observedUpstreamBytes += data.length;
      transfer.onProgress?.call();
      transfer.check();
      if (data.isNotEmpty && !transfer.reportedFirstByte) {
        transfer.reportedFirstByte = true;
        _trace?.mark(
          CdnStartupStage.originFirstByte,
          track: media.track,
          requestId: transfer.requestId,
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('CDN chunk timed out');
      }
      if (bytes.length + data.length > length) {
        throw const HttpException('CDN range too long');
      }
      bytes.add(data);
    }
    if (bytes.length != length) {
      throw const HttpException('CDN range truncated');
    }
    return _Chunk(
      bytes.takeBytes(),
      actualEnd,
      total,
      response.headers.value(HttpHeaders.contentTypeHeader),
      etag,
      modified,
    );
  }, urgent: urgent);

  Future<void> _serveMeasuredStream(
    _Transfer parent,
    _Media media,
    String? rawRange,
    _MediaResponse output,
  ) async {
    final origins = [
      if (media.preferred != null) media.preferred!,
      ...media.origins.where((o) => o.uri != media.preferred?.uri),
    ].take(6).toList();
    final winner = Completer<_StreamingOrigin>();
    final jobs = <_Transfer>[];
    var finished = 0;
    for (var i = 0; i < origins.length; i++) {
      final index = i;
      unawaited(() async {
        if (index > 0) {
          await Future<void>.delayed(Duration(milliseconds: 250 * index));
        }
        if (winner.isCompleted || parent.cancelled) return;
        final job = _Transfer(timeout, _wakeWaiters, media, parent.requestId);
        jobs.add(job);
        parent.children.add(job);
        final timer = Timer(const Duration(seconds: 3), job.cancel);
        StreamIterator<List<int>>? body;
        try {
          await _slot(job, () async {
            final response = await _open(
              job,
              media,
              'GET',
              rawRange ?? 'bytes=0-',
              origin: origins[index].uri,
            );
            if (!parent.reportedHeaders) {
              parent.reportedHeaders = true;
              _trace?.mark(
                CdnStartupStage.originHeaders,
                track: media.track,
                requestId: parent.requestId,
              );
            }
            final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
                .firstMatch(response.headers.value('content-range') ?? '');
            final total = match == null ? 0 : int.parse(match[3]!);
            final wanted = _range(rawRange, total);
            if (response.statusCode != 206 ||
                match == null ||
                wanted == null ||
                wanted.$1 != int.parse(match[1]!) ||
                wanted.$2 != int.parse(match[2]!) ||
                (response.headers.value('content-encoding') ?? 'identity') !=
                    'identity' ||
                (response.contentLength != -1 &&
                    response.contentLength != wanted.$2 - wanted.$1 + 1)) {
              await response.listen((_) {}).cancel();
              throw const HttpException('CDN range metadata mismatch');
            }
            body = StreamIterator(response);
            while (await body!.moveNext()) {
              job.check();
              if (body!.current.isEmpty) continue;
              if (!parent.reportedFirstByte) {
                parent.reportedFirstByte = true;
                _trace?.mark(
                  CdnStartupStage.originFirstByte,
                  track: media.track,
                  requestId: parent.requestId,
                );
              }
              final first = Uint8List.fromList(body!.current);
              _observedUpstreamBytes += first.length;
              if (first.length > wanted.$2 - wanted.$1 + 1) {
                throw const HttpException('CDN range too long');
              }
              final stream = _StreamingOrigin(
                job,
                origins[index],
                body!,
                first,
                wanted.$1,
                wanted.$2,
                _Chunk(
                  first,
                  wanted.$1 + first.length - 1,
                  total,
                  response.headers.value('content-type'),
                  response.headers.value('etag'),
                  response.headers.value('last-modified'),
                ),
              );
              timer.cancel();
              if (!winner.isCompleted) {
                winner.complete(stream);
                await stream.release.future;
              }
              return;
            }
            throw const HttpException('CDN range truncated');
          }, urgent: true);
        } catch (error) {
          if (!winner.isCompleted) {
            _failure(origins[index].uri, 'stream_probe', error);
          }
        } finally {
          timer.cancel();
          await body?.cancel();
          job.finish();
          parent.children.remove(job);
          finished++;
          if (finished == origins.length && !winner.isCompleted) {
            winner.completeError(
              const HttpException('No usable CDN range origin'),
            );
          }
        }
      }());
    }
    _StreamingOrigin? selected;
    try {
      selected = await winner.future.timeout(const Duration(seconds: 6));
      parent.check();
      for (final job in jobs) {
        if (!identical(job, selected.job)) job.cancel();
      }
      final previous = media.observed;
      if (previous != null &&
          (previous.anchor.uri != selected.origin.uri ||
              !_sameObservedVersion(previous.reference, selected.reference))) {
        media.identityEpoch++;
        media.identity = null;
      }
      media
        ..preferred = selected.origin
        ..observed = _ObservedVersion(selected.origin, selected.reference);
      final plan = _Plan(
        media,
        selected.origin,
        selected.reference,
        {},
        null,
        media.identityEpoch,
      );
      _trace?.mark(
        CdnStartupStage.candidateReady,
        track: media.track,
        requestId: parent.requestId,
      );
      _trace?.mark(
        CdnStartupStage.firstRangeValidated,
        track: media.track,
        requestId: parent.requestId,
      );
      output
        ..statusCode = rawRange == null ? 200 : 206
        ..contentLength = selected.end - selected.start + 1;
      output.headers.set('accept-ranges', 'bytes');
      output.headers.set('cache-control', 'no-store');
      output.headers.set(
        'content-type',
        selected.reference.contentType ?? 'application/octet-stream',
      );
      if (rawRange != null) {
        output.headers.set(
          'content-range',
          'bytes ${selected.start}-${selected.end}/${selected.reference.total}',
        );
      }
      var next = selected.start;
      final watch = Stopwatch()..start();
      var supplied = 0;
      var data = selected.first;
      var fallback = false;
      while (true) {
        _ensureCurrent(parent, plan);
        if (next + data.length > selected.end + 1) {
          throw const HttpException('CDN range too long');
        }
        output.add(data);
        await output.flush();
        if (supplied == 0) {
          _trace?.mark(
            CdnStartupStage.proxyFirstFlush,
            track: media.track,
            requestId: parent.requestId,
          );
        }
        next += data.length;
        supplied += data.length;
        if (next > selected.end) break;
        final target = durationSeconds == null
            ? 4 * 1024 * 1024
            : max(128 * 1024, selected.reference.total / durationSeconds! * 3);
        if (parallel &&
            adaptive &&
            watch.elapsedMilliseconds >= 2000 &&
            supplied / (watch.elapsedMicroseconds / 1e6) < target &&
            _hasValidator(selected.reference)) {
          fallback = true;
          break;
        }
        try {
          if (!await selected.body.moveNext().timeout(
            const Duration(seconds: 3),
          )) {
            fallback = true;
            break;
          }
          data = Uint8List.fromList(selected.body.current);
          _observedUpstreamBytes += data.length;
        } catch (error) {
          _failure(selected.origin.uri, 'stream_continuation', error);
          fallback = true;
          break;
        }
      }
      if (fallback) {
        selected.job.cancel();
        selected.release.complete();
        // Continue from the first byte not delivered. Cross-origin fallbacks
        // still pass the original two-sample identity checks.
        await _drainChunks(parent, plan, output, next, selected.end);
      }
    } finally {
      if (selected != null && !selected.release.isCompleted) {
        selected.release.complete();
      }
      if (!winner.isCompleted) {
        winner.completeError(const HttpException('CDN race cancelled'));
      }
      for (final job in jobs) {
        job.cancel();
      }
    }
  }

  Future<_Plan> _prepareMeasured(_Transfer parent, _Media media) async {
    final candidates = [
      if (media.preferred != null) media.preferred!,
      ...media.origins.where((o) => o.uri != media.preferred?.uri),
    ].take(6).toList();
    final done = Completer<(CdnOrigin, _Chunk)>();
    final jobs = <_Transfer>[];
    final failed = <Uri>{};
    var finished = 0;
    Future<void> probe(CdnOrigin origin, int index) async {
      // Fast healthy anchors need no competing request. Slow anchors get a
      // bounded hedge; there is no fixed-order wait for their timeout.
      if (index > 0) {
        await Future<void>.delayed(Duration(milliseconds: 250 * index));
      }
      if (done.isCompleted || parent.cancelled) return;
      final job = _Transfer(timeout, _wakeWaiters, media, parent.requestId);
      jobs.add(job);
      parent.children.add(job);
      final timer = Timer(const Duration(seconds: 3), job.cancel);
      try {
        final chunk = await _readChunk(
          job,
          media,
          origin,
          0,
          _startupChunkSize - 1,
          null,
          true,
        );
        parent.check();
        if (!done.isCompleted) done.complete((origin, chunk));
      } catch (_) {
        // Losing a startup race is cancellation, not an unavailable CDN.
        // Keep the runner-up available for later verified failover.
        if (!done.isCompleted && !parent.cancelled) failed.add(origin.uri);
      } finally {
        timer.cancel();
        job.finish();
        parent.children.remove(job);
        finished++;
        if (finished == candidates.length && !done.isCompleted) {
          done.completeError(const HttpException('No usable CDN range origin'));
        }
      }
    }

    for (var i = 0; i < candidates.length; i++) {
      unawaited(probe(candidates[i], i));
    }
    try {
      final (anchor, reference) = await done.future.timeout(
        const Duration(seconds: 6),
      );
      parent.check();
      final previous = media.observed;
      if (previous != null &&
          (previous.anchor.uri != anchor.uri ||
              !_sameObservedVersion(previous.reference, reference))) {
        media.identityEpoch++;
        media.identity = null;
      }
      media
        ..preferred = anchor
        ..observed = _ObservedVersion(anchor, reference);
      final cache = media.identity;
      final validCache =
          cache != null &&
              DateTime.now().isBefore(cache.expiresAt) &&
              cache.anchor.uri == anchor.uri &&
              _sameVersion(cache.reference, reference)
          ? cache
          : null;
      return _Plan(
        media,
        anchor,
        reference,
        failed,
        validCache,
        media.identityEpoch,
      );
    } finally {
      // Complete on cancel/timeout as well, so delayed hedges never outlive it.
      if (!done.isCompleted) {
        done.completeError(const HttpException('CDN race cancelled'));
      }
      for (final job in jobs) {
        job.cancel();
      }
    }
  }

  Future<_Plan> _prepare(_Transfer transfer, _Media media) async {
    if (autoSelect) return _prepareMeasured(transfer, media);
    final failed = <Uri>{};
    for (final mainland in [true, false]) {
      final tier = media.origins
          .where((origin) => origin.mainland == mainland)
          .toList();
      // Keep only one window of metadata checks ahead. Queuing the whole pool
      // can starve a healthy anchor's samples behind unused failing mirrors.
      // Consume in configured order; response time never determines priority.
      final probes = Queue<Future<_Chunk?>>();
      var nextProbe = 0;
      Future<_Chunk?> probe(CdnOrigin origin, {required bool urgent}) async {
        try {
          return await _readChunk(transfer, media, origin, 0, 0, null, urgent);
        } catch (_) {
          failed.add(origin.uri);
          return null;
        }
      }

      void enqueue() {
        if (nextProbe < tier.length) {
          final index = nextProbe++;
          probes.add(probe(tier[index], urgent: index == 0));
        }
      }

      // A second probe overlaps a failed anchor, without filling every slot
      // before the anchor can send its first media bytes.
      for (
        var index = 0;
        index < min(concurrency >= 3 ? 2 : 1, tier.length);
        index++
      ) {
        enqueue();
      }
      for (var index = 0; index < tier.length; index++) {
        transfer.check();
        final reference = await probes.removeFirst();
        transfer.check();
        if (reference == null) {
          enqueue();
          continue;
        }
        final observed = media.observed;
        if (observed != null &&
            (observed.anchor.uri != tier[index].uri ||
                !_sameObservedVersion(observed.reference, reference))) {
          media.identityEpoch++;
          media.identity = null;
          for (final job in _backgroundTransfers.toList()) {
            if (identical(job.media, media)) job.cancel();
          }
        }
        media.observed = _ObservedVersion(tier[index], reference);
        final previous = media.identity;
        final cached =
            previous != null &&
                DateTime.now().isBefore(previous.expiresAt) &&
                previous.anchor.uri == tier[index].uri &&
                _sameVersion(previous.reference, reference)
            ? previous
            : null;
        if (cached == null) media.identity = null;
        // The anchor may serve immediately. Other origins still need both
        // samples before they are allowed to contribute media bytes.
        return _Plan(
          media,
          tier[index],
          reference,
          failed,
          cached,
          media.identityEpoch,
        );
      }
    }
    throw const HttpException('No usable CDN range origin');
  }

  Future<List<_Chunk>> _samples(
    _Transfer transfer,
    _Plan plan, [
    bool urgent = false,
  ]) {
    final existing = plan.samples;
    if (existing != null) return existing;
    final future = _loadSamples(transfer, plan, urgent);
    if (transfer.background) {
      return future.then((samples) {
        if (!transfer.cancelled &&
            plan.media.identityEpoch == plan.identityEpoch) {
          plan.samples ??= Future.value(samples);
        }
        return samples;
      });
    }
    plan.samples = future;
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(plan.samples, future)) plan.samples = null;
        },
      ),
    );
    return future;
  }

  Future<List<_Chunk>> _loadSamples(
    _Transfer transfer,
    _Plan plan,
    bool urgent,
  ) async {
    _ensureCurrent(transfer, plan);
    if (plan.cached case final cached?) return cached.samples;
    final total = plan.reference.total;
    final prefix = await _readChunk(
      transfer,
      plan.media,
      plan.anchor,
      0,
      min(4095, total - 1),
      plan.reference,
      urgent,
    );
    final middleStart = total ~/ 2;
    final middle = await _readChunk(
      transfer,
      plan.media,
      plan.anchor,
      middleStart,
      min(middleStart + 4095, total - 1),
      plan.reference,
      urgent,
    );
    final samples = [prefix, middle];
    _ensureCurrent(transfer, plan);
    if (_hasValidator(plan.reference)) {
      plan.media.identity = _IdentityCache(
        plan.anchor,
        plan.reference,
        samples,
      );
    }
    return samples;
  }

  Future<_Chunk> _admit(
    _Transfer transfer,
    _Plan plan,
    CdnOrigin origin, [
    bool urgent = false,
  ]) => plan.admitted.putIfAbsent(
    origin.uri,
    () => _verifyPeer(transfer, plan, origin, urgent),
  );

  Future<_Chunk> _verifyPeer(
    _Transfer transfer,
    _Plan plan,
    CdnOrigin origin,
    bool urgent,
  ) async {
    _ensureCurrent(transfer, plan);
    final cached = plan.cached?.admitted[origin.uri];
    if (cached != null && _hasValidator(cached)) {
      try {
        final current = await _readChunk(
          transfer,
          plan.media,
          origin,
          0,
          0,
          null,
          urgent,
        );
        _ensureCurrent(transfer, plan);
        if (_sameVersion(cached, current)) {
          plan.ready[origin.uri] = cached;
          return cached;
        }
      } catch (_) {
        _ensureCurrent(transfer, plan);
      }
    }
    final samples = await _samples(transfer, plan, urgent);
    _ensureCurrent(transfer, plan);
    final prefix = await _readChunk(
      transfer,
      plan.media,
      origin,
      0,
      samples[0].end,
      null,
      urgent,
    );
    if (prefix.total != plan.reference.total ||
        !_sameBytes(prefix.bytes, samples[0].bytes)) {
      throw const HttpException('CDN resource identity mismatch');
    }
    final middle = await _readChunk(
      transfer,
      plan.media,
      origin,
      plan.reference.total ~/ 2,
      samples[1].end,
      prefix,
      urgent,
    );
    if (!_sameBytes(middle.bytes, samples[1].bytes)) {
      throw const HttpException('CDN resource identity mismatch');
    }
    _ensureCurrent(transfer, plan);
    final activeCache = plan.media.identity;
    if (activeCache != null &&
        activeCache.anchor.uri == plan.anchor.uri &&
        _sameVersion(activeCache.reference, plan.reference) &&
        _hasValidator(prefix)) {
      activeCache.admitted[origin.uri] = prefix;
    }
    plan.ready[origin.uri] = prefix;
    if (!transfer.reportedIdentity) {
      transfer.reportedIdentity = true;
      _trace?.mark(
        CdnStartupStage.identityValidated,
        track: plan.media.track,
        requestId: transfer.requestId,
      );
    }
    return prefix;
  }

  void _warmPeers(_Transfer transfer, _Plan plan) {
    if (concurrency == 2) {
      _warmPeersAtTwo(transfer, plan);
      return;
    }
    // Preserve one foreground and one urgent connection while candidates are
    // checked. A slow peer must never become the ordered response's next byte.
    // With four or more connections, an unused speculative metadata request
    // may still occupy one normal slot. Keep another for ordered data.
    final workers = min(
      2,
      max(0, concurrency >= 4 ? concurrency - 3 : concurrency - 2),
    );
    if (workers == 0) return;
    final peers = Queue<CdnOrigin>.from(
      plan.media.origins.where(
        (origin) =>
            origin.mainland == plan.anchor.mainland &&
            origin.uri != plan.anchor.uri &&
            !plan.failed.contains(origin.uri),
      ),
    );
    for (var index = 0; index < min(workers, peers.length); index++) {
      unawaited(() async {
        while (peers.isNotEmpty &&
            !transfer.cancelled &&
            plan.media.identityEpoch == plan.identityEpoch) {
          final origin = peers.removeFirst();
          try {
            await _admit(transfer, plan, origin);
          } catch (_) {
            if (!transfer.cancelled &&
                plan.media.identityEpoch == plan.identityEpoch) {
              plan.failed.add(origin.uri);
            }
          }
        }
      }());
    }
  }

  void _warmPeersAtTwo(_Transfer parent, _Plan plan) {
    final peers = plan.media.origins
        .take(autoSelect ? 4 : 40)
        .where(
          (origin) =>
              origin.mainland == plan.anchor.mainland &&
              origin.uri != plan.anchor.uri &&
              !plan.failed.contains(origin.uri),
        );
    if (peers.isEmpty) return;
    unawaited(() async {
      for (final origin in peers) {
        // Preemption is not an origin failure. Retry with a fresh client once
        // the urgent audio or foreground operation has used the slot.
        while (!parent.cancelled &&
            plan.media.identityEpoch == plan.identityEpoch &&
            !plan.ready.containsKey(origin.uri)) {
          final job = _Transfer(
            timeout,
            _wakeWaiters,
            plan.media,
            parent.requestId,
            background: true,
          );
          parent.children.add(job);
          _backgroundTransfers.add(job);
          var retry = false;
          try {
            await _verifyPeer(job, plan, origin, false);
          } catch (_) {
            retry = job.preempted && !parent.cancelled;
            if (!retry &&
                !parent.cancelled &&
                plan.media.identityEpoch == plan.identityEpoch) {
              plan.failed.add(origin.uri);
            }
          } finally {
            job.cancel();
            parent.children.remove(job);
            _backgroundTransfers.remove(job);
          }
          if (!retry) break;
        }
      }
    }());
  }

  static bool _hasValidator(_Chunk value) =>
      value.etag != null && !value.etag!.startsWith('W/');

  static bool _sameVersion(_Chunk before, _Chunk after) =>
      before.total == after.total &&
      before.etag == after.etag &&
      before.modified == after.modified &&
      _hasValidator(before);

  static bool _sameObservedVersion(_Chunk before, _Chunk after) =>
      before.total == after.total &&
      before.etag == after.etag &&
      before.modified == after.modified;

  static void _ensureCurrent(_Transfer transfer, _Plan plan) {
    transfer.check();
    if (plan.media.identityEpoch != plan.identityEpoch) {
      throw const HttpException('CDN resource version changed');
    }
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<_Chunk> _chunk(
    _Transfer transfer,
    _Plan plan,
    int start,
    int end, [
    bool urgent = false,
  ]) async {
    _ensureCurrent(transfer, plan);
    if (autoSelect) return _measuredChunk(transfer, plan, start, end, urgent);
    final offset = plan.cursor++;
    // Geography is a strict tier, not a speed score. Only availability and
    // content validation can remove an origin from the current request.
    for (final mainland in [true, false]) {
      final tier = plan.media.origins
          .where((o) => o.mainland == mainland)
          .toList();
      for (var index = 0; index < tier.length; index++) {
        final origin = tier[(offset + index) % tier.length];
        if (plan.failed.contains(origin.uri)) continue;
        final ownValidator = plan.ready[origin.uri];
        if (ownValidator == null) continue;
        _ensureCurrent(transfer, plan);
        try {
          final chunk = await _readChunk(
            transfer,
            plan.media,
            origin,
            start,
            end,
            ownValidator,
            urgent,
          );
          _ensureCurrent(transfer, plan);
          return chunk;
        } catch (_) {
          _ensureCurrent(transfer, plan);
          plan.failed.add(origin.uri);
        }
      }
    }
    // Every previously admitted source failed. Only now may the foreground
    // wait for another origin to pass cross-source identity checks.
    for (final mainland in [true, false]) {
      for (final origin in plan.media.origins.where(
        (candidate) => candidate.mainland == mainland,
      )) {
        if (plan.failed.contains(origin.uri)) continue;
        _ensureCurrent(transfer, plan);
        try {
          final ownValidator = await _admit(transfer, plan, origin, urgent);
          _ensureCurrent(transfer, plan);
          final chunk = await _readChunk(
            transfer,
            plan.media,
            origin,
            start,
            end,
            ownValidator,
            urgent,
          );
          _ensureCurrent(transfer, plan);
          return chunk;
        } catch (_) {
          _ensureCurrent(transfer, plan);
          plan.failed.add(origin.uri);
        }
      }
    }
    throw const HttpException('All CDN origins failed for this range');
  }

  Future<_Chunk> _measuredChunk(
    _Transfer transfer,
    _Plan plan,
    int start,
    int end,
    bool urgent,
  ) async {
    final available =
        plan.media.origins
            .where(
              (o) =>
                  plan.ready.containsKey(o.uri) && !plan.failed.contains(o.uri),
            )
            .toList()
          ..sort((a, b) => plan.cost(a.uri).compareTo(plan.cost(b.uri)));
    for (final origin in available) {
      final watch = Stopwatch()..start();
      final job = _Transfer(
        timeout,
        _wakeWaiters,
        plan.media,
        transfer.requestId,
      );
      transfer.children.add(job);
      Timer? timer;
      void progress() {
        timer?.cancel();
        timer = Timer(const Duration(seconds: 3), job.cancel);
      }

      job.onProgress = progress;
      progress();
      plan.active[origin.uri] = (plan.active[origin.uri] ?? 0) + 1;
      try {
        final chunk = await _readChunk(
          job,
          plan.media,
          origin,
          start,
          end,
          plan.ready[origin.uri],
          urgent,
        );
        _ensureCurrent(transfer, plan);
        final seconds = max(.001, watch.elapsedMicroseconds / 1e6);
        final cost = seconds / chunk.bytes.length;
        plan.costs[origin.uri] =
            (plan.costs[origin.uri] ?? cost) * .5 + cost * .5;
        if (seconds > .7 && !plan.warmed) {
          plan.warmed = true;
          _warmPeersAtTwo(transfer, plan);
        }
        return chunk;
      } catch (error) {
        _failure(origin.uri, 'chunk_or_admission', error);
        _ensureCurrent(transfer, plan);
        plan.failed.add(origin.uri);
      } finally {
        timer?.cancel();
        job.finish();
        transfer.children.remove(job);
        plan.active[origin.uri] = (plan.active[origin.uri] ?? 1) - 1;
      }
    }
    for (final origin in plan.media.origins.take(6)) {
      if (plan.failed.contains(origin.uri)) continue;
      final job = _Transfer(
        timeout,
        _wakeWaiters,
        plan.media,
        transfer.requestId,
      );
      transfer.children.add(job);
      final timer = Timer(const Duration(seconds: 3), job.cancel);
      try {
        await _admit(job, plan, origin, true);
        return await _measuredChunk(transfer, plan, start, end, urgent);
      } catch (error) {
        _failure(origin.uri, 'chunk_or_admission', error);
        _ensureCurrent(transfer, plan);
        plan.failed.add(origin.uri);
      } finally {
        timer.cancel();
        job.finish();
        transfer.children.remove(job);
      }
    }
    throw const HttpException('All CDN origins failed for this range');
  }

  Future<_BufferedChunk> _buffered(
    _Transfer transfer,
    _Plan plan,
    int start,
    int end, {
    bool urgent = false,
  }) async {
    final size = end - start + 1;
    void Function()? release;
    try {
      while (_bufferedBytes + size > _maxBufferedBytes) {
        transfer.check();
        final waiter = Completer<void>();
        _waiters.add(waiter);
        await waiter.future;
      }
      transfer.check();
      _bufferedBytes += size;
      var released = false;
      void free() {
        if (released) return;
        released = true;
        _bufferedBytes -= size;
        transfer.buffers.remove(free);
        _wakeWaiters();
      }

      release = free;
      transfer.buffers.add(free);
      return _BufferedChunk(
        await _chunk(transfer, plan, start, end, urgent),
        free,
      );
    } catch (error, stack) {
      release?.call();
      return _BufferedChunk.error(error, stack);
    }
  }

  Future<void> _passthrough(
    _Transfer transfer,
    _Media media,
    HttpRequest request,
    _MediaResponse output,
  ) => _slot(transfer, () async {
    _trace?.mark(
      CdnStartupStage.fallback,
      track: media.track,
      requestId: transfer.requestId,
    );
    final upstream = await _open(
      transfer,
      media,
      request.method,
      request.headers.value(HttpHeaders.rangeHeader),
    );
    output.statusCode = upstream.statusCode;
    for (final name in const [
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.contentEncodingHeader,
      HttpHeaders.etagHeader,
      HttpHeaders.lastModifiedHeader,
    ]) {
      final value = upstream.headers.value(name);
      if (value != null) output.headers.set(name, value);
    }
    output.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    output.contentLength = upstream.contentLength;
    if (request.method == 'HEAD') {
      await upstream.listen((_) {}).cancel();
    } else {
      await for (final data in upstream.timeout(timeout)) {
        transfer.check();
        output.add(data);
        await output.flush().timeout(timeout);
      }
    }
    await output.close();
  }, urgent: true);
}

final class _Media {
  _Media(this.uri, this.headers, this.origins, this.track);
  final Uri uri;
  final Map<String, String> headers;
  final List<CdnOrigin> origins;
  final CdnStartupTrack track;
  final Queue<HttpClient> _idleClients = Queue();
  CdnOrigin? preferred;
  _IdentityCache? identity;
  _ObservedVersion? observed;
  int identityEpoch = 0;
  bool _closed = false;

  HttpClient acquire(Duration timeout) {
    if (_idleClients.isNotEmpty) return _idleClients.removeFirst();
    return HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = timeout
      ..idleTimeout = const Duration(seconds: 5)
      ..findProxy = ((_) => 'DIRECT');
  }

  void release(HttpClient client) {
    if (_closed || _idleClients.length >= 2) {
      client.close(force: true);
    } else {
      _idleClients.add(client);
    }
  }

  void close() {
    _closed = true;
    identityEpoch++;
    identity = null;
    observed = null;
    for (final client in _idleClients) {
      client.close(force: true);
    }
    _idleClients.clear();
  }
}

final class _ObservedVersion {
  const _ObservedVersion(this.anchor, this.reference);
  final CdnOrigin anchor;
  final _Chunk reference;
}

final class _IdentityCache {
  _IdentityCache(this.anchor, this.reference, this.samples);
  final CdnOrigin anchor;
  final _Chunk reference;
  final List<_Chunk> samples;
  final Map<Uri, _Chunk> admitted = {};
  final DateTime expiresAt = DateTime.now().add(const Duration(seconds: 30));
}

final class _Plan {
  _Plan(
    this.media,
    this.anchor,
    this.reference,
    this.failed,
    this.cached,
    this.identityEpoch,
  ) {
    admitted[anchor.uri] = Future.value(reference);
    ready[anchor.uri] = reference;
  }
  final _Media media;
  final CdnOrigin anchor;
  final _Chunk reference;
  final Set<Uri> failed;
  final _IdentityCache? cached;
  final int identityEpoch;
  final Map<Uri, Future<_Chunk>> admitted = {};
  final Map<Uri, _Chunk> ready = {};
  Future<List<_Chunk>>? samples;
  int cursor = 0;
  bool warmed = false;
  bool rampFinished = false;
  final Map<Uri, double> costs = {};
  final Map<Uri, int> active = {};
  double cost(Uri uri) => (costs[uri] ?? 0) * (1 + (active[uri] ?? 0));
}

final class _BufferedChunk {
  _BufferedChunk(this.chunk, this.release) : error = null, stack = null;
  _BufferedChunk.error(this.error, this.stack) : chunk = null, release = _noop;
  final _Chunk? chunk;
  final Object? error;
  final StackTrace? stack;
  final void Function() release;
  static void _noop() {}
  void check() {
    if (error != null) Error.throwWithStackTrace(error!, stack!);
  }
}

final class _Chunk {
  const _Chunk(
    this.bytes,
    this.end,
    this.total,
    this.contentType,
    this.etag,
    this.modified,
  );
  final Uint8List bytes;
  final int end;
  final int total;
  final String? contentType;
  final String? etag;
  final String? modified;
}

final class _Transfer {
  _Transfer(
    Duration timeout,
    this._onCancel,
    this._media,
    this.requestId, {
    this.background = false,
  }) : client = _media.acquire(timeout),
       track = _media.track;
  final _Media _media;
  _Media get media => _media;
  final HttpClient client;
  final CdnStartupTrack track;
  final int requestId;
  final bool background;
  final void Function() _onCancel;
  bool _cancelled = false;
  bool _outputComplete = false;
  bool preempted = false;
  int activeSlots = 0;
  bool get cancelled => _cancelled;
  int pendingWork = 0;
  void Function()? onProgress;
  bool reportedHeaders = false;
  bool reportedFirstByte = false;
  bool reportedIdentity = false;
  bool reportedQueue = false;
  bool reportedSlot = false;
  final Set<void Function()> buffers = {};
  final Set<_Transfer> children = {};
  Socket? _socket;
  StreamSubscription<Uint8List>? _subscription;
  void attach(Socket socket) {
    _socket = socket;
    if (_cancelled) {
      socket.destroy();
      return;
    }
    _subscription = socket.listen(
      (_) {},
      onDone: () {
        if (!_outputComplete) cancel();
      },
      onError: (Object _) => cancel(),
    );
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) => cancel()));
  }

  void check() {
    if (_cancelled) throw const HttpException('CDN request cancelled');
  }

  void markOutputComplete() => _outputComplete = true;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final child in children.toList()) {
      child.cancel();
    }
    client.close(force: true);
    for (final release in buffers.toList()) {
      release();
    }
    _socket?.destroy();
    unawaited(_subscription?.cancel());
    _onCancel();
  }

  void finish() {
    if (_cancelled) return;
    if (pendingWork != 0) {
      cancel();
      return;
    }
    _cancelled = true;
    for (final child in children.toList()) {
      child.cancel();
    }
    for (final release in buffers.toList()) {
      release();
    }
    _media.release(client);
    unawaited(_subscription?.cancel());
    _onCancel();
  }
}

final class _SlotWaiter {
  _SlotWaiter(this.transfer, this.urgent);
  final _Transfer transfer;
  final bool urgent;
  final Completer<void> completer = Completer<void>();
  bool granted = false;
}

/// Minimal close-delimited HTTP/1.1 writer for the detached media connection.
/// Known lengths are advertised for seeking; unknown fallback bodies terminate
/// on close. HTTP parsing remains the responsibility of dart:io's HttpServer.
final class _MediaResponse {
  _MediaResponse(this._socket, this._timeout);
  _MediaResponse.pending(this._timeout) : _socket = null;
  final Socket? _socket;
  final Duration _timeout;
  final headers = _MediaHeaders();
  int statusCode = HttpStatus.ok;
  bool started = false;
  set contentLength(int value) {
    if (value >= 0) {
      headers.set(HttpHeaders.contentLengthHeader, value.toString());
    } else {
      headers.values.remove(HttpHeaders.contentLengthHeader);
    }
  }

  void _commit() {
    if (started) return;
    final socket = _socket;
    if (socket == null) throw const HttpException('Missing media connection');
    final text = StringBuffer('HTTP/1.1 $statusCode Media response\r\n');
    headers.values.forEach((name, value) {
      if (name.contains(RegExp(r'[\r\n]')) ||
          value.contains(RegExp(r'[\r\n]'))) {
        throw const HttpException('Invalid media header');
      }
      text.write('$name: $value\r\n');
    });
    text.write('connection: close\r\n\r\n');
    socket.add(latin1.encode(text.toString()));
    started = true;
  }

  void add(List<int> bytes) {
    _commit();
    _socket!.add(bytes);
  }

  Future<void> flush() async {
    _commit();
    await _socket!.flush().timeout(_timeout);
  }

  Future<void> close() async {
    await flush();
    await _socket!.close().timeout(_timeout);
  }
}

final class _MediaHeaders {
  final Map<String, String> values = {};
  void set(String name, Object value) => values[name] = value.toString();
}

final class _StreamingOrigin {
  _StreamingOrigin(
    this.job,
    this.origin,
    this.body,
    this.first,
    this.start,
    this.end,
    this.reference,
  );
  final _Transfer job;
  final CdnOrigin origin;
  final StreamIterator<List<int>> body;
  final Uint8List first;
  final int start;
  final int end;
  final _Chunk reference;
  final release = Completer<void>();
}

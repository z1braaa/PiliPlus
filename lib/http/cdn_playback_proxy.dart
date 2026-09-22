import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

// This transport is also exercised without Flutter package resolution.
// ignore: always_use_package_imports
import 'cdn_origin_policy.dart';

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
  );

  static Future<CdnPlaybackProxy> start({
    int concurrency = 8,
    int chunkSize = 1024 * 1024,
    Duration timeout = const Duration(seconds: 10),
    bool Function(Uri)? allowOrigin,
    CdnOriginResolver? originResolver,
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
      originResolver ?? CdnOriginPolicy.resolve,
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
  final int chunkSize;
  final Duration timeout;
  final bool Function(Uri) _allowOrigin;
  final CdnOriginResolver _originResolver;
  static const _maxBufferedBytes = 64 * 1024 * 1024;
  int _bufferedBytes = 0;
  final Map<String, _Media> _media = {};
  final Set<_Transfer> _transfers = {};
  final List<Completer<void>> _waiters = [];
  int _inFlight = 0;
  bool _closed = false;

  /// Retains the exact signed origin URL in memory; it is never exposed through
  /// the loopback URL. Unrecognized media stays on the existing native path.
  String register(
    String url, {
    Iterable<String> alternatives = const [],
    Map<String, String> headers = const {},
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
    _media['/$token'] = _Media(originals.first, safeHeaders, orderedOrigins);
    return 'http://127.0.0.1:${_server.port}/$token';
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final transfer in _transfers.toList()) {
      transfer.cancel();
    }
    _media.clear();
    _wakeWaiters();
    await _server.close(force: true);
  }

  void _wakeWaiters() {
    for (final waiter in _waiters.toList()) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiters.clear();
  }

  Future<T> _slot<T>(_Transfer transfer, Future<T> Function() action) async {
    while (_inFlight >= concurrency) {
      transfer.check();
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    transfer.check();
    _inFlight++;
    try {
      return await action();
    } finally {
      _inFlight--;
      _wakeWaiters();
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
    final transfer = _Transfer(timeout, _wakeWaiters);
    _transfers.add(transfer);
    var reply = _MediaResponse.pending(timeout);
    try {
      final socket = await output.detachSocket(writeHeaders: false);
      transfer.attach(socket);
      reply = _MediaResponse(socket, timeout);
      transfer.check();
      final media = _media[request.uri.path]!;
      _Plan plan;
      try {
        plan = await _prepare(transfer, media);
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
        await reply.close();
        return;
      }
      final (start, end) = range;
      _BufferedChunk? first;
      if (request.method == 'GET') {
        try {
          // Startup bytes cannot wait behind speculative data from another
          // track: mpv may need both initial headers before draining either.
          first = _BufferedChunk(
            await _chunk(
              transfer,
              plan,
              start,
              min(end, start + chunkSize - 1),
            ),
            _BufferedChunk._noop,
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
          reply.add(first.chunk!.bytes);
          await reply.flush();
        } finally {
          first.release();
        }
        var next = first.chunk!.end + 1;
        final pending = Queue<Future<_BufferedChunk>>();
        void enqueue() {
          if (next > end) return;
          final chunkEnd = min(end, next + chunkSize - 1);
          pending.add(_buffered(transfer, plan, next, chunkEnd));
          next = chunkEnd + 1;
        }

        // Leave room for the other DASH track even at the largest settings.
        final window = min(
          concurrency,
          max(1, _maxBufferedBytes ~/ 2 ~/ chunkSize),
        );
        for (var i = 0; i < window; i++) {
          enqueue();
        }
        try {
          while (pending.isNotEmpty) {
            transfer.check();
            final item = await pending.removeFirst();
            try {
              item.check();
              transfer.check();
              reply.add(item.chunk!.bytes);
              await reply.flush();
            } finally {
              item.release();
            }
            // A sliding window keeps other connections busy as soon as the
            // next ordered piece is consumed; no whole-batch barrier.
            enqueue();
          }
        } finally {
          for (final future in pending) {
            unawaited(future.then((item) => item.release()));
          }
        }
      }
      await reply.close();
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
  ]) => _slot(transfer, () async {
    final response = await _open(
      transfer,
      media,
      'GET',
      'bytes=$start-$end',
      origin: origin.uri,
      mainland: origin.mainland,
    );
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
        actualEnd != end ||
        total == null ||
        total <= end ||
        (encoding != null && encoding != 'identity') ||
        (expected != null &&
            (total != expected.total ||
                etag != expected.etag ||
                modified != expected.modified))) {
      await response.listen((_) {}).cancel();
      throw const HttpException('CDN range metadata mismatch');
    }
    final bytes = BytesBuilder(copy: false);
    final length = end - start + 1;
    if (response.contentLength != -1 && response.contentLength != length) {
      await response.listen((_) {}).cancel();
      throw const HttpException('CDN range length mismatch');
    }
    final deadline = DateTime.now().add(timeout);
    await for (final data in response.timeout(timeout)) {
      transfer.check();
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
      end,
      total,
      response.headers.value(HttpHeaders.contentTypeHeader),
      etag,
      modified,
    );
  });

  Future<_Plan> _prepare(_Transfer transfer, _Media media) async {
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
      Future<_Chunk?> probe(CdnOrigin origin) async {
        try {
          return await _readChunk(transfer, media, origin, 0, 0);
        } catch (_) {
          failed.add(origin.uri);
          return null;
        }
      }

      void enqueue() {
        if (nextProbe < tier.length) {
          probes.add(probe(tier[nextProbe++]));
        }
      }

      for (var index = 0; index < min(concurrency, tier.length); index++) {
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
        final plan = _Plan(media, tier[index], reference, failed);
        try {
          // Capture identity while the anchor is known-good, before emitting
          // bytes. If this anchor fails, try another; do not poison every peer.
          if (media.origins.length > 1) await _samples(transfer, plan);
          return plan;
        } catch (_) {
          transfer.check();
          failed.add(tier[index].uri);
          enqueue();
        }
      }
    }
    throw const HttpException('No usable CDN range origin');
  }

  Future<List<_Chunk>> _samples(_Transfer transfer, _Plan plan) =>
      plan.samples ??= (() async {
        final total = plan.reference.total;
        final prefix = await _readChunk(
          transfer,
          plan.media,
          plan.anchor,
          0,
          min(4095, total - 1),
          plan.reference,
        );
        final middleStart = total ~/ 2;
        final middle = await _readChunk(
          transfer,
          plan.media,
          plan.anchor,
          middleStart,
          min(middleStart + 4095, total - 1),
          plan.reference,
        );
        return [prefix, middle];
      })();

  Future<_Chunk> _admit(_Transfer transfer, _Plan plan, CdnOrigin origin) {
    return plan.admitted.putIfAbsent(origin.uri, () async {
      final samples = await _samples(transfer, plan);
      final prefix = await _readChunk(
        transfer,
        plan.media,
        origin,
        0,
        samples[0].end,
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
      );
      if (!_sameBytes(middle.bytes, samples[1].bytes)) {
        throw const HttpException('CDN resource identity mismatch');
      }
      return prefix;
    });
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
    int end,
  ) async {
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
        transfer.check();
        try {
          final ownValidator = await _admit(transfer, plan, origin);
          transfer.check();
          return await _readChunk(
            transfer,
            plan.media,
            origin,
            start,
            end,
            ownValidator,
          );
        } catch (_) {
          transfer.check();
          plan.failed.add(origin.uri);
        }
      }
    }
    throw const HttpException('All CDN origins failed for this range');
  }

  Future<_BufferedChunk> _buffered(
    _Transfer transfer,
    _Plan plan,
    int start,
    int end,
  ) async {
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
      return _BufferedChunk(await _chunk(transfer, plan, start, end), free);
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
  });
}

final class _Media {
  const _Media(this.uri, this.headers, this.origins);
  final Uri uri;
  final Map<String, String> headers;
  final List<CdnOrigin> origins;
}

final class _Plan {
  _Plan(this.media, this.anchor, this.reference, this.failed) {
    admitted[anchor.uri] = Future.value(reference);
  }
  final _Media media;
  final CdnOrigin anchor;
  final _Chunk reference;
  final Set<Uri> failed;
  final Map<Uri, Future<_Chunk>> admitted = {};
  Future<List<_Chunk>>? samples;
  int cursor = 0;
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
  _Transfer(Duration timeout, this._onCancel)
    : client = HttpClient()
        ..autoUncompress = false
        ..connectionTimeout = timeout
        ..idleTimeout = const Duration(seconds: 5)
        ..findProxy = ((_) => 'DIRECT');
  final HttpClient client;
  final void Function() _onCancel;
  bool _cancelled = false;
  final Set<void Function()> buffers = {};
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
      onDone: cancel,
      onError: (Object _) => cancel(),
    );
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) => cancel()));
  }

  void check() {
    if (_cancelled) throw const HttpException('CDN request cancelled');
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    client.close(force: true);
    for (final release in buffers.toList()) {
      release();
    }
    _socket?.destroy();
    unawaited(_subscription?.cancel());
    _onCancel();
  }
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

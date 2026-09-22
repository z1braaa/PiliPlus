import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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
  );

  static Future<CdnPlaybackProxy> start({
    int concurrency = 4,
    int chunkSize = 256 * 1024,
    Duration timeout = const Duration(seconds: 10),
    bool Function(Uri)? allowOrigin,
  }) async {
    if (concurrency < 1 ||
        concurrency > 8 ||
        chunkSize < 1024 ||
        chunkSize > 1024 * 1024 ||
        timeout <= Duration.zero) {
      throw ArgumentError('Invalid CDN transport limits');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = CdnPlaybackProxy._(
      server,
      concurrency,
      chunkSize,
      timeout,
      allowOrigin ?? _isMedia,
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
  final Map<String, _Media> _media = {};
  final Set<_Transfer> _transfers = {};
  final List<Completer<void>> _waiters = [];
  int _inFlight = 0;
  bool _closed = false;

  static bool _isMedia(Uri uri) {
    final host = uri.host.toLowerCase();
    return (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.userInfo.isEmpty &&
        (!uri.hasPort || uri.port == 80 || uri.port == 443) &&
        const [
          'bilivideo.com',
          'bilivideo.cn',
          'bilivideo.net',
          'akamaized.net',
        ].any((domain) => host == domain || host.endsWith('.$domain')) &&
        uri.path.startsWith('/upgcxcode/') &&
        (uri.path.endsWith('.m4s') || uri.path.endsWith('.mp4'));
  }

  /// Retains the exact signed origin URL in memory; it is never exposed through
  /// the loopback URL. Unrecognized media stays on the existing native path.
  String register(String url, {Map<String, String> headers = const {}}) {
    if (_closed) return url;
    final uri = Uri.tryParse(url);
    if (uri == null || !_allowOrigin(uri) || _media.length >= 8) return url;
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
    _media['/$token'] = _Media(uri, safeHeaders);
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
      _Chunk probe;
      try {
        probe = await _chunk(transfer, media, 0, 0);
      } catch (_) {
        transfer.check();
        // No response body has been sent: reissue the player's original request
        // as one stream. Never append a full response to partially emitted data.
        await _passthrough(transfer, media, request, reply);
        return;
      }
      final total = probe.total;
      final range = _range(rawRange, total);
      if (range == null) {
        reply.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        reply.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await reply.close();
        return;
      }
      final (start, end) = range;
      _Chunk? first;
      if (request.method == 'GET') {
        try {
          first = await _chunk(
            transfer,
            media,
            start,
            min(end, start + chunkSize - 1),
            probe,
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
      if (probe.etag != null) {
        reply.headers.set(HttpHeaders.etagHeader, probe.etag!);
      }
      if (rawRange != null) {
        reply.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$total',
        );
      }
      if (first != null) {
        reply.add(first.bytes);
        await reply.flush().timeout(timeout);
        var next = first.end + 1;
        while (next <= end) {
          transfer.check();
          final jobs = <Future<_Chunk>>[];
          for (var i = 0; i < concurrency && next <= end; i++) {
            final chunkEnd = min(end, next + chunkSize - 1);
            jobs.add(_chunk(transfer, media, next, chunkEnd, probe));
            next = chunkEnd + 1;
          }
          // At most concurrency chunks per response are retained. A failed
          // batch is discarded, preserving an exact prefix on the wire.
          final chunks = await Future.wait(jobs, eagerError: true);
          for (final chunk in chunks) {
            transfer.check();
            reply.add(chunk.bytes);
            await reply.flush().timeout(timeout);
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
    String? range,
  ) async {
    var uri = media.uri;
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
      if (!_allowOrigin(uri)) {
        throw const HttpException('Unsupported CDN redirect');
      }
    }
    throw const HttpException('Too many CDN redirects');
  }

  Future<_Chunk> _chunk(
    _Transfer transfer,
    _Media media,
    int start,
    int end, [
    _Chunk? expected,
  ]) => _slot(transfer, () async {
    final response = await _open(transfer, media, 'GET', 'bytes=$start-$end');
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
  const _Media(this.uri, this.headers);
  final Uri uri;
  final Map<String, String> headers;
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

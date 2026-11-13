import "dart:async";
import "dart:io";

/// Numeric, per-generation observations; no listening URLs or request paths.
class LocalProxySnapshot {
  const LocalProxySnapshot({
    required this.generation,
    required this.listening,
    required this.requestCount,
  });

  final int generation;
  final bool listening;
  final int requestCount;
}

/// Owns one loopback listener. Starts and stops are shared, including bind time.
/// Kept separate from audio routing so bind failures and shutdown can be tested.
class LocalProxyServer {
  LocalProxyServer({Future<HttpServer> Function()? bind})
      : _bind = bind ?? _bindLoopback;

  final Future<HttpServer> Function() _bind;
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  Future<void>? _starting;
  Future<void>? _stopping;
  int _generation = 0;
  int _requestCount = 0;

  static Future<HttpServer> _bindLoopback() =>
      // Port zero asks the OS for an available, process-local listening port.
      HttpServer.bind(InternetAddress.loopbackIPv4, 0);

  int get port => _server!.port;

  LocalProxySnapshot get snapshot => LocalProxySnapshot(
        generation: _generation,
        listening: _server != null,
        requestCount: _requestCount,
      );

  Future<void> ensureRunning(Future<void> Function(HttpRequest) handler) {
    final stopping = _stopping;
    if (stopping != null) {
      return stopping.then((ignoredValue) => ensureRunning(handler));
    }
    final starting = _starting;
    if (starting != null) return starting;
    if (_server != null) return Future.value();
    return _starting = _start(handler);
  }

  Future<void> _start(Future<void> Function(HttpRequest) handler) async {
    try {
      // Future.sync also makes a synchronous bind failure release _starting.
      final server = await Future<HttpServer>.sync(_bind);
      _server = server;
      _generation++;
      _requestCount = 0;
      try {
        _subscription = server.listen(
          (request) {
            if (identical(_server, server)) _requestCount++;
            unawaited(_dispatch(handler, request));
          },
          onDone: () => _ended(server),
          onError: (Object failure, StackTrace trace) => _ended(server),
        );
      } catch (failure) {
        _server = null;
        await server.close(force: true);
        rethrow;
      }
    } finally {
      _starting = null;
    }
  }

  Future<void> _dispatch(
    Future<void> Function(HttpRequest) handler,
    HttpRequest request,
  ) async {
    try {
      await handler(request);
    } catch (failure) {
      // A disconnected native reader must not produce an unhandled exception.
      try {
        request.response.statusCode = HttpStatus.internalServerError;
      } catch (headerFailure) {
        // Headers may already have been sent; still close the response below.
      }
      try {
        await request.response.close();
      } catch (closeFailure) {
        // The response may already have been closed by a seek/reset.
      }
    }
  }

  void _ended(HttpServer server) {
    // Late events from an older listener cannot invalidate its replacement.
    if (!identical(_server, server)) return;
    _server = null;
    _subscription = null;
    unawaited(server.close(force: true).then<void>(
          (ignoredValue) {},
          onError: (Object failure, StackTrace trace) {},
        ));
  }

  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    try {
      try {
        await (_starting ?? Future<void>.value());
      } catch (failure) {
        // A failed start has no listener, but still needs to finish resetting.
      }
      final server = _server;
      final subscription = _subscription;
      _server = null;
      _subscription = null;
      try {
        if (server != null) await server.close(force: true);
      } finally {
        await subscription?.cancel();
      }
    } finally {
      _stopping = null;
    }
  }
}

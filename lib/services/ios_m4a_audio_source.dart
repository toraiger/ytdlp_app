import "dart:async";
import "dart:math" as math;
import "dart:typed_data";

import "package:http/http.dart" as http;
import "package:just_audio/just_audio.dart";

import "api_http_client.dart";
import "../models/audio_transport_diagnostics.dart";
import "../models/m4a_header_diagnostics.dart";
import "m4a_fragment_header.dart";

/// Serves the original byte ranges with only empty DASH header durations reset.
/// A bounded prefix is retained, so playback and seeking do not wait for a full
/// download. URLs and upstream errors never appear in player diagnostics.
class IosM4aAudioSource extends StreamAudioSource {
  IosM4aAudioSource(
    this.uri, {
    required Map<String, String> headers,
    super.tag,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _headers = {
         for (final entry in headers.entries)
           if (!{
             "x-api-key",
             "range",
             "host",
             "content-length",
             "accept-encoding",
           }.contains(entry.key.toLowerCase()))
             entry.key: entry.value,
         "Accept-Encoding": "identity",
       },
       _client = client ?? createApiHttpClient(),
       super(
         options: const ProgressiveAudioSourceOptions(
           darwinAssetOptions: DarwinAssetOptions(
             preferPreciseDurationAndTiming: true,
           ),
         ),
       );

  final Uri uri;
  final Map<String, String> _headers;
  final http.Client _client;
  final Duration timeout;
  final _requests = <Completer<void>>{};
  Future<void>? _prepared;
  Uint8List _prefix = Uint8List(0);
  M4aFragmentHeader _header = const M4aFragmentHeader([]);
  int? _length;
  String? _validator;
  String? _validatorHeader;
  bool _closed = false;
  bool _headerReady = false;
  int _attempts = 0;
  int _localRequestCount = 0;
  MediaTransferStage _stage = MediaTransferStage.notStarted;
  MediaTransferFailure _failureKind = MediaTransferFailure.none;
  int? _httpStatus;
  int? _nativeCode;

  int get localRequestCount => _localRequestCount;

  MediaTransferDiagnostics get transferDiagnostics => MediaTransferDiagnostics(
    attempts: _attempts,
    stage: _stage,
    failure: _failureKind,
    httpStatus: _httpStatus,
    nativeCode: _nativeCode,
  );

  void _recordFailure(
    Object failure,
    MediaTransferStage stage, {
    MediaTransferFailure? kind,
  }) {
    // Cancellation during cleanup must not replace the failure that caused it.
    if (_failureKind != MediaTransferFailure.none) return;
    _stage = stage;
    _nativeCode = nativeHttpErrorCode(failure);
    _failureKind = kind ?? _classifyFailure(failure);
  }

  MediaTransferFailure _classifyFailure(Object failure) {
    if (failure is TimeoutException) return MediaTransferFailure.timeout;
    if (failure is http.RequestAbortedException) {
      return MediaTransferFailure.cancelled;
    }
    if (_closed) return MediaTransferFailure.closed;
    if (failure is http.ClientException) return MediaTransferFailure.connection;
    return MediaTransferFailure.invalidResponse;
  }

  int? get normalizedDurationFields =>
      _headerReady ? _header.durationFields.length : null;

  M4aHeaderDiagnostics get headerDiagnostics =>
      _headerReady
          ? _header.diagnostics
          : const M4aHeaderDiagnostics(outcome: M4aHeaderOutcome.pending);

  static StateError _failure() => StateError("Audio data unavailable");

  Future<void> _prepare() async {
    var wanted = 64 * 1024;
    while (true) {
      final response = await _open(0, wanted, stage: MediaTransferStage.prefix);
      final bytes = BytesBuilder(copy: false);
      try {
        await for (final chunk in _slice(
          response,
          0,
          math.min(wanted, _length!),
        )) {
          bytes.add(chunk);
        }
      } finally {
        response.close();
      }
      _prefix = bytes.takeBytes();
      _header = M4aFragmentHeader.inspect(_prefix);
      final required = _header.requiredLength;
      if (required == null) {
        _headerReady = true;
        return;
      }
      if (required <= wanted || required > _length!) throw _failure();
      wanted = required;
    }
  }

  Future<_MediaResponse> _open(
    int start,
    int end, {
    required MediaTransferStage stage,
    Completer<void>? cancellation,
  }) async {
    if (_closed) throw _failure();
    final abort = cancellation ?? Completer<void>();
    _requests.add(abort);
    void close() {
      if (!abort.isCompleted) abort.complete();
      _requests.remove(abort);
    }

    try {
      _attempts++;
      if (_failureKind == MediaTransferFailure.none) _stage = stage;
      final request =
          http.AbortableRequest("GET", uri, abortTrigger: abort.future)
            ..headers.addAll(_headers)
            ..headers["Range"] = "bytes=$start-${end - 1}";
      if (_validator != null) request.headers["If-Range"] = _validator!;
      final response = await _client.send(request).timeout(timeout);
      if (_failureKind == MediaTransferFailure.none) {
        _httpStatus = response.statusCode;
      }
      if (_closed ||
          abort.isCompleted ||
          !{"", "identity"}.contains(
            (response.headers["content-encoding"] ?? "").toLowerCase(),
          )) {
        throw _failure();
      }
      int length;
      int offset;
      if (response.statusCode == 206) {
        final match = RegExp(
          r"^bytes (\d+)-(\d+)/(\d+)$",
        ).firstMatch(response.headers["content-range"] ?? "");
        if (match == null) throw _failure();
        offset = int.parse(match[1]!);
        final last = int.parse(match[2]!);
        length = int.parse(match[3]!);
        if (offset != start ||
            last < offset ||
            last >= length ||
            last >= end ||
            (response.contentLength != null &&
                response.contentLength != last - offset + 1)) {
          throw _failure();
        }
      } else if (response.statusCode == 200 && response.contentLength != null) {
        length = response.contentLength!;
        offset = 0;
      } else {
        final failure = _failure();
        _recordFailure(
          failure,
          stage,
          kind:
              response.statusCode == 200
                  ? MediaTransferFailure.invalidResponse
                  : MediaTransferFailure.httpStatus,
        );
        throw _failure();
      }
      if (length <= 0) {
        throw _failure();
      }
      if (_length != null &&
          (length != _length ||
              (_validator != null &&
                  response.headers[_validatorHeader] != _validator &&
                  (response.statusCode != 206 ||
                      response.headers.containsKey(_validatorHeader))))) {
        // A response from another representation must not reuse cached bytes.
        _recordFailure(
          _failure(),
          stage,
          kind: MediaTransferFailure.invalidResponse,
        );
        this.close();
        throw _failure();
      }
      // A 206 already confirms If-Range; representation headers can be omitted.
      // A 200 needs an explicit matching validator before cached bytes are used.
      if (_length == null) {
        final etag = response.headers["etag"];
        if (etag != null && !etag.startsWith("W/")) {
          _validatorHeader = "etag";
          _validator = etag;
        } else if (response.headers["last-modified"] != null) {
          _validatorHeader = "last-modified";
          _validator = response.headers["last-modified"];
        }
      }
      _length = length;
      return _MediaResponse(
        response.stream,
        offset,
        close,
        stage,
        () => abort.isCompleted,
      );
    } catch (failure) {
      if (!abort.isCompleted) _recordFailure(failure, stage);
      close();
      // http exceptions can contain signed URLs. Expose a fixed message only.
      throw _failure();
    }
  }

  Stream<List<int>> _slice(_MediaResponse response, int start, int end) async* {
    var at = response.offset;
    var emitted = 0;
    try {
      await for (final chunk in response.stream.timeout(timeout)) {
        if (_closed) throw _failure();
        final from = (start - at).clamp(0, chunk.length);
        final to = (end - at).clamp(0, chunk.length);
        if (to > from) {
          emitted += to - from;
          yield chunk.sublist(from, to);
        }
        at += chunk.length;
        if (at >= end) break;
      }
      if (emitted != end - start) throw _failure();
    } catch (failure) {
      // Seeks normally cancel an old range. That is not an upstream failure.
      if (!response.isCancelled()) _recordFailure(failure, response.stage);
      throw _failure();
    } finally {
      response.close();
    }
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    _localRequestCount++;
    if (_closed) throw _failure();
    try {
      await (_prepared ??= _prepare());
    } catch (failure) {
      _recordFailure(failure, MediaTransferStage.prefix);
      rethrow;
    }
    final from = start ?? 0;
    final to = math.min(end ?? _length!, _length!);
    if (from < 0 || from >= to) throw _failure();
    return StreamAudioResponse(
      sourceLength: _length,
      contentLength: to - from,
      offset: start != null || end != null ? from : null,
      contentType: "audio/mp4",
      stream: _serve(from, to),
    );
  }

  Stream<List<int>> _serve(int start, int end) {
    late StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;
    Completer<void>? cancellation;
    var finished = false;

    void stop() {
      final abort = cancellation;
      if (abort != null && !abort.isCompleted) abort.complete();
      final pending = subscription?.cancel();
      if (pending != null) {
        // async* cancellation can wait for an idle upstream and then fail.
        // Abort it directly above and consume cleanup errors independently.
        unawaited(
          pending.then<void>(
            (_) {},
            onError: (Object ignoredError, StackTrace ignoredStack) {},
          ),
        );
      }
    }

    void finish({bool failed = false}) {
      if (finished) return;
      finished = true;
      stop();
      if (failed) controller.addError(_failure());
      unawaited(controller.close());
    }

    Future<void> serve() async {
      try {
        if (_closed) throw _failure();
        var at = start;
        if (at < _prefix.length) {
          final to = math.min(end, _prefix.length);
          controller.add(_header.apply(_prefix.sublist(at, to), at));
          at = to;
        }
        if (at >= end) {
          finish();
          return;
        }
        final abort = cancellation = Completer<void>();
        final response = await _open(
          at,
          end,
          stage: MediaTransferStage.range,
          cancellation: abort,
        );
        if (finished) {
          response.close();
          return;
        }
        subscription = _slice(response, at, end).listen(
          (chunk) {
            if (finished) return;
            controller.add(_header.apply(chunk, at));
            at += chunk.length;
          },
          onError:
              (Object ignoredError, StackTrace ignoredStack) =>
                  finish(failed: true),
          onDone: finish,
        );
        if (controller.isPaused) subscription!.pause();
      } on Object {
        finish(failed: true);
      }
    }

    controller = StreamController<List<int>>(
      onListen: () => unawaited(serve()),
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        finished = true;
        stop();
      },
    );
    return controller.stream;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final abort in _requests.toList()) {
      if (!abort.isCompleted) abort.complete();
    }
    _requests.clear();
    _client.close();
    _prefix = Uint8List(0);
    _headerReady = false;
  }
}

class _MediaResponse {
  const _MediaResponse(
    this.stream,
    this.offset,
    this.close,
    this.stage,
    this.isCancelled,
  );
  final Stream<List<int>> stream;
  final int offset;
  final void Function() close;
  final MediaTransferStage stage;
  final bool Function() isCancelled;
}

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

import 'api_http_client.dart';
import 'm4a_fragment_header.dart';

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
             'x-api-key',
             'range',
             'host',
             'content-length',
             'accept-encoding',
           }.contains(entry.key.toLowerCase()))
             entry.key: entry.value,
         'Accept-Encoding': 'identity',
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
  bool _closed = false;

  int? get normalizedDurationFields =>
      _prepared != null && _length != null
          ? _header.durationFields.length
          : null;

  static StateError _failure() => StateError('Audio data unavailable');

  Future<void> _prepare() async {
    var wanted = 64 * 1024;
    while (true) {
      final response = await _open(0, wanted);
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
      if (required == null) return;
      if (required <= wanted || required > _length!) throw _failure();
      wanted = required;
    }
  }

  Future<_MediaResponse> _open(int start, int end) async {
    if (_closed) throw _failure();
    final abort = Completer<void>();
    _requests.add(abort);
    void close() {
      if (!abort.isCompleted) abort.complete();
      _requests.remove(abort);
    }

    try {
      final request =
          http.AbortableRequest('GET', uri, abortTrigger: abort.future)
            ..headers.addAll(_headers)
            ..headers['Range'] = 'bytes=$start-${end - 1}';
      if (_validator != null) request.headers['If-Range'] = _validator!;
      final response = await _client.send(request).timeout(timeout);
      if (_closed ||
          !{'', 'identity'}.contains(
            (response.headers['content-encoding'] ?? '').toLowerCase(),
          )) {
        throw _failure();
      }
      int length;
      int offset;
      if (response.statusCode == 206) {
        final match = RegExp(
          r'^bytes (\d+)-(\d+)/(\d+)$',
        ).firstMatch(response.headers['content-range'] ?? '');
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
        throw _failure();
      }
      if (length <= 0 || (_length != null && length != _length)) {
        throw _failure();
      }
      _length = length;
      final etag = response.headers['etag'];
      _validator ??=
          etag != null && !etag.startsWith('W/')
              ? etag
              : response.headers['last-modified'];
      return _MediaResponse(response.stream, offset, close);
    } on Object {
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
    } on Object {
      throw _failure();
    } finally {
      response.close();
    }
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    if (_closed) throw _failure();
    await (_prepared ??= _prepare());
    final from = start ?? 0;
    final to = math.min(end ?? _length!, _length!);
    if (from < 0 || from >= to) throw _failure();
    return StreamAudioResponse(
      sourceLength: _length,
      contentLength: to - from,
      offset: start != null || end != null ? from : null,
      contentType: 'audio/mp4',
      stream: _serve(from, to),
    );
  }

  Stream<List<int>> _serve(int start, int end) async* {
    if (_closed) throw _failure();
    var at = start;
    if (at < _prefix.length) {
      final to = math.min(end, _prefix.length);
      yield _header.apply(_prefix.sublist(at, to), at);
      at = to;
    }
    if (at < end) {
      final response = await _open(at, end);
      await for (final chunk in _slice(response, at, end)) {
        yield _header.apply(chunk, at);
        at += chunk.length;
      }
    }
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
  }
}

class _MediaResponse {
  const _MediaResponse(this.stream, this.offset, this.close);
  final Stream<List<int>> stream;
  final int offset;
  final void Function() close;
}

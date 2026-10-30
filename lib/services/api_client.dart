import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/api_models.dart';
import '../models/api_timing.dart';
import 'api_http_client.dart';
import 'startup_timing.dart';

class ApiFailure implements Exception {
  const ApiFailure(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({
    required String serverUrl,
    required String apiKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 90),
    DateTime Function()? now,
  }) : baseUri = validateServerUrl(serverUrl),
       _apiKey = apiKey.trim(),
       _client = client ?? createApiHttpClient(),
       _now = now ?? DateTime.now;

  static Uri validateServerUrl(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const ApiFailure(
        'API URL は HTTPS で指定してください。認証情報・クエリ・フラグメントは使用できません。',
      );
    }
    return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
  }

  final Uri baseUri;
  final String _apiKey;
  final http.Client _client;
  final Duration timeout;
  final lastTiming = ValueNotifier<ApiTiming?>(null);
  final DateTime Function() _now;
  final _streams = <String, _CachedStream>{};
  final _resolving = <String, Future<StreamResponse>>{};
  bool _closed = false;

  StreamFormat? cachedMedia(String videoId, PlaybackMode mode) {
    final cached = _cachedStream(videoId, mode);
    return mode == PlaybackMode.audio
        ? cached?.response.audio
        : cached?.response.videoAudio;
  }

  _CachedStream? _cachedStream(String videoId, PlaybackMode mode) {
    final cached = _streams[videoId];
    if (cached == null) return null;
    final age = _now().difference(cached.resolvedAt);
    if (age.isNegative || age >= const Duration(minutes: 5)) {
      _streams.remove(videoId);
      return null;
    }
    final media =
        mode == PlaybackMode.audio
            ? cached.response.audio
            : cached.response.videoAudio;
    final uri = media?.url;
    if (uri == null) return null;
    // Keep the existing query and HLS path expiry checks for the selected format.
    final expiries = [
      ...?uri.queryParametersAll['expire'],
      ...?uri.queryParametersAll['expires'],
    ];
    final segments = uri.pathSegments;
    for (var i = 0; i + 1 < segments.length; i++) {
      if (segments[i] == 'expire') expiries.add(segments[i + 1]);
    }
    final safeUntil =
        _now().add(const Duration(seconds: 30)).millisecondsSinceEpoch;
    for (final value in expiries) {
      final expiry = int.tryParse(value);
      if (expiry != null && expiry * 1000 <= safeUntil) return null;
    }
    _streams.remove(videoId);
    _streams[videoId] = cached;
    return cached;
  }

  void invalidateStream(String videoId) => _streams.remove(videoId);

  // Mixの応答時間をURL取得・プレーヤー読み込みの時間と分けて計測する。
  Future<MixResponse> fetchMix(String url, {int count = 20}) => measureStartup(
    'mix_response',
    () async => _decodeMix(await _post(['mix'], {'url': url, 'count': count})),
  );

  Future<MixResponse> extendMix(String sessionId, {int count = 20}) async =>
      _decodeMix(await _post(['mix', sessionId, 'extend'], {'count': count}));

  Future<StreamResponse> resolveStream(
    String videoId, {
    PlaybackMode mode = PlaybackMode.audio,
    bool refresh = false,
  }) {
    if (refresh) {
      invalidateStream(videoId);
    } else {
      final cached = _cachedStream(videoId, mode);
      if (cached != null) return Future.value(cached.response);
    }
    return _resolving[videoId] ??= _resolveStream(videoId);
  }

  Future<StreamResponse> _resolveStream(String videoId) async {
    try {
      final response = await _fetchStream(videoId);
      if (!_closed) {
        _streams.remove(videoId);
        _streams[videoId] = _CachedStream(response, _now());
        while (_streams.length > 16) {
          _streams.remove(_streams.keys.first);
        }
      }
      return response;
    } finally {
      unawaited(_resolving.remove(videoId));
    }
  }

  Future<StreamResponse> _fetchStream(String videoId) =>
      measureStartup('stream_response', () async {
        final json = await _post(
          ['stream'],
          {'video_id': videoId, 'include_formats': false},
        );
        try {
          return StreamResponse.fromJson(json);
        } on FormatException {
          throw const ApiFailure('再生 URL の応答形式が正しくありません。');
        } on TypeError {
          throw const ApiFailure('再生 URL の応答形式が正しくありません。');
        }
      });

  MixResponse _decodeMix(Map<String, dynamic> json) {
    try {
      return MixResponse.fromJson(json);
    } on FormatException {
      throw const ApiFailure('Mix の応答形式が正しくありません。');
    } on TypeError {
      throw const ApiFailure('Mix の応答形式が正しくありません。');
    }
  }

  Future<Map<String, dynamic>> _post(
    List<String> path,
    Map<String, dynamic> body,
  ) async {
    final watch = Stopwatch()..start();
    Duration? toHeaders;
    int? statusCode;
    var succeeded = false;
    final uri = baseUri.replace(
      pathSegments: [
        ...baseUri.pathSegments.where((segment) => segment.isNotEmpty),
        ...path,
      ],
    );
    final request =
        http.Request('POST', uri)
          ..followRedirects = false
          ..headers.addAll({
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'X-API-Key': _apiKey,
          })
          ..body = jsonEncode(body);
    try {
      final response = await (() async {
        final streamed = await _client.send(request);
        toHeaders = watch.elapsed;
        statusCode = streamed.statusCode;
        return http.Response.fromStream(streamed);
      })().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final status = response.statusCode;
        throw ApiFailure(
          'API エラー（HTTP $status）。サーバー設定と接続状態を確認してください。',
          statusCode: status,
        );
      }
      final data = jsonObject(jsonDecode(utf8.decode(response.bodyBytes)));
      succeeded = true;
      return data;
    } on TimeoutException {
      throw const ApiFailure('API の応答がタイムアウトしました。しばらくしてから再度お試しください。');
    } on http.ClientException {
      throw const ApiFailure('API サーバーに接続できません。URL とネットワークを確認してください。');
    } on FormatException {
      throw const ApiFailure('API から正しい JSON が返されませんでした。');
    } finally {
      watch.stop();
      if (!_closed) {
        lastTiming.value = ApiTiming(
          operation:
              path.last == 'extend'
                  ? ApiOperation.extend
                  : path.first == 'stream'
                  ? ApiOperation.stream
                  : ApiOperation.mix,
          total: watch.elapsed,
          succeeded: succeeded,
          toHeaders: toHeaders,
          statusCode: statusCode,
        );
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _streams.clear();
    _resolving.clear();
    _client.close();
    lastTiming.dispose();
  }
}

class _CachedStream {
  const _CachedStream(this.response, this.resolvedAt);
  final StreamResponse response;
  final DateTime resolvedAt;
}

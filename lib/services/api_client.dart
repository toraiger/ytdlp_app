import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/api_models.dart';
import '../models/api_timing.dart';
import '../models/youtube_cookies.dart';
import 'api_http_client.dart';
import 'startup_timing.dart';
import "request_scope.dart";

class ApiFailure implements Exception {
  const ApiFailure(this.message, {this.statusCode, this.retryable = false});

  final String message;
  final int? statusCode;
  final bool retryable;

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
  final _prefetching = <(RequestScope, String), Future<StreamResponse>>{};
  final _streamRevisions = <String, int>{};
  bool _closed = false;
  bool get hasApiKey => _apiKey.isNotEmpty;

  Future<YoutubeCookieStatus> youtubeCookieStatus() async =>
      _decodeCookieStatus(
        await _requestJson('GET', [
          'youtube',
          'cookies',
        ], operation: ApiOperation.youtubeCookieStatus),
      );

  Future<YoutubeCookieStatus> uploadYoutubeCookies(
    YoutubeCookies cookies,
  ) async {
    final result = _decodeCookieStatus(
      await _requestJson(
        'PUT',
        ['youtube', 'cookies'],
        rawBody: cookies.toNetscape(),
        contentType: 'text/plain',
        operation: ApiOperation.youtubeCookieUpload,
        requestTimeout: const Duration(seconds: 120),
      ),
    );
    if (!result.configured) {
      throw const ApiFailure('Cookieの登録が完了しませんでした。保存状態を確認してください。');
    }
    return result;
  }

  YoutubeCookieStatus _decodeCookieStatus(Map<String, dynamic> json) {
    try {
      return YoutubeCookieStatus.fromJson(json);
    } on FormatException {
      throw const ApiFailure('Cookie保存状態の応答形式が正しくありません。');
    }
  }

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
    RequestScope? scope,
  }) {
    scope?.check();
    if (refresh) {
      invalidateStream(videoId);
    } else {
      final cached = _cachedStream(videoId, mode);
      if (cached != null) return Future.value(cached.response);
    }
    if (scope != null) {
      final key = (scope, videoId);
      return _prefetching[key] ??= _resolveStream(videoId, scope: scope);
    }
    return _resolving[videoId] ??= _resolveStream(videoId);
  }

  Future<StreamResponse> _resolveStream(
    String videoId, {
    RequestScope? scope,
  }) async {
    final revision = (_streamRevisions[videoId] ?? 0) + 1;
    _streamRevisions[videoId] = revision;
    try {
      final response = await _fetchStream(videoId, scope: scope);
      scope?.check();
      if (!_closed && _streamRevisions[videoId] == revision) {
        _streams.remove(videoId);
        _streams[videoId] = _CachedStream(response, _now());
        while (_streams.length > 16) {
          _streams.remove(_streams.keys.first);
        }
      }
      return response;
    } finally {
      if (scope == null) {
        unawaited(_resolving.remove(videoId));
      } else {
        unawaited(_prefetching.remove((scope, videoId)));
      }
    }
  }

  Future<StreamResponse> _fetchStream(String videoId, {RequestScope? scope}) =>
      measureStartup('stream_response', () async {
        final json = await _requestJson(
          "POST",
          ['stream'],
          rawBody: jsonEncode({'video_id': videoId, 'include_formats': false}),
          scope: scope,
          requestTimeout: scope == null ? null : const Duration(seconds: 20),
        );
        try {
          final response = StreamResponse.fromJson(json);
          if (response.videoId != videoId) {
            throw const ApiFailure('再生 URL が要求した曲と一致しません。Mix を取得し直してください。');
          }
          return response;
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
  ) => _requestJson('POST', path, rawBody: jsonEncode(body));

  Future<Map<String, dynamic>> _requestJson(
    String method,
    List<String> path, {
    String? rawBody,
    String contentType = 'application/json',
    ApiOperation? operation,
    Duration? requestTimeout,
    RequestScope? scope,
  }) async {
    scope?.check();
    if (_closed) throw const ApiFailure('API接続が変更されました。画面を開き直してください。');
    if (operation != null && !hasApiKey) {
      throw const ApiFailure('Cookieを送信する前にAPIキーを設定してください。');
    }
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
    final abort = Completer<void>();
    void cancelRequest() {
      if (!abort.isCompleted) abort.complete();
    }

    final request =
        http.AbortableRequest(
            method,
            uri,
            abortTrigger:
                scope == null
                    ? abort.future
                    : Future.any([abort.future, scope.cancelled]),
          )
          ..followRedirects = false
          ..headers.addAll({
            'Content-Type': contentType,
            'Accept': 'application/json',
            'X-API-Key': _apiKey,
          });
    if (rawBody != null) request.bodyBytes = utf8.encode(rawBody);
    try {
      final transfer =
          (() async {
            final streamed = await _client.send(request);
            toHeaders = watch.elapsed;
            statusCode = streamed.statusCode;
            return http.Response.fromStream(streamed);
          })();
      final response = await (scope == null
              ? transfer
              : Future.any([
                transfer,
                scope.cancelled.then<http.Response>(
                  (_) => throw const RequestCancelled(),
                ),
              ]))
          .timeout(requestTimeout ?? timeout);
      scope?.check();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final status = response.statusCode;
        if (operation != null && (status == 404 || status == 501)) {
          throw ApiFailure('このサーバーはCookie登録APIに対応していません。', statusCode: status);
        }
        throw ApiFailure(
          'API エラー（HTTP $status）。サーバー設定と接続状態を確認してください。',
          statusCode: status,
          retryable:
              status == 408 || status == 425 || status == 429 || status >= 500,
        );
      }
      final data = jsonObject(jsonDecode(utf8.decode(response.bodyBytes)));
      succeeded = true;
      return data;
    } on TimeoutException {
      cancelRequest();
      throw const ApiFailure(
        'API の応答がタイムアウトしました。しばらくしてから再度お試しください。',
        retryable: true,
      );
    } on http.RequestAbortedException {
      scope?.check();
      throw const ApiFailure("API通信が中断されました。", retryable: true);
    } on http.ClientException {
      scope?.check();
      throw const ApiFailure(
        'API サーバーに接続できません。URL とネットワークを確認してください。',
        retryable: true,
      );
    } on FormatException {
      throw const ApiFailure('API から正しい JSON が返されませんでした。');
    } finally {
      watch.stop();
      if (!_closed && !(scope?.isCancelled ?? false)) {
        lastTiming.value = ApiTiming(
          operation:
              operation ??
              (path.last == 'extend'
                  ? ApiOperation.extend
                  : path.first == 'stream'
                  ? ApiOperation.stream
                  : ApiOperation.mix),
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
    for (final scope in _prefetching.keys.map((key) => key.$1).toSet()) {
      scope.cancel();
    }
    _prefetching.clear();
    _streamRevisions.clear();
    _client.close();
    lastTiming.dispose();
  }
}

class _CachedStream {
  const _CachedStream(this.response, this.resolvedAt);
  final StreamResponse response;
  final DateTime resolvedAt;
}

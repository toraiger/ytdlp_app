import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/api_models.dart';

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
  }) : baseUri = validateServerUrl(serverUrl),
       _apiKey = apiKey.trim(),
       _client = client ?? http.Client();

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

  Future<MixResponse> fetchMix(String url, {int count = 20}) async =>
      _decodeMix(await _post(['mix'], {'url': url, 'count': count}));

  Future<MixResponse> extendMix(String sessionId, {int count = 20}) async =>
      _decodeMix(await _post(['mix', sessionId, 'extend'], {'count': count}));

  Future<StreamResponse> resolveStream(String videoId) async {
    final json = await _post(['stream'], {'video_id': videoId});
    try {
      return StreamResponse.fromJson(json);
    } on FormatException {
      throw const ApiFailure('再生 URL の応答形式が正しくありません。');
    } on TypeError {
      throw const ApiFailure('再生 URL の応答形式が正しくありません。');
    }
  }

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
        return http.Response.fromStream(streamed);
      })().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final status = response.statusCode;
        throw ApiFailure(
          'API エラー（HTTP $status）。サーバー設定と接続状態を確認してください。',
          statusCode: status,
        );
      }
      return jsonObject(jsonDecode(utf8.decode(response.bodyBytes)));
    } on TimeoutException {
      throw const ApiFailure('API の応答がタイムアウトしました。しばらくしてから再度お試しください。');
    } on http.ClientException {
      throw const ApiFailure('API サーバーに接続できません。URL とネットワークを確認してください。');
    } on FormatException {
      throw const ApiFailure('API から正しい JSON が返されませんでした。');
    }
  }

  void close() => _client.close();
}

import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mix_player_app/services/api_client.dart';
import 'support/fakes.dart';

void main() {
  test('UT-04 Mix request uses POST, count=20 and X-API-Key', () async {
    final api = mockApi((request) {
      expect(request.method, 'POST');
      expect(request.url.path, '/mix');
      expect(request.headers['X-API-Key'], 'test-key');
      expect(request.headers['Accept'], 'application/json');
      expect(jsonDecode(request.body), {
        'url': 'https://youtube.com/?list=RD1',
        'count': 20,
      });
      expect(request.followRedirects, isFalse);
      return jsonResponse(mixJson(['a']));
    });
    addTearDown(api.close);
    expect(
      (await api.fetchMix('https://youtube.com/?list=RD1')).items,
      hasLength(1),
    );
  });
  test('UT-05 Base URLs reject HTTP, credentials, queries and fragments', () {
    for (final url in [
      'http://api.test',
      'https://user:password@api.test',
      'https://api.test?key=value',
      'https://api.test#fragment',
      'https:///missing',
    ]) {
      expect(
        () => ApiClient(serverUrl: url, apiKey: ''),
        throwsA(isA<ApiFailure>()),
      );
    }
  });
  test('Subpath base URL and session path segment are preserved', () async {
    final api = ApiClient(
      serverUrl: 'https://api.test/v1/',
      apiKey: 'test',
      client: MockClient((request) async {
        expect(request.url.pathSegments, [
          'v1',
          'mix',
          'session/unsafe',
          'extend',
        ]);
        expect(jsonDecode(request.body), {'count': 20});
        return jsonResponse(mixJson(['a']));
      }),
    );
    addTearDown(api.close);
    await api.extendMix('session/unsafe');
  });
  // 旧サーバー相当の全形式付き応答も、新サーバーの軽量応答も同じモデルで読む。
  test(
    'Stream request opts out of formats and accepts legacy response',
    () async {
      final api = mockApi((request) {
        expect(request.url.path, '/stream');
        expect(jsonDecode(request.body), {
          'video_id': 'a',
          'include_formats': false,
        });
        return jsonResponse({...streamJson('a'), 'formats': []});
      });
      addTearDown(api.close);
      expect((await api.resolveStream('a')).audio?.url, isNotNull);
    },
  );
  test('HTTP errors preserve status and never expose response body', () async {
    final api = mockApi((_) => http.Response('private-key signed-url', 403));
    addTearDown(api.close);
    try {
      await api.fetchMix('url');
      fail('Expected HTTP failure');
    } on ApiFailure catch (error) {
      expect(error.statusCode, 403);
      expect(error.message, contains('403'));
      expect(error.message, isNot(contains('private-key')));
      expect(error.message, isNot(contains('signed-url')));
    }
  });
  test('Malformed JSON and unexpected payloads yield ApiFailure', () async {
    for (final body in ['not JSON', '[]', '{"session_id":"s","items":[{}]}']) {
      final api = mockApi((_) => http.Response(body, 200));
      await expectLater(api.fetchMix('url'), throwsA(isA<ApiFailure>()));
      api.close();
    }
  });
  test('Timeout covers the complete HTTP operation', () async {
    final completer = Completer<http.Response>();
    final api = ApiClient(
      serverUrl: 'https://api.test',
      apiKey: '',
      client: MockClient((_) => completer.future),
      timeout: const Duration(milliseconds: 5),
    );
    addTearDown(api.close);
    await expectLater(api.fetchMix('url'), throwsA(isA<ApiFailure>()));
    completer.complete(jsonResponse(mixJson(['a'])));
  });
  test('Network exceptions do not leak request details', () async {
    final api = mockApi((_) => throw http.ClientException('secret detail'));
    addTearDown(api.close);
    await expectLater(
      api.fetchMix('url'),
      throwsA(
        isA<ApiFailure>().having(
          (e) => e.message,
          'message',
          isNot(contains('secret detail')),
        ),
      ),
    );
  });
}

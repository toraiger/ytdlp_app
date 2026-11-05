import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mix_player_app/models/api_timing.dart';
import 'package:mix_player_app/models/youtube_cookies.dart';
import 'package:mix_player_app/services/api_client.dart';

import 'support/fakes.dart';
import 'youtube_cookies_test.dart' show dummyCookieFile;

void main() {
  final cookies = YoutubeCookies.fromNetscape(dummyCookieFile);

  test(
    'PUT sends raw Netscape text with auth to saved HTTPS subpath',
    () async {
      final api = ApiClient(
        serverUrl: 'https://api.example.test/v1/',
        apiKey: 'dummy-key',
        client: MockClient((request) async {
          expect(request.method, 'PUT');
          expect(
            request.url.toString(),
            'https://api.example.test/v1/youtube/cookies',
          );
          expect(request.followRedirects, isFalse);
          expect(request.headers['Content-Type'], 'text/plain');
          expect(request.headers['Accept'], 'application/json');
          expect(request.headers['X-API-Key'], 'dummy-key');
          expect(utf8.decode(request.bodyBytes), dummyCookieFile);
          return jsonResponse({
            'configured': true,
            'updated_at': '2026-11-05T03:00:00Z',
          });
        }),
      );
      addTearDown(api.close);
      expect((await api.uploadYoutubeCookies(cookies)).configured, isTrue);
      expect(api.lastTiming.value?.operation, ApiOperation.youtubeCookieUpload);
    },
  );

  test(
    'GET reads storage state without sending Cookie values or a body',
    () async {
      final api = mockApi((request) {
        expect(request.method, 'GET');
        expect(request.url.path, '/youtube/cookies');
        expect(request.headers['X-API-Key'], 'test-key');
        expect(request.bodyBytes, isEmpty);
        expect(request.followRedirects, isFalse);
        return jsonResponse({'configured': false});
      });
      addTearDown(api.close);
      expect((await api.youtubeCookieStatus()).configured, isFalse);
      expect(api.lastTiming.value?.operation, ApiOperation.youtubeCookieStatus);
    },
  );

  test(
    'Cookie APIs reject missing keys before contacting the server',
    () async {
      var requests = 0;
      final api = ApiClient(
        serverUrl: 'https://api.test',
        apiKey: '',
        client: MockClient((_) async {
          requests++;
          return jsonResponse({'configured': true});
        }),
      );
      addTearDown(api.close);
      await expectLater(api.youtubeCookieStatus(), throwsA(isA<ApiFailure>()));
      await expectLater(
        api.uploadYoutubeCookies(cookies),
        throwsA(isA<ApiFailure>()),
      );
      expect(requests, 0);
    },
  );

  test(
    'Unsupported, redirect, auth and validation failures are redacted',
    () async {
      for (final status in [301, 401, 403, 404, 422, 500, 501]) {
        final api = mockApi(
          (_) => http.Response('dummy-private-cookie dummy-key', status),
        );
        await expectLater(
          api.uploadYoutubeCookies(cookies),
          throwsA(
            isA<ApiFailure>()
                .having((error) => error.statusCode, 'HTTP status', status)
                .having(
                  (error) => error.message,
                  'redacted',
                  isNot(contains('dummy-private')),
                )
                .having(
                  (error) => error.message,
                  'unsupported',
                  status == 404 || status == 501
                      ? contains('対応していません')
                      : isNot(contains('対応していません')),
                ),
          ),
        );
        api.close();
      }
    },
  );

  test(
    'Upload rejects configured:false and malformed success responses',
    () async {
      for (final body in [
        '{"configured":false}',
        '{"configured":"true"}',
        '{}',
        '[]',
        'not-json',
      ]) {
        final api = mockApi((_) => http.Response(body, 200));
        await expectLater(
          api.uploadYoutubeCookies(cookies),
          throwsA(isA<ApiFailure>()),
        );
        api.close();
      }
    },
  );

  testWidgets(
    'PUT allows 120 seconds, while normal requests keep their timeout',
    (tester) async {
      final response = Completer<http.Response>();
      final api = mockApi((_) => response.future);
      addTearDown(api.close);
      var finished = false;
      final result = api
          .uploadYoutubeCookies(cookies)
          .then((_) => finished = true);
      await tester.pump(const Duration(seconds: 91));
      expect(finished, isFalse);
      response.complete(jsonResponse({'configured': true}));
      await tester.pump();
      await result;
      expect(finished, isTrue);

      final delayed = Completer<http.Response>();
      final timeoutApi = mockApi((_) => delayed.future);
      addTearDown(timeoutApi.close);
      final timeout = expectLater(
        timeoutApi.uploadYoutubeCookies(cookies),
        throwsA(isA<ApiFailure>()),
      );
      await tester.pump(const Duration(seconds: 121));
      await timeout;
      delayed.complete(jsonResponse({'configured': true}));
      await tester.pump();
    },
  );

  test(
    'Cookie registration adds no credential ID or Cookie header to Mix',
    () async {
      final requests = <http.Request>[];
      final api = mockApi((request) {
        requests.add(request);
        return jsonResponse(
          request.method == 'PUT' ? {'configured': true} : mixJson(['a']),
        );
      });
      addTearDown(api.close);
      await api.uploadYoutubeCookies(cookies);
      await api.fetchMix('https://youtube.com/?list=RD1');
      final request = requests.last;
      expect(jsonDecode(request.body), {
        'url': 'https://youtube.com/?list=RD1',
        'count': 20,
      });
      expect(
        request.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('cookie')),
      );
      expect(
        request.headers.keys.any(
          (key) => key.toLowerCase().contains('credential'),
        ),
        isFalse,
      );
    },
  );
}

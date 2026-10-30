import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mix_player_app/models/api_models.dart';
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
  test('Resolved URLs and media headers are reused for both modes', () async {
    var requests = 0;
    final api = mockApi((_) {
      requests++;
      return jsonResponse(streamJson('a'));
    });
    addTearDown(api.close);
    await api.resolveStream('a');
    final audio = await api.resolveStream('a');
    final video = await api.resolveStream('a', mode: PlaybackMode.video);
    expect(requests, 1);
    expect(audio.audio?.httpHeaders['User-Agent'], 'audio-a');
    expect(video.videoAudio?.httpHeaders['User-Agent'], 'video-a');
  });
  test('Concurrent stream requests share one API operation', () async {
    final response = Completer<http.Response>();
    var requests = 0;
    final api = mockApi((_) {
      requests++;
      return response.future;
    });
    addTearDown(api.close);
    final first = api.resolveStream('a');
    final second = api.resolveStream('a', mode: PlaybackMode.video);
    await drain();
    expect(requests, 1);
    response.complete(jsonResponse(streamJson('a')));
    expect(await first, same(await second));
  });
  test('Cached URLs expire after five minutes', () async {
    var now = DateTime.utc(2026, 10, 29);
    var requests = 0;
    final api = mockApi((_) {
      requests++;
      return jsonResponse(streamJson('a'));
    }, now: () => now);
    addTearDown(api.close);
    await api.resolveStream('a');
    now = now.add(const Duration(minutes: 5));
    expect(api.cachedMedia('a', PlaybackMode.audio), isNull);
    await api.resolveStream('a');
    expect(requests, 2);
  });
  test('Signed URL expiry is checked separately for each mode', () async {
    var now = DateTime.utc(2026, 10, 29);
    final expiry =
        now.add(const Duration(minutes: 2)).millisecondsSinceEpoch ~/ 1000;
    var requests = 0;
    final api = mockApi((_) {
      requests++;
      final data = streamJson('a');
      (data['video_audio'] as Map<String, dynamic>)['url'] =
          'https://media.example.test/a.mp4?expire=$expiry';
      return jsonResponse(data);
    }, now: () => now);
    addTearDown(api.close);
    await api.resolveStream('a');
    now = now.add(const Duration(seconds: 90));
    expect(api.cachedMedia('a', PlaybackMode.audio), isNotNull);
    expect(api.cachedMedia('a', PlaybackMode.video), isNull);
    await api.resolveStream('a', mode: PlaybackMode.video);
    expect(requests, 2);
  });
  test('Refresh replaces cached URLs and preserves the new headers', () async {
    var requests = 0;
    final api = mockApi((_) {
      final data = streamJson('a');
      (data['audio'] as Map<String, dynamic>)['http_headers'] = {
        'User-Agent': 'request-${++requests}',
      };
      return jsonResponse(data);
    });
    addTearDown(api.close);
    await api.resolveStream('a');
    final response = await api.resolveStream('a', refresh: true);
    expect(requests, 2);
    expect(response.audio?.httpHeaders['User-Agent'], 'request-2');
  });
  test('Failed requests are not cached and can be retried', () async {
    var requests = 0;
    final api = mockApi(
      (_) =>
          ++requests == 1
              ? http.Response('', 503)
              : jsonResponse(streamJson('a')),
    );
    addTearDown(api.close);
    await expectLater(api.resolveStream('a'), throwsA(isA<ApiFailure>()));
    await api.resolveStream('a');
    expect(requests, 2);
  });
  test('Stream cache retains at most sixteen recently used results', () async {
    final api = mockApi((request) {
      final id = jsonDecode(request.body)['video_id'] as String;
      return jsonResponse(streamJson(id));
    });
    addTearDown(api.close);
    for (var i = 0; i < 17; i++) {
      await api.resolveStream('$i');
    }
    expect(api.cachedMedia('0', PlaybackMode.audio), isNull);
    expect(api.cachedMedia('16', PlaybackMode.audio), isNotNull);
  });
  test('Closing a client discards cached and late stream responses', () async {
    final delayed = Completer<http.Response>();
    final api = mockApi((_) => delayed.future);
    final pending = api.resolveStream('a');
    await drain();
    api.close();
    delayed.complete(jsonResponse(streamJson('a')));
    await pending;
    expect(api.cachedMedia('a', PlaybackMode.audio), isNull);
    final other = mockApi((_) => jsonResponse(streamJson('a')));
    addTearDown(other.close);
    expect(other.cachedMedia('a', PlaybackMode.audio), isNull);
  });
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

import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mix_player_app/controllers/mix_controller.dart';
import 'package:mix_player_app/services/app_settings.dart';
import 'support/fakes.dart';

void main() {
  test(
    'Full and incremental extensions merge without duplicate tracks',
    () async {
      var extension = 0;
      final mix =
          MixController()..configure(
            mockApi((request) {
              if (request.url.path.endsWith('extend')) {
                extension++;
                return jsonResponse(
                  mixJson(extension == 1 ? ['a', 'b', 'c'] : ['d', 'c']),
                );
              }
              return jsonResponse(mixJson(['a', 'b', 'a']));
            }),
          );
      addTearDown(mix.dispose);
      expect(await mix.load(defaultMixUrl), isTrue);
      expect(await mix.extend(), 1);
      expect(await mix.extend(), 1);
      expect(mix.items.map((t) => t.videoId), ['a', 'b', 'c', 'd']);
    },
  );
  test('Invalid source URL never sends a request', () async {
    var requests = 0;
    final mix =
        MixController()..configure(
          mockApi((_) {
            requests++;
            return jsonResponse(mixJson(['a']));
          }),
        );
    addTearDown(mix.dispose);
    for (final url in [
      'https://other.test/?list=RD',
      'http://youtube.com/?list=RD',
      'https://youtube.com/watch?v=a',
    ]) {
      expect(await mix.load(url), isFalse);
    }
    expect(requests, 0);
  });
  test('An empty playlist is a load failure', () async {
    final mix =
        MixController()..configure(mockApi((_) => jsonResponse(mixJson([]))));
    addTearDown(mix.dispose);
    expect(await mix.load(defaultMixUrl), isFalse);
    expect(mix.error, contains('曲がありません'));
    expect(mix.isLoading, isFalse);
  });
  test('Older in-flight response cannot replace a newer Mix', () async {
    final old = Completer<http.Response>();
    final mix =
        MixController()..configure(
          mockApi((request) {
            final source = jsonDecode(request.body)['url'] as String;
            return source.contains('old')
                ? old.future
                : jsonResponse(mixJson(['new'], session: 'new'));
          }),
        );
    addTearDown(mix.dispose);
    final first = mix.load('https://youtube.com/?list=old');
    await drain();
    await mix.load('https://youtube.com/?list=new');
    old.complete(jsonResponse(mixJson(['old'], session: 'old')));
    await first;
    expect(mix.sessionId, 'new');
    expect(mix.items.single.videoId, 'new');
  });
  test(
    'Concurrent extensions are coalesced and expired sessions are reported',
    () async {
      final extension = Completer<http.Response>();
      var calls = 0;
      final mix =
          MixController()..configure(
            mockApi((request) {
              if (request.url.path.endsWith('extend')) {
                calls++;
                return extension.future;
              }
              return jsonResponse(mixJson(['a']));
            }),
          );
      addTearDown(mix.dispose);
      await mix.load(defaultMixUrl);
      final first = mix.extend();
      expect(await mix.extend(), 0);
      extension.complete(http.Response('', 404));
      expect(await first, 0);
      expect(calls, 1);
      expect(mix.error, contains('404'));
    },
  );
}

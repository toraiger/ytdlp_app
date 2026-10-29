import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mix_player_app/controllers/mix_controller.dart';
import 'package:mix_player_app/controllers/playback_controller.dart';
import 'package:mix_player_app/models/api_timing.dart';
import 'package:mix_player_app/services/api_client.dart';
import 'package:mix_player_app/services/app_settings.dart';

import 'support/fakes.dart';

void main() {
  testWidgets(
    'iOS processes API responses and cache hits without a fixed wait',
    (tester) async {
      var calls = 0;
      final api = mockApi((_) {
        calls++;
        return jsonResponse(streamJson('a'));
      });
      addTearDown(api.close);
      var completed = false;
      final pending = api.resolveStream('a').then((_) => completed = true);
      await tester.pump();
      expect(completed, isTrue);
      expect(calls, 1);
      final timing = api.lastTiming.value!;
      expect(timing.operation, ApiOperation.stream);
      expect(timing.succeeded, isTrue);
      expect(timing.statusCode, 200);
      expect(timing.toHeaders, isNotNull);
      expect(timing.total, greaterThanOrEqualTo(timing.toHeaders!));
      await pending;

      await api.resolveStream('a');
      expect(calls, 1);
      expect(api.lastTiming.value, same(timing));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS prepares and starts first audio without an artificial media wait',
    (tester) async {
      final mix =
          MixController()..configure(
            mockApi(
              (request) => jsonResponse(
                request.url.path == '/stream'
                    ? streamJson('a')
                    : mixJson(['a']),
              ),
            ),
          );
      final audio = FakeAudioEngine();
      final playback = PlaybackController(mix: mix, audio: audio);
      var loaded = false;
      final loading = mix.load(defaultMixUrl).then((_) => loaded = true);
      await tester.pump();
      expect(loaded, isTrue);
      expect(audio.loadCount, 1);
      expect(audio.playing, isFalse);
      await loading;
      var started = false;
      final playing = playback.playTrack(0).then((_) => started = true);
      await tester.pump();
      expect(started, isTrue);
      expect(audio.loadCount, 1);
      expect(audio.playing, isTrue);
      await playing;
      playback.dispose();
      mix.dispose();
      await tester.pump();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  test(
    'Failed API requests retain timing without private request details',
    () async {
      final api = mockApi(
        (_) => throw http.ClientException('private-key signed-url'),
      );
      addTearDown(api.close);
      await expectLater(api.fetchMix('url'), throwsA(isA<ApiFailure>()));
      final timing = api.lastTiming.value!;
      expect(timing.operation, ApiOperation.mix);
      expect(timing.succeeded, isFalse);
      expect(timing.toHeaders, isNull);
      expect(timing.statusCode, isNull);
      expect(timing.statusLabel, '通信失敗');
    },
  );

  test(
    'Response body failures are distinguished from successful HTTP headers',
    () async {
      final api = ApiClient(
        serverUrl: 'https://api.example.test',
        apiKey: 'test-key',
        client: MockClient.streaming(
          (_, __) async => http.StreamedResponse(
            Stream<List<int>>.error(
              http.ClientException('private response details'),
            ),
            200,
          ),
        ),
      );
      addTearDown(api.close);
      await expectLater(api.resolveStream('a'), throwsA(isA<ApiFailure>()));
      final timing = api.lastTiming.value!;
      expect(timing.succeeded, isFalse);
      expect(timing.statusCode, 200);
      expect(timing.toHeaders, isNotNull);
      expect(timing.statusLabel, '失敗・HTTP 200');
    },
  );

  test('Late responses cannot update disposed timing listeners', () async {
    final delayed = Completer<http.Response>();
    final api = mockApi((_) => delayed.future);
    var notifications = 0;
    api.lastTiming.addListener(() => notifications++);
    final pending = api.resolveStream('a');
    await drain();
    api.close();
    api.close();
    delayed.complete(jsonResponse(streamJson('a')));
    await pending;
    expect(notifications, 0);
  });

  test(
    'Extension timing records an operation instead of a session identifier',
    () async {
      final api = mockApi((_) => jsonResponse(mixJson(['a'])));
      addTearDown(api.close);
      await api.extendMix('private-session-identifier');
      expect(api.lastTiming.value!.operation, ApiOperation.extend);
      expect(api.lastTiming.value!.succeeded, isTrue);
    },
  );
}

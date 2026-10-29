import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mix_player_app/controllers/mix_controller.dart';
import 'package:mix_player_app/controllers/playback_controller.dart';
import 'package:mix_player_app/models/api_models.dart';
import 'package:mix_player_app/services/api_client.dart';
import 'package:mix_player_app/services/app_settings.dart';

import 'support/fakes.dart';

MixController oneTrackMix({VoidCallback? onStream}) =>
    MixController()..configure(
      mockApi((request) {
        if (request.url.path == '/stream') {
          onStream?.call();
          return jsonResponse(streamJson('a'));
        }
        return jsonResponse(mixJson(['a']));
      }),
    );

void main() {
  testWidgets(
    'iOS delays real API responses once and reuses cached results',
    (tester) async {
      var calls = 0;
      final api = mockApi((_) {
        calls++;
        return jsonResponse(streamJson('a'));
      });
      addTearDown(api.close);
      var finished = false;
      final first = api.resolveStream('a').then((value) {
        finished = true;
        return value;
      });
      final shared = api.resolveStream('a');
      await tester.pump();
      expect(calls, 1);
      await tester.pump(const Duration(milliseconds: 999));
      expect(finished, isFalse);
      expect(api.cachedMedia('a', PlaybackMode.audio), isNull);
      await tester.pump(const Duration(milliseconds: 1));
      expect(finished, isTrue);
      expect(await first, same(await shared));

      finished = false;
      final cached = api.resolveStream('a').then((_) => finished = true);
      await tester.pump();
      expect(finished, isTrue);
      expect(calls, 1);
      await cached;
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS API delay remains within the overall request timeout',
    (tester) async {
      final api = ApiClient(
        serverUrl: 'https://api.example.test',
        apiKey: 'test-key',
        timeout: const Duration(milliseconds: 500),
        client: MockClient((_) async => jsonResponse(streamJson('a'))),
      );
      addTearDown(api.close);
      Object? failure;
      final pending = api
          .resolveStream('a')
          .then<void>(
            (_) => fail('Expected the request timeout'),
            onError: (Object error, StackTrace stack) {
              failure = error;
            },
          );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(failure, isA<ApiFailure>());
      expect(api.cachedMedia('a', PlaybackMode.audio), isNull);
      await pending;
      await tester.pump(const Duration(milliseconds: 500));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS first-track preparation adds 1s for API and 400ms before loading',
    (tester) async {
      var streamCalls = 0;
      final mix = oneTrackMix(onStream: () => streamCalls++);
      final audio = FakeAudioEngine();
      final playback = PlaybackController(mix: mix, audio: audio);
      final loading = mix.load(defaultMixUrl);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(await loading, isTrue);
      final playing = playback.playTrack(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 999));
      expect(playback.isResolvingUrl, isTrue);
      expect(audio.loadCount, 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(playback.isResolvingUrl, isFalse);
      await tester.pump(const Duration(milliseconds: 399));
      expect(audio.loadCount, 0);
      expect(audio.playing, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      await playing;
      expect(streamCalls, 1);
      expect(audio.loadCount, 1);
      expect(audio.playing, isTrue);
      // Finish the one-track playlist's extension request before disposal.
      await tester.pump(const Duration(seconds: 1));
      playback.dispose();
      mix.dispose();
      await tester.pump();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Stopping during the iOS media delay prevents a late audio load',
    (tester) async {
      final mix = oneTrackMix();
      final loading = mix.load(defaultMixUrl);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await loading;
      final audio = FakeAudioEngine();
      final playback = PlaybackController(mix: mix, audio: audio);
      final playing = playback.playTrack(0);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(playback.isResolvingUrl, isFalse);
      final stopping = playback.stop();
      await tester.pump(const Duration(milliseconds: 400));
      await Future.wait([playing, stopping]);
      expect(audio.loadCount, 0);
      expect(audio.playing, isFalse);
      expect(playback.currentTrack, isNull);
      playback.dispose();
      mix.dispose();
      await tester.pump();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iOS waits 400ms before creating and initializing the video player',
    (tester) async {
      final mix = oneTrackMix();
      final loading = mix.load(defaultMixUrl);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await loading;
      final videos = <FakeVideoEngine>[];
      final playback = PlaybackController(
        mix: mix,
        audio: FakeAudioEngine(),
        videoFactory: (_, __) {
          final video = FakeVideoEngine();
          videos.add(video);
          return video;
        },
      );
      await playback.setMode(PlaybackMode.video);
      final playing = playback.playTrack(0);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 399));
      expect(videos, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await playing;
      expect(videos.single.value.initialized, isTrue);
      expect(videos.single.value.playing, isTrue);
      playback.dispose();
      mix.dispose();
      await tester.pump();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Android API and audio loading have no added delays',
    (tester) async {
      final mix = oneTrackMix();
      await mix.load(defaultMixUrl);
      final audio = FakeAudioEngine();
      final playback = PlaybackController(mix: mix, audio: audio);
      var finished = false;
      final playing = playback.playTrack(0).then((_) => finished = true);
      await tester.pump();
      expect(finished, isTrue);
      expect(audio.loadCount, 1);
      expect(audio.playing, isTrue);
      await playing;
      playback.dispose();
      mix.dispose();
      await tester.pump();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

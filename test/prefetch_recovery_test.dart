import "dart:async";
import "dart:convert";

import "package:fake_async/fake_async.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:mix_player_app/controllers/mix_controller.dart";
import "package:mix_player_app/controllers/playback_controller.dart";
import "package:mix_player_app/models/prefetch_diagnostics.dart";
import "package:mix_player_app/models/api_failure_diagnostics.dart";
import "package:mix_player_app/services/app_settings.dart";
import "package:mix_player_app/services/error_report.dart";
import "package:mix_player_app/services/network_path.dart";
import "package:mix_player_app/services/playback_engines.dart";

import "support/fakes.dart";

void main() {
  late MixController mix;
  late PlaybackController playback;
  late FakeAudioEngine audio;
  late StreamController<NetworkPath> paths;
  late List<String> resolutions;
  FutureOr<http.Response> Function(String)? resolve;

  setUp(() async {
    resolutions = [];
    resolve = null;
    mix =
        MixController()..configure(
          mockApi((request) {
            if (request.url.path == "/stream") {
              final videoId = jsonDecode(request.body)["video_id"] as String;
              resolutions.add(videoId);
              return resolve?.call(videoId) ??
                  jsonResponse(streamJson(videoId));
            }
            return jsonResponse(mixJson(["a", "b", "c", "d", "e"]));
          }),
        );
    await mix.load(defaultMixUrl);
    audio = FakeAudioEngine();
    paths = StreamController<NetworkPath>.broadcast(sync: true);
    playback = PlaybackController(mix: mix, audio: audio, paths: paths.stream);
  });

  tearDown(() async {
    playback.dispose();
    mix.dispose();
    await paths.close();
    await drain();
  });

  test(
    "A failed media prefix recovers the same next song during the current song",
    () async {
      var failures = 0;
      audio.onPrepare = (entry) {
        if (entry.mixIndex == 1 && failures++ == 0) {
          throw const AudioPreparationFailure("prefix_connection");
        }
      };
      await playback.playTrack(0);
      audio.positionEvents.add(const Duration(seconds: 37));
      await drain();
      expect(resolutions.where((videoId) => videoId == "b"), hasLength(2));
      expect(audio.entries.map((entry) => entry.track.videoId), [
        "a",
        "b",
        "c",
      ]);
      expect(playback.currentIndex, 0);
      expect(playback.position, const Duration(seconds: 37));
      expect(audio.playing, isTrue);
      expect(audio.stopCount, 1);
      expect(audio.resetCount, 0);
      expect(audio.lastSeek, isNull);
      expect(
        playback.diagnostics.prefetch
            .firstWhere((state) => state.listIndex == 1)
            .retryCount,
        1,
      );
    },
  );

  test(
    "A native future-item failure replaces only that item and preserves its successor",
    () async {
      await playback.playTrack(0);
      await drain();
      final current = audio.entries.first;
      final following = audio.entries.last;
      audio.positionEvents.add(const Duration(seconds: 39));
      audio.emitPrepared(
        audio.prepared.first,
        failure: const AudioPreparationFailure("native_-1004"),
      );
      await drain();
      expect(audio.entries.first, same(current));
      expect(audio.entries.last, same(following));
      expect(audio.replacements.map((entry) => entry.mixIndex), [1]);
      expect(playback.currentIndex, 0);
      expect(playback.position, const Duration(seconds: 39));
      expect(playback.isPlaying, isTrue);
      expect(audio.lastSeek, isNull);
      expect(audio.stopCount, 1);
      final report = playback.errorReport!.toText();
      expect(report, contains("先読み対象の曲番号: 2"));
      expect(report, contains("先読み差し替え結果: replaced"));
      expect(report, isNot(contains("https://")));
    },
  );

  test(
    'Parallel prefetch failures retain separate request diagnostics for copying',
    () async {
      resolve = (id) {
        if (id == 'b') throw http.ClientException('connection lost');
        if (id == 'c') return http.Response('private-response-body', 503);
        return jsonResponse(streamJson(id));
      };
      await playback.playTrack(0);
      await drain();
      final states = playback.diagnostics.prefetch;
      final next = states.firstWhere((state) => state.listIndex == 1);
      final following = states.firstWhere((state) => state.listIndex == 2);
      expect(next.lastApiFailure!.kind, ApiFailureKind.connection);
      expect(next.lastApiFailure!.timing.statusCode, isNull);
      expect(following.lastApiFailure!.kind, ApiFailureKind.httpStatus);
      expect(following.lastApiFailure!.timing.statusCode, 503);
      final report = playback.errorReport!.toText();
      final nextSection =
          report.split('先読み対象の曲番号: 2').last.split('先読み対象の曲番号: 3').first;
      final followingSection = report.split('先読み対象の曲番号: 3').last;
      expect(nextSection, contains('API失敗種別: connection'));
      expect(nextSection, isNot(contains('HTTP 503')));
      expect(followingSection, contains('HTTP 503'));
      expect(report, isNot(contains('private-response-body')));
      expect(report, isNot(contains('https://')));
      expect(playback.currentIndex, 0);
      expect(playback.isPlaying, isTrue);
    },
  );

  test(
    "A path change preserves automatic progression to the next and following songs",
    () async {
      await playback.playTrack(0);
      await drain();
      audio.positionEvents.add(const Duration(seconds: 41));
      paths.add(const NetworkPath(generation: 1, available: true));
      await drain();
      expect(audio.replacements.map((entry) => entry.mixIndex), [1, 2]);
      expect(playback.position, const Duration(seconds: 41));
      expect(audio.lastSeek, isNull);
      audio.advance(1);
      await drain();
      expect(playback.currentIndex, 1);
      expect(audio.entries.map((entry) => entry.mixIndex), [1, 2, 3]);
      audio.advance(1);
      await drain();
      expect(playback.currentIndex, 2);
      expect(audio.entries.map((entry) => entry.mixIndex), [2, 3, 4]);
      expect(audio.stopCount, 1);
      expect(audio.resetCount, 0);
      expect(audio.playing, isTrue);
    },
  );

  test("URL, media prefix and native readiness remain distinct", () async {
    final prefix = Completer<void>();
    audio.automaticallyReady = false;
    audio.onPrepare = (entry) => entry.mixIndex == 1 ? prefix.future : null;
    await playback.playTrack(0);
    await drain();
    expect(resolutions, ["a", "b", "c"]);
    expect(audio.entries, hasLength(1));
    var state = playback.diagnostics.prefetch.first;
    expect(state.stage, PrefetchStage.media);
    expect(state.mediaReady, isFalse);
    prefix.complete();
    await drain();
    state = playback.diagnostics.prefetch.first;
    expect(state.mediaReady, isTrue);
    expect(state.nativeReady, isFalse);
    expect(state.stage, PrefetchStage.native);
    audio.emitPrepared(audio.prepared.first);
    expect(playback.diagnostics.prefetch.first.nativeReady, isTrue);
  });

  test(
    "Offline prefetch sends no requests and resumes on a usable path",
    () async {
      paths.add(const NetworkPath(generation: 1, available: false));
      await playback.playTrack(0);
      await drain();
      expect(resolutions, ["a"]);
      expect(
        playback.diagnostics.prefetch.every(
          (state) => state.stage == PrefetchStage.offline,
        ),
        isTrue,
      );
      paths.add(const NetworkPath(generation: 2, available: true));
      await drain();
      expect(resolutions, ["a", "b", "c"]);
      expect(audio.entries, hasLength(3));
      expect(audio.stopCount, 1);
      expect(audio.rotations, 1);
    },
  );

  test(
    "A path change cancels old requests and their late responses cannot replace fresh media",
    () async {
      final oldResponse = Completer<http.Response>();
      var requests = 0;
      resolve = (videoId) {
        if (videoId == "b" && requests++ == 0) return oldResponse.future;
        final response = streamJson(videoId);
        (response["audio"] as Map)["url"] =
            "https://media.example.test/$videoId.m4a?generation=fresh";
        return jsonResponse(response);
      };
      await playback.playTrack(0);
      await drain();
      expect(audio.entries, hasLength(1));
      paths.add(const NetworkPath(generation: 1, available: true));
      await drain();
      expect(audio.entries.map((entry) => entry.track.videoId), [
        "a",
        "b",
        "c",
      ]);
      oldResponse.complete(jsonResponse(streamJson("b")));
      await drain();
      expect(audio.entries[1].uri.queryParameters["generation"], "fresh");
      expect(
        mix.api
            .cachedMedia("b", playback.mode)!
            .url!
            .queryParameters["generation"],
        "fresh",
      );
      expect(
        audio.prepared
            .where((prepared) => prepared.entry.mixIndex == 1)
            .single
            .networkGeneration,
        1,
      );
      expect(audio.lastSeek, isNull);
      expect(audio.stopCount, 1);
    },
  );

  test(
    "At the track end the same next song waits for preparation and starts automatically",
    () async {
      final prefix = Completer<void>();
      audio.onPrepare = (entry) => entry.mixIndex == 1 ? prefix.future : null;
      await playback.playTrack(0);
      await drain();
      audio.stateEvents.add(const AudioStatus(true, AudioPhase.completed));
      await drain();
      expect(playback.isWaitingForNext, isTrue);
      expect(playback.currentIndex, 0);
      expect(resolutions, ["a", "b", "c"]);
      prefix.complete();
      await drain();
      expect(playback.isWaitingForNext, isFalse);
      expect(playback.currentIndex, 1);
      expect(playback.isPlaying, isTrue);
      expect(audio.loadCount, 1);
      expect(audio.stopCount, 1);
    },
  );

  test(
    "Pausing while waiting prevents autoplay until an explicit resume",
    () async {
      final prefix = Completer<void>();
      audio.onPrepare = (entry) => entry.mixIndex == 1 ? prefix.future : null;
      await playback.playTrack(0);
      await drain();
      audio.stateEvents.add(const AudioStatus(true, AudioPhase.completed));
      await drain();
      await playback.togglePlay();
      prefix.complete();
      await drain();
      expect(playback.currentIndex, 0);
      expect(playback.isWaitingForNext, isTrue);
      expect(audio.playing, isFalse);
      expect(audio.lastSeek, isNull);
      await playback.togglePlay();
      await drain();
      expect(playback.currentIndex, 1);
      expect(audio.playing, isTrue);
    },
  );

  test(
    "A lock-screen pause remains respected when a held item becomes ready",
    () async {
      audio.automaticallyReady = false;
      await playback.playTrack(0);
      await drain();
      audio.stateEvents.add(const AudioStatus(true, AudioPhase.completed));
      await drain();
      await audio.pause();
      audio.emitPrepared(audio.prepared.first);
      await drain();
      expect(playback.isWaitingForNext, isTrue);
      expect(playback.currentIndex, 0);
      expect(audio.playing, isFalse);
      expect(audio.lastSeek, isNull);
    },
  );

  test(
    "Stopping is not blocked by a pending media read and cancels delayed autoplay",
    () async {
      final prefix = Completer<void>();
      audio.onPrepare = (entry) => entry.mixIndex == 1 ? prefix.future : null;
      await playback.playTrack(0);
      await drain();
      await playback.stop();
      expect(audio.prepared.first.cancelled, isTrue);
      prefix.complete();
      await drain();
      expect(playback.currentTrack, isNull);
      expect(audio.entries, isEmpty);
      expect(audio.playing, isFalse);
    },
  );

  test("A manual selection cancels an older pending preparation", () async {
    final prefix = Completer<void>();
    audio.onPrepare = (entry) => entry.mixIndex == 1 ? prefix.future : null;
    await playback.playTrack(0);
    await drain();
    await playback.playTrack(3);
    prefix.complete();
    await drain();
    expect(playback.currentIndex, 3);
    expect(audio.entries.first.track.videoId, "d");
    expect(audio.entries.any((entry) => entry.track.videoId == "b"), isFalse);
  });

  test(
    "A future source error is not handled as failure of the active song",
    () async {
      await playback.playTrack(0);
      await drain();
      audio.emitError(
        "future",
        details: const FailureDetails(
          type: "PlayerException",
          sourceIndex: 1,
          nativeCode: -1004,
        ),
      );
      await drain();
      expect(playback.currentIndex, 0);
      expect(audio.resetCount, 0);
      expect(audio.loadCount, 1);
      expect(audio.replacements, hasLength(1));
    },
  );

  test(
    "An item that becomes current during replacement is preserved",
    () async {
      await playback.playTrack(0);
      await drain();
      final original = audio.entries[1];
      audio.onReplace = (_) => audio.advance(1);
      audio.emitPrepared(
        audio.prepared.first,
        failure: const AudioPreparationFailure("native_-1004"),
      );
      await drain();
      expect(playback.currentIndex, 1);
      expect(audio.entries.first, same(original));
      expect(audio.entries.where((entry) => entry.mixIndex == 1), hasLength(1));
      expect(audio.stopCount, 1);
      expect(audio.resetCount, 0);
      expect(audio.lastSeek, isNull);
    },
  );

  test("Consecutive failures back off at 1, 2, 4, 8 and then 15 seconds", () {
    // Test the production timers without real waits or network requests.
    fakeAsync((clock) {
      final attempted = <String>[];
      final retryMix =
          MixController()..configure(
            mockApi((request) {
              if (request.url.path == "/stream") {
                final videoId = jsonDecode(request.body)["video_id"] as String;
                attempted.add(videoId);
                return videoId == "b"
                    ? http.Response("", 503)
                    : jsonResponse(streamJson(videoId));
              }
              return jsonResponse(mixJson(["a", "b", "c"]));
            }),
          );
      final retryAudio = FakeAudioEngine();
      final retryPlayback = PlaybackController(
        mix: retryMix,
        audio: retryAudio,
        paths: const Stream.empty(),
      );
      unawaited(
        retryMix.load(defaultMixUrl).then((_) => retryPlayback.playTrack(0)),
      );
      clock.flushMicrotasks();
      clock.elapse(Duration.zero);
      var expectedAttempts = 2; // Initial failure and the immediate recovery.
      expect(
        attempted.where((videoId) => videoId == "b"),
        hasLength(expectedAttempts),
      );
      for (final seconds in [1, 2, 4, 8, 15, 15]) {
        clock.elapse(Duration(milliseconds: seconds * 1000 - 1));
        expect(
          attempted.where((videoId) => videoId == "b"),
          hasLength(expectedAttempts),
        );
        clock.elapse(const Duration(milliseconds: 1));
        expectedAttempts++;
        expect(
          attempted.where((videoId) => videoId == "b"),
          hasLength(expectedAttempts),
        );
      }
      retryPlayback.dispose();
      retryMix.dispose();
      clock.flushMicrotasks();
    });
  });
}

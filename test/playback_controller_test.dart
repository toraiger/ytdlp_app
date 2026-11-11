import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import "package:just_audio/just_audio.dart";
import 'package:mix_player_app/controllers/mix_controller.dart';
import 'package:mix_player_app/controllers/playback_controller.dart';
import 'package:mix_player_app/models/api_models.dart';
import 'package:mix_player_app/services/app_settings.dart';
import "package:mix_player_app/services/error_report.dart";
import 'package:mix_player_app/services/playback_engines.dart';
import 'support/fakes.dart';

void main() {
  late MixController mix;
  late FakeAudioEngine audio;
  late PlaybackController playback;
  late List<String> resolutions;
  late List<FakeVideoEngine> videos;
  late List<Map<String, String>> videoHeaders;
  late int extensions;
  late DateTime now;
  FutureOr<http.Response> Function(String)? resolveOverride;
  setUp(() async {
    resolutions = [];
    videos = [];
    videoHeaders = [];
    extensions = 0;
    resolveOverride = null;
    now = DateTime.utc(2026, 10, 29);
    mix =
        MixController()..configure(
          mockApi((request) {
            if (request.url.path == '/stream') {
              final id = jsonDecode(request.body)['video_id'] as String;
              resolutions.add(id);
              return resolveOverride?.call(id) ?? jsonResponse(streamJson(id));
            }
            if (request.url.path.endsWith('extend')) extensions++;
            return jsonResponse(mixJson(['a', 'b', 'c', 'd', 'e']));
          }, now: () => now),
        );
    await mix.load(defaultMixUrl);
    audio = FakeAudioEngine();
    playback = PlaybackController(
      mix: mix,
      audio: audio,
      videoFactory: (_, headers) {
        videoHeaders.add(headers);
        final video = FakeVideoEngine();
        videos.add(video);
        return video;
      },
    );
  });
  tearDown(() async {
    playback.dispose();
    mix.dispose();
    await drain();
  });
  test('Audio resolves selected track and only two upcoming tracks', () async {
    await playback.playTrack(0);
    await drain();
    expect(resolutions, ['a', 'b', 'c']);
    expect(audio.entries.map((e) => e.track.videoId), ['a', 'b', 'c']);
    expect(audio.entries.map((e) => e.httpHeaders['User-Agent']), [
      'audio-a',
      'audio-b',
      'audio-c',
    ]);
    expect(playback.isPlaying, isTrue);
    expect(playback.upcomingCount, 2);
    audio.advance(1);
    await drain();
    expect(playback.currentIndex, 1);
    expect(resolutions, ['a', 'b', 'c', 'd']);
    expect(audio.entries.last.httpHeaders['User-Agent'], 'audio-d');
  });
  test('Mix load prepares the first audio source without autoplay', () async {
    await mix.load(defaultMixUrl);
    await drain();
    expect(resolutions, ['a', 'b', 'c']);
    expect(audio.loadCount, 1);
    expect(audio.playing, isFalse);
    expect(playback.currentTrack, isNull);
    expect(playback.isBusy, isFalse);

    await playback.playTrack(0);
    await drain();
    expect(audio.loadCount, 1);
    expect(audio.stopCount, 0);
    expect(audio.entries.map((entry) => entry.track.videoId), ['a', 'b', 'c']);
    expect(resolutions, ['a', 'b', 'c']);
    expect(playback.currentIndex, 0);
    expect(playback.isPlaying, isTrue);
  });
  test(
    'First tap shares the URL request already started by Mix load',
    () async {
      final delayed = Completer<http.Response>();
      resolveOverride =
          (id) => id == 'a' ? delayed.future : jsonResponse(streamJson(id));
      await mix.load(defaultMixUrl);
      await drain();
      final playing = playback.playTrack(0);
      await drain();
      expect(resolutions, ['a']);
      expect(playback.isResolvingUrl, isTrue);
      expect(audio.playing, isFalse);
      delayed.complete(jsonResponse(streamJson('a')));
      await playing;
      await drain();
      expect(resolutions.where((id) => id == 'a'), hasLength(1));
      expect(audio.loadCount, 1);
      expect(audio.playing, isTrue);
    },
  );
  test(
    'First tap waits for the existing media load instead of loading twice',
    () async {
      final loaded = Completer<void>();
      audio.onLoad = (_) => loaded.future;
      await mix.load(defaultMixUrl);
      await drain();
      expect(audio.loadCount, 1);
      expect(audio.playing, isFalse);
      final playing = playback.playTrack(0);
      await drain();
      expect(playback.isBusy, isTrue);
      expect(playback.isResolvingUrl, isFalse);
      loaded.complete();
      await playing;
      await drain();
      expect(audio.loadCount, 1);
      expect(audio.playing, isTrue);
    },
  );
  test('First playback does not wait for the next tracks URL', () async {
    final delayed = Completer<http.Response>();
    resolveOverride =
        (id) => id == 'b' ? delayed.future : jsonResponse(streamJson(id));
    await mix.load(defaultMixUrl);
    await drain();
    await playback.playTrack(0);
    expect(audio.playing, isTrue);
    expect(playback.isBusy, isFalse);
    expect(audio.loadCount, 1);
    delayed.complete(jsonResponse(streamJson('b')));
    await drain();
  });
  test(
    'Selecting another track invalidates pending first-track preparation',
    () async {
      final delayed = Completer<http.Response>();
      resolveOverride =
          (id) => id == 'a' ? delayed.future : jsonResponse(streamJson(id));
      await mix.load(defaultMixUrl);
      await drain();
      await playback.playTrack(2);
      delayed.complete(jsonResponse(streamJson('a')));
      await drain();
      expect(playback.currentTrack?.videoId, 'c');
      expect(audio.entries.first.track.videoId, 'c');
      expect(audio.loadCount, 1);
    },
  );
  test('Stop during first-track loading prevents delayed autoplay', () async {
    final loaded = Completer<void>();
    audio.onLoad = (_) => loaded.future;
    await mix.load(defaultMixUrl);
    await drain();
    final playing = playback.playTrack(0);
    await drain();
    final stopping = playback.stop();
    loaded.complete();
    await Future.wait([playing, stopping]);
    await drain();
    expect(playback.currentTrack, isNull);
    expect(audio.playing, isFalse);
    expect(audio.entries, isEmpty);
  });
  test('A failed first-track preparation is retried when tapped', () async {
    var failed = false;
    resolveOverride = (id) {
      if (id == 'a' && !failed) {
        failed = true;
        return http.Response('', 503);
      }
      return jsonResponse(streamJson(id));
    };
    await mix.load(defaultMixUrl);
    await drain();
    expect(playback.error, isNull);
    expect(audio.playing, isFalse);
    await playback.playTrack(0);
    await drain();
    expect(resolutions.where((id) => id == 'a'), hasLength(2));
    expect(audio.playing, isTrue);
  });
  test(
    'List taps and previous reuse the loaded queue and reset time',
    () async {
      await playback.playTrack(0);
      await drain();
      await playback.playTrack(1);
      await drain();
      expect(audio.loadCount, 1);
      expect(resolutions.where((id) => id == 'b'), hasLength(1));
      expect(playback.currentIndex, 1);
      expect(playback.position, Duration.zero);
      audio.positionEvents.add(const Duration(seconds: 1));
      await playback.previous();
      expect(playback.currentIndex, 0);
      expect(playback.position, Duration.zero);
      expect(resolutions.where((id) => id == 'a'), hasLength(1));
      expect(audio.loadCount, 1);
      expect(audio.stopCount, 1);
      expect(audio.entries.first.httpHeaders['User-Agent'], 'audio-a');
    },
  );
  test(
    'Tapping the current track restarts it without rebuilding the player',
    () async {
      await playback.playTrack(0);
      await drain();
      audio.positionEvents.add(const Duration(seconds: 10));
      await playback.playTrack(0);
      expect(playback.position, Duration.zero);
      expect(audio.loadCount, 1);
      expect(resolutions.where((id) => id == 'a'), hasLength(1));
    },
  );
  test('Expired queued URLs are refreshed instead of reused', () async {
    await playback.playTrack(0);
    await drain();
    now = now.add(const Duration(minutes: 5));
    await playback.playTrack(1);
    await drain();
    expect(audio.loadCount, 2);
    expect(resolutions.where((id) => id == 'b'), hasLength(2));
    expect(playback.currentIndex, 1);
  });
  test('A failed queue seek refreshes the selected URL once', () async {
    await playback.playTrack(0);
    await drain();
    audio.onSeek = (_) => throw StateError('Expired queued source');
    await playback.playTrack(1);
    await drain();
    expect(resolutions.where((id) => id == 'b'), hasLength(2));
    expect(audio.loadCount, 2);
    expect(playback.error, isNull);
    expect(playback.currentIndex, 1);
  });
  test(
    'A reused source playback error refreshes once without an error loop',
    () async {
      await playback.playTrack(0);
      await drain();
      await playback.playTrack(1);
      audio.emitError('Cached source rejected');
      await drain();
      expect(resolutions.where((id) => id == 'b'), hasLength(2));
      expect(playback.error, isNull);
      expect(playback.currentIndex, 1);
      audio.emitError('Fresh source rejected');
      await drain();
      expect(resolutions.where((id) => id == 'b'), hasLength(2));
      expect(playback.error, 'Fresh source rejected');
    },
  );
  test('Loading a rejected cached URL retries with fresh media', () async {
    await playback.playTrack(0);
    await drain();
    await playback.stop();
    audio.onLoad = (_) {
      if (audio.loadCount == 2) throw StateError('Cached source rejected');
    };
    await playback.playTrack(0);
    await drain();
    expect(audio.loadCount, 3);
    expect(resolutions.where((id) => id == 'a'), hasLength(2));
    expect(playback.error, isNull);
    expect(audio.playing, isTrue);
  });
  test("A newly resolved source can recover after a long pause", () async {
    await playback.playTrack(0);
    await drain();
    await playback.togglePlay();
    // URLの通常の有効期間を越える一時停止を時計だけ進めて再現する。
    const pauseBeyondStreamLifetime = Duration(hours: 7);
    now = now.add(pauseBeyondStreamLifetime);

    audio.emitError("Source expired while paused");
    await drain();

    expect(resolutions.where((id) => id == "a"), hasLength(2));
    expect(audio.loadCount, 2);
    expect(audio.stopCount, 2);
    expect(playback.currentIndex, 0);
    expect(playback.error, isNull);
    expect(playback.isPlaying, isTrue);

    audio.emitError("Replacement rejected");
    await drain();
    expect(resolutions.where((id) => id == "a"), hasLength(2));
    expect(playback.error, "Replacement rejected");
    expect(playback.isPlaying, isFalse);
  });
  test("A newly resolved source load failure retries only once", () async {
    audio.onLoad = (entry) => throw StateError("Media load rejected");

    await playback.playTrack(0);
    await drain();

    expect(resolutions, ["a", "a"]);
    expect(audio.loadCount, 2);
    expect(playback.error, isNotNull);
    expect(playback.isBusy, isFalse);
    expect(playback.isPlaying, isFalse);
    expect(mix.api.cachedMedia("a", PlaybackMode.audio), isNull);

    // Retry through the playback button, without restarting or reloading Mix.
    audio.onLoad = null;
    await playback.togglePlay();
    await drain();
    expect(resolutions.where((id) => id == "a"), hasLength(3));
    expect(playback.currentIndex, 0);
    expect(playback.error, isNull);
    expect(playback.isPlaying, isTrue);
  });
  test("Late native events cannot revive a failed playback", () async {
    await playback.playTrack(0);
    await drain();
    audio.emitError("Initial failure");
    await drain();
    audio.emitError("Retry failed");
    await drain();

    audio.stateEvents.add(const AudioStatus(true, AudioPhase.ready));
    audio.advance(1);
    audio.stateEvents.add(const AudioStatus(true, AudioPhase.completed));
    await drain();

    expect(playback.isPlaying, isFalse);
    expect(playback.currentIndex, 0);
    expect(playback.error, "Retry failed");
    expect(resolutions.where((id) => id == "a"), hasLength(2));

    await playback.togglePlay();
    await drain();
    expect(resolutions.where((id) => id == "a"), hasLength(3));
    expect(playback.currentIndex, 0);
    expect(playback.isPlaying, isTrue);
    expect(playback.error, isNull);
  });
  test("Stopping during automatic recovery prevents late autoplay", () async {
    await playback.playTrack(0);
    await drain();
    final response = Completer<http.Response>();
    resolveOverride = (id) => response.future;
    audio.emitError("Media expired");
    await drain();
    expect(playback.isResolvingUrl, isTrue);

    await playback.stop();
    response.complete(jsonResponse(streamJson("a")));
    await drain();

    expect(audio.loadCount, 1);
    expect(playback.currentTrack, isNull);
    expect(playback.isPlaying, isFalse);
    expect(playback.isBusy, isFalse);
    expect(audio.entries, isEmpty);
  });
  test("Reloading Mix after failure does not reuse the rejected URL", () async {
    audio.onLoad = (entry) => throw StateError("Media rejected");
    await playback.playTrack(0);
    await drain();
    expect(resolutions, ["a", "a"]);

    audio.onLoad = null;
    resolveOverride = (id) {
      final json = streamJson(id);
      json["audio"] = {
        "url": "https://media.example.test/$id-fresh.m4a",
        "http_headers": {"User-Agent": "fresh-agent"},
      };
      return jsonResponse(json);
    };
    await mix.load(defaultMixUrl);
    await drain();
    await playback.playTrack(0);
    await drain();

    expect(resolutions.where((id) => id == "a"), hasLength(3));
    expect(audio.entries.first.uri.path, "/a-fresh.m4a");
    expect(audio.entries.first.httpHeaders, {"User-Agent": "fresh-agent"});
    expect(playback.error, isNull);
    expect(playback.isPlaying, isTrue);
  });
  test(
    "Loading failures keep native details after automatic refresh",
    () async {
      audio.onLoad =
          (entry) =>
              throw PlayerException(
                -1009,
                "https://private.example/media?token=private-token",
                0,
              );
      await playback.playTrack(0);
      await drain();

      final report = playback.errorReport!;
      expect(report.operation, "音声の読み込み");
      expect(report.details.nativeCode, -1009);
      expect(report.details.sourceIndex, 0);
      expect(report.refreshed, isTrue);
      expect(report.playback!.listIndex, 0);
      expect(report.uptime, isNotNull);
      expect(report.toText(), isNot(contains("private")));
      expect(audio.loadCount, 2);

      await playback.stop();
      expect(playback.errorReport, isNull);
    },
  );
  test(
    "Playback errors capture a snapshot before later player events",
    () async {
      await playback.playTrack(0);
      await drain();
      audio.emitError("Initial failure");
      await drain();
      const failurePosition = Duration(seconds: 37);
      audio.positionEvents.add(failurePosition);
      audio.emitError(
        "音声を再生できません。",
        details: const FailureDetails(
          type: "PlayerException",
          nativeCode: -11800,
          sourceIndex: 0,
        ),
      );
      final report = playback.errorReport!;
      final textAtFailure = report.toText();
      expect(report.playback!.mediaPosition, failurePosition);
      expect(report.refreshed, isTrue);

      audio.advance(1);
      audio.positionEvents.add(Duration.zero);
      audio.emitError("Duplicate failure");
      await drain();
      expect(playback.errorReport, same(report));
      expect(report.toText(), textAtFailure);

      await playback.togglePlay();
      expect(playback.errorReport, isNull);
      expect(playback.isPlaying, isTrue);
    },
  );
  test("Stream API failures retain the HTTP status in their report", () async {
    resolveOverride = (id) => http.Response("private-response", 503);
    await playback.playTrack(0);
    final report = playback.errorReport!;

    expect(report.details.httpStatusCode, 503);
    expect(report.apiTiming!.succeeded, isFalse);
    expect(report.apiTiming!.statusCode, 503);
    expect(report.toText(), isNot(contains("private-response")));
  });
  test("Video reports preserve the original failure snapshot", () async {
    await playback.setMode(PlaybackMode.video);
    await playback.playTrack(0);
    const failedStatus = VideoStatus(
      hasError: true,
      position: Duration(seconds: 37),
      failure: FailureDetails(type: "PlatformException", nativeCode: -11800),
    );
    videos.single.emit(failedStatus);
    final report = playback.errorReport!;
    expect(report.details.nativeCode, -11800);
    expect(report.playback!.mediaPosition, failedStatus.position);

    videos.single.emit(const VideoStatus(hasError: true));
    expect(playback.errorReport, same(report));
    expect(report.playback!.mediaPosition, failedStatus.position);
  });
  test(
    'Automatic advance during append updates the current track and timing',
    () async {
      audio.onAppend = (entry) {
        if (entry.track.videoId != 'b') return;
        // The native player can start the new item before append completes.
        audio.indexEvents.add(1);
        audio.positionEvents.add(Duration.zero);
        audio.durationEvents.add(const Duration(seconds: 263));
      };

      await playback.playTrack(0);
      await drain();

      expect(playback.currentTrack?.videoId, 'b');
      expect(playback.currentIndex, 1);
      expect(playback.position, Duration.zero);
      expect(playback.duration, const Duration(seconds: 263));
    },
  );
  test(
    'Automatic advance uses the next tracks own time and duration',
    () async {
      await playback.playTrack(0);
      await drain();
      audio.durationEvents.add(const Duration(seconds: 264));
      audio.positionEvents.add(const Duration(seconds: 264));

      audio.advance(1, duration: const Duration(seconds: 263));

      expect(playback.currentTrack?.videoId, 'b');
      expect(playback.position, Duration.zero);
      expect(playback.duration, const Duration(seconds: 263));
    },
  );
  test(
    'Automatic advance resets time when consecutive durations are equal',
    () async {
      await playback.playTrack(0);
      await drain();
      audio.positionEvents.add(const Duration(seconds: 120));

      audio.advance(1);

      expect(playback.currentTrack?.videoId, 'b');
      expect(playback.position, Duration.zero);
      expect(playback.duration, const Duration(seconds: 120));
    },
  );
  test(
    'Prefetch skips failures and preserves the original list index',
    () async {
      resolveOverride =
          (id) =>
              id == 'b' ? http.Response('', 403) : jsonResponse(streamJson(id));
      await playback.playTrack(0);
      await drain();
      expect(audio.entries.map((e) => e.track.videoId), ['a', 'c', 'd']);
      audio.advance(1);
      expect(playback.currentIndex, 2);
      expect(playback.error, contains('スキップ'));
    },
  );
  test('Tail extension runs once at unchanged length', () async {
    await playback.playTrack(4);
    await drain();
    await playback.next();
    await playback.next();
    await drain();
    expect(extensions, 1);
  });
  test('Stop during URL resolution prevents late playback', () async {
    final delayed = Completer<http.Response>();
    resolveOverride = (_) => delayed.future;
    final pending = playback.playTrack(0);
    await drain();
    await playback.stop();
    delayed.complete(jsonResponse(streamJson('a')));
    await pending;
    expect(audio.loadCount, 0);
    expect(playback.currentTrack, isNull);
    expect(audio.playing, isFalse);
  });
  test('Older selection cannot overwrite a newer selection', () async {
    final delayed = Completer<http.Response>();
    resolveOverride =
        (id) => id == 'a' ? delayed.future : jsonResponse(streamJson(id));
    final first = playback.playTrack(0);
    await drain();
    await playback.playTrack(2);
    delayed.complete(jsonResponse(streamJson('a')));
    await first;
    await drain();
    expect(playback.currentTrack?.videoId, 'c');
    expect(audio.entries.first.track.videoId, 'c');
  });
  test(
    'Previous restarts at three seconds or selects the previous track',
    () async {
      await playback.playTrack(1);
      await drain();
      audio.positionEvents.add(const Duration(seconds: 4));
      await playback.previous();
      expect(audio.lastSeek, Duration.zero);
      expect(playback.currentIndex, 1);
      audio.positionEvents.add(const Duration(seconds: 1));
      await playback.previous();
      expect(playback.currentIndex, 0);
    },
  );
  test('Pause, resume and bounded seek use the active audio player', () async {
    await playback.playTrack(0);
    await playback.togglePlay();
    expect(playback.isPlaying, isFalse);
    await playback.togglePlay();
    expect(playback.isPlaying, isTrue);
    await playback.seek(const Duration(seconds: 999));
    expect(audio.lastSeek, const Duration(seconds: 120));
  });
  test(
    'A queued seek cannot change the next track after auto advance',
    () async {
      final appended = Completer<void>();
      audio.onAppend = (_) => appended.future;
      await playback.playTrack(0);
      await drain();
      final seeking = playback.seek(const Duration(seconds: 40));
      audio.advance(1);
      appended.complete();
      await seeking;
      await drain();
      expect(playback.currentIndex, 1);
      expect(audio.lastSeek, isNull);
      expect(playback.position, Duration.zero);
    },
  );
  test(
    'Only the latest seek waiting behind a queue update is applied',
    () async {
      final appended = Completer<void>();
      audio.onAppend = (_) => appended.future;
      var seeks = 0;
      audio.onSeek = (_) => seeks++;
      await playback.playTrack(0);
      await drain();
      final requests = [
        playback.seek(const Duration(seconds: 10)),
        playback.seek(const Duration(seconds: 20)),
        playback.seek(const Duration(seconds: 30)),
      ];
      appended.complete();
      await Future.wait(requests);
      expect(seeks, 1);
      expect(audio.lastSeek, const Duration(seconds: 30));
    },
  );
  test(
    'Unknown native duration uses the current tracks listed duration',
    () async {
      await playback.playTrack(0);
      await drain();
      audio.durationEvents.add(null);
      expect(playback.duration, const Duration(seconds: 120));
      expect(playback.diagnostics.mediaDuration, isNull);
      expect(playback.diagnostics.listDuration, const Duration(seconds: 120));
      audio.positionEvents.add(const Duration(seconds: 999));
      expect(playback.position, const Duration(seconds: 999));
    },
  );
  test(
    'Resolved metadata follows the selected and automatically advanced track',
    () async {
      resolveOverride = (id) {
        final result = streamJson(id);
        result['duration'] = id == 'a' ? 237.125 : 235.25;
        (result['audio'] as Map<String, dynamic>).addAll(<String, Object>{
          'format_id': id == 'a' ? '140' : '141',
          'ext': 'm4a',
          'protocol': 'https',
          'acodec': 'mp4a.40.2',
        });
        return jsonResponse(result);
      };
      await playback.playTrack(0);
      await drain();
      expect(playback.error, isNull);
      expect(
        audio.entries.first.streamDuration,
        const Duration(milliseconds: 237125),
      );
      expect(
        audio.entries[1].streamDuration,
        const Duration(milliseconds: 235250),
      );
      audio.durationEvents.add(const Duration(seconds: 473));
      audio.positionEvents.add(const Duration(seconds: 362));
      final info = playback.diagnostics;
      expect(info.listDuration, const Duration(seconds: 120));
      expect(info.apiDuration, const Duration(milliseconds: 237125));
      expect(info.mediaDuration, const Duration(seconds: 473));
      expect(info.formatId, '140');
      expect(info.mediaExtension, 'm4a');
      expect(info.mediaProtocol, 'https');
      expect(info.audioCodec, 'mp4a.40.2');
      // A metadata difference must not cut off playback or invent a transition.
      expect(playback.currentIndex, 0);
      expect(playback.duration, const Duration(seconds: 473));
      expect(playback.position, const Duration(seconds: 362));

      audio.advance(1, duration: const Duration(seconds: 235));
      expect(playback.currentIndex, 1);
      expect(playback.position, Duration.zero);
      expect(
        playback.diagnostics.apiDuration,
        const Duration(milliseconds: 235250),
      );
      expect(playback.diagnostics.formatId, '141');

      await playback.playTrack(0);
      expect(
        playback.diagnostics.apiDuration,
        const Duration(milliseconds: 237125),
      );
      expect(playback.diagnostics.formatId, '140');
      await playback.playDirect('https://media.example.test/direct.m4a');
      expect(playback.diagnostics.apiDuration, isNull);
      expect(playback.diagnostics.formatId, isNull);
      await playback.stop();
      expect(playback.diagnostics.apiDuration, isNull);
      expect(playback.diagnostics.mediaProtocol, isNull);
    },
  );
  test(
    'Unknown native duration prefers the full stream lookup over list metadata',
    () async {
      resolveOverride =
          (id) => jsonResponse({...streamJson(id), 'duration': 237.125});
      await playback.playTrack(0);
      await drain();
      audio.durationEvents.add(null);
      expect(playback.duration, const Duration(milliseconds: 237125));
      expect(playback.diagnostics.mediaDuration, isNull);
      audio.durationEvents.add(Duration.zero);
      expect(playback.duration, const Duration(milliseconds: 237125));
      audio.durationEvents.add(const Duration(seconds: 238));
      expect(playback.duration, const Duration(seconds: 238));
    },
  );
  test(
    'An unknown stream duration still falls back to the listed length',
    () async {
      resolveOverride =
          (id) => jsonResponse({...streamJson(id), 'duration': 0});
      await playback.playTrack(0);
      await drain();
      audio.durationEvents.add(null);
      expect(playback.duration, const Duration(seconds: 120));
    },
  );
  test(
    'Video diagnostics use the selected video format and API duration',
    () async {
      resolveOverride = (id) {
        final result = streamJson(id)..['duration'] = 237.125;
        (result['video_audio'] as Map<String, dynamic>).addAll(<String, Object>{
          'format_id': '18',
          'ext': 'mp4',
          'protocol': 'https',
          'acodec': 'mp4a.40.2',
        });
        return jsonResponse(result);
      };
      await playback.setMode(PlaybackMode.video);
      await playback.playTrack(0);
      expect(playback.error, isNull);
      videos.single.emit(const VideoStatus(initialized: true));
      expect(playback.duration, const Duration(milliseconds: 237125));
      expect(
        playback.diagnostics.apiDuration,
        const Duration(milliseconds: 237125),
      );
      expect(playback.diagnostics.formatId, '18');
      expect(playback.diagnostics.mediaExtension, 'mp4');
      expect(playback.diagnostics.mediaDuration, Duration.zero);
      expect(playback.diagnostics.playerIndex, isNull);
    },
  );
  test(
    'Direct playback makes no stream requests and has no next track',
    () async {
      await playback.playDirect(
        'https://media.example.test/test.m4a?signature=example',
      );
      await drain();
      await playback.next();
      expect(resolutions, isEmpty);
      expect(audio.entries, hasLength(1));
      expect(audio.entries.single.httpHeaders, isEmpty);
      expect(playback.isDirect, isTrue);
      await playback.playDirect('http://media.example.test/test.m4a');
      expect(playback.error, contains('HTTPS'));
    },
  );
  test(
    'Video completion starts next track and releases the old player',
    () async {
      await playback.setMode(PlaybackMode.video);
      await playback.playTrack(0);
      expect(videoHeaders.single['User-Agent'], 'video-a');
      expect(videoHeaders.single.containsKey('X-API-Key'), isFalse);
      final old = videos.single;
      old.emit(
        const VideoStatus(
          initialized: true,
          completed: true,
          position: Duration(seconds: 120),
          duration: Duration(seconds: 120),
        ),
      );
      await drain();
      expect(playback.currentIndex, 1);
      expect(resolutions, ['a', 'b']);
      expect(videoHeaders.last['User-Agent'], 'video-b');
      expect(old.disposed, isTrue);
      expect(audio.loadCount, 0);
    },
  );
  test('Direct playback does not reuse API media headers', () async {
    await playback.playTrack(0);
    await drain();
    expect(audio.entries.first.httpHeaders, isNotEmpty);
    await playback.playDirect('https://media.example.test/direct.m4a');
    expect(audio.entries.single.httpHeaders, isEmpty);
  });
  test(
    'Background pauses video and changing mode releases resources',
    () async {
      await playback.setMode(PlaybackMode.video);
      await playback.playTrack(0);
      await playback.pauseVideoForBackground();
      expect(playback.isPlaying, isFalse);
      final old = videos.single;
      await playback.setMode(PlaybackMode.audio);
      expect(old.disposed, isTrue);
      expect(playback.currentTrack, isNull);
    },
  );
  test(
    'Video resolved after backgrounding stays paused until user resumes',
    () async {
      await playback.setMode(PlaybackMode.video);
      final delayed = Completer<http.Response>();
      resolveOverride = (_) => delayed.future;
      final pending = playback.playTrack(0);
      await drain();
      await playback.pauseVideoForBackground();
      delayed.complete(jsonResponse(streamJson('a')));
      await pending;
      expect(videos.single.value.playing, isFalse);
      expect(playback.isPlaying, isFalse);
      playback.resumeForeground();
      await playback.togglePlay();
      expect(playback.isPlaying, isTrue);
    },
  );
  test(
    'Video completion in background does not resolve or play another track',
    () async {
      await playback.setMode(PlaybackMode.video);
      await playback.playTrack(0);
      await playback.pauseVideoForBackground();
      videos.single.emit(
        const VideoStatus(
          initialized: true,
          completed: true,
          position: Duration(seconds: 120),
          duration: Duration(seconds: 120),
        ),
      );
      await drain();
      expect(playback.currentIndex, 0);
      expect(resolutions, ['a']);
      expect(videos, hasLength(1));
    },
  );
}

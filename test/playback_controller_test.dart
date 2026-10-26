import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mix_player_app/controllers/mix_controller.dart';
import 'package:mix_player_app/controllers/playback_controller.dart';
import 'package:mix_player_app/models/api_models.dart';
import 'package:mix_player_app/services/app_settings.dart';
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
  FutureOr<http.Response> Function(String)? resolveOverride;
  setUp(() async {
    resolutions = [];
    videos = [];
    videoHeaders = [];
    extensions = 0;
    resolveOverride = null;
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
          }),
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

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mix_player_app/controllers/mix_controller.dart';
import 'package:mix_player_app/controllers/playback_controller.dart';
import 'package:mix_player_app/models/api_models.dart';
import 'package:mix_player_app/services/app_settings.dart';

import 'support/fakes.dart';

/// URL準備の寿命・競合を検証する。外部通信や実時間での長い待機は行わない。
void main() {
  late MixController mix;
  late PlaybackController playback;
  late FakeAudioEngine audio;
  late List<FakeVideoEngine> videos;
  late List<Map<String, String>> videoHeaders;
  late List<String> resolutions;
  late DateTime now;
  FutureOr<http.Response> Function(String)? resolveOverride;

  setUp(() async {
    now = DateTime.utc(2026, 10, 29);
    resolveOverride = null;
    resolutions = [];
    videos = [];
    videoHeaders = [];
    mix =
        MixController()..configure(
          mockApi((request) {
            if (request.url.path == '/stream') {
              final id = jsonDecode(request.body)['video_id'] as String;
              resolutions.add(id);
              return resolveOverride?.call(id) ?? jsonResponse(streamJson(id));
            }
            return jsonResponse(mixJson(['a', 'b', 'c']));
          }),
        );
    await mix.load(defaultMixUrl);
    audio = FakeAudioEngine();
    playback = PlaybackController(
      mix: mix,
      audio: audio,
      now: () => now,
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

  test(
    'Preparation resolves only first URL without loading or playing media',
    () async {
      playback.prepareFirstTrack();
      await drain();
      expect(resolutions, ['a']);
      expect(audio.loadCount, 0);
      expect(audio.playing, isFalse);
      expect(videos, isEmpty);
      expect(playback.currentTrack, isNull);

      now = now.add(const Duration(seconds: 59));
      await playback.playTrack(0);
      await drain();
      expect(resolutions, ['a', 'b', 'c']);
      expect(audio.entries.first.httpHeaders['User-Agent'], 'audio-a');
      expect(audio.playing, isTrue);
    },
  );

  test('Tapping pending preparation shares the same request', () async {
    final response = Completer<http.Response>();
    resolveOverride =
        (id) => id == 'a' ? response.future : jsonResponse(streamJson(id));
    playback.prepareFirstTrack();
    final pending = playback.playTrack(0);
    await drain();
    expect(resolutions, ['a']);
    expect(audio.loadCount, 0);
    response.complete(jsonResponse(streamJson('a')));
    await pending;
    await drain();
    expect(resolutions.where((id) => id == 'a'), hasLength(1));
    expect(audio.playing, isTrue);
  });

  test('Video mode reuses prepared video URL and its own headers', () async {
    await playback.setMode(PlaybackMode.video);
    playback.prepareFirstTrack();
    await drain();
    await playback.playTrack(0);
    expect(resolutions, ['a']);
    expect(videoHeaders.single['User-Agent'], 'video-a');
    expect(videos.single.value.playing, isTrue);
  });

  test(
    'Failed preparation is silent and next tap makes a fresh request',
    () async {
      resolveOverride = (_) => http.Response('', 502);
      playback.prepareFirstTrack();
      await drain();
      expect(playback.error, isNull);
      resolveOverride = null;
      await playback.playTrack(0);
      await drain();
      expect(resolutions.where((id) => id == 'a'), hasLength(2));
      expect(audio.playing, isTrue);
    },
  );

  test(
    'Pending preparation failure falls back once for an active tap',
    () async {
      final response = Completer<http.Response>();
      resolveOverride = (_) => response.future;
      playback.prepareFirstTrack();
      final pending = playback.playTrack(0);
      await drain();
      resolveOverride = null;
      response.complete(http.Response('', 502));
      await pending;
      await drain();
      expect(resolutions.where((id) => id == 'a'), hasLength(2));
      expect(playback.error, isNull);
    },
  );

  // 期限は取得開始ではなく取得完了から数える。境界の60秒では再利用しない。
  test('Cache lasts at most sixty seconds from response completion', () async {
    final response = Completer<http.Response>();
    resolveOverride = (_) => response.future;
    playback.prepareFirstTrack();
    now = now.add(const Duration(seconds: 20));
    response.complete(jsonResponse(streamJson('a')));
    await drain();
    now = now.add(const Duration(seconds: 60));
    resolveOverride = null;
    await playback.playTrack(0);
    await drain();
    expect(resolutions.where((id) => id == 'a'), hasLength(2));
  });

  for (final location in ['audio-query', 'video-query', 'video-path']) {
    test(
      '$location expiry limits preparation to thirty seconds before expiry',
      () async {
        final expires =
            now.add(const Duration(seconds: 45)).millisecondsSinceEpoch ~/ 1000;
        final json = streamJson('a');
        final key = location.startsWith('audio') ? 'audio' : 'video_audio';
        final format = json[key] as Map<String, dynamic>;
        format['url'] =
            location.endsWith('path')
                ? 'https://media.example.test/expire/$expires/file.m3u8'
                : 'https://media.example.test/file?expire=$expires';
        resolveOverride = (_) => jsonResponse(json);
        playback.prepareFirstTrack();
        await drain();
        now = now.add(const Duration(seconds: 15));
        resolveOverride = null;
        await playback.playTrack(0);
        await drain();
        expect(resolutions.where((id) => id == 'a'), hasLength(2));
      },
    );
  }

  test('An already unsafe URL is not reused', () async {
    final expires =
        now.add(const Duration(seconds: 20)).millisecondsSinceEpoch ~/ 1000;
    final json = streamJson('a');
    (json['audio'] as Map<String, dynamic>)['url'] =
        'https://media.example.test/a?expire=$expires';
    resolveOverride = (_) => jsonResponse(json);
    playback.prepareFirstTrack();
    await drain();
    resolveOverride = null;
    await playback.playTrack(0);
    await drain();
    expect(resolutions.where((id) => id == 'a'), hasLength(2));
  });

  test(
    'Stop discards preparation and prevents late playback or retry',
    () async {
      final response = Completer<http.Response>();
      resolveOverride = (_) => response.future;
      playback.prepareFirstTrack();
      final pending = playback.playTrack(0);
      await drain();
      await playback.stop();
      response.complete(http.Response('', 502));
      await pending;
      expect(resolutions, ['a']);
      expect(audio.loadCount, 0);
      expect(playback.error, isNull);
      resolveOverride = null;
      await playback.playTrack(0);
      await drain();
      expect(resolutions.where((id) => id == 'a'), hasLength(2));
    },
  );

  test('Reloading even the same Mix session discards preparation', () async {
    playback.prepareFirstTrack();
    await drain();
    await mix.load(defaultMixUrl);
    await playback.playTrack(0);
    await drain();
    expect(resolutions.where((id) => id == 'a'), hasLength(2));
  });

  test(
    'New API configuration prevents old pending response from starting',
    () async {
      final response = Completer<http.Response>();
      resolveOverride = (_) => response.future;
      playback.prepareFirstTrack();
      final pending = playback.playTrack(0);
      await drain();
      mix.configure(mockApi((_) => jsonResponse(mixJson(['new']))));
      response.complete(jsonResponse(streamJson('a')));
      await pending;
      expect(audio.loadCount, 0);
      expect(playback.currentTrack, isNull);
    },
  );

  test(
    'Late first track preparation cannot replace another selected track',
    () async {
      final response = Completer<http.Response>();
      resolveOverride =
          (id) => id == 'a' ? response.future : jsonResponse(streamJson(id));
      playback.prepareFirstTrack();
      final first = playback.playTrack(0);
      await drain();
      await playback.playTrack(1);
      response.complete(jsonResponse(streamJson('a')));
      await first;
      expect(playback.currentTrack?.videoId, 'b');
      expect(audio.entries.first.track.videoId, 'b');
    },
  );

  test('URL resolution overlaps stop but player load waits for both', () async {
    final stopped = Completer<void>();
    audio.onStop = () => stopped.future;
    final pending = playback.playTrack(0);
    await drain();
    expect(resolutions, ['a']);
    expect(audio.loadCount, 0);
    stopped.complete();
    await pending;
    expect(audio.loadCount, 1);
  });

  test(
    'Resolution failure during delayed cleanup is handled without loading',
    () async {
      final stopped = Completer<void>();
      audio.onStop = () => stopped.future;
      resolveOverride = (_) => http.Response('', 502);
      final pending = playback.playTrack(0);
      await drain();
      stopped.complete();
      await pending;
      expect(audio.loadCount, 0);
      expect(playback.error, contains('502'));
    },
  );

  test(
    'Video resolution overlaps disposal but initialization waits for disposal',
    () async {
      await playback.setMode(PlaybackMode.video);
      await playback.playTrack(0);
      final disposed = Completer<void>();
      videos.single.onDispose = () => disposed.future;
      final pending = playback.playTrack(1);
      await drain();
      expect(resolutions, ['a', 'b']);
      expect(videos, hasLength(1));
      disposed.complete();
      await pending;
      expect(videos, hasLength(2));
      expect(videos.first.disposed, isTrue);
    },
  );

  test(
    'Progress timing is emitted once after position advances and contains no media data',
    () async {
      final messages = <String>[];
      final originalPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) messages.add(message);
      };
      addTearDown(() => debugPrint = originalPrint);
      await playback.playTrack(0);
      await drain();
      expect(messages.where((m) => m.contains('tap_to_progress')), isEmpty);
      audio.positionEvents.add(const Duration(milliseconds: 200));
      audio.positionEvents.add(const Duration(milliseconds: 400));
      expect(
        messages.where((m) => m.contains('tap_to_progress')),
        hasLength(1),
      );
      for (final message in messages) {
        expect(
          message,
          matches(RegExp(r'^mix_startup phase=[a-z_]+ elapsed_ms=\d+$')),
        );
      }
    },
  );

  // 解放開始後に別の曲を続けて選んでも、解放中のFutureを飛び越さない。
  test(
    'Rapid video selections both wait for the outstanding disposal',
    () async {
      await playback.setMode(PlaybackMode.video);
      await playback.playTrack(0);
      final disposed = Completer<void>();
      videos.single.onDispose = () => disposed.future;
      final second = playback.playTrack(1);
      await drain();
      final third = playback.playTrack(2);
      await drain();
      expect(resolutions, ['a', 'b', 'c']);
      expect(videos, hasLength(1));
      disposed.complete();
      await Future.wait([second, third]);
      expect(videos, hasLength(2));
      expect(playback.currentTrack?.videoId, 'c');
    },
  );
}

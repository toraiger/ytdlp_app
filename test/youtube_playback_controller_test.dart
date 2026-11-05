import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mix_player_app/controllers/mix_controller.dart';
import 'package:mix_player_app/controllers/playback_controller.dart';
import 'package:mix_player_app/controllers/youtube_playback_controller.dart';
import 'package:mix_player_app/models/api_models.dart';
import 'package:mix_player_app/services/playback_engines.dart';

import 'support/fakes.dart';

const a = 'aaaaaaaaaaa';
const b = 'bbbbbbbbbbb';
const c = 'ccccccccccc';
const d = 'ddddddddddd';
Uri videoPage(String id, {String? list}) => Uri.https(
  'www.youtube.com',
  '/watch',
  {'v': id, if (list != null) 'list': list},
);

void main() {
  late MixController mix;
  late PlaybackController player;
  late YoutubePlaybackController youtube;
  late FakeAudioEngine audio;
  late List<FakeVideoEngine> videos;
  late List<Map<String, String>> videoHeaders;
  late List<http.Request> requests;
  FutureOr<http.Response> Function(http.Request)? handler;
  setUp(() {
    handler = null;
    requests = [];
    videos = [];
    videoHeaders = [];
    mix =
        MixController()..configure(
          mockApi((request) {
            requests.add(request);
            if (handler != null) return handler!(request);
            if (request.url.path == '/stream') {
              return jsonResponse(
                streamJson(jsonDecode(request.body)['video_id'] as String),
              );
            }
            return jsonResponse(mixJson([a, b, c, d]));
          }),
        );
    audio = FakeAudioEngine();
    player = PlaybackController(
      mix: mix,
      audio: audio,
      videoFactory: (_, headers) {
        videoHeaders.add(headers);
        final video = FakeVideoEngine();
        videos.add(video);
        return video;
      },
    );
    youtube = YoutubePlaybackController(mix: mix, playback: player)
      ..setVisible(true);
  });
  tearDown(() async {
    youtube.dispose();
    player.dispose();
    mix.dispose();
    await drain();
  });
  List<String> resolvedIds() =>
      requests
          .where((r) => r.url.path == '/stream')
          .map((r) => jsonDecode(r.body)['video_id'] as String)
          .toList();

  test(
    'Navigation request does not play; committed page resolves exactly once',
    () async {
      youtube.navigationStarted(videoPage(a));
      await drain();
      expect(requests, isEmpty);
      await youtube.pageCommitted(videoPage(a));
      await youtube.pageCommitted(Uri.parse('${videoPage(a)}&t=20'));
      await drain();
      expect(resolvedIds(), [a]);
      expect(audio.playing, isTrue);
      expect(audio.entries.single.track.title, 'Track $a');
      expect(audio.entries.single.httpHeaders['User-Agent'], 'audio-$a');
      expect(
        audio.entries.single.httpHeaders.containsKey('X-API-Key'),
        isFalse,
      );
      expect(player.isDirect, isTrue);
    },
  );

  test(
    'Single video does not play or extend the previous Mix at completion',
    () async {
      await mix.load(
        videoPage(a, list: 'RD$a').toString(),
        prepareFirstTrack: false,
      );
      await youtube.pageCommitted(videoPage(b));
      audio.stateEvents.add(const AudioStatus(false, AudioPhase.completed));
      await drain();
      expect(audio.entries, hasLength(1));
      expect(resolvedIds(), [b]);
      expect(requests.where((r) => r.url.path.endsWith('extend')), isEmpty);
      expect(player.currentTrack?.videoId, b);
      expect(player.isPlaying, isFalse);
    },
  );

  test(
    'Mix starts selected middle track without preloading the first track',
    () async {
      await youtube.pageCommitted(videoPage(b, list: 'RD$a'));
      await drain();
      expect(requests.first.url.path, '/mix');
      expect(jsonDecode(requests.first.body), {
        'url': videoPage(b, list: 'RD$a').toString(),
        'count': 20,
      });
      expect(resolvedIds(), [b, c, d]);
      expect(audio.entries.first.track.videoId, b);
      expect(player.currentIndex, 1);
      expect(player.isDirect, isFalse);
      expect(youtube.error, isNull);
    },
  );

  test(
    'Next/previous and automatic transition follow pages without resolving again',
    () async {
      await youtube.pageCommitted(videoPage(a, list: 'RD$a'));
      await drain();
      final loads = audio.loadCount;
      audio.advance(1);
      await drain();
      expect(youtube.pageToLoad, videoPage(b, list: 'RD$a'));
      final before = requests.length;
      youtube.navigationStarted(youtube.pageToLoad!);
      await youtube.pageCommitted(youtube.pageToLoad!);
      await drain();
      expect(requests.length, before);
      expect(audio.loadCount, loads);
      expect(player.currentIndex, 1);
      await player.previous();
      expect(youtube.pageToLoad, videoPage(a, list: 'RD$a'));
      await youtube.pageCommitted(youtube.pageToLoad!);
      await player.next();
      expect(youtube.pageToLoad, videoPage(b, list: 'RD$a'));
    },
  );

  test(
    'Selecting a loaded track in the same Mix reuses its queue and session',
    () async {
      await youtube.pageCommitted(videoPage(a, list: 'RD$a'));
      await drain();
      final loads = audio.loadCount;
      await youtube.pageCommitted(videoPage(b, list: 'RD$a'));
      expect(requests.where((r) => r.url.path == '/mix'), hasLength(1));
      expect(audio.loadCount, loads);
      expect(player.currentIndex, 1);
    },
  );

  test(
    'Latest committed single video wins when API responses finish out of order',
    () async {
      final first = Completer<http.Response>();
      handler =
          (request) =>
              jsonDecode(request.body)['video_id'] == a
                  ? first.future
                  : jsonResponse(streamJson(b));
      final old = youtube.pageCommitted(videoPage(a));
      await drain();
      expect(player.isResolvingUrl, isTrue);
      await youtube.pageCommitted(videoPage(b));
      first.complete(jsonResponse(streamJson(a)));
      await old;
      await drain();
      expect(player.currentTrack?.videoId, b);
      expect(audio.entries.single.track.videoId, b);
      expect(youtube.pageUri, videoPage(b));
      expect(youtube.isSelecting, isFalse);
    },
  );

  test('Late Mix response cannot replace a newer single selection', () async {
    final oldMix = Completer<http.Response>();
    handler =
        (request) =>
            request.url.path == '/mix'
                ? oldMix.future
                : jsonResponse(streamJson(b));
    final old = youtube.pageCommitted(videoPage(a, list: 'RD$a'));
    await drain();
    await youtube.pageCommitted(videoPage(b));
    oldMix.complete(jsonResponse(mixJson([a, c, d])));
    await old;
    await drain();
    expect(mix.items, isEmpty);
    expect(player.currentTrack?.videoId, b);
    expect(audio.entries, hasLength(1));
    expect(resolvedIds(), [b]);
  });

  test(
    'Cancelling a pending Mix prevents late autoplay and supports retry',
    () async {
      final oldMix = Completer<http.Response>();
      handler = (_) => oldMix.future;
      final pending = youtube.pageCommitted(videoPage(a, list: 'RD$a'));
      await drain();
      youtube.cancelSelection();
      oldMix.complete(jsonResponse(mixJson([a, b, c])));
      await pending;
      await drain();
      expect(audio.playing, isFalse);
      expect(youtube.isSelecting, isFalse);
      expect(mix.items, isEmpty);
      handler = null;
      await youtube.retry();
      expect(audio.playing, isTrue);
    },
  );

  test(
    'Background and hidden pages defer follow until foreground/reopen',
    () async {
      await youtube.pageCommitted(videoPage(a, list: 'RD$a'));
      await drain();
      final before = youtube.pageRevision;
      youtube.setForeground(false);
      audio.advance(1);
      await drain();
      expect(youtube.pageRevision, before);
      youtube.setForeground(true);
      expect(youtube.pageToLoad, videoPage(b, list: 'RD$a'));
      await youtube.pageCommitted(youtube.pageToLoad!);
      youtube.setVisible(false);
      audio.advance(2);
      await drain();
      expect(youtube.pageUri, videoPage(b, list: 'RD$a'));
      youtube.setVisible(true);
      expect(youtube.pageToLoad, videoPage(c, list: 'RD$a'));
    },
  );

  test(
    'Missing selected Mix track never falls back to a different first track',
    () async {
      handler = (_) => jsonResponse(mixJson([b, c, d]));
      await youtube.pageCommitted(videoPage(a, list: 'RD$a'));
      expect(youtube.error, contains('含まれていません'));
      expect(audio.playing, isFalse);
      expect(resolvedIds(), isEmpty);
      handler = null;
      await youtube.retry();
      expect(player.currentTrack?.videoId, a);
      expect(youtube.error, isNull);
    },
  );

  test('Private API failure remains redacted and retry succeeds', () async {
    handler = (_) => http.Response('dummy-private-cookie', 403);
    await youtube.pageCommitted(videoPage(a));
    expect(youtube.error, contains('403'));
    expect(youtube.error, isNot(contains('dummy-private-cookie')));
    handler = null;
    await youtube.retry();
    expect(audio.playing, isTrue);
    expect(youtube.error, isNull);
  });

  test(
    'Single video inherits video mode and media headers without auto-next',
    () async {
      await player.setMode(PlaybackMode.video);
      await youtube.pageCommitted(videoPage(a));
      expect(videos.single.value.playing, isTrue);
      expect(videoHeaders.single['User-Agent'], 'video-$a');
      videos.single.emit(
        const VideoStatus(
          initialized: true,
          completed: true,
          duration: Duration(seconds: 120),
        ),
      );
      await drain();
      expect(videos, hasLength(1));
      expect(requests.where((r) => r.url.path == '/mix'), isEmpty);
    },
  );

  test(
    'Cached single failure refreshes once and retains API resolving semantics',
    () async {
      await mix.api.resolveStream(a);
      var failed = false;
      audio.onLoad = (_) {
        if (!failed) {
          failed = true;
          throw StateError('expired media');
        }
      };
      await youtube.pageCommitted(videoPage(a));
      expect(resolvedIds(), [a, a]);
      expect(audio.playing, isTrue);
      expect(player.isDirect, isTrue);
    },
  );

  test('Navigation to search or Google login does not resolve video', () async {
    for (final url in [
      'https://www.youtube.com/results?search_query=music',
      'https://accounts.google.com/',
      'https://evil.test/watch?v=$a',
    ]) {
      await youtube.pageCommitted(Uri.parse(url));
    }
    expect(requests, isEmpty);
  });

  test(
    'API reconfiguration invalidates a pending selection and busy state',
    () async {
      final response = Completer<http.Response>();
      handler = (_) => response.future;
      final pending = youtube.pageCommitted(videoPage(a));
      await drain();
      await player.stop();
      mix.configure(mockApi((_) => jsonResponse(streamJson(b))));
      response.complete(jsonResponse(streamJson(a)));
      await pending;
      expect(youtube.isSelecting, isFalse);
      expect(audio.playing, isFalse);
    },
  );
  test(
    'Consent redirects during page follow never restart the current track',
    () async {
      await youtube.pageCommitted(videoPage(a, list: 'RD$a'));
      await drain();
      audio.advance(1);
      await drain();
      audio.positionEvents.add(const Duration(seconds: 15));
      final loads = audio.loadCount;
      final requestsBefore = requests.length;
      final consent = Uri.https('consent.youtube.com', '/m');
      youtube.navigationStarted(consent);
      await youtube.pageCommitted(consent);
      youtube.navigationStarted(videoPage(b, list: 'RD$a'));
      await youtube.pageCommitted(videoPage(b, list: 'RD$a'));
      await drain();
      expect(requests.length, requestsBefore);
      expect(audio.loadCount, loads);
      expect(player.position, const Duration(seconds: 15));
    },
  );
}

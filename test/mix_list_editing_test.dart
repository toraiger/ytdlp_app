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
  late PlaybackController player;
  late FakeAudioEngine audio;
  late List<FakeVideoEngine> videos;
  late List<String> streams;
  FutureOr<http.Response> Function(http.Request)? override;
  setUp(() async {
    streams = [];
    videos = [];
    override = null;
    mix =
        MixController()..configure(
          mockApi((r) {
            if (r.url.path == '/stream') {
              streams.add(jsonDecode(r.body)['video_id'] as String);
            }
            return override?.call(r) ??
                jsonResponse(
                  r.url.path == '/stream'
                      ? streamJson(jsonDecode(r.body)['video_id'] as String)
                      : mixJson(['a', 'b', 'c', 'd', 'e']),
                );
          }),
        );
    await mix.load(defaultMixUrl);
    audio = FakeAudioEngine();
    player = PlaybackController(
      mix: mix,
      audio: audio,
      videoFactory: (_, __) {
        final video = FakeVideoEngine();
        videos.add(video);
        return video;
      },
    );
  });
  tearDown(() async {
    player.dispose();
    mix.dispose();
    await drain();
  });
  List<String> ids() => mix.items.map((e) => e.videoId).toList();

  test(
    'Move uses stable IDs and preserves edits when append includes duplicates',
    () async {
      final revision = mix.revision;
      expect(mix.moveTrack('c', 0), isTrue);
      expect(ids(), ['c', 'a', 'b', 'd', 'e']);
      final removed = mix.removeTrack('a')!;
      await mix.extend();
      expect(ids(), ['c', 'b', 'd', 'e']);
      expect(mix.revision, revision);
      expect(mix.restoreTrack(removed), isTrue);
      expect(ids(), ['c', 'a', 'b', 'd', 'e']);
      expect(mix.restoreTrack(removed), isFalse);
    },
  );
  test(
    'New successful Mix resets exclusions, failed reload retains edits and invalidates undo',
    () async {
      final removed = mix.removeTrack('b')!;
      mix.moveTrack('e', 0);
      override = (_) => http.Response('', 503);
      expect(await mix.load(defaultMixUrl), isFalse);
      expect(ids(), ['e', 'a', 'c', 'd']);
      override = null;
      await mix.extend();
      expect(ids(), ['e', 'a', 'c', 'd']);
      expect(mix.restoreTrack(removed), isFalse);
      await mix.load(defaultMixUrl);
      expect(ids(), ['a', 'b', 'c', 'd', 'e']);
    },
  );
  test(
    'In-flight extension merges into current order and excludes deleted songs',
    () async {
      final response = Completer<http.Response>();
      override =
          (r) =>
              r.url.path.endsWith('/extend')
                  ? response.future
                  : jsonResponse(streamJson('a'));
      final extending = mix.extend();
      mix.removeTrack('b');
      mix.moveTrack('d', 0);
      response.complete(jsonResponse(mixJson(['a', 'b', 'c', 'd', 'e', 'f'])));
      await extending;
      expect(ids(), ['d', 'a', 'c', 'e', 'f']);
    },
  );
  test(
    'Emptying a list cancels late additions; undo restores one song without autoplay',
    () async {
      final response = Completer<http.Response>();
      override = (_) => response.future;
      final pending = mix.extend();
      RemovedMixTrack? removed;
      for (final id in ids()) {
        removed = mix.removeTrack(id);
      }
      response.complete(jsonResponse(mixJson(['a', 'b', 'f'])));
      await pending;
      await drain();
      expect(ids(), isEmpty);
      override = null;
      expect(mix.restoreTrack(removed!), isTrue);
      await drain();
      expect(ids(), ['e']);
      expect(audio.playing, isFalse);
    },
  );
  test(
    'Reorder upcoming native sources without reloading current song or resetting time',
    () async {
      await player.playTrack(0);
      await drain();
      audio.positionEvents.add(const Duration(seconds: 30));
      final loads = audio.loadCount;
      mix.moveTrack('c', 1);
      await drain();
      expect(audio.entries.map((e) => e.track.videoId), ['a', 'c', 'b']);
      expect(player.currentTrack?.videoId, 'a');
      expect(player.position, const Duration(seconds: 30));
      expect(audio.loadCount, loads);
      expect(audio.playing, isTrue);
      await player.next();
      expect(player.currentTrack?.videoId, 'c');
      expect(audio.entries.first.httpHeaders['User-Agent'], 'audio-a');
    },
  );
  test(
    'Editing preserves resolved duration and format for retained sources',
    () async {
      override = (request) {
        if (request.url.path != '/stream') return jsonResponse(mixJson(ids()));
        final id = jsonDecode(request.body)['video_id'] as String;
        final data = streamJson(id);
        data['duration'] = id == 'a' ? 237.125 : 235.25;
        (data['audio'] as Map<String, dynamic>).addAll(<String, Object>{
          'format_id': id == 'a' ? '140' : '141',
          'protocol': 'https',
          'acodec': 'mp4a.40.2',
        });
        return jsonResponse(data);
      };
      final resolved = await mix.api.resolveStream('a');
      expect(resolved.duration, const Duration(milliseconds: 237125));
      await player.playTrack(0);
      await drain();
      expect(player.error, isNull);
      expect(
        audio.entries.first.streamDuration,
        const Duration(milliseconds: 237125),
      );
      final loads = audio.loadCount;
      mix.moveTrack('c', 1);
      await drain();
      expect(
        player.diagnostics.apiDuration,
        const Duration(milliseconds: 237125),
      );
      expect(player.diagnostics.formatId, '140');
      expect(player.diagnostics.audioCodec, 'mp4a.40.2');
      expect(audio.loadCount, loads);
      await player.next();
      expect(player.currentTrack?.videoId, 'c');
      expect(
        player.diagnostics.apiDuration,
        const Duration(milliseconds: 235250),
      );
      expect(player.diagnostics.formatId, '141');
      final removed = mix.removeTrack('b')!;
      await drain();
      mix.restoreTrack(removed);
      await drain();
      expect(
        player.diagnostics.apiDuration,
        const Duration(milliseconds: 235250),
      );
      expect(player.diagnostics.mediaProtocol, 'https');
      expect(player.diagnostics.audioCodec, 'mp4a.40.2');
      expect(audio.loadCount, loads);
    },
  );
  test(
    'Moving current song remaps its index and native prefix without seek or reload',
    () async {
      await player.playTrack(0);
      await drain();
      await player.playTrack(1);
      await drain();
      audio.positionEvents.add(const Duration(seconds: 35));
      final loads = audio.loadCount;
      mix.moveTrack('b', 3);
      await drain();
      expect(player.currentTrack?.videoId, 'b');
      expect(player.currentIndex, 3);
      expect(player.position, const Duration(seconds: 35));
      expect(audio.loadCount, loads);
      expect(audio.entries[audio.snapshot.index!].track.videoId, 'b');
      await player.next();
      expect(player.currentTrack?.videoId, 'e');
    },
  );
  test(
    'Removing a queued future song keeps current playback and skips it',
    () async {
      await player.playTrack(0);
      await drain();
      audio.positionEvents.add(const Duration(seconds: 45));
      final loads = audio.loadCount;
      mix.removeTrack('b');
      await drain();
      expect(player.position, const Duration(seconds: 45));
      expect(audio.loadCount, loads);
      expect(audio.entries.map((e) => e.track.videoId), ['a', 'c', 'd']);
      audio.advance(1);
      await drain();
      expect(player.currentTrack?.videoId, 'c');
    },
  );
  test(
    'Deleting current song plays the successor, undo does not rewind it',
    () async {
      await player.playTrack(1);
      await drain();
      final removed = mix.removeTrack('b')!;
      await drain();
      expect(player.currentTrack?.videoId, 'c');
      expect(player.isPlaying, isTrue);
      audio.positionEvents.add(const Duration(seconds: 12));
      mix.restoreTrack(removed);
      await drain();
      expect(player.currentTrack?.videoId, 'c');
      expect(player.position, const Duration(seconds: 12));
    },
  );
  test(
    'Deleting paused current song loads the successor without briefly playing it',
    () async {
      await player.playTrack(1);
      await drain();
      await player.togglePlay();
      mix.removeTrack('b');
      await drain();
      expect(player.currentTrack?.videoId, 'c');
      expect(audio.playing, isFalse);
      expect(player.isPlaying, isFalse);
    },
  );
  test(
    'Deleting the last current song stops, even with previous songs remaining',
    () async {
      await player.playTrack(4);
      await drain();
      mix.removeTrack('e');
      await drain();
      expect(player.currentTrack, isNull);
      expect(audio.playing, isFalse);
    },
  );
  test(
    'Pending prefetch of deleted song cannot enter the edited queue',
    () async {
      final response = Completer<http.Response>();
      override =
          (r) =>
              jsonDecode(r.body)['video_id'] == 'b'
                  ? response.future
                  : jsonResponse(
                    streamJson(jsonDecode(r.body)['video_id'] as String),
                  );
      await player.playTrack(0);
      await drain();
      mix.removeTrack('b');
      await drain();
      response.complete(jsonResponse(streamJson('b')));
      await drain();
      expect(audio.entries.map((e) => e.track.videoId), ['a', 'c', 'd']);
      expect(player.currentTrack?.videoId, 'a');
    },
  );
  test(
    'Pending first preparation cannot restore the old first song after a move',
    () async {
      final response = Completer<http.Response>();
      override =
          (r) =>
              r.url.path == '/mix'
                  ? jsonResponse(mixJson(['a', 'b', 'c']))
                  : jsonDecode(r.body)['video_id'] == 'a'
                  ? response.future
                  : jsonResponse(
                    streamJson(jsonDecode(r.body)['video_id'] as String),
                  );
      await mix.load(defaultMixUrl);
      await drain();
      mix.moveTrack('b', 0);
      await drain();
      response.complete(jsonResponse(streamJson('a')));
      await drain();
      expect(audio.entries.first.track.videoId, 'b');
      expect(audio.playing, isFalse);
      await player.playTrack(0);
      expect(player.currentTrack?.videoId, 'b');
    },
  );
  test(
    'Video reordering preserves the engine and position; deleting paused video stays paused',
    () async {
      await player.setMode(PlaybackMode.video);
      await player.playTrack(1);
      videos.single.emit(
        const VideoStatus(
          initialized: true,
          playing: true,
          position: Duration(seconds: 20),
          duration: Duration(seconds: 120),
        ),
      );
      final old = videos.single;
      mix.moveTrack('b', 2);
      await drain();
      expect(videos, hasLength(1));
      expect(old.disposed, isFalse);
      expect(player.position, const Duration(seconds: 20));
      await player.togglePlay();
      mix.removeTrack('b');
      await drain();
      expect(player.currentTrack?.videoId, 'd');
      expect(videos.last.value.playing, isFalse);
    },
  );
  test('Editing a Mix leaves a standalone YouTube video untouched', () async {
    await player.playYoutubeVideo('aaaaaaaaaaa');
    final loads = audio.loadCount;
    mix.moveTrack('b', 0);
    mix.removeTrack('a');
    await drain();
    expect(player.currentTrack?.videoId, 'aaaaaaaaaaa');
    expect(audio.loadCount, loads);
    expect(audio.playing, isTrue);
  });
  test('An already executing stale append is removed after the edit', () async {
    final appended = Completer<void>();
    audio.onAppend =
        (entry) => entry.track.videoId == 'b' ? appended.future : null;
    await player.playTrack(0);
    await drain();
    mix.removeTrack('b');
    appended.complete();
    await drain();
    expect(audio.entries.map((e) => e.track.videoId), ['a', 'c', 'd']);
    expect(player.currentTrack?.videoId, 'a');
  });
  test(
    'Completion during a queue mutation advances according to the new order',
    () async {
      await player.playTrack(0);
      await drain();
      audio.onRemove = (_) {
        audio.stateEvents.add(const AudioStatus(false, AudioPhase.completed));
      };
      mix.removeTrack('b');
      await drain();
      expect(player.currentTrack?.videoId, 'c');
      expect(player.isPlaying, isTrue);
    },
  );
  test(
    'A newer track selection wins over an in-flight native queue edit',
    () async {
      await player.playTrack(0);
      await drain();
      final removed = Completer<void>();
      audio.onRemove = (_) => removed.future;
      mix.removeTrack('b');
      await drain();
      final selected = player.playTrack(2);
      removed.complete();
      await selected;
      await drain();
      expect(player.currentTrack?.videoId, 'd');
      expect(audio.entries.first.track.videoId, 'd');
      expect(player.isUpdatingQueue, isFalse);
    },
  );
  test(
    'A cached next selection during an edit is not advanced again by page reconciliation',
    () async {
      await player.playTrack(0);
      await drain();
      final removed = Completer<void>();
      audio.onRemove = (_) => removed.future;
      mix.removeTrack('c');
      await drain();
      final next = player.next();
      removed.complete();
      await next;
      await drain();
      expect(player.currentTrack?.videoId, 'b');
      expect(audio.entries.first.track.videoId, 'b');
    },
  );
  test(
    'Native edit failure stops safely and permits another selection',
    () async {
      await player.playTrack(0);
      await drain();
      audio.onRemove = (_) => throw StateError('native failure');
      mix.removeTrack('b');
      await drain();
      expect(player.currentTrack, isNull);
      expect(player.error, contains('更新できません'));
      audio.onRemove = null;
      await player.playTrack(0);
      expect(player.isPlaying, isTrue);
    },
  );
  test(
    'Undo while a paused deletion is resolving does not enable autoplay',
    () async {
      final response = Completer<http.Response>();
      override =
          (r) =>
              r.url.path == '/stream' && jsonDecode(r.body)['video_id'] == 'c'
                  ? response.future
                  : jsonResponse(
                    r.url.path == '/stream'
                        ? streamJson(jsonDecode(r.body)['video_id'] as String)
                        : mixJson(['a', 'b', 'c', 'd']),
                  );
      await player.playTrack(1);
      await player.togglePlay();
      final removed = mix.removeTrack('b')!;
      await drain();
      expect(player.isBusy, isTrue);
      mix.restoreTrack(removed);
      response.complete(jsonResponse(streamJson('c')));
      await drain();
      expect(player.currentTrack?.videoId, 'c');
      expect(player.isPlaying, isFalse);
      expect(audio.playing, isFalse);
    },
  );
  test(
    'A second edit retains a completion received during the first edit',
    () async {
      await player.playTrack(0);
      await drain();
      final gate = Completer<void>();
      var signalled = false;
      audio.onRemove = (_) async {
        if (!signalled) {
          signalled = true;
          audio.stateEvents.add(const AudioStatus(false, AudioPhase.completed));
          await gate.future;
        }
      };
      mix.removeTrack('b');
      await drain();
      mix.moveTrack('d', 1);
      gate.complete();
      await drain();
      expect(player.currentTrack?.videoId, 'd');
      expect(player.isPlaying, isTrue);
    },
  );
}

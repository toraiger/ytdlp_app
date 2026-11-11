import "dart:async";
import "dart:convert";

import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:mix_player_app/controllers/mix_controller.dart";
import "package:mix_player_app/controllers/playback_controller.dart";
import "package:mix_player_app/controllers/youtube_playback_controller.dart";
import "package:mix_player_app/models/api_models.dart";
import "package:mix_player_app/models/mix_queue_item.dart";
import "package:mix_player_app/models/youtube_video_page.dart";
import "package:mix_player_app/services/api_client.dart";
import "package:mix_player_app/services/playback_engines.dart";

import "support/fakes.dart";

void main() {
  const firstVideoId = "aaaaaaaaaaa";
  const secondVideoId = "bbbbbbbbbbb";
  const thirdVideoId = "ccccccccccc";
  const addedVideoId = "ddddddddddd";
  const lastVideoId = "eeeeeeeeeee";
  const mixVideoIds = [firstVideoId, secondVideoId, thirdVideoId];
  final mixPage = YoutubeVideoPage(
    videoId: firstVideoId,
    mixId: "RD$firstVideoId",
  );
  late MixController mix;
  late PlaybackController playback;
  late YoutubePlaybackController youtube;
  late FakeAudioEngine audio;
  late List<FakeVideoEngine> videos;
  late List<String> streamRequests;
  FutureOr<http.Response> Function(http.Request)? handler;

  setUp(() {
    handler = null;
    videos = [];
    streamRequests = [];
    mix =
        MixController()..configure(
          mockApi((request) {
            if (request.url.path == "/stream") {
              streamRequests.add(
                jsonDecode(request.body)["video_id"] as String,
              );
            }
            return handler?.call(request) ??
                jsonResponse(
                  request.url.path == "/stream"
                      ? streamJson(
                        jsonDecode(request.body)["video_id"] as String,
                      )
                      : mixJson(mixVideoIds),
                );
          }),
        );
    audio = FakeAudioEngine();
    playback = PlaybackController(
      mix: mix,
      audio: audio,
      videoFactory: (uri, headers) {
        final video = FakeVideoEngine();
        videos.add(video);
        return video;
      },
    );
    youtube = YoutubePlaybackController(mix: mix, playback: playback)
      ..setVisible(true);
  });
  tearDown(() async {
    youtube.dispose();
    playback.dispose();
    mix.dispose();
    await drain();
  });

  List<String> videoIds() => mix.items.map((track) => track.videoId).toList();
  Future<bool> add(String videoId, QueueInsertPosition position) =>
      youtube.addToQueue(
        YoutubeVideoTarget(
          page: YoutubeVideoPage(videoId: videoId),
          title: "Video $videoId",
        ),
        position,
      );
  Future<void> playMix() async {
    await youtube.pageCommitted(mixPage.uri);
    await drain();
  }

  test(
    "Next and last insertions retain the active source, time and pause state",
    () async {
      await playMix();
      audio.positionEvents.add(const Duration(seconds: 25));
      await playback.togglePlay();
      final activeEntryId = playback.currentEntryId;
      final loadCount = audio.loadCount;
      final stopCount = audio.stopCount;
      expect(await add(addedVideoId, QueueInsertPosition.next), isTrue);
      await drain();
      expect(await add(lastVideoId, QueueInsertPosition.last), isTrue);
      await drain();
      expect(videoIds(), [
        firstVideoId,
        addedVideoId,
        secondVideoId,
        thirdVideoId,
        lastVideoId,
      ]);
      expect(playback.currentEntryId, activeEntryId);
      expect(playback.position, const Duration(seconds: 25));
      expect(playback.isPlaying, isFalse);
      expect(audio.loadCount, loadCount);
      expect(audio.stopCount, stopCount);
      expect(mix.items[1].title, "Track $addedVideoId");
      expect(audio.entries[1].track.videoId, addedVideoId);
    },
  );

  test(
    "Repeated current videos have separate IDs and play as separate occurrences",
    () async {
      await playMix();
      final originalId = playback.currentEntryId;
      await add(firstVideoId, QueueInsertPosition.next);
      await add(firstVideoId, QueueInsertPosition.next);
      await drain();
      final entryIds = mix.queueItems.map((item) => item.entryId).toList();
      expect(entryIds.toSet().length, entryIds.length);
      expect(videoIds().take(3), [firstVideoId, firstVideoId, firstVideoId]);
      expect(playback.currentEntryId, originalId);
      await playback.next();
      expect(playback.currentEntryId, entryIds[1]);
      expect(youtube.pageUri.queryParameters.containsKey("list"), isFalse);
      await playback.next();
      expect(playback.currentEntryId, entryIds[2]);
      expect(
        streamRequests.where((videoId) => videoId == firstVideoId).length,
        1,
      );
    },
  );

  test(
    "Duplicate entries can move, delete and undo independently of the active occurrence",
    () async {
      await playMix();
      await add(firstVideoId, QueueInsertPosition.next);
      await add(firstVideoId, QueueInsertPosition.last);
      await drain();
      final originalId = playback.currentEntryId;
      final lastId = mix.queueItems.last.entryId;
      expect(mix.moveTrack(lastId, 1), isTrue);
      await drain();
      final removed = mix.removeTrack(lastId)!;
      await drain();
      expect(playback.currentEntryId, originalId);
      expect(mix.restoreTrack(removed), isTrue);
      await drain();
      expect(mix.queueItems[1].entryId, lastId);
      expect(playback.currentEntryId, originalId);
      mix.removeTrack(originalId!);
      await drain();
      expect(playback.currentEntryId, lastId);
      expect(playback.currentTrack?.videoId, firstVideoId);
    },
  );

  test(
    "Sequential requests retain acceptance order and newest next is first",
    () async {
      await playMix();
      final response = Completer<http.Response>();
      handler = (request) => response.future;
      final firstAddition = add(addedVideoId, QueueInsertPosition.next);
      final secondAddition = add(lastVideoId, QueueInsertPosition.next);
      await drain();
      expect(streamRequests, isNot(contains(lastVideoId)));
      handler = null;
      response.complete(jsonResponse(streamJson(addedVideoId)));
      expect(await firstAddition, isTrue);
      expect(await secondAddition, isTrue);
      await drain();
      expect(videoIds(), [
        firstVideoId,
        lastVideoId,
        addedVideoId,
        secondVideoId,
        thirdVideoId,
      ]);
      expect(audio.entries.take(3).map((entry) => entry.track.videoId), [
        firstVideoId,
        lastVideoId,
        addedVideoId,
      ]);
    },
  );

  for (final mode in PlaybackMode.values) {
    test(
      "Standalone $mode promotes to a manual queue without reloading",
      () async {
        await mix.load(mixPage.uri.toString(), prepareFirstTrack: false);
        await playback.setMode(mode);
        await youtube.pageCommitted(
          YoutubeVideoPage(videoId: addedVideoId).uri,
        );
        if (mode == PlaybackMode.audio) {
          audio.positionEvents.add(const Duration(seconds: 32));
        } else {
          await playback.seek(const Duration(seconds: 32));
        }
        await playback.togglePlay();
        final loadCount = audio.loadCount;
        final videoCount = videos.length;
        expect(await add(lastVideoId, QueueInsertPosition.last), isTrue);
        await drain();
        expect(videoIds(), [addedVideoId, lastVideoId]);
        expect(mix.canExtend, isFalse);
        expect(playback.isDirect, isFalse);
        expect(playback.currentIndex, 0);
        expect(playback.currentTrack?.videoId, addedVideoId);
        expect(playback.position, const Duration(seconds: 32));
        expect(playback.isPlaying, isFalse);
        expect(audio.loadCount, loadCount);
        expect(videos.length, videoCount);
        await playback.next();
        expect(playback.currentTrack?.videoId, lastVideoId);
        expect(youtube.pageUri.queryParameters["v"], lastVideoId);
        expect(youtube.pageUri.queryParameters.containsKey("list"), isFalse);
      },
    );
  }

  test(
    "Empty queues and stopped lists receive additions without autoplay",
    () async {
      expect(await add(addedVideoId, QueueInsertPosition.last), isTrue);
      await drain();
      expect(await add(lastVideoId, QueueInsertPosition.next), isTrue);
      await drain();
      expect(videoIds(), [lastVideoId, addedVideoId]);
      expect(playback.currentTrack, isNull);
      expect(audio.playing, isFalse);
      await mix.load(mixPage.uri.toString(), prepareFirstTrack: false);
      await add(addedVideoId, QueueInsertPosition.next);
      await drain();
      expect(videoIds().first, addedVideoId);
      expect(playback.currentTrack, isNull);
    },
  );

  test("Mix extension preserves manually inserted repeats", () async {
    await playMix();
    await add(firstVideoId, QueueInsertPosition.last);
    await add(firstVideoId, QueueInsertPosition.last);
    final manualIds =
        mix.queueItems
            .skip(mixVideoIds.length)
            .map((item) => item.entryId)
            .toList();
    await mix.extend();
    expect(videoIds(), [...mixVideoIds, firstVideoId, firstVideoId]);
    expect(
      mix.queueItems.skip(mixVideoIds.length).map((item) => item.entryId),
      manualIds,
    );
  });

  test(
    "API failure leaves the list and playback unchanged and later requests work",
    () async {
      await playMix();
      final activeEntryId = playback.currentEntryId;
      handler = (request) => http.Response("", 503);
      await expectLater(
        add(addedVideoId, QueueInsertPosition.next),
        throwsA(isA<ApiFailure>()),
      );
      expect(videoIds(), mixVideoIds);
      expect(playback.currentEntryId, activeEntryId);
      expect(playback.isPlaying, isTrue);
      handler = null;
      expect(await add(lastVideoId, QueueInsertPosition.last), isTrue);
    },
  );

  test("Missing playable media cannot create a queue item", () async {
    handler = (request) => jsonResponse({"video_id": addedVideoId});
    await expectLater(
      add(addedVideoId, QueueInsertPosition.next),
      throwsA(isA<ApiFailure>()),
    );
    expect(mix.items, isEmpty);
  });

  for (final replacement in ["reload", "configure", "selection"]) {
    test("A pending addition is discarded after $replacement", () async {
      await playMix();
      final response = Completer<http.Response>();
      handler = (request) => response.future;
      final addition = add(addedVideoId, QueueInsertPosition.next);
      await drain();
      handler = null;
      switch (replacement) {
        case "reload":
          await mix.load(mixPage.uri.toString(), prepareFirstTrack: false);
        case "configure":
          mix.configure(
            mockApi((request) => jsonResponse(mixJson(mixVideoIds))),
          );
        case "selection":
          await youtube.pageCommitted(
            YoutubeVideoPage(videoId: lastVideoId).uri,
          );
      }
      response.complete(jsonResponse(streamJson(addedVideoId)));
      expect(await addition, isFalse);
      expect(videoIds(), isNot(contains(addedVideoId)));
    });
  }

  test(
    "Completion while resolving an addition uses the current track at insertion",
    () async {
      await playMix();
      final response = Completer<http.Response>();
      handler = (request) => response.future;
      final addition = add(addedVideoId, QueueInsertPosition.next);
      await drain();
      audio.indexEvents.add(1);
      await drain();
      handler = null;
      response.complete(jsonResponse(streamJson(addedVideoId)));
      expect(await addition, isTrue);
      await drain();
      expect(playback.currentTrack?.videoId, secondVideoId);
      expect(videoIds(), [
        firstVideoId,
        secondVideoId,
        addedVideoId,
        thirdVideoId,
      ]);
    },
  );

  test(
    "A pending native append cannot jump ahead of a newly inserted next item",
    () async {
      final append = Completer<void>();
      audio.onAppend = (entry) async {
        if (entry.track.videoId == secondVideoId) await append.future;
      };
      await youtube.pageCommitted(mixPage.uri);
      await drain();
      expect(await add(addedVideoId, QueueInsertPosition.next), isTrue);
      append.complete();
      await drain();
      expect(audio.entries.map((entry) => entry.track.videoId), [
        firstVideoId,
        addedVideoId,
        secondVideoId,
      ]);
      expect(playback.currentTrack?.videoId, firstVideoId);
    },
  );

  test(
    "An accepted addition waits for a concurrent next-track activation",
    () async {
      await playMix();
      final response = Completer<http.Response>();
      final seeking = Completer<void>();
      audio.onSeek = (index) => seeking.future;
      handler = (request) => response.future;
      var additionFinished = false;
      final addition = add(addedVideoId, QueueInsertPosition.next).then((
        added,
      ) {
        additionFinished = true;
        return added;
      });
      await drain();
      final advancing = playback.next();
      await drain();
      expect(playback.isBusy, isTrue);
      handler = null;
      response.complete(jsonResponse(streamJson(addedVideoId)));
      await drain();
      expect(additionFinished, isFalse);
      seeking.complete();
      await advancing;
      expect(await addition, isTrue);
      await drain();
      expect(playback.currentTrack?.videoId, secondVideoId);
      expect(videoIds(), [
        firstVideoId,
        secondVideoId,
        addedVideoId,
        thirdVideoId,
      ]);
    },
  );

  test(
    "Completion during native queue editing advances to the newly inserted next item",
    () async {
      await playMix();
      var completed = false;
      audio.onRemove = (index) {
        if (completed) return;
        completed = true;
        audio.stateEvents.add(const AudioStatus(false, AudioPhase.completed));
      };
      await add(addedVideoId, QueueInsertPosition.next);
      await drain();
      expect(playback.currentTrack?.videoId, addedVideoId);
      expect(playback.currentEntryId, mix.queueItems[1].entryId);
    },
  );

  test("Obsolete API errors are discarded after reloading", () async {
    await playMix();
    final response = Completer<http.Response>();
    handler = (request) => response.future;
    final addition = add(addedVideoId, QueueInsertPosition.next);
    await drain();
    handler = null;
    await mix.load(mixPage.uri.toString(), prepareFirstTrack: false);
    response.complete(http.Response("", 503));
    expect(await addition, isFalse);
    expect(videoIds(), mixVideoIds);
  });

  test("Direct media playback disables addition", () async {
    await playback.playDirect("https://media.example.test/direct.mp3");
    expect(youtube.canAddToQueue, isFalse);
    expect(await add(addedVideoId, QueueInsertPosition.next), isFalse);
    expect(streamRequests, isEmpty);
    expect(mix.items, isEmpty);
  });
}

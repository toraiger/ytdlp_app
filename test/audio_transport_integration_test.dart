import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:mix_player_app/controllers/mix_controller.dart";
import "package:mix_player_app/controllers/playback_controller.dart";
import "package:mix_player_app/models/api_models.dart";
import "package:mix_player_app/models/audio_transport_diagnostics.dart";
import "package:mix_player_app/models/prefetch_diagnostics.dart";
import "package:mix_player_app/services/app_settings.dart";
import "package:mix_player_app/services/m4a_fragment_header.dart";
import "package:mix_player_app/services/network_path.dart";
import "package:mix_player_app/services/playback_engines.dart";
import "support/fakes.dart"
    show drain, jsonResponse, mixJson, mockApi, streamJson;

/// Only AVPlayer is replaced. The Dart player, loopback server, M4A source,
/// HTTP clients and reset API below are the production implementations.
class _NativePlayerStub {
  _NativePlayerStub(this.messenger, {this.readMedia = true}) {
    _register("com.ryanheise.audio_session", (call) async => null);
    _register("com.ryanheise.just_audio.preparations", (call) async => null);
    _register("com.ryanheise.just_audio.methods", (call) async {
      final arguments = call.arguments as Map?;
      if (call.method == "init") {
        final playerId = arguments!["id"] as String;
        _playerId = playerId;
        activePlayers++;
        expect(activePlayers, 1, reason: "Background audio permits one player");
        _registerPlayer(playerId);
      } else if (call.method == "disposePlayer") {
        activePlayers--;
      } else if (call.method == "mixHoldUpcoming") {
        return (arguments!["sourceIds"] as List)
            .where(
              (sourceId) =>
                  sources.indexWhere((source) => source["id"] == sourceId) >
                  currentIndex,
            )
            .toList();
      } else if (call.method == "mixReplaceUpcoming") {
        final index = arguments!["index"] as int;
        if (index <= currentIndex ||
            sources[index]["id"] != arguments["sourceId"]) {
          return false;
        }
        sources[index] = Map.of(arguments["source"] as Map);
        await _readSource(sources[index]);
        if (automaticallyReady) await emitPreparation(sources[index]);
        return true;
      } else if (call.method == "mixRetirePlayed") {
        final count = arguments!["count"] as int;
        if (currentIndex != count ||
            sources[count]["id"] != arguments["currentSourceId"]) {
          return false;
        }
        sources.removeRange(0, count);
        await emitPlayback();
        return true;
      }
      return <String, Object?>{};
    });
  }

  final TestDefaultBinaryMessenger messenger;
  final bool readMedia;
  bool automaticallyReady = true;
  final _channels = <MethodChannel>[];
  final loadedUris = <Uri>[];
  final receivedAudio = <List<int>>[];
  int activePlayers = 0;
  String? _playerId;
  int currentIndex = 0;
  final sources = <Map>[];
  final commands = <String>[];

  Future<void> _readSource(Map source) async {
    final uri = Uri.parse(source["uri"] as String);
    loadedUris.add(uri);
    // Direct media is fetched by AVPlayer; controller-only scenarios stub it.
    if (!readMedia) return;
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(uri)).close();
      expect(response.statusCode, HttpStatus.ok);
      receivedAudio.add(await response.expand((chunk) => chunk).toList());
    } finally {
      client.close(force: true);
    }
  }

  Future<void> emitPreparation(Map source, {bool ready = true, int code = 0}) =>
      messenger.handlePlatformMessage(
        "com.ryanheise.just_audio.preparations",
        const StandardMethodCodec().encodeSuccessEnvelope({
          "sourceId": source["id"],
          "ready": ready,
          "code": code,
        }),
        (reply) {},
      );

  Future<void> emitPlayback({
    int index = 0,
    Duration position = Duration.zero,
    int processingState = 3,
  }) async {
    currentIndex = index;
    await messenger.handlePlatformMessage(
      "com.ryanheise.just_audio.events.$_playerId",
      const StandardMethodCodec().encodeSuccessEnvelope({
        "processingState": processingState,
        "updateTime": DateTime.now().millisecondsSinceEpoch,
        "updatePosition": position.inMicroseconds,
        "bufferedPosition": const Duration(seconds: 120).inMicroseconds,
        "duration": const Duration(seconds: 120).inMicroseconds,
        "currentIndex": index,
      }),
      (reply) {},
    );
  }

  void _register(String name, Future<Object?> Function(MethodCall) handler) {
    final channel = MethodChannel(name);
    _channels.add(channel);
    messenger.setMockMethodCallHandler(channel, handler);
  }

  void _registerPlayer(String playerId) {
    _register(
      "com.ryanheise.just_audio.events.$playerId",
      (call) async => null,
    );
    _register("com.ryanheise.just_audio.data.$playerId", (call) async => null);
    _register("com.ryanheise.just_audio.methods.$playerId", (call) async {
      commands.add(call.method);
      final arguments = call.arguments as Map?;
      if (call.method == "seek") {
        await emitPlayback(
          index: arguments!["index"] as int? ?? currentIndex,
          position: Duration(microseconds: arguments["position"] as int? ?? 0),
        );
      }
      if (call.method == "concatenatingInsertAll") {
        final added = (arguments!["children"] as List).cast<Map>();
        sources.insertAll(arguments["index"] as int, added);
        for (final source in added) {
          await _readSource(source);
          if (automaticallyReady) await emitPreparation(source);
        }
        return <String, Object?>{};
      }
      if (call.method == "concatenatingRemoveRange") {
        final start = arguments!["startIndex"] as int;
        final end = arguments["endIndex"] as int;
        sources.removeRange(start, end);
        await emitPlayback(
          index: (currentIndex - (end - start)).clamp(0, sources.length - 1),
        );
      }
      if (call.method != "load") return <String, Object?>{};
      final audioSource = (call.arguments as Map)["audioSource"] as Map;
      final child = (audioSource["children"] as List).first as Map;
      sources
        ..clear()
        ..addAll((audioSource["children"] as List).cast<Map>());
      await _readSource(child);
      const duration = Duration(seconds: 120);
      await messenger.handlePlatformMessage(
        "com.ryanheise.just_audio.events.$playerId",
        const StandardMethodCodec().encodeSuccessEnvelope({
          // just_audio's native processing state value for ready.
          "processingState": 3,
          "updateTime": DateTime.now().millisecondsSinceEpoch,
          "updatePosition": 0,
          "bufferedPosition": duration.inMicroseconds,
          "duration": duration.inMicroseconds,
          "currentIndex": 0,
        }),
        (reply) {},
      );
      return {"duration": duration.inMicroseconds};
    });
  }

  void close() {
    for (final channel in _channels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  }
}

// Use real sockets for this integration test without changing global overrides.
class _SocketHttpOverrides extends HttpOverrides {}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test(
    "Transport reset rebinds the real M4A proxy and releases the old client",
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final native = _NativePlayerStub(binding.defaultBinaryMessenger);
        final original = File("test/fixtures/dash-tone.m4a").readAsBytesSync();
        final expected = M4aFragmentHeader.inspect(original).apply(original, 0);
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var upstreamRequests = 0;
        upstream.listen((request) async {
          upstreamRequests++;
          expect(request.headers.value("X-API-Key"), isNull);
          request.response
            ..statusCode = HttpStatus.partialContent
            ..contentLength = original.length
            ..headers.set(
              "Content-Range",
              "bytes 0-${original.length - 1}/${original.length}",
            )
            ..add(original);
          await request.response.close();
        });
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final engine = JustAudioEngine();
        try {
          final entry = QueueEntry(
            track: const MixTrack(videoId: "fixture", title: "Fixture"),
            uri: Uri.http("localhost:${upstream.port}", "/audio"),
            httpHeaders: const {"X-API-Key": "private-key"},
            format: const StreamFormat(ext: "m4a", acodec: "mp4a.40.2"),
          );
          await engine.load(entry);
          final first = engine.transportDiagnostics;
          expect(first.route, AudioTransportRoute.m4aLoopback);
          expect(first.proxyListening, isTrue);
          expect(first.localRequestCount, 1);
          expect(first.upstream!.attempts, 1);
          await engine.resetTransport();
          expect(
            engine.transportDiagnostics.reset,
            TransportResetState.completed,
          );
          expect(engine.transportDiagnostics.proxyListening, isFalse);

          final disconnected = HttpClient();
          try {
            await expectLater(
              disconnected.getUrl(native.loadedUris.single),
              throwsA(isA<SocketException>()),
            );
          } finally {
            disconnected.close(force: true);
          }
          await engine.load(entry);
          expect(
            engine.transportDiagnostics.proxyGeneration,
            first.proxyGeneration + 1,
          );
          expect(engine.transportDiagnostics.localRequestCount, 1);
          expect(native.receivedAudio, [expected, expected]);
          final client = HttpClient();
          try {
            // Old routes are gone even on the new listener, rather than pointing
            // at a closed source retained in the handler map.
            final staleRoute = native.loadedUris.last.replace(
              path: native.loadedUris.first.path,
            );
            final stale = await (await client.getUrl(staleRoute)).close();
            expect(stale.statusCode, HttpStatus.notFound);
            await stale.drain<void>();
            final unsupported =
                await (await client.postUrl(native.loadedUris.last)).close();
            expect(unsupported.statusCode, HttpStatus.methodNotAllowed);
            await unsupported.drain<void>();
          } finally {
            client.close(force: true);
          }
          // A new source/client fetches the prefix again instead of reusing it.
          expect(upstreamRequests, 2);
          expect(native.activePlayers, 1);
        } finally {
          await engine.dispose();
          await upstream.close(force: true);
          debugDefaultTargetPlatformOverride = null;
          native.close();
        }
      }, _SocketHttpOverrides());
    },
  );

  test(
    "Future M4A sources reuse prepared bytes on a new proxy while the active route survives",
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final native = _NativePlayerStub(binding.defaultBinaryMessenger);
        final original = File("test/fixtures/dash-tone.m4a").readAsBytesSync();
        final expected = M4aFragmentHeader.inspect(original).apply(original, 0);
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var requests = 0;
        upstream.listen((request) async {
          requests++;
          request.response
            ..statusCode = HttpStatus.partialContent
            ..contentLength = original.length
            ..headers.set(
              "Content-Range",
              "bytes 0-${original.length - 1}/${original.length}",
            )
            ..add(original);
          await request.response.close();
        });
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final engine = JustAudioEngine();
        QueueEntry entry(int index) => QueueEntry(
          track: MixTrack(videoId: "fixture-$index", title: "Fixture"),
          mixIndex: index,
          uri: Uri.http("localhost:${upstream.port}", "/audio/$index"),
          format: const StreamFormat(ext: "m4a", acodec: "mp4a.40.2"),
        );
        final preparations = <AudioPreparationEvent>[];
        final subscription = engine.preparations.listen(preparations.add);
        try {
          await engine.load(entry(0));
          final currentUri = native.loadedUris.single;
          await native.emitPlayback(position: const Duration(seconds: 37));
          await drain();
          final first = engine.prepare(entry(1), networkGeneration: 0);
          await first.ready;
          expect(requests, 2);
          expect(await engine.installUpcoming(first), isTrue);
          await drain();
          expect(preparations.last.entry, same(first.entry));
          expect(preparations.last.stage, PrefetchStage.ready);
          expect(preparations.last.failure, isNull);
          expect(
            requests,
            2,
            reason: "Playback must reuse the prepared M4A prefix",
          );
          final staleUri = native.loadedUris.last;
          await native.emitPreparation(
            native.sources[1],
            ready: false,
            code: -1004,
          );
          await drain();
          expect(preparations.last.entry, same(first.entry));
          expect(preparations.last.stage, PrefetchStage.failed);
          expect(preparations.last.failure!.reason, "native_-1004");
          await engine.holdUpcoming([first.entry], rotateTransport: true);
          first.cancel();
          final fresh = engine.prepare(entry(1), networkGeneration: 1);
          await fresh.ready;
          expect(
            await engine.installUpcoming(fresh, replacing: first.entry),
            isTrue,
          );
          await drain();
          expect(preparations.last.entry, same(fresh.entry));
          expect(preparations.last.networkGeneration, 1);
          expect(preparations.last.stage, PrefetchStage.ready);
          expect(preparations.last.failure, isNull);
          final freshUri = native.loadedUris.last;
          expect(freshUri.port, isNot(currentUri.port));
          expect(engine.snapshot.index, 0);
          expect(engine.snapshot.position, const Duration(seconds: 37));
          expect(
            native.commands.where((command) => command == "load"),
            hasLength(1),
          );
          expect(native.commands, isNot(contains("seek")));
          expect(native.activePlayers, 1);
          final client = HttpClient();
          try {
            final current = await (await client.getUrl(currentUri)).close();
            expect(current.statusCode, HttpStatus.ok);
            expect(await current.expand((chunk) => chunk).toList(), expected);
            final stale = await (await client.getUrl(staleUri)).close();
            expect(stale.statusCode, HttpStatus.notFound);
            await stale.drain<void>();
          } finally {
            client.close(force: true);
          }
          expect(requests, 3);
          expect(native.receivedAudio, [expected, expected, expected]);
          // Native can advance before Dart receives its index event. Neither
          // cancellation nor a late replacement may close that active source.
          native.currentIndex = 1;
          fresh.cancel();
          await engine.holdUpcoming([fresh.entry], rotateTransport: true);
          final late = engine.prepare(entry(1), networkGeneration: 2);
          await late.ready;
          expect(
            await engine.installUpcoming(late, replacing: fresh.entry),
            isFalse,
          );
          late.cancel();
          await native.emitPlayback(index: 1);
          await drain();
          await engine.retireBefore(1);
          expect(native.sources, hasLength(1));
          final disconnected = HttpClient();
          try {
            await expectLater(
              disconnected.getUrl(currentUri),
              throwsA(isA<SocketException>()),
            );
            final freshResponse =
                await (await disconnected.getUrl(freshUri)).close();
            expect(freshResponse.statusCode, HttpStatus.ok);
            await freshResponse.drain<void>();
          } finally {
            disconnected.close(force: true);
          }
        } finally {
          await subscription.cancel();
          await engine.dispose();
          await upstream.close(force: true);
          debugDefaultTargetPlatformOverride = null;
          native.close();
        }
      }, _SocketHttpOverrides());
    },
  );

  test(
    "Native readiness resumes the same next song after a path change and API retry",
    () async {
      // Keep the production controller, API client, player and native channels.
      // Only AVPlayer's direct-media IO and progress notifications are stubbed.
      final native = _NativePlayerStub(
        binding.defaultBinaryMessenger,
        readMedia: false,
      );
      final paths = StreamController<NetworkPath>.broadcast(sync: true);
      final recovery = Completer<http.Response>();
      final resolutions = <String>[];
      var recovering = false;
      var failNextResolution = false;
      final mix =
          MixController()..configure(
            mockApi((request) {
              if (request.url.path != "/stream") {
                return jsonResponse(mixJson(["a", "b", "c"]));
              }
              final id = jsonDecode(request.body)["video_id"] as String;
              resolutions.add(id);
              if (id == "b" && recovering) {
                if (failNextResolution) {
                  failNextResolution = false;
                  return http.Response("", 503);
                }
                return recovery.future;
              }
              return jsonResponse(streamJson(id));
            }),
          );
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final engine = JustAudioEngine();
      final playback = PlaybackController(
        mix: mix,
        audio: engine,
        paths: paths.stream,
      );
      try {
        await mix.load(defaultMixUrl);
        await playback.playTrack(0);
        await drain();
        expect(native.sources, hasLength(3));
        expect(
          playback.diagnostics.prefetch.every((state) => state.nativeReady),
          isTrue,
        );
        final activeSource = native.sources.first["id"];
        final initialSeekCount =
            native.commands.where((method) => method == "seek").length;
        await native.emitPlayback(position: const Duration(seconds: 37));
        await drain();

        recovering = true;
        failNextResolution = true;
        paths.add(const NetworkPath(generation: 1, available: true));
        await drain();
        expect(resolutions.where((id) => id == "b"), hasLength(3));
        expect(playback.currentIndex, 0);
        // The production player extrapolates position while playing.
        expect(
          playback.position.inMilliseconds,
          inInclusiveRange(37000, 38000),
        );
        expect(playback.isPlaying, isTrue);
        expect(native.sources.first["id"], activeSource);
        final retry = playback.diagnostics.prefetch.firstWhere(
          (state) => state.listIndex == 1,
        );
        expect(retry.reason, "api_503");
        expect(retry.retryCount, 1);
        expect(retry.nativeReady, isFalse);

        await native.emitPlayback(
          position: const Duration(seconds: 120),
          processingState: 4,
        );
        await drain();
        expect(playback.isWaitingForNext, isTrue);
        expect(playback.currentIndex, 0);
        native.automaticallyReady = false;
        recovery.complete(jsonResponse(streamJson("b")));
        await drain();
        final installed = playback.diagnostics.prefetch.firstWhere(
          (state) => state.listIndex == 1,
        );
        expect(installed.stage, PrefetchStage.native);
        expect(installed.replacement, "replaced");
        expect(playback.isWaitingForNext, isTrue);
        expect(
          native.commands.where((method) => method == "seek"),
          hasLength(initialSeekCount),
        );

        await native.emitPreparation(native.sources[1]);
        await drain();
        expect(playback.isWaitingForNext, isFalse);
        expect(playback.currentIndex, 1);
        expect(playback.currentTrack!.videoId, "b");
        expect(playback.isPlaying, isTrue);
        expect(
          playback.diagnostics.prefetch
              .firstWhere((state) => state.listIndex == 1)
              .nativeReady,
          isTrue,
        );
        expect(native.sources, hasLength(2));

        await native.emitPlayback(index: 1);
        await drain();
        expect(playback.currentIndex, 2);
        expect(playback.currentTrack!.videoId, "c");
        expect(playback.isPlaying, isTrue);
        expect(native.sources, hasLength(1));
        expect(
          native.commands.where((method) => method == "load"),
          hasLength(1),
        );
        expect(
          native.commands.where((method) => method == "seek"),
          hasLength(initialSeekCount + 1),
        );
        expect(native.activePlayers, 1);
      } finally {
        playback.dispose();
        mix.dispose();
        await paths.close();
        await drain();
        debugDefaultTargetPlatformOverride = null;
        native.close();
      }
    },
  );
}

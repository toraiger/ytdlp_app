import "dart:io";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:mix_player_app/models/api_models.dart";
import "package:mix_player_app/models/audio_transport_diagnostics.dart";
import "package:mix_player_app/services/m4a_fragment_header.dart";
import "package:mix_player_app/services/playback_engines.dart";
import "support/fakes.dart" show drain;

/// Only AVPlayer is replaced. The Dart player, loopback server, M4A source,
/// HTTP clients and reset API below are the production implementations.
class _NativePlayerStub {
  _NativePlayerStub(this.messenger) {
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
        await _emitPreparation(sources[index]);
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
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(uri)).close();
      expect(response.statusCode, HttpStatus.ok);
      receivedAudio.add(await response.expand((chunk) => chunk).toList());
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _emitPreparation(Map source) => messenger.handlePlatformMessage(
    "com.ryanheise.just_audio.preparations",
    const StandardMethodCodec().encodeSuccessEnvelope({
      "sourceId": source["id"],
      "ready": true,
      "code": 0,
    }),
    (reply) {},
  );

  Future<void> emitPlayback({
    int index = 0,
    Duration position = Duration.zero,
  }) async {
    currentIndex = index;
    await messenger.handlePlatformMessage(
      "com.ryanheise.just_audio.events.$_playerId",
      const StandardMethodCodec().encodeSuccessEnvelope({
        "processingState": 3,
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
      if (call.method == "concatenatingInsertAll") {
        final added = (arguments!["children"] as List).cast<Map>();
        sources.insertAll(arguments["index"] as int, added);
        for (final source in added) {
          await _readSource(source);
          await _emitPreparation(source);
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
        try {
          await engine.load(entry(0));
          final currentUri = native.loadedUris.single;
          await native.emitPlayback(position: const Duration(seconds: 37));
          await drain();
          final first = engine.prepare(entry(1), networkGeneration: 0);
          await first.ready;
          expect(requests, 2);
          expect(await engine.installUpcoming(first), isTrue);
          expect(
            requests,
            2,
            reason: "Playback must reuse the prepared M4A prefix",
          );
          final staleUri = native.loadedUris.last;
          await engine.holdUpcoming([first.entry], rotateTransport: true);
          first.cancel();
          final fresh = engine.prepare(entry(1), networkGeneration: 1);
          await fresh.ready;
          expect(
            await engine.installUpcoming(fresh, replacing: first.entry),
            isTrue,
          );
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
          await engine.dispose();
          await upstream.close(force: true);
          debugDefaultTargetPlatformOverride = null;
          native.close();
        }
      }, _SocketHttpOverrides());
    },
  );
}

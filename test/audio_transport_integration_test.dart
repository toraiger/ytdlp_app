import "dart:io";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:mix_player_app/models/api_models.dart";
import "package:mix_player_app/models/audio_transport_diagnostics.dart";
import "package:mix_player_app/services/m4a_fragment_header.dart";
import "package:mix_player_app/services/playback_engines.dart";

/// Only AVPlayer is replaced. The Dart player, loopback server, M4A source,
/// HTTP clients and reset API below are the production implementations.
class _NativePlayerStub {
  _NativePlayerStub(this.messenger) {
    _register("com.ryanheise.audio_session", (call) async => null);
    _register("com.ryanheise.just_audio.methods", (call) async {
      final arguments = call.arguments as Map?;
      if (call.method == "init") {
        final playerId = arguments!["id"] as String;
        activePlayers++;
        expect(activePlayers, 1, reason: "Background audio permits one player");
        _registerPlayer(playerId);
      } else if (call.method == "disposePlayer") {
        activePlayers--;
      }
      return <String, Object?>{};
    });
  }

  final TestDefaultBinaryMessenger messenger;
  final _channels = <MethodChannel>[];
  final loadedUris = <Uri>[];
  final receivedAudio = <List<int>>[];
  int activePlayers = 0;

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
      if (call.method != "load") return <String, Object?>{};
      final audioSource = (call.arguments as Map)["audioSource"] as Map;
      final child = (audioSource["children"] as List).first as Map;
      final uri = Uri.parse(child["uri"] as String);
      loadedUris.add(uri);
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(uri)).close();
        expect(response.statusCode, HttpStatus.ok);
        receivedAudio.add(await response.expand((chunk) => chunk).toList());
      } finally {
        client.close(force: true);
      }
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
}

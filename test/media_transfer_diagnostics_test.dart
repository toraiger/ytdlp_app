import "dart:async";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:mix_player_app/models/audio_transport_diagnostics.dart";
import "package:mix_player_app/services/error_report.dart";
import "package:mix_player_app/services/ios_m4a_audio_source.dart";

void main() {
  for (final kind in [
    MediaTransferFailure.connection,
    MediaTransferFailure.timeout,
    MediaTransferFailure.httpStatus,
    MediaTransferFailure.invalidResponse,
  ]) {
    test(
      "Prefix failure is classified without private data: ${kind.name}",
      () async {
        final events = <MediaTransferDiagnostics>[];
        final source = IosM4aAudioSource(
          Uri.parse("https://private.example/audio?token=private-token"),
          headers: {"Cookie": "private-cookie"},
          onFailure: events.add,
          client: MockClient.streaming((request, body) async {
            switch (kind) {
              case MediaTransferFailure.connection:
                throw http.ClientException(
                  "private-url private-key",
                  request.url,
                );
              case MediaTransferFailure.timeout:
                throw TimeoutException("private-url");
              case MediaTransferFailure.httpStatus:
                return http.StreamedResponse(Stream.value([1, 2]), 403);
              default:
                return http.StreamedResponse(
                  Stream.value([1, 2]),
                  206,
                  headers: {"content-range": "invalid private-header"},
                );
            }
          }),
        );
        addTearDown(source.close);
        await expectLater(source.prepare(), throwsStateError);
        await expectLater(source.request(), throwsStateError);
        final transfer = source.transferDiagnostics;
        expect(transfer.attempts, 1);
        expect(transfer.stage, MediaTransferStage.prefix);
        expect(transfer.failure, kind);
        expect(events, hasLength(1));
        expect(events.single.failure, kind);
        final report = ErrorReport.capture(
          operation: "音声の読み込み",
          message: "音声を再生できません。",
          transport: AudioTransportDiagnostics(
            route: AudioTransportRoute.m4aLoopback,
            reset: TransportResetState.completed,
            proxyGeneration: 2,
            proxyListening: true,
            localRequestCount: 1,
            upstream: transfer,
          ),
        );
        final captured = report.toText();
        source.close();
        expect(report.toText(), captured);
        expect(captured, contains("配信元取得の失敗種別: ${kind.name}"));
        expect(captured, contains("ローカル要求の到達数: 1"));
        expect(captured, isNot(contains("private")));
        expect(captured, isNot(contains("https://")));
      },
    );
  }

  test(
    "A range body failure is recorded as range, not successful HTTP headers",
    () async {
      const prefixLength = 64 * 1024;
      final bytes = Uint8List(prefixLength * 2);
      var requests = 0;
      final events = <MediaTransferDiagnostics>[];
      final source = IosM4aAudioSource(
        Uri.https("media.example.test", "/audio"),
        headers: {},
        onFailure: events.add,
        client: MockClient.streaming((request, body) async {
          requests++;
          final start = requests == 1 ? 0 : prefixLength;
          final stream =
              requests == 1
                  ? Stream.value(bytes.sublist(0, prefixLength))
                  : Stream<List<int>>.error(
                    TimeoutException("private stream data"),
                  );
          return http.StreamedResponse(
            stream,
            206,
            contentLength: prefixLength,
            headers: {
              "content-range":
                  "bytes $start-${start + prefixLength - 1}/${bytes.length}",
            },
          );
        }),
      );
      addTearDown(source.close);
      final response = await source.request(prefixLength, bytes.length);
      await expectLater(response.stream.drain<void>(), throwsStateError);
      expect(source.transferDiagnostics.stage, MediaTransferStage.range);
      expect(source.transferDiagnostics.failure, MediaTransferFailure.timeout);
      expect(source.transferDiagnostics.httpStatus, 206);
      expect(events.single.stage, MediaTransferStage.range);
      expect(events.single.failure, MediaTransferFailure.timeout);
    },
  );

  test(
    "A normally paused native reader does not time out or trigger recovery",
    () async {
      const prefixLength = 64 * 1024;
      final bytes = Uint8List(prefixLength + 8);
      final body = StreamController<List<int>>();
      final failures = <MediaTransferDiagnostics>[];
      var requests = 0;
      final source = IosM4aAudioSource(
        Uri.https("media.example.test", "/audio"),
        headers: {},
        onFailure: failures.add,
        timeout: const Duration(milliseconds: 100),
        client: MockClient.streaming((request, upload) async {
          final prefix = requests++ == 0;
          return http.StreamedResponse(
            prefix ? Stream.value(bytes.sublist(0, prefixLength)) : body.stream,
            206,
            contentLength: prefix ? prefixLength : 8,
            headers: {
              "content-range":
                  prefix
                      ? "bytes 0-${prefixLength - 1}/${bytes.length}"
                      : "bytes $prefixLength-${bytes.length - 1}/${bytes.length}",
            },
          );
        }),
      );
      addTearDown(source.close);
      final response = await source.request(prefixLength);
      final firstChunk = Completer<void>();
      final complete = Completer<void>();
      late StreamSubscription<List<int>> subscription;
      subscription = response.stream.listen((chunk) {
        if (!firstChunk.isCompleted) {
          subscription.pause();
          firstChunk.complete();
        }
      }, onDone: complete.complete);
      body.add([1, 2, 3, 4]);
      await firstChunk.future;
      expect(subscription.isPaused, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(failures, isEmpty);
      subscription.resume();
      body.add([5, 6, 7, 8]);
      await body.close();
      await complete.future;
      expect(failures, isEmpty);
    },
  );
}

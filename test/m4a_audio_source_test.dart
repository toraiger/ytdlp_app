import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mix_player_app/models/api_models.dart';
import "package:mix_player_app/models/audio_transport_diagnostics.dart";
import 'package:mix_player_app/services/ios_m4a_audio_source.dart';
import 'package:mix_player_app/services/m4a_fragment_header.dart';
import 'package:mix_player_app/services/playback_engines.dart';

void main() {
  final original = File('test/fixtures/dash-tone.m4a').readAsBytesSync();
  final header = M4aFragmentHeader.inspect(original);
  final expected = header.apply(original, 0);

  test('DASH initialization durations are cleared without moving media', () {
    expect(header.durationFields, hasLength(3));
    final durationBytes = {
      for (final field in header.durationFields)
        for (var i = 0; i < field.length; i++) field.offset + i,
    };
    expect(expected.length, original.length);
    for (var i = 0; i < original.length; i++) {
      expect(expected[i], durationBytes.contains(i) ? 0 : original[i]);
    }
    expect(header.apply(expected, 0), expected);
  });

  test('Partial byte ranges receive exactly the same repair', () {
    for (var start = 0; start < original.length; start += 7) {
      final end = (start + 7).clamp(0, original.length);
      expect(
        header.apply(original.sublist(start, end), start),
        expected.sublist(start, end),
      );
    }
  });

  test('An incomplete moov requests a bounded larger prefix', () {
    final partial = M4aFragmentHeader.inspect(original.sublist(0, 80));
    expect(partial.durationFields, isEmpty);
    expect(partial.requiredLength, greaterThan(80));
    expect(partial.requiredLength, lessThan(M4aFragmentHeader.maxLength));
  });

  test(
    'Non-DASH, malformed, populated and edited initialization pass through',
    () {
      final variants = <Uint8List>[
        Uint8List(0),
        Uint8List.fromList([0, 0, 0, 1, 109, 111, 111, 118]),
        Uint8List.fromList(original)..setRange(8, 12, 'M4A '.codeUnits),
      ];
      int find(String name) {
        for (var i = 4; i < original.length - 4; i++) {
          if (String.fromCharCodes(original.sublist(i, i + 4)) == name) {
            return i;
          }
        }
        throw StateError('Missing fixture box');
      }

      final populated = Uint8List.fromList(original);
      ByteData.sublistView(populated).setUint32(find('stts') + 8, 1);
      variants.add(populated);
      final edited = Uint8List.fromList(original);
      edited.setRange(find('mvex'), find('mvex') + 4, 'edts'.codeUnits);
      variants.add(edited);
      for (final bytes in variants) {
        final inspected = M4aFragmentHeader.inspect(bytes);
        expect(inspected.durationFields, isEmpty);
        expect(inspected.apply(bytes, 0), bytes);
      }
    },
  );

  test('iOS M4A uses repair; Android and HLS retain their transports', () {
    final entry = QueueEntry(
      track: const MixTrack(videoId: 'a', title: 'A'),
      uri: Uri.parse('https://media.example.test/videoplayback'),
      format: const StreamFormat(ext: 'm4a', acodec: 'mp4a.40.2'),
    );
    final source =
        createAudioSource(entry, platform: TargetPlatform.iOS)
            as IosM4aAudioSource;
    expect(
      source.options?.darwinAssetOptions?.preferPreciseDurationAndTiming,
      true,
    );
    source.close();
    expect(
      createAudioSource(entry, platform: TargetPlatform.android),
      isA<ProgressiveAudioSource>(),
    );
    expect(
      createAudioSource(
        QueueEntry(
          track: entry.track,
          uri: entry.uri,
          format: const StreamFormat(
            ext: 'm4a',
            acodec: 'mp4a.40.2',
            protocol: 'm3u8_native',
          ),
        ),
        platform: TargetPlatform.iOS,
      ),
      isA<HlsAudioSource>(),
    );
  });

  for (final ignoreRange in [false, true]) {
    test(
      'Range reads and concurrent seeks preserve exact bytes ($ignoreRange)',
      () async {
        final requests = <String>[];
        final source = IosM4aAudioSource(
          Uri.parse('https://media.example.test/audio?signature=private'),
          headers: {'User-Agent': 'fixture', 'X-API-Key': 'private-key'},
          client: MockClient.streaming((request, _) async {
            expect(
              request.headers.keys.map((s) => s.toLowerCase()),
              isNot(contains('x-api-key')),
            );
            expect(request.headers['Accept-Encoding'], 'identity');
            expect(request.headers['User-Agent'], 'fixture');
            final range = request.headers['Range']!;
            requests.add(range);
            final parts = range.substring(6).split('-').map(int.parse).toList();
            final start = ignoreRange ? 0 : parts[0];
            final end =
                ignoreRange
                    ? original.length
                    : (parts[1] + 1).clamp(0, original.length);
            final bytes = original.sublist(start, end);
            return http.StreamedResponse(
              Stream.fromIterable([
                for (var i = 0; i < bytes.length; i += 37)
                  bytes.sublist(i, (i + 37).clamp(0, bytes.length)),
              ]),
              ignoreRange ? 200 : 206,
              contentLength: bytes.length,
              headers: {
                if (!ignoreRange)
                  'content-range': 'bytes $start-${end - 1}/${original.length}',
              },
            );
          }),
        );
        Future<List<int>> read(int? start, int? end) async {
          final response = await source.request(start, end);
          expect(response.sourceLength, original.length);
          expect(response.contentType, 'audio/mp4');
          return response.stream.expand((bytes) => bytes).toList();
        }

        final reads = await Future.wait([
          read(0, 2),
          read(200, 1500),
          read(null, null),
        ]);
        expect(reads[0], expected.sublist(0, 2));
        expect(reads[1], expected.sublist(200, 1500));
        expect(reads[2], expected);
        expect(requests, hasLength(1));
        expect(source.normalizedDurationFields, 3);
        source.close();
        await expectLater(source.request(), throwsStateError);
      },
    );
  }

  test('Seeking outside the cached prefix sends an upstream range', () async {
    final large = Uint8List.fromList([...original, ...List.filled(100000, 7)]);
    final requests = <String>[];
    final source = IosM4aAudioSource(
      Uri.https('media.example.test', '/audio'),
      headers: {},
      client: MockClient.streaming((request, _) async {
        requests.add(request.headers['Range']!);
        final range =
            request.headers['Range']!
                .substring(6)
                .split('-')
                .map(int.parse)
                .toList();
        final start = range[0];
        final end = (range[1] + 1).clamp(0, large.length);
        return http.StreamedResponse(
          Stream.value(large.sublist(start, end)),
          206,
          contentLength: end - start,
          headers: {'content-range': 'bytes $start-${end - 1}/${large.length}'},
        );
      }),
    );
    final response = await source.request(70000, 71000);
    expect(
      await response.stream.expand((b) => b).toList(),
      large.sublist(70000, 71000),
    );
    expect(requests, ['bytes=0-65535', 'bytes=70000-70999']);
    source.close();
  });

  test(
    'Upstream errors are redacted and in-flight requests abort on close',
    () async {
      final started = Completer<void>();
      final aborted = Completer<void>();
      final source = IosM4aAudioSource(
        Uri.parse('https://media.example.test/audio?signature=private'),
        headers: {},
        client: MockClient.streaming((request, _) async {
          unawaited(
            (request as http.Abortable).abortTrigger!.then(
              (_) => aborted.complete(),
            ),
          );
          started.complete();
          await aborted.future;
          throw http.ClientException('private URL and key', request.url);
        }),
      );
      final pending = expectLater(
        source.request(),
        throwsA(
          predicate(
            (error) =>
                error is StateError &&
                !error.toString().contains('private') &&
                !error.toString().contains('https://'),
          ),
        ),
      );
      await started.future;
      source.close();
      await aborted.future;
      await pending;
    },
  );

  for (final waitingForHeaders in [false, true]) {
    test(
      'Cancelling a range aborts while waiting for ${waitingForHeaders ? 'headers' : 'body'}',
      () async {
        final large = Uint8List.fromList([
          ...original,
          ...List.filled(100000, 7),
        ]);
        final started = Completer<void>();
        final aborted = Completer<void>();
        final body = StreamController<List<int>>(
          onListen: () {
            if (!started.isCompleted) started.complete();
          },
        );
        var calls = 0;
        final source = IosM4aAudioSource(
          Uri.https('media.example.test', '/audio'),
          headers: {},
          timeout: const Duration(seconds: 5),
          client: MockClient.streaming((request, _) async {
            if (calls++ == 0) {
              return http.StreamedResponse(
                Stream.value(large.sublist(0, 65536)),
                206,
                contentLength: 65536,
                headers: {'content-range': 'bytes 0-65535/${large.length}'},
              );
            }
            unawaited(
              (request as http.Abortable).abortTrigger!.then((_) {
                aborted.complete();
                unawaited(body.close());
              }),
            );
            if (waitingForHeaders) {
              started.complete();
              await aborted.future;
              throw http.ClientException('private', request.url);
            }
            return http.StreamedResponse(
              body.stream,
              206,
              contentLength: 1000,
              headers: {'content-range': 'bytes 70000-70999/${large.length}'},
            );
          }),
        );
        addTearDown(source.close);
        final response = await source.request(70000, 71000);
        final errors = <Object>[];
        final subscription = response.stream.listen(
          (_) {},
          onError: errors.add,
        );
        await started.future;
        await subscription.cancel().timeout(const Duration(seconds: 1));
        await aborted.future.timeout(const Duration(seconds: 1));
        await Future<void>.delayed(Duration.zero);
        expect(errors, isEmpty);
        expect(source.transferDiagnostics.failure, MediaTransferFailure.none);
      },
    );
  }

  for (final validatorHeader in ['etag', 'last-modified']) {
    for (final status in [200, 206]) {
      test(
        'Changed $validatorHeader rejects same-size $status media',
        () async {
          final large = Uint8List.fromList([
            ...original,
            ...List.filled(100000, 7),
          ]);
          final updated = Uint8List.fromList(large)..[50000] = 8;
          updated[80000] = 9;
          final before =
              validatorHeader == 'etag'
                  ? '"version-1"'
                  : 'Mon, 09 Nov 2026 00:00:00 GMT';
          final after =
              validatorHeader == 'etag'
                  ? '"version-2"'
                  : 'Mon, 09 Nov 2026 01:00:00 GMT';
          var calls = 0;
          final source = IosM4aAudioSource(
            Uri.https('media.example.test', '/audio'),
            headers: {},
            client: MockClient.streaming((request, _) async {
              if (calls++ == 0) {
                return http.StreamedResponse(
                  Stream.value(large.sublist(0, 65536)),
                  206,
                  contentLength: 65536,
                  headers: {
                    'content-range': 'bytes 0-65535/${large.length}',
                    validatorHeader: before,
                  },
                );
              }
              expect(request.headers['If-Range'], before);
              final start = status == 200 ? 0 : 65536;
              return http.StreamedResponse(
                Stream.value(updated.sublist(start)),
                status,
                contentLength: updated.length - start,
                headers: {
                  validatorHeader: after,
                  if (status == 206)
                    'content-range':
                        'bytes $start-${updated.length - 1}/${updated.length}',
                },
              );
            }),
          );
          addTearDown(source.close);
          final response = await source.request();
          final output = <int>[];
          await expectLater(
            response.stream.forEach(output.addAll),
            throwsStateError,
          );
          expect(output.length, lessThanOrEqualTo(65536));
          await expectLater(source.request(0, 2), throwsStateError);
        },
      );
    }
  }

  test('Unchanged ETag permits a server that ignores Range', () async {
    final large = Uint8List.fromList([...original, ...List.filled(100000, 7)]);
    var calls = 0;
    final source = IosM4aAudioSource(
      Uri.https('media.example.test', '/audio'),
      headers: {},
      client: MockClient.streaming((request, _) async {
        if (calls++ > 0) expect(request.headers['If-Range'], '"same-version"');
        return http.StreamedResponse(
          Stream.value(large),
          200,
          contentLength: large.length,
          headers: {'etag': '"same-version"'},
        );
      }),
    );
    addTearDown(source.close);
    final response = await source.request();
    expect(
      await response.stream.expand((b) => b).toList(),
      header.apply(large, 0),
    );
  });

  for (final validatorHeader in ['etag', 'last-modified']) {
    for (final status in [200, 206]) {
      test(
        'Missing $validatorHeader is ${status == 206 ? 'allowed for conditional 206' : 'rejected for 200'}',
        () async {
          final large = Uint8List.fromList([
            ...original,
            ...List.filled(100000, 7),
          ]);
          final validator =
              validatorHeader == 'etag'
                  ? '"version-1"'
                  : 'Mon, 09 Nov 2026 00:00:00 GMT';
          var calls = 0;
          final source = IosM4aAudioSource(
            Uri.https('media.example.test', '/audio'),
            headers: {},
            client: MockClient.streaming((request, _) async {
              if (calls++ == 0) {
                return http.StreamedResponse(
                  Stream.value(large.sublist(0, 65536)),
                  206,
                  contentLength: 65536,
                  headers: {
                    'content-range': 'bytes 0-65535/${large.length}',
                    validatorHeader: validator,
                  },
                );
              }
              expect(request.headers['If-Range'], validator);
              final start = status == 200 ? 0 : 65536;
              return http.StreamedResponse(
                Stream.value(large.sublist(start)),
                status,
                contentLength: large.length - start,
                headers: {
                  if (status == 206)
                    'content-range':
                        'bytes $start-${large.length - 1}/${large.length}',
                },
              );
            }),
          );
          addTearDown(source.close);
          final response = await source.request();
          final output = response.stream.expand((b) => b).toList();
          if (status == 206) {
            expect(await output, header.apply(large, 0));
          } else {
            await expectLater(output, throwsStateError);
            await expectLater(source.request(0, 2), throwsStateError);
          }
        },
      );
    }
  }

  for (final response in [
    http.StreamedResponse(Stream.value([1, 2]), 403),
    http.StreamedResponse(
      Stream.value([1, 2]),
      206,
      headers: {'content-range': 'bytes 1-2/100'},
    ),
    http.StreamedResponse(
      Stream.value([1, 2]),
      200,
      contentLength: 2,
      headers: {'content-encoding': 'gzip'},
    ),
    http.StreamedResponse(Stream.value([1, 2]), 200, contentLength: 100),
  ]) {
    test(
      'Invalid or truncated HTTP media is rejected (${response.statusCode}, ${response.headers})',
      () async {
        final source = IosM4aAudioSource(
          Uri.https('media.example.test', '/audio'),
          headers: {},
          client: MockClient.streaming((_, _) async => response),
        );
        await expectLater(source.request(), throwsStateError);
        source.close();
      },
    );
  }
}

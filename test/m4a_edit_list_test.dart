import "dart:async";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:mix_player_app/models/m4a_header_diagnostics.dart";
import "package:mix_player_app/services/ios_m4a_audio_source.dart";
import "package:mix_player_app/services/m4a_fragment_header.dart";

import "support/m4a_fixture.dart";

void main() {
  const sampleRate = 44100;
  const editedStartSamples = 1600;
  const prefixLength = 64 * 1024;
  final original = File("test/fixtures/dash-tone.m4a").readAsBytesSync();

  void expectOnlyDurationChanges(List<int> input, M4aFragmentHeader inspected) {
    final output = inspected.apply(input, 0);
    final editable = <int>{
      for (final field in inspected.durationFields)
        for (
          var byteOffset = field.offset;
          byteOffset < field.offset + field.length;
          byteOffset++
        )
          byteOffset,
    };
    expect(output.length, input.length);
    for (var byteOffset = 0; byteOffset < input.length; byteOffset++) {
      if (!editable.contains(byteOffset)) {
        expect(output[byteOffset], input[byteOffset]);
      }
    }
    expect(inspected.apply(output, 0), output);
  }

  test("Unedited fragmented AAC retains its existing normalization", () {
    final inspected = M4aFragmentHeader.inspect(original);
    expect(inspected.diagnostics.outcome, M4aHeaderOutcome.normalized);
    expect(inspected.diagnostics.hasEditList, false);
    expect(inspected.durationFields, hasLength(3));
  });

  for (final version in [0, 1]) {
    for (final startSamples in [0, editedStartSamples]) {
      test(
        "Version $version single edit at sample $startSamples preserves all edit and media bytes",
        () {
          final fixture = withEditList(
            original,
            version: version,
            mediaStart: startSamples,
          );
          final inspected = M4aFragmentHeader.inspect(fixture);
          expect(inspected.durationFields, hasLength(3));
          expect(inspected.diagnostics.outcome, M4aHeaderOutcome.normalized);
          expect(inspected.diagnostics.hasEditList, true);
          expect(inspected.diagnostics.editVersion, version);
          expect(inspected.diagnostics.editEntryCount, 1);
          expect(
            inspected.diagnostics.editStart,
            Duration(
              microseconds:
                  startSamples * Duration.microsecondsPerSecond ~/ sampleRate,
            ),
          );
          expectOnlyDurationChanges(fixture, inspected);
        },
      );
    }
  }

  test("Movie duration and media start use their distinct time bases", () {
    const presentationSeconds = 5;
    const movieScales = [1000, sampleRate];
    for (final movieScale in movieScales) {
      final fixture = withEditList(
        original,
        movieTimescale: movieScale,
        segmentDuration: presentationSeconds * movieScale,
      );
      final inspected = M4aFragmentHeader.inspect(fixture);
      expect(
        inspected.diagnostics.editDuration,
        const Duration(seconds: presentationSeconds),
      );
      expect(
        inspected.diagnostics.editStart,
        const Duration(
          microseconds:
              editedStartSamples * Duration.microsecondsPerSecond ~/ sampleRate,
        ),
      );
    }
  });

  final unsupportedFixtures = {
    "multiple edit containers": withEditList(withEditList(original)),
    "multiple intervals": withEditList(original, entryCount: 2),
    "no intervals": withEditList(original, entryCount: 0),
    "empty edit": withEditList(original, mediaStart: -1),
    "zero duration": withEditList(original, segmentDuration: 0),
    "changed playback rate": withEditList(original, rateInteger: 2),
    "fractional playback rate": withEditList(original, rateFraction: 1),
    "unknown edit version": withEditList(original, version: 2),
  };
  for (final fixture in unsupportedFixtures.entries) {
    test("Unsupported ${fixture.key} is unchanged with a fixed reason", () {
      final inspected = M4aFragmentHeader.inspect(fixture.value);
      expect(inspected.durationFields, isEmpty);
      expect(
        inspected.diagnostics.outcome,
        M4aHeaderOutcome.unsupportedEditList,
      );
      expect(inspected.diagnostics.hasEditList, true);
      expect(inspected.apply(fixture.value, 0), fixture.value);
    });
  }

  test(
    "Truncated initialization requests more data; malformed input reports failure",
    () {
      final fixture = withEditList(original);
      final partial = M4aFragmentHeader.inspect(fixture.sublist(0, 80));
      expect(partial.diagnostics.outcome, M4aHeaderOutcome.pending);
      expect(partial.requiredLength, greaterThan(80));
      final invalid = M4aFragmentHeader.inspect(fixture.sublist(0, 3));
      expect(invalid.diagnostics.outcome, M4aHeaderOutcome.invalidHeader);
      expect(invalid.durationFields, isEmpty);
    },
  );

  test(
    "Pending range reads cannot report zero, and queued seeks reuse the completed edit inspection",
    () async {
      final fixture = withEditList(original);
      final releaseBody = Completer<void>();
      final bodyListening = Completer<void>();
      var requestCount = 0;
      Stream<List<int>> delayedBody() async* {
        bodyListening.complete();
        await releaseBody.future;
        yield fixture;
      }

      final source = IosM4aAudioSource(
        Uri.https("media.example.test", "/audio"),
        headers: {},
        client: MockClient.streaming((request, ignoredBody) async {
          requestCount++;
          return http.StreamedResponse(
            delayedBody(),
            206,
            contentLength: fixture.length,
            headers: {
              "content-range":
                  "bytes 0-${fixture.length - 1}/${fixture.length}",
            },
          );
        }),
      );
      addTearDown(source.close);
      final earlyRead = source.request(0, 2);
      await bodyListening.future;
      expect(source.normalizedDurationFields, isNull);
      expect(source.headerDiagnostics.outcome, M4aHeaderOutcome.pending);
      releaseBody.complete();
      await (await earlyRead).stream.drain<void>();
      for (final rangeStart in [0, 200, 0]) {
        final response = await source.request(rangeStart, rangeStart + 2);
        await response.stream.drain<void>();
        expect(source.normalizedDurationFields, 3);
        expect(
          source.headerDiagnostics.editStart,
          const Duration(microseconds: 36281),
        );
      }
      expect(requestCount, 1);
      expect(fixture.length, lessThan(prefixLength));
    },
  );

  test(
    "Only fixed outcomes and typed numeric edit values enter copied diagnostics",
    () {
      expect(
        M4aHeaderDiagnostics.fromMap({"m4aHeaderOutcome": "https://private"}),
        isNull,
      );
      final malformed =
          M4aHeaderDiagnostics.fromMap({
            "m4aHeaderOutcome": "unsupportedEditList",
            "m4aHasEditList": "private",
            "m4aEditStartUs": -1,
            "m4aEditDurationUs": "secret",
            "m4aEditEntryCount": 1.5,
          })!;
      expect(malformed.hasEditList, isNull);
      expect(malformed.editStart, isNull);
      expect(malformed.editDuration, isNull);
      expect(malformed.editEntryCount, isNull);
      final expected = M4aHeaderDiagnostics(
        outcome: M4aHeaderOutcome.normalized,
        hasEditList: true,
        editVersion: 1,
        editEntryCount: 1,
        editStart: const Duration(microseconds: 36281),
        editDuration: const Duration(seconds: 5),
      );
      expect(
        M4aHeaderDiagnostics.fromMap(expected.toMap())!.toMap(),
        expected.toMap(),
      );
    },
  );
}

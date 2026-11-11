import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mix_player_app/models/native_playback_timing.dart';

void main() {
  test('Native timing keeps item, asset and seekable durations separate', () {
    final timing = NativePlaybackTiming.fromMap({
      'itemDurationUs': 237125000,
      'assetDurationUs': 237125000,
      'seekableStartUs': 0,
      'seekableDurationUs': 473000000,
      'positionUs': 4000000,
      'actualIndex': 0,
      'storedIndex': 1,
      'queueLength': 2,
      'sourceCount': 3,
      'durationSource': 'item',
      'm4aHeaderFields': 3,
      'url': 'https://must-not-be-stored.test/private',
    }, NativeTimingPhase.inspect);
    expect(timing.itemDuration, const Duration(milliseconds: 237125));
    expect(timing.assetDuration, const Duration(milliseconds: 237125));
    expect(timing.seekableDuration, const Duration(seconds: 473));
    expect(timing.seekableStart, Duration.zero);
    expect(timing.position, const Duration(seconds: 4));
    expect(timing.actualIndex, 0);
    expect(timing.storedIndex, 1);
    expect(timing.queueLength, 2);
    expect(timing.sourceCount, 3);
    expect(timing.durationSource, NativeDurationSource.item);
    expect(timing.m4aHeaderFields, 3);
  });
  test('Unavailable or malformed native values remain unknown', () {
    final timing = NativePlaybackTiming.fromMap({
      'itemDurationUs': -1,
      'assetDurationUs': double.nan,
      'seekableDurationUs': 'https://private.test',
      'actualIndex': -1,
      'storedIndex': 1.5,
      'queueLength': -1,
      'durationSource': 'do-not-copy-secret',
      'm4aHeaderFields': 'do-not-copy-secret',
    }, NativeTimingPhase.load);
    expect(timing.itemDuration, isNull);
    expect(timing.assetDuration, isNull);
    expect(timing.seekableDuration, isNull);
    expect(timing.actualIndex, isNull);
    expect(timing.storedIndex, isNull);
    expect(timing.queueLength, 0);
    expect(timing.durationSource, NativeDurationSource.unknown);
    expect(timing.m4aHeaderFields, isNull);
  });
  test('History keeps the latest eight immutable snapshots', () async {
    var position = 0;
    final recorder = NativeTimingRecorder(
      () async => {'positionUs': position++},
    );
    for (var i = 0; i < 12; i++) {
      await recorder.capture(NativeTimingPhase.append);
    }
    final history = recorder.history;
    expect(history, hasLength(8));
    expect(history.first.position, const Duration(microseconds: 4));
    expect(history.last.position, const Duration(microseconds: 11));
    expect(() => history.clear(), throwsUnsupportedError);
    await recorder.capture(NativeTimingPhase.inspect);
    expect(history.last.position, const Duration(microseconds: 11));
    expect(recorder.history.last.position, const Duration(microseconds: 12));
  });
  test('A response from an invalidated load or seek is discarded', () async {
    for (final clear in [false, true]) {
      final response = Completer<Map<Object?, Object?>?>();
      final recorder = NativeTimingRecorder(() => response.future);
      final pending = recorder.capture(NativeTimingPhase.inspect);
      recorder.invalidate(clear: clear);
      response.complete({'positionUs': 1});
      await pending;
      expect(recorder.history, isEmpty);
    }
  });
  test('An automatic transition discards the previous source probe', () async {
    final response = Completer<Map<Object?, Object?>?>();
    final recorder = NativeTimingRecorder(() => response.future);
    var index = 0;
    final pending = recorder.capture(
      NativeTimingPhase.append,
      isCurrent: () => index == 0,
    );
    index = 1;
    response.complete({'actualIndex': 0});
    await pending;
    expect(recorder.history, isEmpty);
  });
  test(
    'Unavailable, failed and timed-out probes never fail playback',
    () async {
      final absent = NativeTimingRecorder(() async => null);
      final failed = NativeTimingRecorder(
        () async => throw StateError('secret'),
      );
      final late = Completer<Map<Object?, Object?>?>();
      final timedOut = NativeTimingRecorder(
        () => late.future,
        timeout: Duration.zero,
      );
      await absent.capture(NativeTimingPhase.load);
      await failed.capture(NativeTimingPhase.inspect);
      await timedOut.capture(NativeTimingPhase.append);
      late.complete({'positionUs': 1});
      await Future<void>.delayed(Duration.zero);
      expect(absent.history, isEmpty);
      expect(failed.history, isEmpty);
      expect(timedOut.history, isEmpty);
    },
  );
}

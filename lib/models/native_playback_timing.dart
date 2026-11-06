enum NativeTimingPhase { load, append, seek, inspect }

enum NativeDurationSource { unknown, item, seekable }

/// Only numeric native timing and fixed enums cross into the diagnostic report.
class NativePlaybackTiming {
  const NativePlaybackTiming({
    required this.phase,
    required this.durationSource,
    required this.queueLength,
    required this.sourceCount,
    this.itemDuration,
    this.assetDuration,
    this.seekableStart,
    this.seekableDuration,
    this.position,
    this.actualIndex,
    this.storedIndex,
  });

  factory NativePlaybackTiming.fromMap(
    Map<Object?, Object?> data,
    NativeTimingPhase phase,
  ) {
    int? nonNegative(String key) {
      final value = data[key];
      return value is int && value >= 0 ? value : null;
    }

    Duration? time(String key) {
      final value = nonNegative(key);
      return value == null ? null : Duration(microseconds: value);
    }

    return NativePlaybackTiming(
      phase: phase,
      durationSource: switch (data['durationSource']) {
        'item' => NativeDurationSource.item,
        'seekable' => NativeDurationSource.seekable,
        _ => NativeDurationSource.unknown,
      },
      itemDuration: time('itemDurationUs'),
      assetDuration: time('assetDurationUs'),
      seekableStart: time('seekableStartUs'),
      seekableDuration: time('seekableDurationUs'),
      position: time('positionUs'),
      actualIndex: nonNegative('actualIndex'),
      storedIndex: nonNegative('storedIndex'),
      queueLength: nonNegative('queueLength') ?? 0,
      sourceCount: nonNegative('sourceCount') ?? 0,
    );
  }

  final NativeTimingPhase phase;
  final NativeDurationSource durationSource;
  final Duration? itemDuration;
  final Duration? assetDuration;
  final Duration? seekableStart;
  final Duration? seekableDuration;
  final Duration? position;
  final int? actualIndex;
  final int? storedIndex;
  final int queueLength;
  final int sourceCount;
}

/// Bounded, in-memory history. Replaced loads/seeks cannot publish late replies.
class NativeTimingRecorder {
  NativeTimingRecorder(
    this.read, {
    this.timeout = const Duration(milliseconds: 500),
  });

  final Future<Map<Object?, Object?>?> Function() read;
  final Duration timeout;
  final List<NativePlaybackTiming> _history = [];
  int _revision = 0;

  List<NativePlaybackTiming> get history => List.unmodifiable(_history);

  void invalidate({bool clear = false}) {
    _revision++;
    if (clear) _history.clear();
  }

  Future<void> capture(
    NativeTimingPhase phase, {
    bool Function()? isCurrent,
  }) async {
    final revision = _revision;
    try {
      final data = await read().timeout(timeout);
      if (data == null || revision != _revision || isCurrent?.call() == false) {
        return;
      }
      _history.add(NativePlaybackTiming.fromMap(data, phase));
      if (_history.length > 8) _history.removeAt(0);
    } catch (_) {
      // An unavailable diagnostic bridge must never fail playback or leak errors.
    }
  }
}

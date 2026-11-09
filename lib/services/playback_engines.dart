import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:video_player/video_player.dart';

import '../models/api_models.dart';
import '../models/native_playback_timing.dart';
import 'ios_m4a_audio_source.dart';

enum AudioPhase { idle, loading, ready, completed }

class AudioStatus {
  const AudioStatus(this.playing, this.phase);
  final bool playing;
  final AudioPhase phase;
}

class AudioSnapshot {
  const AudioSnapshot({
    this.index,
    this.position = Duration.zero,
    this.duration,
  });

  final int? index;
  final Duration position;
  final Duration? duration;
}

class QueueEntry {
  const QueueEntry({
    required this.track,
    required this.uri,
    this.mixIndex,
    this.httpHeaders = const {},
    this.format,
    this.streamDuration,
  });
  final MixTrack track;
  final Uri uri;
  final int? mixIndex;
  final Map<String, String> httpHeaders;
  final StreamFormat? format;
  final Duration? streamDuration;
}

/// Preserve manifest transports even when the signed URL has no file extension.
AudioSource createAudioSource(QueueEntry entry, {TargetPlatform? platform}) {
  final tag = MediaItem(
    id: entry.track.videoId,
    title: entry.track.title,
    artist: entry.track.channel,
    artUri: entry.track.thumbnail,
    duration:
        entry.streamDuration != null && entry.streamDuration! > Duration.zero
            ? entry.streamDuration
            : entry.track.duration,
  );
  final protocol = entry.format?.protocol;
  if (protocol == 'm3u8' || protocol == 'm3u8_native') {
    return HlsAudioSource(entry.uri, headers: entry.httpHeaders, tag: tag);
  }
  final source = AudioSource.uri(
    entry.uri,
    headers: entry.httpHeaders,
    tag: tag,
  );
  if (source is! ProgressiveAudioSource) return source;
  if (!kIsWeb &&
      (platform ?? defaultTargetPlatform) == TargetPlatform.iOS &&
      entry.format?.ext == 'm4a' &&
      (entry.format?.acodec?.startsWith('mp4a.') ?? false)) {
    return IosM4aAudioSource(entry.uri, headers: entry.httpHeaders, tag: tag);
  }
  // AVPlayer's default timing is approximate. Request precise timing for VOD
  // without changing the media's duration or clipping it to list metadata.
  return ProgressiveAudioSource(
    entry.uri,
    headers: entry.httpHeaders,
    tag: tag,
    options: const ProgressiveAudioSourceOptions(
      darwinAssetOptions: DarwinAssetOptions(
        preferPreciseDurationAndTiming: true,
      ),
    ),
  );
}

abstract interface class AudioEngine {
  AudioSnapshot get snapshot;
  Stream<AudioStatus> get states;
  Stream<Duration> get positions;
  Stream<Duration?> get durations;
  Stream<int?> get indexes;
  Stream<String> get errors;
  Future<void> load(QueueEntry entry);
  Future<void> append(QueueEntry entry);
  Future<void> removeAt(int index);
  Future<void> move(int from, int to);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position, {int? index});
  Future<void> dispose();
}

abstract interface class NativeAudioTimingProvider {
  List<NativePlaybackTiming> get nativeTimingHistory;
  Future<void> refreshNativeTiming();
}

class JustAudioEngine implements AudioEngine, NativeAudioTimingProvider {
  final AudioPlayer _player = AudioPlayer(useProxyForRequestHeaders: false);
  late final NativeTimingRecorder _timing = NativeTimingRecorder(
    _readNativeTiming,
  );
  final _sources = <AudioSource>[];
  int _timingEpoch = 0;

  Future<Map<Object?, Object?>?> _readNativeTiming() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return null;
    final timing = await const MethodChannel(
      'com.ryanheise.just_audio.methods',
    ).invokeMapMethod<Object?, Object?>('mixGetNativeTiming');
    final index = timing?['actualIndex'];
    if (timing != null &&
        index is int &&
        index >= 0 &&
        index < _sources.length) {
      final source = _sources[index];
      if (source is IosM4aAudioSource) {
        timing['m4aHeaderFields'] = source.normalizedDurationFields;
      }
    }
    return timing;
  }

  @override
  List<NativePlaybackTiming> get nativeTimingHistory => _timing.history;

  Future<void> _captureTiming(NativeTimingPhase phase, {int? epoch}) {
    final requestedEpoch = epoch ?? _timingEpoch;
    if (requestedEpoch != _timingEpoch) return Future.value();
    final index = _player.playbackEvent.currentIndex;
    return _timing.capture(
      phase,
      isCurrent:
          () =>
              requestedEpoch == _timingEpoch &&
              _player.playbackEvent.currentIndex == index,
    );
  }

  @override
  Future<void> refreshNativeTiming() =>
      _captureTiming(NativeTimingPhase.inspect);

  @override
  AudioSnapshot get snapshot {
    final event = _player.playbackEvent;
    return AudioSnapshot(
      index: event.currentIndex,
      position: _player.position,
      duration: event.duration,
    );
  }

  @override
  Stream<AudioStatus> get states => _player.playerStateStream.map(
    (state) => AudioStatus(state.playing, switch (state.processingState) {
      ProcessingState.idle => AudioPhase.idle,
      ProcessingState.loading ||
      ProcessingState.buffering => AudioPhase.loading,
      ProcessingState.ready => AudioPhase.ready,
      ProcessingState.completed => AudioPhase.completed,
    }),
  );
  @override
  Stream<Duration> get positions => _player.positionStream;
  @override
  Stream<Duration?> get durations => _player.durationStream;
  @override
  Stream<int?> get indexes => _player.currentIndexStream;
  @override
  Stream<String> get errors =>
      _player.errorStream.map((_) => '音声を再生できません。曲を選び直して再生 URL を取得してください。');
  @override
  Future<void> load(QueueEntry entry) async {
    final epoch = ++_timingEpoch;
    _timing.invalidate(clear: true);
    final source = createAudioSource(entry);
    final previous = _sources.toList();
    _sources
      ..clear()
      ..add(source);
    try {
      await _player.setAudioSources([source]);
      await _captureTiming(NativeTimingPhase.load, epoch: epoch);
    } finally {
      _closeSources(previous);
    }
  }

  @override
  Future<void> append(QueueEntry entry) async {
    final epoch = _timingEpoch;
    final source = createAudioSource(entry);
    _sources.add(source);
    try {
      await _player.addAudioSource(source);
      await _captureTiming(NativeTimingPhase.append, epoch: epoch);
    } on Object {
      _sources.remove(source);
      _closeSources([source]);
      rethrow;
    }
  }

  @override
  Future<void> removeAt(int index) async {
    _timingEpoch++;
    _timing.invalidate();
    final source = _sources.removeAt(index);
    try {
      await _player.removeAudioSourceAt(index);
    } on Object {
      _sources.insert(index, source);
      rethrow;
    }
    _closeSources([source]);
  }

  @override
  Future<void> move(int from, int to) async {
    _timingEpoch++;
    _timing.invalidate();
    final source = _sources.removeAt(from);
    _sources.insert(to, source);
    try {
      await _player.moveAudioSource(from, to);
    } on Object {
      _sources.removeAt(to);
      _sources.insert(from, source);
      rethrow;
    }
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> stop() {
    _timingEpoch++;
    _timing.invalidate(clear: true);
    return _player.stop();
  }

  @override
  Future<void> seek(Duration position, {int? index}) async {
    final epoch = ++_timingEpoch;
    _timing.invalidate();
    await _player.seek(position, index: index);
    await _captureTiming(NativeTimingPhase.seek, epoch: epoch);
  }

  @override
  Future<void> dispose() async {
    _timingEpoch++;
    _timing.invalidate(clear: true);
    try {
      await _player.dispose();
    } finally {
      _closeSources(_sources);
      _sources.clear();
    }
  }

  void _closeSources(Iterable<AudioSource> sources) {
    for (final source in sources) {
      if (source is IosM4aAudioSource) source.close();
    }
  }
}

class VideoStatus {
  const VideoStatus({
    this.initialized = false,
    this.playing = false,
    this.completed = false,
    this.hasError = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });
  final bool initialized;
  final bool playing;
  final bool completed;
  final bool hasError;
  final Duration position;
  final Duration duration;
}

abstract interface class VideoEngine {
  VideoPlayerController? get controller;
  VideoStatus get value;
  void addListener(void Function() listener);
  void removeListener(void Function() listener);
  Future<void> initialize();
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> dispose();
}

class NativeVideoEngine implements VideoEngine {
  NativeVideoEngine(Uri uri, Map<String, String> httpHeaders)
    : controller = VideoPlayerController.networkUrl(
        uri,
        httpHeaders: httpHeaders,
        videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: false),
      );

  @override
  final VideoPlayerController controller;
  @override
  VideoStatus get value {
    final v = controller.value;
    return VideoStatus(
      initialized: v.isInitialized,
      playing: v.isPlaying,
      completed:
          v.isInitialized &&
          v.duration > Duration.zero &&
          v.position >= v.duration &&
          !v.isPlaying,
      hasError: v.hasError,
      position: v.position,
      duration: v.duration,
    );
  }

  @override
  void addListener(void Function() listener) =>
      controller.addListener(listener);
  @override
  void removeListener(void Function() listener) =>
      controller.removeListener(listener);
  @override
  Future<void> initialize() => controller.initialize();
  @override
  Future<void> play() => controller.play();
  @override
  Future<void> pause() => controller.pause();
  @override
  Future<void> seek(Duration position) => controller.seekTo(position);
  @override
  Future<void> dispose() => controller.dispose();
}

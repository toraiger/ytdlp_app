import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:video_player/video_player.dart';

import '../models/api_models.dart';
import "../models/audio_transport_diagnostics.dart";
import "error_report.dart";
import "../models/native_playback_timing.dart";
import "ios_m4a_audio_source.dart";
import "../models/prefetch_diagnostics.dart";

enum AudioPhase { idle, loading, ready, completed }

class AudioPreparationFailure implements Exception {
  const AudioPreparationFailure(this.reason, {this.retryable = true});
  final String reason;
  final bool retryable;
}

class AudioPreparationEvent {
  const AudioPreparationEvent(
    this.entry,
    this.networkGeneration,
    this.stage, {
    this.failure,
  });
  final QueueEntry entry;
  final int networkGeneration;
  final PrefetchStage stage;
  final AudioPreparationFailure? failure;
}

abstract interface class AudioPreparation {
  QueueEntry get entry;

  /// Prefix IO finishes before installation; native readiness arrives separately.
  Future<void> get ready;
  bool get mediaReady;
  void cancel();
}

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
AudioSource createAudioSource(
  QueueEntry entry, {
  TargetPlatform? platform,
  void Function(MediaTransferDiagnostics)? onFailure,
  void Function()? onPrepared,
}) {
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
    return IosM4aAudioSource(
      entry.uri,
      headers: entry.httpHeaders,
      tag: tag,
      onFailure: onFailure,
      onPrepared: onPrepared,
    );
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
  AudioTransportDiagnostics get transportDiagnostics;
  Stream<AudioStatus> get states;
  Stream<Duration> get positions;
  Stream<Duration?> get durations;
  Stream<int?> get indexes;
  Stream<MediaFailure> get errors;
  Stream<AudioPreparationEvent> get preparations;
  AudioPreparation prepare(QueueEntry entry, {required int networkGeneration});
  Future<bool> installUpcoming(
    AudioPreparation preparation, {
    QueueEntry? replacing,
  });
  Future<void> holdUpcoming(
    List<QueueEntry> entries, {
    bool rotateTransport = false,
  });
  Future<bool> retireBefore(int index);
  Future<void> load(QueueEntry entry);
  Future<void> append(QueueEntry entry);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> resetTransport();
  Future<void> seek(Duration position, {int? index});
  Future<void> dispose();
}

abstract interface class NativeAudioTimingProvider {
  List<NativePlaybackTiming> get nativeTimingHistory;
  Future<void> refreshNativeTiming();
}

class JustAudioEngine implements AudioEngine, NativeAudioTimingProvider {
  JustAudioEngine() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      _nativePreparations = const EventChannel(
        "com.ryanheise.just_audio.preparations",
      ).receiveBroadcastStream().listen(
        _onNativePreparation,
        onError: (Object failure) {},
      );
    }
  }
  final AudioPlayer _player = AudioPlayer(useProxyForRequestHeaders: false);
  late final NativeTimingRecorder _timing = NativeTimingRecorder(
    _readNativeTiming,
  );
  final _sources = <AudioSource>[];
  final _entries = <QueueEntry>[];
  final _preparedSources = <String, _PreparedAudioSource>{};
  final _preparationEvents =
      StreamController<AudioPreparationEvent>.broadcast();
  StreamSubscription<dynamic>? _nativePreparations;

  @override
  Stream<AudioPreparationEvent> get preparations => _preparationEvents.stream;

  void _emitPreparation(
    _PreparedAudioSource source,
    PrefetchStage stage, {
    AudioPreparationFailure? failure,
  }) {
    if (source.cancelled || _preparationEvents.isClosed) return;
    if (stage == PrefetchStage.ready) source.nativeReady = true;
    _preparationEvents.add(
      AudioPreparationEvent(
        source.entry,
        source.networkGeneration,
        stage,
        failure: failure,
      ),
    );
  }

  void _onNativePreparation(dynamic event) {
    if (event is! Map) return;
    final source = _preparedSources[event["sourceId"]];
    if (source == null) return;
    if (event["ready"] == true) {
      _emitPreparation(source, PrefetchStage.ready);
    } else {
      final code = event["code"];
      _emitPreparation(
        source,
        PrefetchStage.failed,
        failure: AudioPreparationFailure(
          "native_$code",
          retryable: code != -11828 && code != -11829,
        ),
      );
    }
  }

  @override
  AudioPreparation prepare(QueueEntry entry, {required int networkGeneration}) {
    late _PreparedAudioSource prepared;
    final source = createAudioSource(
      entry,
      onFailure: (failure) {
        _emitPreparation(
          prepared,
          PrefetchStage.failed,
          failure: AudioPreparationFailure(
            "${failure.stage.name}_${failure.failure.name}",
            retryable: failure.failure != MediaTransferFailure.invalidResponse,
          ),
        );
      },
      onPrepared: () => _emitPreparation(prepared, PrefetchStage.media),
    );
    prepared = _PreparedAudioSource(entry, source, networkGeneration, () {
      // Native can advance before Dart receives its new index. An installed
      // source is closed only after native confirms it is held or replaced.
      if (prepared.installed) return;
      _preparedSources.remove(_player.sourceIdentity(source));
      if (!identical(source, _currentSource)) {
        _closeSources([source]);
        unawaited(
          _player.releaseLocalSource(source).catchError((Object ignored) {}),
        );
      }
    });
    _preparedSources[_player.sourceIdentity(source)] = prepared;
    prepared.ready =
        source is IosM4aAudioSource ? source.prepare() : Future.value();
    return prepared;
  }

  @override
  Future<bool> installUpcoming(
    AudioPreparation preparation, {
    QueueEntry? replacing,
  }) async {
    final prepared = preparation as _PreparedAudioSource;
    if (prepared.cancelled) return false;
    prepared.installed = true;
    if (replacing == null) {
      _sources.add(prepared.source);
      _entries.add(prepared.entry);
      await _player.addAudioSource(prepared.source);
    } else {
      final index = _entries.indexOf(replacing);
      if (index < 0 || index <= (snapshot.index ?? 0)) {
        prepared.installed = false;
        return false;
      }
      if (!await _player.replaceUpcomingAudioSource(index, prepared.source)) {
        prepared.installed = false;
        return false;
      }
      final previous = _sources[index];
      _sources[index] = prepared.source;
      _entries[index] = prepared.entry;
      await _forgetSource(previous);
    }
    // Other platforms expose readiness through their ordinary playback stream.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      _emitPreparation(prepared, PrefetchStage.ready);
    }
    return true;
  }

  @override
  Future<void> holdUpcoming(
    List<QueueEntry> entries, {
    bool rotateTransport = false,
  }) async {
    final sources = <AudioSource>[];
    for (final entry in entries) {
      final index = _entries.indexOf(entry);
      if (index > (snapshot.index ?? 0)) sources.add(_sources[index]);
    }
    final held = await _player.holdUpcomingAudioSources(sources);
    for (final source in sources) {
      if (held.contains(_player.sourceIdentity(source))) {
        _closeSources([source]);
      }
    }
    if (rotateTransport) _player.rotateLocalProxy();
  }

  @override
  Future<bool> retireBefore(int index) async {
    if (index <= 0 || snapshot.index != index) return false;
    final previous = _sources.take(index).toList();
    if (!await _player.retirePlayedAudioSources(index)) return false;
    _sources.removeRange(0, index);
    _entries.removeRange(0, index);
    for (final source in previous) {
      await _forgetSource(source);
    }
    return true;
  }

  Future<void> _forgetSource(AudioSource source) async {
    _preparedSources.remove(_player.sourceIdentity(source));
    _closeSources([source]);
    await _player.releaseLocalSource(source);
  }

  int _timingEpoch = 0;
  AudioTransportRoute _route = AudioTransportRoute.unknown;
  TransportResetState _reset = TransportResetState.notRequested;
  MediaTransferDiagnostics? _previousTransfer;
  int _previousLocalRequestCount = 0;

  AudioSource? get _currentSource {
    final index = _player.playbackEvent.currentIndex;
    if (index != null && (index >= 0 && index < _sources.length)) {
      return _sources[index];
    }
    return _sources.length == 1 ? _sources.first : null;
  }

  @override
  AudioTransportDiagnostics get transportDiagnostics {
    final proxy = _player.localProxySnapshot;
    final source = _currentSource;
    final route = source == null ? _route : _sourceRoute(source);
    return AudioTransportDiagnostics(
      route: route,
      reset: _reset,
      proxyGeneration: proxy.generation,
      proxyListening: proxy.listening,
      localRequestCount:
          source is IosM4aAudioSource
              ? source.localRequestCount
              : _previousLocalRequestCount,
      upstream:
          source is IosM4aAudioSource
              ? source.transferDiagnostics
              : _previousTransfer,
    );
  }

  AudioTransportRoute _sourceRoute(AudioSource source) {
    if (source is IosM4aAudioSource) return AudioTransportRoute.m4aLoopback;
    if (source is HlsAudioSource) return AudioTransportRoute.hls;
    return AudioTransportRoute.direct;
  }

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
        timing.addAll(source.headerDiagnostics.toMap());
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
  Stream<MediaFailure> get errors => _player.errorStream.map(
    (failure) => MediaFailure(
      "音声を再生できません。曲を選び直して再生 URL を取得してください。",
      details: FailureDetails.fromException(failure),
    ),
  );
  @override
  Future<void> load(QueueEntry entry) async {
    final epoch = ++_timingEpoch;
    _timing.invalidate(clear: true);
    final source = createAudioSource(entry);
    _route = _sourceRoute(source);
    _previousTransfer = null;
    _previousLocalRequestCount = 0;
    final previous = _sources.toList();
    _sources
      ..clear()
      ..add(source);
    _entries
      ..clear()
      ..add(entry);
    try {
      await _player.setAudioSources([source]);
      await _captureTiming(NativeTimingPhase.load, epoch: epoch);
    } finally {
      for (final oldSource in previous) {
        await _forgetSource(oldSource);
      }
    }
  }

  @override
  Future<void> append(QueueEntry entry) async {
    final epoch = _timingEpoch;
    final source = createAudioSource(entry);
    _sources.add(source);
    _entries.add(entry);
    try {
      await _player.addAudioSource(source);
      await _captureTiming(NativeTimingPhase.append, epoch: epoch);
    } on Object {
      _sources.remove(source);
      _entries.remove(entry);
      _closeSources([source]);
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
    _reset = TransportResetState.notRequested;
    return _player.stop();
  }

  @override
  Future<void> resetTransport() async {
    try {
      final source = _currentSource;
      if (source != null) _route = _sourceRoute(source);
      if (source is IosM4aAudioSource) {
        _previousTransfer = source.transferDiagnostics;
        _previousLocalRequestCount = source.localRequestCount;
      }
      await stop();
      // Keep the AudioPlayer and its subscriptions: background playback supports
      // one player. Stop native reads before closing clients and proxy routes.
      _closeSources(_sources);
      _sources.clear();
      _entries.clear();
      for (final source in _preparedSources.values.toList()) {
        source.cancel();
      }
      _preparedSources.clear();
      await _player.resetLocalProxy();
      _reset = TransportResetState.completed;
    } catch (failure) {
      _reset = TransportResetState.failed;
      rethrow;
    }
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
      await _nativePreparations?.cancel();
      await _player.dispose();
    } finally {
      for (final source in _preparedSources.values.toList()) {
        source.cancel();
      }
      _preparedSources.clear();
      _closeSources(_sources);
      _sources.clear();
      _entries.clear();
      await _preparationEvents.close();
    }
  }

  void _closeSources(Iterable<AudioSource> sources) {
    for (final source in sources) {
      if (source is IosM4aAudioSource) source.close();
    }
  }
}

class _PreparedAudioSource implements AudioPreparation {
  _PreparedAudioSource(
    this.entry,
    this.source,
    this.networkGeneration,
    this._release,
  );
  @override
  final QueueEntry entry;
  final AudioSource source;
  final int networkGeneration;
  final void Function() _release;
  @override
  late Future<void> ready;
  @override
  bool get mediaReady =>
      source is IosM4aAudioSource &&
      (source as IosM4aAudioSource).normalizedDurationFields != null;
  bool cancelled = false;
  bool installed = false;
  bool nativeReady = false;
  @override
  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _release();
  }
}

class VideoStatus {
  const VideoStatus({
    this.initialized = false,
    this.playing = false,
    this.completed = false,
    this.hasError = false,
    this.failure,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });
  final bool initialized;
  final bool playing;
  final bool completed;
  final bool hasError;
  final FailureDetails? failure;
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
    final value = controller.value;
    return VideoStatus(
      initialized: value.isInitialized,
      playing: value.isPlaying,
      completed:
          (value.isInitialized && !value.isPlaying) &&
          (value.duration > Duration.zero && value.position >= value.duration),
      hasError: value.hasError,
      failure:
          value.hasError
              ? FailureDetails.fromException(
                PlatformException(
                  code: "VideoError",
                  message: value.errorDescription,
                ),
              )
              : null,
      position: value.position,
      duration: value.duration,
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

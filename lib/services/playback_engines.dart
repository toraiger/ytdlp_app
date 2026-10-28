import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:video_player/video_player.dart';

import '../models/api_models.dart';

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
  });
  final MixTrack track;
  final Uri uri;
  final int? mixIndex;
  final Map<String, String> httpHeaders;
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
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position, {int? index});
  Future<void> dispose();
}

class JustAudioEngine implements AudioEngine {
  final AudioPlayer _player = AudioPlayer(useProxyForRequestHeaders: false);

  @override
  AudioSnapshot get snapshot {
    final event = _player.playbackEvent;
    return AudioSnapshot(
      index: event.currentIndex,
      position: _player.position,
      duration: event.duration,
    );
  }

  AudioSource _source(QueueEntry entry) => AudioSource.uri(
    entry.uri,
    headers: entry.httpHeaders,
    tag: MediaItem(
      id: entry.track.videoId,
      title: entry.track.title,
      artist: entry.track.channel,
      artUri: entry.track.thumbnail,
      duration: entry.track.duration,
    ),
  );

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
    await _player.setAudioSources([_source(entry)]);
  }

  @override
  Future<void> append(QueueEntry entry) =>
      _player.addAudioSource(_source(entry));
  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> seek(Duration position, {int? index}) =>
      _player.seek(position, index: index);
  @override
  Future<void> dispose() => _player.dispose();
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

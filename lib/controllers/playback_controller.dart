import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../models/api_models.dart';
import '../services/api_client.dart';
import '../services/playback_engines.dart';
import 'mix_controller.dart';

typedef VideoEngineFactory =
    VideoEngine Function(Uri uri, Map<String, String> httpHeaders);

class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.mix,
    required AudioEngine audio,
    VideoEngineFactory? videoFactory,
  }) : _audio = audio,
       _videoFactory = videoFactory ?? NativeVideoEngine.new {
    _subscriptions.addAll([
      _audio.states.listen(_onAudioState),
      _audio.positions.listen((_) => _syncAudioProgress()),
      _audio.durations.listen((_) => _syncAudioProgress()),
      _audio.indexes.listen((_) => _syncAudioProgress()),
      _audio.errors.listen((value) {
        error = value;
        _notify();
      }),
    ]);
    mix.addListener(_onMixChanged);
  }

  final MixController mix;
  final AudioEngine _audio;
  final VideoEngineFactory _videoFactory;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<QueueEntry> _queue = [];
  Future<void> _audioTail = Future.value();
  VideoEngine? _video;
  int _generation = 0;
  int? _fillingGeneration;
  int? _completedGeneration;
  int? _attemptedExtendLength;
  int _queueIndex = 0;
  int _nextCandidate = 0;
  bool _disposed = false;
  bool _videoForeground = true;

  PlaybackMode mode = PlaybackMode.audio;
  MixTrack? currentTrack;
  int? currentIndex;
  bool isDirect = false;
  bool isPlaying = false;
  bool isBusy = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  String? error;

  VideoPlayerController? get videoController => _video?.controller;
  int get upcomingCount => (_queue.length - _queueIndex - 1).clamp(0, 2);

  bool _isCurrent(int generation) => !_disposed && generation == _generation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // Serialize native player mutations; stale API responses cannot modify a new queue.
  Future<void> _mutateAudio(int generation, Future<void> Function() action) {
    final operation = _audioTail.then((_) async {
      if (_isCurrent(generation)) await action();
    });
    _audioTail = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> setMode(PlaybackMode value) async {
    if (mode == value) return;
    await stop();
    mode = value;
    _notify();
  }

  Future<void> playTrack(int index) async {
    if (index < 0 || index >= mix.items.length) return;
    final track = mix.items[index];
    await _start(
      track,
      mixIndex: index,
      resolve: () async {
        final response = await mix.api.resolveStream(track.videoId);
        return mode == PlaybackMode.audio
            ? response.audio
            : response.videoAudio;
      },
    );
  }

  Future<void> playDirect(String url) async {
    final uri = playableUri(url);
    if (uri == null) {
      error = '直接再生には HTTPS のメディア URL を入力してください。';
      _notify();
      return;
    }
    await _start(
      const MixTrack(
        videoId: 'direct',
        title: '直接 URL テスト',
        channel: 'HTTPS stream',
      ),
      resolve: () async => StreamFormat(url: uri),
    );
  }

  Future<void> _start(
    MixTrack track, {
    int? mixIndex,
    required Future<StreamFormat?> Function() resolve,
  }) async {
    final generation = ++_generation;
    final requestedMode = mode;
    _queue.clear();
    _queueIndex = 0;
    _nextCandidate = (mixIndex ?? 0) + 1;
    _attemptedExtendLength = null;
    currentTrack = track;
    currentIndex = mixIndex;
    isDirect = mixIndex == null;
    isBusy = true;
    isPlaying = false;
    position = Duration.zero;
    duration = Duration.zero;
    error = null;
    _notify();
    try {
      await _releaseVideo();
      await _mutateAudio(generation, _audio.stop);
      if (!_isCurrent(generation)) return;
      final media = await resolve();
      if (!_isCurrent(generation)) return;
      final uri = media?.url;
      if (media == null || uri == null) {
        throw const ApiFailure('この曲に再生可能な HTTPS URL がありません。別の曲をお試しください。');
      }
      if (requestedMode == PlaybackMode.audio) {
        final entry = QueueEntry(
          track: track,
          uri: uri,
          mixIndex: mixIndex,
          httpHeaders: media.httpHeaders,
        );
        _queue.add(entry);
        await _mutateAudio(generation, () => _audio.load(entry));
        if (!_isCurrent(generation)) return;
        _playAudio(generation);
        if (!isDirect) unawaited(_fillQueue(generation));
      } else {
        final video = _videoFactory(uri, media.httpHeaders);
        _video = video;
        await video.initialize();
        if (!_isCurrent(generation) || _video != video) return;
        video.addListener(_onVideoChanged);
        _onVideoChanged();
        if (_videoForeground) await video.play();
      }
    } catch (e) {
      if (_isCurrent(generation)) {
        error =
            e is ApiFailure ? e.message : 'メディアを再生できません。曲を選び直すか、接続状態を確認してください。';
        isPlaying = false;
      }
    } finally {
      if (_isCurrent(generation)) {
        isBusy = false;
        if (requestedMode == PlaybackMode.audio && error == null) {
          _syncAudioProgress();
        }
        _notify();
      }
    }
  }

  void _playAudio(int generation) {
    if (!_isCurrent(generation)) return;
    unawaited(
      _audio.play().catchError((Object _) {
        if (_isCurrent(generation)) {
          error = '音声を再生できません。曲を選び直して再度お試しください。';
          isPlaying = false;
          _notify();
        }
      }),
    );
  }

  Future<void> _fillQueue(int generation) async {
    if (!_isCurrent(generation) ||
        isDirect ||
        mode != PlaybackMode.audio ||
        _queue.isEmpty ||
        _fillingGeneration == generation) {
      return;
    }
    _fillingGeneration = generation;
    try {
      while (_isCurrent(generation) && _queue.length - _queueIndex < 3) {
        if (_nextCandidate >= mix.items.length) {
          await _extendOnce(generation);
          if (!_isCurrent(generation) || _nextCandidate >= mix.items.length) {
            break;
          }
        }
        final index = _nextCandidate++;
        final track = mix.items[index];
        try {
          final response = await mix.api.resolveStream(track.videoId);
          if (!_isCurrent(generation)) return;
          final media = response.audio;
          final uri = media?.url;
          if (media == null || uri == null) {
            throw const ApiFailure('先読みした曲に音声 URL がありません。');
          }
          final entry = QueueEntry(
            track: track,
            uri: uri,
            mixIndex: index,
            httpHeaders: media.httpHeaders,
          );
          await _mutateAudio(generation, () async {
            await _audio.append(entry);
            if (_isCurrent(generation)) {
              _queue.add(entry);
              // A short track may finish while the next source is appended.
              // Re-read the player after its queue and our queue agree again.
              _syncAudioProgress();
            }
          });
          _notify();
        } catch (_) {
          if (!_isCurrent(generation)) return;
          error = '先読みできなかった曲をスキップしました。現在の曲の再生は続きます。';
          _notify();
        }
      }
    } finally {
      if (_fillingGeneration == generation) _fillingGeneration = null;
    }
  }

  Future<void> _extendOnce(int generation) async {
    if (!_isCurrent(generation) ||
        _attemptedExtendLength == mix.items.length ||
        mix.isExtending) {
      return;
    }
    _attemptedExtendLength = mix.items.length;
    await mix.extend();
  }

  void _onMixChanged() {
    if (currentTrack != null && !isDirect && !isBusy) {
      unawaited(_fillQueue(_generation));
    }
  }

  void _syncAudioProgress() {
    if (mode != PlaybackMode.audio || isBusy || currentTrack == null) return;
    final snapshot = _audio.snapshot;
    final index = snapshot.index;
    if (index == null || index < 0 || index >= _queue.length) {
      return;
    }
    final entry = _queue[index];
    final changed = _queueIndex != index || currentTrack != entry.track;
    _queueIndex = index;
    currentTrack = entry.track;
    currentIndex = entry.mixIndex;
    position = snapshot.position;
    duration = snapshot.duration ?? Duration.zero;
    if (changed) _completedGeneration = null;
    _notify();
    if (changed && !isDirect) unawaited(_fillQueue(_generation));
  }

  void _onAudioState(AudioStatus state) {
    if (mode != PlaybackMode.audio || currentTrack == null) return;
    isPlaying = state.playing && state.phase != AudioPhase.completed;
    _notify();
    if (state.phase == AudioPhase.completed &&
        !isDirect &&
        !isBusy &&
        _completedGeneration != _generation) {
      _completedGeneration = _generation;
      unawaited(next());
    }
  }

  void _onVideoChanged() {
    final value = _video?.value;
    if (value == null || mode != PlaybackMode.video) return;
    position = value.position;
    duration = value.duration;
    isPlaying = value.playing;
    if (value.hasError) {
      error = '動画を再生できません。曲を選び直して再度お試しください。';
    }
    _notify();
    if (value.completed &&
        _videoForeground &&
        !isDirect &&
        !isBusy &&
        _completedGeneration != _generation) {
      _completedGeneration = _generation;
      unawaited(next());
    }
  }

  Future<void> togglePlay() async {
    if (currentTrack == null || isBusy) return;
    try {
      if (mode == PlaybackMode.audio) {
        if (isPlaying) {
          await _mutateAudio(_generation, _audio.pause);
        } else {
          if (duration > Duration.zero && position >= duration) {
            await seek(Duration.zero);
          }
          _playAudio(_generation);
        }
      } else if (isPlaying) {
        await _video?.pause();
      } else {
        if (duration > Duration.zero && position >= duration) {
          await seek(Duration.zero);
        }
        await _video?.play();
      }
    } catch (_) {
      error = '再生操作に失敗しました。曲を選び直してください。';
      _notify();
    }
  }

  Future<void> next() async {
    if (currentIndex == null || isDirect || isBusy) return;
    final generation = _generation;
    if (mode == PlaybackMode.audio && _queueIndex + 1 < _queue.length) {
      try {
        await _mutateAudio(
          generation,
          () => _audio.seek(Duration.zero, index: _queueIndex + 1),
        );
        _playAudio(generation);
      } catch (_) {
        error = '次の曲へ移動できません。曲一覧から選び直してください。';
        _notify();
      }
      return;
    }
    final index = currentIndex! + 1;
    if (index >= mix.items.length) await _extendOnce(generation);
    if (!_isCurrent(generation)) return;
    if (index < mix.items.length) {
      await playTrack(index);
    } else {
      isPlaying = false;
      _notify();
    }
  }

  Future<void> previous() async {
    if (currentTrack == null || isBusy) return;
    if (position >= const Duration(seconds: 3) ||
        currentIndex == null ||
        currentIndex == 0) {
      await seek(Duration.zero);
    } else {
      await playTrack(currentIndex! - 1);
    }
  }

  Future<void> seek(Duration value) async {
    if (currentTrack == null || isBusy) return;
    final safe =
        value < Duration.zero
            ? Duration.zero
            : duration > Duration.zero && value > duration
            ? duration
            : value;
    try {
      if (mode == PlaybackMode.audio) {
        await _mutateAudio(_generation, () => _audio.seek(safe));
      } else {
        await _video?.seek(safe);
      }
    } catch (_) {
      error = '再生位置を変更できません。';
      _notify();
    }
  }

  Future<void> pauseVideoForBackground() async {
    _videoForeground = false;
    if (mode != PlaybackMode.video) return;
    try {
      await _video?.pause();
    } catch (_) {
      error = '動画の一時停止に失敗しました。';
      _notify();
    }
  }

  void resumeForeground() {
    _videoForeground = true;
  }

  Future<void> _releaseVideo() async {
    final old = _video;
    _video = null;
    if (old != null) {
      old.removeListener(_onVideoChanged);
      await old.dispose();
    }
  }

  Future<void> stop() async {
    final generation = ++_generation;
    _queue.clear();
    currentTrack = null;
    currentIndex = null;
    isDirect = false;
    isPlaying = false;
    isBusy = false;
    position = Duration.zero;
    duration = Duration.zero;
    error = null;
    _notify();
    try {
      await _releaseVideo();
      await _mutateAudio(generation, _audio.stop);
    } catch (_) {
      if (_isCurrent(generation)) {
        error = 'プレーヤーの停止に失敗しました。';
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    mix.removeListener(_onMixChanged);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_releaseVideo().catchError((Object _) {}));
    unawaited(
      _audioTail.then((_) => _audio.dispose()).catchError((Object _) {}),
    );
    super.dispose();
  }
}

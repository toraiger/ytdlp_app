import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../models/api_models.dart';
import '../models/playback_diagnostics.dart';
import '../services/api_client.dart';
import "../services/error_report.dart";
import '../services/playback_engines.dart';
import '../services/startup_timing.dart';
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
    _mixRevision = mix.revision;
    _subscriptions.addAll([
      _audio.states.listen(_onAudioState),
      _audio.positions.listen((_) => _syncAudioProgress()),
      _audio.durations.listen((_) => _syncAudioProgress()),
      _audio.indexes.listen((_) => _syncAudioProgress()),
      _audio.errors.listen(_onAudioError),
    ]);
    mix.addListener(_onMixChanged);
  }

  final MixController mix;
  final AudioEngine _audio;
  final VideoEngineFactory _videoFactory;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<QueueEntry> _queue = [];
  Future<void> _audioTail = Future.value();
  // _videoをnullにした後も解放が続くため、次の選択もその完了を共有して待つ。
  Future<void> _videoTail = Future.value();
  late int _mixRevision;
  Stopwatch? _startupProgress;
  VideoEngine? _video;
  int _generation = 0;
  int _selection = 0;
  int _seekRevision = 0;
  int? _fillingGeneration;
  int? _completedGeneration;
  int? _attemptedExtendLength;
  int _queueIndex = 0;
  int _nextCandidate = 0;
  bool _disposed = false;
  bool _videoForeground = true;
  Future<bool>? _firstPreparation;
  int? _firstPreparationGeneration;
  String? _preparedSession;
  ApiClient? _preparedApi;
  bool _firstMediaLoading = false;
  bool _canRefreshCurrent = false;
  // 再取得の可否とは別に、今回読み込んだURLが再取得によるものかを残す。
  bool _currentWasRefreshed = false;
  bool _playbackFailed = false;
  MediaFailure? _pendingAudioError;
  // アプリ起動直後に作るコントローラーの稼働時間で、時間経過に伴う失敗を調べる。
  final _uptime = Stopwatch()..start();

  PlaybackMode mode = PlaybackMode.audio;
  MixTrack? currentTrack;
  int? currentIndex;
  bool isDirect = false;
  bool isPlaying = false;
  bool isBusy = false;
  bool isResolvingUrl = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  String? error;
  ErrorReport? errorReport;

  VideoPlayerController? get videoController => _video?.controller;
  int get upcomingCount => (_queue.length - _queueIndex - 1).clamp(0, 2);
  int get playbackRevision => _selection;

  PlaybackDiagnostics get diagnostics {
    final audio = mode == PlaybackMode.audio ? _audio.snapshot : null;
    final video = mode == PlaybackMode.video ? _video?.value : null;
    return PlaybackDiagnostics(
      mode: mode,
      queueLength: mode == PlaybackMode.audio ? _queue.length : 0,
      listIndex: currentIndex,
      playerIndex: currentTrack == null ? null : audio?.index,
      listDuration: currentTrack?.duration,
      mediaDuration:
          currentTrack == null ? null : audio?.duration ?? video?.duration,
      mediaPosition:
          currentTrack == null
              ? Duration.zero
              : audio?.position ?? video?.position ?? Duration.zero,
    );
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _recordError(
    String message, {
    required String operation,
    Object? failure,
    bool? refreshed,
  }) {
    error = message;
    errorReport = ErrorReport.capture(
      operation: operation,
      message: message,
      failure: failure,
      playback: diagnostics,
      uptime: _uptime.elapsed,
      refreshed: refreshed ?? _currentWasRefreshed,
      apiTiming: mix.isConfigured ? mix.api.lastTiming.value : null,
    );
  }

  void _clearError() {
    error = null;
    errorReport = null;
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
    if (mode == PlaybackMode.audio) _onMixChanged();
    _notify();
  }

  /// 音声は先頭曲を読み込み、動画はURLだけ準備する。再生は開始しない。
  void prepareFirstTrack() {
    if (_disposed || mix.isLoading || mix.items.isEmpty) return;
    if (mode == PlaybackMode.audio) {
      _onMixChanged();
    } else {
      unawaited(
        mix.api
            .resolveStream(mix.items.first.videoId, mode: mode)
            .then((_) {}, onError: (Object _) {}),
      );
    }
  }

  Future<void> playTrack(int index) async {
    if (index < 0 || index >= mix.items.length) return;
    final track = mix.items[index];
    if (mode == PlaybackMode.audio && !isDirect && !_playbackFailed) {
      final preparation =
          index == 0 && _firstPreparationGeneration == _generation
              ? _firstPreparation
              : null;
      if (preparation != null || (!isBusy && _reusableQueueIndex(index) >= 0)) {
        await _activateQueuedTrack(track, index, preparation);
        return;
      }
    }
    await _startTrack(track, index, refresh: _playbackFailed);
  }

  Future<void> _startTrack(
    MixTrack track,
    int index, {
    bool refresh = false,
  }) async {
    final requestedMode = mode;
    await _start(
      track,
      mixIndex: index,
      refresh: refresh,
      cached: mix.api.cachedMedia(track.videoId, requestedMode) != null,
      resolve: (refresh) async {
        final response = await mix.api.resolveStream(
          track.videoId,
          mode: requestedMode,
          refresh: refresh,
        );
        return requestedMode == PlaybackMode.audio
            ? response.audio
            : response.videoAudio;
      },
    );
  }

  Future<void> playDirect(String url) async {
    final uri = playableUri(url);
    if (uri == null) {
      _recordError("直接再生には HTTPS のメディア URL を入力してください。", operation: "直接URLの確認");
      _notify();
      return;
    }
    await _start(
      const MixTrack(
        videoId: 'direct',
        title: '直接 URL テスト',
        channel: 'HTTPS stream',
      ),
      resolve: (_) async => StreamFormat(url: uri),
    );
  }

  Future<void> _start(
    MixTrack track, {
    int? mixIndex,
    required Future<StreamFormat?> Function(bool refresh) resolve,
    bool refresh = false,
    bool cached = false,
  }) async {
    final generation = ++_generation;
    final selection = ++_selection;
    final requestedMode = mode;
    final usesApi = mixIndex != null;
    _startupProgress = Stopwatch()..start();
    _firstPreparation = null;
    // 新規取得したURLも、一時停止や回線切替の後は失効し得るため1回だけ更新する。
    _canRefreshCurrent = usesApi && !refresh;
    _currentWasRefreshed = refresh;
    _playbackFailed = false;
    _pendingAudioError = null;
    _queue.clear();
    _queueIndex = 0;
    _nextCandidate = (mixIndex ?? 0) + 1;
    _attemptedExtendLength = null;
    currentTrack = track;
    currentIndex = mixIndex;
    isDirect = mixIndex == null;
    isBusy = true;
    isResolvingUrl = mixIndex != null && (refresh || !cached);
    isPlaying = false;
    position = Duration.zero;
    duration = Duration.zero;
    _clearError();
    _notify();
    var resolvedMedia = false;
    var operation = "再生準備（URL取得・プレーヤー停止）";
    try {
      // 両方のFutureに直ちにエラーハンドラーを付ける。終了処理中のAPI失敗も
      // 未処理例外にせず、新プレーヤーは終了処理とURL取得の両方を待って作る。
      final results = await Future.wait<StreamFormat?>([
        Future.sync(() => resolve(refresh)),
        (() async {
          await _releaseVideo();
          await _mutateAudio(generation, _audio.stop);
          return null;
        })(),
      ]);
      if (!_isCurrent(generation)) return;
      final media = results.first;
      final uri = media?.url;
      if (media == null || uri == null) {
        throw const ApiFailure('この曲に再生可能な HTTPS URL がありません。別の曲をお試しください。');
      }
      resolvedMedia = true;
      isResolvingUrl = false;
      _pendingAudioError = null;
      _notify();
      if (requestedMode == PlaybackMode.audio) {
        operation = "音声の読み込み";
        final entry = QueueEntry(
          track: track,
          uri: uri,
          mixIndex: mixIndex,
          httpHeaders: media.httpHeaders,
        );
        _queue.add(entry);
        await measureStartup(
          'player_load',
          () => _mutateAudio(generation, () => _audio.load(entry)),
        );
        if (!_isCurrent(generation)) return;
        _playAudio(generation);
        if (!isDirect) unawaited(_fillQueue(generation));
      } else {
        operation = "動画の読み込み";
        final video = _videoFactory(uri, media.httpHeaders);
        _video = video;
        await measureStartup('player_load', video.initialize);
        if (!_isCurrent(generation) || _video != video) return;
        video.addListener(_onVideoChanged);
        _onVideoChanged();
        if (_videoForeground) {
          operation = "動画の再生";
          await video.play();
        }
      }
    } catch (failure) {
      if (_isCurrent(generation)) {
        if ((usesApi && !refresh) && resolvedMedia) {
          await _start(
            track,
            mixIndex: mixIndex,
            resolve: resolve,
            refresh: true,
          );
          return;
        }
        _startupProgress = null;
        final message =
            failure is ApiFailure
                ? failure.message
                : "メディアを再生できません。曲を選び直すか、接続状態を確認してください。";
        _recordError(
          message,
          operation: operation,
          failure: failure,
          refreshed: refresh,
        );
        _playbackFailed = true;
        if (usesApi) mix.api.invalidateStream(track.videoId);
        isPlaying = false;
      }
    } finally {
      _finishPreparation(generation, selection);
    }
  }

  bool _isSelectionCurrent(int generation, int selection) =>
      _isCurrent(generation) && _selection == selection;

  int _reusableQueueIndex(int mixIndex) {
    if (mixIndex < 0 || mixIndex >= mix.items.length) return -1;
    final track = mix.items[mixIndex];
    final media = mix.api.cachedMedia(track.videoId, PlaybackMode.audio);
    return _queue.indexWhere(
      (entry) =>
          entry.mixIndex == mixIndex &&
          entry.track.videoId == track.videoId &&
          media?.url == entry.uri &&
          mapEquals(media?.httpHeaders, entry.httpHeaders),
    );
  }

  Future<void> _activateQueuedTrack(
    MixTrack track,
    int mixIndex,
    Future<bool>? preparation,
  ) async {
    final generation = _generation;
    final selection = ++_selection;
    _startupProgress = Stopwatch()..start();
    currentTrack = track;
    currentIndex = mixIndex;
    isBusy = true;
    isResolvingUrl = preparation != null && !_firstMediaLoading;
    isPlaying = false;
    position = Duration.zero;
    duration = track.duration ?? Duration.zero;
    _completedGeneration = null;
    _canRefreshCurrent = true;
    _currentWasRefreshed = false;
    _playbackFailed = false;
    _pendingAudioError = null;
    _clearError();
    _notify();
    try {
      final prepared = preparation == null || await preparation;
      if (!_isSelectionCurrent(generation, selection)) return;
      final queueIndex = prepared ? _reusableQueueIndex(mixIndex) : -1;
      if (queueIndex < 0) {
        await _startTrack(track, mixIndex, refresh: !prepared);
        return;
      }
      isResolvingUrl = false;
      await _mutateAudio(generation, () async {
        if (_isSelectionCurrent(generation, selection)) {
          await _audio.seek(Duration.zero, index: queueIndex);
        }
      });
      if (_isSelectionCurrent(generation, selection)) _playAudio(generation);
    } catch (_) {
      if (_isSelectionCurrent(generation, selection)) {
        await _startTrack(track, mixIndex, refresh: true);
      }
    } finally {
      _finishPreparation(generation, selection);
    }
  }

  void _finishPreparation(int generation, int selection) {
    if (!_isSelectionCurrent(generation, selection)) return;
    isBusy = false;
    isResolvingUrl = false;
    if (mode == PlaybackMode.audio && !_playbackFailed) {
      _syncAudioProgress();
      if (!isDirect) unawaited(_fillQueue(generation));
    }
    final pendingError = _pendingAudioError;
    _pendingAudioError = null;
    _notify();
    if (pendingError != null && !_playbackFailed) _onAudioError(pendingError);
  }

  void _onAudioError(MediaFailure failure) {
    if (_playbackFailed) return;
    if (mode != PlaybackMode.audio || currentTrack == null) return;
    if (isBusy) {
      _pendingAudioError = failure;
      return;
    }
    if (_canRefreshCurrent && !isDirect && currentIndex != null) {
      _canRefreshCurrent = false;
      unawaited(_startTrack(currentTrack!, currentIndex!, refresh: true));
      return;
    }
    _recordError(failure.message, operation: "音声の再生", failure: failure);
    _playbackFailed = true;
    if (!isDirect) mix.api.invalidateStream(currentTrack!.videoId);
    isPlaying = false;
    _notify();
  }

  void _playAudio(int generation) {
    if (!_isCurrent(generation)) return;
    final selection = _selection;
    unawaited(
      _audio.play().catchError((Object failure) {
        if (_isSelectionCurrent(generation, selection)) {
          _onAudioError(
            MediaFailure(
              "音声を再生できません。曲を選び直して再度お試しください。",
              details: FailureDetails.fromException(failure),
            ),
          );
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
        } catch (failure) {
          if (!_isCurrent(generation)) return;
          _recordError(
            "先読みできなかった曲をスキップしました。現在の曲の再生は続きます。",
            operation: "次の曲の先読み",
            failure: failure,
          );
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
    if (_mixRevision != mix.revision) {
      _mixRevision = mix.revision;
      _preparedSession = null;
      _preparedApi = null;
      if (!isDirect &&
          (currentTrack != null ||
              _firstPreparation != null ||
              _queue.isNotEmpty)) {
        unawaited(stop());
      }
    }
    if (mix.isLoading || mix.items.isEmpty) {
      _preparedSession = null;
      _preparedApi = null;
      return;
    }
    if (mode == PlaybackMode.audio &&
        currentTrack == null &&
        !isBusy &&
        (_preparedSession != mix.sessionId || _preparedApi != mix.api)) {
      _preparedSession = mix.sessionId;
      _preparedApi = mix.api;
      final generation = _generation;
      _firstPreparationGeneration = generation;
      _firstMediaLoading = false;
      final preparation = _prepareFirstTrack(generation, mix.api);
      _firstPreparation = preparation;
      unawaited(
        preparation.then((_) {
          if (identical(_firstPreparation, preparation)) {
            _firstPreparation = null;
          }
        }),
      );
    }
    if (currentTrack != null && !isDirect && !isBusy) {
      unawaited(_fillQueue(_generation));
    }
  }

  Future<bool> _prepareFirstTrack(int generation, ApiClient api) async {
    final track = mix.items.first;
    try {
      final response = await api.resolveStream(track.videoId);
      if (!_isCurrent(generation)) return false;
      final media = response.audio;
      final uri = media?.url;
      if (media == null || uri == null) return false;
      _firstMediaLoading = true;
      if (isBusy && currentIndex == 0) {
        isResolvingUrl = false;
        _notify();
      }
      await _mutateAudio(generation, () async {
        _queue
          ..clear()
          ..add(
            QueueEntry(
              track: track,
              uri: uri,
              mixIndex: 0,
              httpHeaders: media.httpHeaders,
            ),
          );
        _queueIndex = 0;
        _nextCandidate = 1;
        await measureStartup('player_load', () => _audio.load(_queue.single));
      });
      if (!_isCurrent(generation)) return false;
      unawaited(_prepareUpcomingUrls(generation, api));
      return true;
    } catch (_) {
      if (_isCurrent(generation)) {
        _queue.clear();
        api.invalidateStream(track.videoId);
      }
      return false;
    }
  }

  Future<void> _prepareUpcomingUrls(int generation, ApiClient api) async {
    final tracks = mix.items.skip(1).take(2);
    for (final track in tracks) {
      if (!_isCurrent(generation)) return;
      try {
        await api.resolveStream(track.videoId);
      } catch (_) {
        return;
      }
    }
  }

  void _syncAudioProgress() {
    if (_playbackFailed) return;
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
    duration = _trackDuration(snapshot.duration);
    position = _nonNegativePosition(snapshot.position);
    _recordFirstProgress();
    if (changed) {
      _completedGeneration = null;
      _canRefreshCurrent = true;
      _currentWasRefreshed = false;
    }
    _notify();
    if (changed && !isDirect) unawaited(_fillQueue(_generation));
  }

  void _onAudioState(AudioStatus state) {
    if (mode != PlaybackMode.audio || currentTrack == null) return;
    // 遅いネイティブ通知でエラー表示を再生中に戻したり、次曲へ進めたりしない。
    if (_playbackFailed) return;
    isPlaying = state.playing && state.phase != AudioPhase.completed;
    _recordFirstProgress();
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
    duration = _trackDuration(value.duration);
    position = _nonNegativePosition(value.position);
    isPlaying = value.playing;
    _recordFirstProgress();
    if (value.hasError) {
      // 同じエラーの位置通知で、最初に記録した発生時刻を上書きしない。
      if (!_playbackFailed) {
        _recordError(
          "動画を再生できません。曲を選び直して再度お試しください。",
          operation: "動画の再生",
          failure: MediaFailure(
            "動画の再生エラー",
            details: value.failure ?? const FailureDetails(type: "VideoError"),
          ),
        );
      }
      _playbackFailed = true;
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

  /// 再生指示だけでは発音と見なさず、位置が進んだ最初の通知で待ち時間を一度記録する。
  void _recordFirstProgress() {
    final stopwatch = _startupProgress;
    if (stopwatch == null || !isPlaying || position <= Duration.zero) return;
    _startupProgress = null;
    recordStartupTiming('tap_to_progress', stopwatch);
  }

  Future<void> togglePlay() async {
    if (currentTrack == null || isBusy) return;
    if (_playbackFailed && !isDirect) {
      await _startTrack(currentTrack!, currentIndex!, refresh: true);
      return;
    }
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
    } catch (failure) {
      _recordError(
        "再生操作に失敗しました。曲を選び直してください。",
        operation: "再生・一時停止の操作",
        failure: failure,
      );
      _notify();
    }
  }

  Future<void> next() async {
    if (currentIndex == null || isDirect || isBusy) return;
    if (mode == PlaybackMode.audio && _queueIndex + 1 < _queue.length) {
      await playTrack(_queue[_queueIndex + 1].mixIndex!);
      return;
    }
    final generation = _generation;
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
    final generation = _generation;
    final selection = _selection;
    final request = ++_seekRevision;
    final track = currentTrack;
    final requestedMode = mode;
    final index = _queueIndex;
    final video = _video;
    bool isCurrent() =>
        _isSelectionCurrent(generation, selection) &&
        request == _seekRevision &&
        identical(currentTrack, track) &&
        mode == requestedMode &&
        !isBusy;
    final safe =
        value < Duration.zero
            ? Duration.zero
            : duration > Duration.zero && value > duration
            ? duration
            : value;
    try {
      if (requestedMode == PlaybackMode.audio) {
        await _mutateAudio(generation, () async {
          if (isCurrent() && _audio.snapshot.index == index) {
            await _audio.seek(safe, index: index);
          }
        });
        if (isCurrent()) _syncAudioProgress();
      } else {
        if (isCurrent() && identical(_video, video)) {
          await video?.seek(safe);
          if (isCurrent()) _onVideoChanged();
        }
      }
    } catch (failure) {
      if (isCurrent()) {
        _recordError("再生位置を変更できません。", operation: "再生位置の変更", failure: failure);
        _notify();
      }
    }
  }

  Duration _trackDuration(Duration? reported) =>
      reported != null && reported > Duration.zero
          ? reported
          : currentTrack?.duration ?? Duration.zero;

  Duration _nonNegativePosition(Duration value) =>
      value < Duration.zero ? Duration.zero : value;

  Future<void> pauseVideoForBackground() async {
    _videoForeground = false;
    if (mode != PlaybackMode.video) return;
    try {
      await _video?.pause();
    } catch (failure) {
      _recordError(
        "動画の一時停止に失敗しました。",
        operation: "バックグラウンド移行時の一時停止",
        failure: failure,
      );
      _notify();
    }
  }

  void resumeForeground() {
    _videoForeground = true;
  }

  // 解放中の動画がある場合は後続の呼び出しも待たせ、古い解放と新規生成を重ねない。
  Future<void> _releaseVideo() {
    final old = _video;
    _video = null;
    final operation = _videoTail.then((_) async {
      if (old != null) {
        old.removeListener(_onVideoChanged);
        await old.dispose();
      }
    });
    _videoTail = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> stop() async {
    final generation = ++_generation;
    _startupProgress = null;
    _selection++;
    _firstPreparation = null;
    _pendingAudioError = null;
    _canRefreshCurrent = false;
    _currentWasRefreshed = false;
    _playbackFailed = false;
    _queue.clear();
    currentTrack = null;
    currentIndex = null;
    isDirect = false;
    isPlaying = false;
    isBusy = false;
    isResolvingUrl = false;
    position = Duration.zero;
    duration = Duration.zero;
    _clearError();
    _notify();
    try {
      await _releaseVideo();
      await _mutateAudio(generation, _audio.stop);
    } catch (failure) {
      if (_isCurrent(generation)) {
        _recordError(
          "プレーヤーの停止に失敗しました。",
          operation: "プレーヤーの停止",
          failure: failure,
        );
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _uptime.stop();
    _generation++;
    _startupProgress = null;
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

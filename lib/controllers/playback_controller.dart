import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../models/api_models.dart';
import '../models/playback_diagnostics.dart';
import "../models/prefetch_diagnostics.dart";
import '../services/api_client.dart';
import "../services/error_report.dart";
import '../services/playback_engines.dart';
import '../services/startup_timing.dart';
import "../services/network_path.dart";
import "../services/request_scope.dart";
import 'mix_controller.dart';

typedef VideoEngineFactory =
    VideoEngine Function(Uri uri, Map<String, String> httpHeaders);

typedef _ResolvedMedia = ({StreamFormat? format, Duration? duration});

class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.mix,
    required AudioEngine audio,
    VideoEngineFactory? videoFactory,
    Stream<NetworkPath>? paths,
  }) : _audio = audio,
       _videoFactory = videoFactory ?? NativeVideoEngine.new {
    _mixRevision = mix.revision;
    _subscriptions.addAll([
      _audio.states.listen(_onAudioState),
      _audio.positions.listen((_) => _syncAudioProgress()),
      _audio.durations.listen((_) => _syncAudioProgress()),
      _audio.indexes.listen((_) => _syncAudioProgress()),
      _audio.errors.listen(_onAudioError),
      _audio.preparations.listen(_onPreparationEvent),
      (paths ?? networkPaths()).listen(
        _onNetworkPath,
        onError: (Object failure) {},
      ),
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
  StreamFormat? _currentMedia;
  Duration? _streamDuration;
  int _generation = 0;
  int _selection = 0;
  int _seekRevision = 0;
  final _prefetchJobs = <int, _PrefetchJob>{};
  final _prefetchHistory = <PrefetchDiagnostics>[];
  int _networkGeneration = 0;
  bool _networkAvailable = true;
  bool _wantsPlayback = false;
  bool _advancingWaiting = false;
  bool _pruningQueue = false;
  bool _networkTransition = false;
  int? _completedGeneration;
  int? _attemptedExtendLength;
  int _queueIndex = 0;
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
  bool isWaitingForNext = false;

  VideoPlayerController? get videoController => _video?.controller;
  int get upcomingCount => (_queue.length - _queueIndex - 1).clamp(0, 2);
  int get playbackRevision => _selection;
  bool get playbackRequested => isWaitingForNext ? _wantsPlayback : isPlaying;

  PlaybackDiagnostics get diagnostics {
    final audio = mode == PlaybackMode.audio ? _audio.snapshot : null;
    final video = mode == PlaybackMode.video ? _video?.value : null;
    return PlaybackDiagnostics(
      mode: mode,
      queueLength: mode == PlaybackMode.audio ? _queue.length : 0,
      listIndex: currentIndex,
      playerIndex: currentTrack == null ? null : audio?.index,
      listDuration: currentTrack?.duration,
      apiDuration: _streamDuration,
      formatId: _currentMedia?.formatId,
      mediaExtension: _currentMedia?.ext,
      mediaProtocol: _currentMedia?.protocol,
      audioCodec: _currentMedia?.acodec,
      nativeTiming:
          mode == PlaybackMode.audio &&
                  currentTrack != null &&
                  _audio is NativeAudioTimingProvider
              ? (_audio as NativeAudioTimingProvider).nativeTimingHistory
              : const [],
      prefetch: [
        ..._prefetchHistory,
        ..._prefetchJobs.values.map((job) => job.diagnostics),
      ],
      mediaDuration:
          currentTrack == null ? null : audio?.duration ?? video?.duration,
      mediaPosition:
          currentTrack == null
              ? Duration.zero
              : audio?.position ?? video?.position ?? Duration.zero,
    );
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  Future<void> refreshNativeTiming() async {
    if (_disposed ||
        mode != PlaybackMode.audio ||
        currentTrack == null ||
        _audio is! NativeAudioTimingProvider) {
      return;
    }
    final generation = _generation;
    final selection = _selection;
    final track = currentTrack;
    try {
      await (_audio as NativeAudioTimingProvider).refreshNativeTiming();
    } catch (_) {
      // Optional diagnostics never change playback state or user-facing errors.
    }
    if (_isSelectionCurrent(generation, selection) &&
        identical(track, currentTrack)) {
      _notify();
    }
  }

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
      transport:
          mode == PlaybackMode.audio ? _audio.transportDiagnostics : null,
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
        return (
          format:
              requestedMode == PlaybackMode.audio
                  ? response.audio
                  : response.videoAudio,
          duration: response.duration,
        );
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
      resolve: (_) async => (format: StreamFormat(url: uri), duration: null),
    );
  }

  Future<void> _start(
    MixTrack track, {
    int? mixIndex,
    required Future<_ResolvedMedia> Function(bool refresh) resolve,
    bool refresh = false,
    bool cached = false,
  }) async {
    final generation = ++_generation;
    _cancelPrefetch();
    _networkTransition = false;
    isWaitingForNext = false;
    _wantsPlayback = true;
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
    _attemptedExtendLength = null;
    _currentMedia = null;
    _streamDuration = null;
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
      final results = await Future.wait<_ResolvedMedia?>([
        Future.sync(() => resolve(refresh)),
        (() async {
          await _releaseVideo();
          await _mutateAudio(
            generation,
            refresh ? _audio.resetTransport : _audio.stop,
          );
          return null;
        })(),
      ]);
      if (!_isCurrent(generation)) return;
      final resolved = results.first;
      final media = resolved?.format;
      final uri = media?.url;
      if (media == null || uri == null) {
        throw const ApiFailure('この曲に再生可能な HTTPS URL がありません。別の曲をお試しください。');
      }
      resolvedMedia = true;
      _currentMedia = media;
      _streamDuration = resolved?.duration;
      duration = _trackDuration(null);
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
          format: media,
          streamDuration: _streamDuration,
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
    final preparation = _prefetchJobs[mixIndex];
    if (preparation != null &&
        preparation.stage != PrefetchStage.ready &&
        preparation.stage != PrefetchStage.native) {
      return -1;
    }
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
    _cancelPendingPrefetch();
    isWaitingForNext = false;
    _wantsPlayback = true;
    final selection = ++_selection;
    _startupProgress = Stopwatch()..start();
    _currentMedia = null;
    _streamDuration = null;
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
      final entry = _queue[queueIndex];
      _currentMedia = entry.format;
      _streamDuration = entry.streamDuration;
      duration = _trackDuration(null);
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
    final failedIndex = failure.details.sourceIndex;
    if (failedIndex != null &&
        failedIndex > (_audio.snapshot.index ?? _queueIndex) &&
        failedIndex < _queue.length) {
      final job = _prefetchJobs[_queue[failedIndex].mixIndex];
      if (job != null) {
        _failPrefetch(job, const AudioPreparationFailure("native"));
      }
      return;
    }
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
        _networkTransition) {
      return;
    }
    final baseIndex = currentIndex ?? _queue[_queueIndex].mixIndex ?? 0;
    if (_networkAvailable && baseIndex + 2 >= mix.items.length) {
      await _extendOnce(generation);
    }
    if (!_isCurrent(generation) || _networkTransition) return;
    for (final index in [baseIndex + 1, baseIndex + 2]) {
      if (index >= mix.items.length || _prefetchJobs.containsKey(index)) {
        continue;
      }
      final existing =
          _queue.where((entry) => entry.mixIndex == index).firstOrNull;
      final job = _PrefetchJob(index, generation, _networkGeneration)
        ..installed = existing;
      _prefetchJobs[index] = job;
      _launchPrefetch(job, refresh: existing != null);
    }
  }

  bool _ownsPrefetch(_PrefetchJob job) =>
      _isCurrent(job.generation) &&
      identical(_prefetchJobs[job.index], job) &&
      job.networkGeneration == _networkGeneration;

  void _launchPrefetch(_PrefetchJob job, {bool refresh = false}) {
    if (!_ownsPrefetch(job) || job.running || job.terminal) return;
    job.timer?.cancel();
    job.timer = null;
    if (!_networkAvailable) {
      job.stage = PrefetchStage.offline;
      _notify();
      return;
    }
    job.running = true;
    job.scope = RequestScope(_networkGeneration);
    unawaited(_prepareUpcoming(job, refresh: refresh));
  }

  Future<void> _prepareUpcoming(
    _PrefetchJob job, {
    required bool refresh,
  }) async {
    final scope = job.scope!;
    try {
      job.stage = PrefetchStage.url;
      final track = mix.items[job.index];
      final response = await mix.api.resolveStream(
        track.videoId,
        refresh: refresh,
        scope: scope,
      );
      scope.check();
      if (!_ownsPrefetch(job)) return;
      final media = response.audio;
      if (media?.url == null) throw const ApiFailure("先読みした曲に再生可能な音声形式がありません。");
      final entry = QueueEntry(
        track: track,
        uri: media!.url!,
        mixIndex: job.index,
        httpHeaders: media.httpHeaders,
        format: media,
        streamDuration: response.duration,
      );
      job.stage = PrefetchStage.media;
      final prepared = _audio.prepare(
        entry,
        networkGeneration: job.networkGeneration,
      );
      job.preparation = prepared;
      // HTTP and prefix processing never hold _audioTail, so stop remains immediate.
      await Future.any([
        prepared.ready,
        scope.cancelled.then<void>((_) => throw const RequestCancelled()),
      ]);
      scope.check();
      if (!_ownsPrefetch(job)) return;
      job.prepared = true;
      job.mediaReady = prepared.mediaReady;
      job.stage = PrefetchStage.native;
      await _commitUpcoming(job.generation);
    } on RequestCancelled {
      // Expected on a new path, selection, stop or disposal.
    } catch (failure) {
      if (_ownsPrefetch(job) && !scope.isCancelled) {
        _failPrefetch(job, failure);
      }
    } finally {
      if (identical(job.scope, scope)) job.running = false;
    }
  }

  Future<void> _commitUpcoming(
    int generation,
  ) => _mutateAudio(generation, () async {
    final jobs =
        _prefetchJobs.values.toList()
          ..sort((left, right) => left.index.compareTo(right.index));
    for (final job in jobs) {
      final preparation = job.preparation;
      if (!_ownsPrefetch(job) ||
          job.scope?.isCancelled == true ||
          !job.prepared ||
          preparation == null ||
          identical(preparation.entry, job.installed)) {
        continue;
      }
      final currentMixIndex = currentIndex ?? _queue.first.mixIndex ?? 0;
      if (job.index <= currentMixIndex) continue;
      final previous = job.installed;
      if (previous == null && (_queue.last.mixIndex ?? -1) + 1 != job.index) {
        continue;
      }
      final applied = await _audio.installUpcoming(
        preparation,
        replacing: previous,
      );
      if (!_ownsPrefetch(job) || job.scope?.isCancelled == true) {
        // This mutation may have committed before the path notification arrived.
        // Keep the Dart queue aligned, then hold the old-path item for replacement.
        if (applied && _isCurrent(generation)) {
          _acceptUpcoming(job, preparation.entry, previous);
        }
        continue;
      }
      if (!applied) {
        job.replacement = "becameCurrent";
        preparation.cancel();
        _syncAudioProgress();
        continue;
      }
      _acceptUpcoming(job, preparation.entry, previous);
      job.replacement = previous == null ? "appended" : "replaced";
      job.stage = job.nativeReady ? PrefetchStage.ready : PrefetchStage.native;
      if (job.retryCount > 0) _updatePrefetchReport();
      _syncAudioProgress();
      _notify();
    }
    unawaited(_resumeWaitingNext());
  });

  void _acceptUpcoming(
    _PrefetchJob job,
    QueueEntry entry,
    QueueEntry? previous,
  ) {
    final index = previous == null ? -1 : _queue.indexOf(previous);
    if (index >= 0) {
      _queue[index] = entry;
    } else if (!_queue.contains(entry)) {
      _queue.add(entry);
    }
    job.installed = entry;
  }

  void _onPreparationEvent(AudioPreparationEvent event) {
    final job = _prefetchJobs[event.entry.mixIndex];
    if (job == null ||
        !_ownsPrefetch(job) ||
        event.networkGeneration != _networkGeneration ||
        !identical(job.preparation?.entry, event.entry)) {
      return;
    }
    // A source that has already become current belongs to normal playback.
    if (job.index <= (currentIndex ?? -1)) return;
    if (event.failure != null) {
      _failPrefetch(job, event.failure!);
    } else if (event.stage == PrefetchStage.ready) {
      job.mediaReady = true;
      job.nativeReady = true;
      job.stage = PrefetchStage.ready;
      if (job.retryCount > 0) _updatePrefetchReport();
      unawaited(_resumeWaitingNext());
    }
    _notify();
  }

  void _failPrefetch(_PrefetchJob job, Object failure) {
    if (!_ownsPrefetch(job) || job.scope?.isCancelled == true) return;
    final retryable =
        failure is ApiFailure
            ? failure.retryable
            : failure is AudioPreparationFailure
            ? failure.retryable
            : true;
    job.reason =
        failure is AudioPreparationFailure
            ? failure.reason
            : failure is ApiFailure
            ? "api_${failure.statusCode ?? "connection"}"
            : "media";
    job.scope?.cancel();
    job.preparation?.cancel();
    job.preparation = null;
    job.running = false;
    job.mediaReady = false;
    job.prepared = false;
    job.nativeReady = false;
    job.terminal = !retryable;
    job.stage = retryable ? PrefetchStage.retry : PrefetchStage.failed;
    final held = job.installed == null ? <QueueEntry>[] : [job.installed!];
    unawaited(
      _mutateAudio(
        job.generation,
        () => _audio.holdUpcoming(held),
      ).catchError((Object ignored) {}),
    );
    _recordError(
      retryable
          ? "次の曲を再準備しています。現在の曲の再生は続きます。"
          : "次の曲を準備できません。認証・公開範囲・音声形式を確認してください。",
      operation: "次の曲の先読み",
      failure: failure,
    );
    if (retryable) {
      const delays = [1, 2, 4, 8, 15];
      final retry = job.retryCount++;
      final delay =
          retry == 0
              ? Duration.zero
              : Duration(
                seconds: delays[(retry - 1).clamp(0, delays.length - 1)],
              );
      job.timer?.cancel();
      job.timer = Timer(delay, () => _launchPrefetch(job, refresh: true));
    }
    _notify();
  }

  void _updatePrefetchReport() {
    final report = errorReport;
    if (report?.operation != "次の曲の先読み") return;
    errorReport = ErrorReport.withPrefetch(report!, diagnostics.prefetch);
  }

  void _onNetworkPath(NetworkPath path) {
    if (_disposed || path.generation <= _networkGeneration) return;
    _networkGeneration = path.generation;
    _networkAvailable = path.available;
    _attemptedExtendLength = null;
    final previousJobs = _prefetchJobs.values.toList();
    for (final job in previousJobs) {
      job.scope?.cancel();
      job.timer?.cancel();
      job.preparation?.cancel();
      _prefetchJobs.remove(job.index);
    }
    if (mode != PlaybackMode.audio || isDirect || _queue.isEmpty) return;
    final generation = _generation;
    _networkTransition = true;
    unawaited(
      _mutateAudio(generation, () async {
        final held =
            _queue.skip((_audio.snapshot.index ?? _queueIndex) + 1).toList();
        await _audio.holdUpcoming(held, rotateTransport: true);
      }).then(
        (_) {
          if (!_isCurrent(generation) ||
              path.generation != _networkGeneration) {
            return;
          }
          _networkTransition = false;
          final baseIndex = currentIndex ?? _queue[_queueIndex].mixIndex ?? 0;
          for (final index in [baseIndex + 1, baseIndex + 2]) {
            if (index >= mix.items.length) continue;
            final job =
                _PrefetchJob(index, generation, _networkGeneration)
                  ..installed =
                      _queue
                          .where((entry) => entry.mixIndex == index)
                          .firstOrNull
                  ..reason = "networkChanged";
            _prefetchJobs[index] = job;
            _launchPrefetch(job, refresh: true);
          }
          unawaited(_fillQueue(generation));
        },
        onError: (Object failure) {
          if (_isCurrent(generation)) {
            _networkTransition = false;
            _recordError(
              "次の曲の接続を準備できません。",
              operation: "次の曲の先読み",
              failure: failure,
            );
          }
        },
      ),
    );
    _notify();
  }

  void _cancelPrefetch() {
    for (final job in _prefetchJobs.values) {
      job.scope?.cancel();
      job.timer?.cancel();
      job.preparation?.cancel();
    }
    _prefetchJobs.clear();
    _prefetchHistory.clear();
  }

  void _cancelPendingPrefetch() {
    for (final job in _prefetchJobs.values.toList()) {
      if (job.stage == PrefetchStage.ready ||
          (job.preparation != null &&
              identical(job.preparation!.entry, job.installed) &&
              job.scope?.isCancelled != true)) {
        continue;
      }
      job.scope?.cancel();
      job.timer?.cancel();
      if (!identical(job.preparation?.entry, job.installed)) {
        job.preparation?.cancel();
      }
      _prefetchJobs.remove(job.index);
    }
  }

  Future<void> _resumeWaitingNext() async {
    if (!isWaitingForNext ||
        !_wantsPlayback ||
        _advancingWaiting ||
        isBusy ||
        currentIndex == null) {
      return;
    }
    final job = _prefetchJobs[currentIndex! + 1];
    if (job?.installed == null ||
        !job!.nativeReady ||
        job.scope?.isCancelled == true) {
      return;
    }
    final generation = _generation;
    final selection = _selection;
    _advancingWaiting = true;
    try {
      await _mutateAudio(generation, () async {
        if (!_isSelectionCurrent(generation, selection) ||
            !_wantsPlayback ||
            !isWaitingForNext) {
          return;
        }
        final index = _queue.indexOf(job.installed!);
        if (index <= (_audio.snapshot.index ?? _queueIndex)) return;
        await _audio.seek(Duration.zero, index: index);
      });
      if (_isSelectionCurrent(generation, selection) && _wantsPlayback) {
        isWaitingForNext = false;
        _completedGeneration = null;
        _syncAudioProgress();
        _playAudio(generation);
      }
    } catch (failure) {
      if (_isSelectionCurrent(generation, selection)) {
        _failPrefetch(job, const AudioPreparationFailure("nativeTransition"));
      }
    } finally {
      _advancingWaiting = false;
      _notify();
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
              format: media,
              streamDuration: response.duration,
            ),
          );
        _queueIndex = 0;
        await measureStartup('player_load', () => _audio.load(_queue.single));
      });
      if (!_isCurrent(generation)) return false;
      unawaited(_fillQueue(generation));
      return true;
    } catch (_) {
      if (_isCurrent(generation)) {
        _queue.clear();
        api.invalidateStream(track.videoId);
      }
      return false;
    }
  }

  void _syncAudioProgress() {
    if (_pruningQueue) return;
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
    _currentMedia = entry.format;
    _streamDuration = entry.streamDuration;
    duration = _trackDuration(snapshot.duration);
    position = _nonNegativePosition(snapshot.position);
    _recordFirstProgress();
    if (changed) {
      isWaitingForNext = false;
      _completedGeneration = null;
      _canRefreshCurrent = true;
      _currentWasRefreshed = false;
    }
    _notify();
    if (changed && !isDirect) {
      for (final job in _prefetchJobs.values.toList()) {
        if (job.index > (currentIndex ?? -1)) continue;
        _prefetchHistory.add(job.diagnostics);
        job.timer?.cancel();
        job.scope?.cancel();
        _prefetchJobs.remove(job.index);
      }
      while (_prefetchHistory.length > 4) {
        _prefetchHistory.removeAt(0);
      }
      unawaited(_retirePlayed());
      unawaited(_fillQueue(_generation));
    }
  }

  Future<void> _retirePlayed() {
    final generation = _generation;
    return _mutateAudio(generation, () async {
      final index = _audio.snapshot.index ?? 0;
      if (isBusy ||
          index <= 0 ||
          index >= _queue.length ||
          _queue[index].track != currentTrack) {
        return;
      }
      _pruningQueue = true;
      try {
        if (await _audio.retireBefore(index) && _isCurrent(generation)) {
          _queue.removeRange(0, index);
          _queueIndex = 0;
        }
      } finally {
        _pruningQueue = false;
      }
      _syncAudioProgress();
    }).catchError((Object failure) {
      if (_isCurrent(generation)) {
        _recordError("再生済み音源の解放に失敗しました。", operation: "音源の解放", failure: failure);
      }
    });
  }

  void _onAudioState(AudioStatus state) {
    if (mode != PlaybackMode.audio || currentTrack == null) return;
    // 遅いネイティブ通知でエラー表示を再生中に戻したり、次曲へ進めたりしない。
    if (_playbackFailed) return;
    if (!isBusy && state.phase != AudioPhase.completed) {
      _wantsPlayback = state.playing;
      if (isWaitingForNext && _wantsPlayback) unawaited(_resumeWaitingNext());
    }
    isPlaying = state.playing && state.phase != AudioPhase.completed;
    _recordFirstProgress();
    _notify();
    if (state.phase == AudioPhase.completed &&
        !isDirect &&
        !isBusy &&
        _completedGeneration != _generation) {
      _completedGeneration = _generation;
      // A held or unresolved successor must keep its original Mix index.
      isWaitingForNext = true;
      unawaited(_waitForNext());
    }
  }

  Future<void> _waitForNext() async {
    final generation = _generation;
    await _fillQueue(generation);
    if (!_isCurrent(generation) || currentIndex == null) return;
    if (currentIndex! + 1 >= mix.items.length) {
      isWaitingForNext = false;
      _wantsPlayback = false;
      _notify();
      return;
    }
    await _resumeWaitingNext();
    _notify();
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
    if (isWaitingForNext) {
      _wantsPlayback = !_wantsPlayback;
      if (!_wantsPlayback) {
        await _mutateAudio(_generation, _audio.pause);
      } else {
        await _resumeWaitingNext();
      }
      _notify();
      return;
    }
    if (_playbackFailed && !isDirect) {
      await _startTrack(currentTrack!, currentIndex!, refresh: true);
      return;
    }
    try {
      if (mode == PlaybackMode.audio) {
        if (isPlaying) {
          _wantsPlayback = false;
          await _mutateAudio(_generation, _audio.pause);
        } else {
          _wantsPlayback = true;
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

  Duration _trackDuration(Duration? reported) {
    if (reported != null && reported > Duration.zero) return reported;
    final resolved = _streamDuration;
    if (resolved != null && resolved > Duration.zero) return resolved;
    return currentTrack?.duration ?? Duration.zero;
  }

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
    _networkTransition = false;
    _wantsPlayback = false;
    isWaitingForNext = false;
    _cancelPrefetch();
    _startupProgress = null;
    _selection++;
    _firstPreparation = null;
    _pendingAudioError = null;
    _canRefreshCurrent = false;
    _currentWasRefreshed = false;
    _playbackFailed = false;
    _queue.clear();
    _currentMedia = null;
    _streamDuration = null;
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
    _cancelPrefetch();
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

class _PrefetchJob {
  _PrefetchJob(this.index, this.generation, this.networkGeneration);
  final int index;
  final int generation;
  final int networkGeneration;
  RequestScope? scope;
  Timer? timer;
  AudioPreparation? preparation;
  QueueEntry? installed;
  PrefetchStage stage = PrefetchStage.url;
  bool running = false;
  bool terminal = false;
  bool mediaReady = false;
  bool prepared = false;
  bool nativeReady = false;
  int retryCount = 0;
  String reason = "none";
  String replacement = "pending";

  PrefetchDiagnostics get diagnostics => PrefetchDiagnostics(
    listIndex: index,
    stage: stage,
    networkGeneration: networkGeneration,
    reason: reason,
    retryCount: retryCount,
    mediaReady: mediaReady,
    nativeReady: nativeReady,
    replacement: replacement,
  );
}

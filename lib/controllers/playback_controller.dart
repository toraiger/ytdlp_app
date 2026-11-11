import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../models/api_models.dart';
import "../models/mix_queue_item.dart";
import '../models/playback_diagnostics.dart';
import '../models/youtube_video_page.dart';
import '../services/api_client.dart';
import '../services/playback_engines.dart';
import '../services/startup_timing.dart';
import 'mix_controller.dart';

typedef VideoEngineFactory =
    VideoEngine Function(Uri uri, Map<String, String> httpHeaders);

typedef _ResolvedMedia = ({StreamFormat? format, Duration? duration});

class PlaybackController extends ChangeNotifier {
  static const _upcomingLimit = 2;
  static const _readyWindowSize = _upcomingLimit + 1;
  PlaybackController({
    required this.mix,
    required AudioEngine audio,
    VideoEngineFactory? videoFactory,
  }) : _audio = audio,
       _videoFactory = videoFactory ?? NativeVideoEngine.new {
    _mixRevision = mix.revision;
    _mixEditRevision = mix.editRevision;
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
  late int _mixEditRevision;
  int _editRequest = 0;
  bool isUpdatingQueue = false;
  bool _completedDuringEdit = false;
  Stopwatch? _startupProgress;
  VideoEngine? _video;
  StreamFormat? _currentMedia;
  Duration? _streamDuration;
  int _generation = 0;
  int _selection = 0;
  int _seekRevision = 0;
  (int, int)? _fillingGeneration;
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
  bool _playbackFailed = false;
  bool _isYoutubeSingle = false;
  bool _autoPlayRequested = false;
  String? _pendingAudioError;
  Completer<void>? _queueReadiness;

  PlaybackMode mode = PlaybackMode.audio;
  MixTrack? currentTrack;
  String? currentEntryId;
  int? currentIndex;
  bool isDirect = false;
  bool isPlaying = false;
  bool isBusy = false;
  bool isResolvingUrl = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  String? error;

  VideoPlayerController? get videoController => _video?.controller;
  int get upcomingCount =>
      (_queue.length - _queueIndex - 1).clamp(0, _upcomingLimit);
  int get playbackRevision => _selection;

  bool get canAddToQueue {
    if (!mix.isConfigured || mix.isLoading) return false;
    if (isBusy || _playbackFailed) return false;
    return !isDirect || _isYoutubeSingle;
  }

  /// An accepted addition can finish resolving while auto-advance is loading
  /// the next source. Wait for that source instead of silently losing the item.
  Future<void> get readyForQueueAddition {
    if (_disposed || !isBusy) return Future.value();
    return (_queueReadiness ??= Completer<void>()).future;
  }

  void _completeQueueReadiness() {
    _queueReadiness?.complete();
    _queueReadiness = null;
  }

  MixQueueItem? get currentQueueItem {
    for (final item in mix.queueItems) {
      if (item.entryId == currentEntryId) return item;
    }
    return null;
  }

  /// Promote standalone YouTube playback without stopping, seeking or loading
  /// its source. The insertion then uses the same edit path as a Mix reorder.
  bool insertQueuedTrack(MixTrack track, QueueInsertPosition placement) {
    if (!canAddToQueue) return false;
    if (isDirect) {
      final anchor = mix.createManualQueue(currentTrack!);
      currentEntryId = anchor.entryId;
      currentIndex = 0;
      isDirect = false;
      _isYoutubeSingle = false;
      _selection++;
      if (mode == PlaybackMode.audio) {
        _queue[_queueIndex] = _queue[_queueIndex].withListItem(anchor, 0);
        _nextCandidate = 1;
      }
    }
    final index = switch (placement) {
      QueueInsertPosition.next => (currentIndex ?? -1) + 1,
      QueueInsertPosition.last => mix.items.length,
    };
    mix.insertTrack(track, index);
    return true;
  }

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
    if (!isBusy) _completeQueueReadiness();
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
    if (mode == PlaybackMode.audio &&
        !isDirect &&
        !_playbackFailed &&
        !isUpdatingQueue) {
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
    int? index, {
    bool autoPlay = true,
    bool refresh = false,
  }) async {
    final requestedMode = mode;
    final api = mix.api;
    var resolvedTrack = track;
    await _start(
      track,
      mixIndex: index,
      autoPlay: autoPlay,
      refresh: refresh,
      cached: api.cachedMedia(track.videoId, requestedMode) != null,
      usesApi: true,
      resolvedTrack: () => resolvedTrack,
      resolve: (refresh) async {
        final response = await api.resolveStream(
          track.videoId,
          mode: requestedMode,
          refresh: refresh,
        );
        if (index == null) {
          resolvedTrack = MixTrack(
            videoId: track.videoId,
            title: response.title ?? track.title,
            channel: "YouTube",
            duration: response.duration,
            webpageUrl: track.webpageUrl,
          );
        }
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

  Future<void> playYoutubeVideo(String videoId) async {
    if (!YoutubeVideoPage.isVideoId(videoId) || !mix.isConfigured) {
      error = 'YouTube動画とAPIサーバー設定を確認してください。';
      _notify();
      return;
    }
    final page = YoutubeVideoPage(videoId: videoId);
    await _startTrack(
      MixTrack(
        videoId: videoId,
        title: 'YouTube動画',
        channel: 'YouTube',
        webpageUrl: page.uri,
      ),
      null,
      refresh: _playbackFailed && currentTrack?.videoId == videoId,
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
      resolve: (_) async => (format: StreamFormat(url: uri), duration: null),
    );
  }

  Future<void> _start(
    MixTrack track, {
    int? mixIndex,
    required Future<_ResolvedMedia> Function(bool refresh) resolve,
    bool refresh = false,
    bool cached = false,
    bool autoPlay = true,
    bool usesApi = false,
    MixTrack Function()? resolvedTrack,
  }) async {
    _editRequest++;
    isUpdatingQueue = false;
    final generation = ++_generation;
    final selection = ++_selection;
    final requestedMode = mode;
    _startupProgress = Stopwatch()..start();
    _firstPreparation = null;
    _canRefreshCurrent = !refresh && cached;
    _playbackFailed = false;
    _pendingAudioError = null;
    _queue.clear();
    _queueIndex = 0;
    _nextCandidate = (mixIndex ?? 0) + 1;
    _attemptedExtendLength = null;
    _currentMedia = null;
    _streamDuration = null;
    currentTrack = track;
    currentIndex = mixIndex;
    currentEntryId = mixIndex == null ? null : mix.queueItems[mixIndex].entryId;
    final entryId = currentEntryId;
    _autoPlayRequested = autoPlay;
    isDirect = mixIndex == null;
    _isYoutubeSingle = usesApi && isDirect;
    isBusy = true;
    isResolvingUrl = usesApi && (refresh || !cached);
    isPlaying = false;
    position = Duration.zero;
    duration = Duration.zero;
    error = null;
    _notify();
    var resolvedMedia = false;
    try {
      // 両方のFutureに直ちにエラーハンドラーを付ける。終了処理中のAPI失敗も
      // 未処理例外にせず、新プレーヤーは終了処理とURL取得の両方を待って作る。
      final results = await Future.wait<_ResolvedMedia?>([
        Future.sync(() => resolve(refresh)),
        (() async {
          await _releaseVideo();
          await _mutateAudio(generation, _audio.stop);
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
      track = resolvedTrack?.call() ?? track;
      currentTrack = track;
      resolvedMedia = true;
      _currentMedia = media;
      _streamDuration = resolved?.duration;
      duration = _trackDuration(null);
      isResolvingUrl = false;
      _pendingAudioError = null;
      _notify();
      if (requestedMode == PlaybackMode.audio) {
        final entry = QueueEntry(
          track: track,
          entryId: entryId,
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
        if (autoPlay) _playAudio(generation);
        if (!isDirect) unawaited(_fillQueue(generation));
      } else {
        final video = _videoFactory(uri, media.httpHeaders);
        _video = video;
        await measureStartup('player_load', video.initialize);
        if (!_isCurrent(generation) || _video != video) return;
        video.addListener(_onVideoChanged);
        _onVideoChanged();
        if (_videoForeground && autoPlay) await video.play();
      }
    } catch (failure) {
      if (_isCurrent(generation)) {
        if (cached && !refresh && resolvedMedia) {
          await _start(
            track,
            mixIndex: mixIndex,
            resolve: resolve,
            refresh: true,
            autoPlay: autoPlay,
            usesApi: usesApi,
            resolvedTrack: resolvedTrack,
          );
          return;
        }
        _startupProgress = null;
        error =
            failure is ApiFailure
                ? failure.message
                : "メディアを再生できません。曲を選び直すか、接続状態を確認してください。";
        _playbackFailed = true;
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
    final entryId = mix.queueItems[mixIndex].entryId;
    final media = mix.api.cachedMedia(track.videoId, PlaybackMode.audio);
    return _queue.indexWhere(
      (entry) =>
          entry.mixIndex == mixIndex &&
          entry.entryId == entryId &&
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
    _autoPlayRequested = true;
    final selection = ++_selection;
    _startupProgress = Stopwatch()..start();
    _currentMedia = null;
    _streamDuration = null;
    currentTrack = track;
    currentIndex = mixIndex;
    currentEntryId = mix.queueItems[mixIndex].entryId;
    isBusy = true;
    isResolvingUrl = preparation != null && !_firstMediaLoading;
    isPlaying = false;
    position = Duration.zero;
    duration = track.duration ?? Duration.zero;
    _completedGeneration = null;
    _canRefreshCurrent = true;
    _playbackFailed = false;
    _pendingAudioError = null;
    error = null;
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

  void _onAudioError(String value) {
    if (mode != PlaybackMode.audio || currentTrack == null) return;
    if (isBusy) {
      _pendingAudioError = value;
      return;
    }
    if (_canRefreshCurrent && (!isDirect || _isYoutubeSingle)) {
      _canRefreshCurrent = false;
      unawaited(_startTrack(currentTrack!, currentIndex, refresh: true));
      return;
    }
    error = value;
    _playbackFailed = true;
    isPlaying = false;
    _notify();
  }

  void _playAudio(int generation) {
    if (!_isCurrent(generation)) return;
    final selection = _selection;
    unawaited(
      _audio.play().catchError((Object _) {
        if (_isSelectionCurrent(generation, selection)) {
          _onAudioError('音声を再生できません。曲を選び直して再度お試しください。');
        }
      }),
    );
  }

  Future<void> _fillQueue(int generation) async {
    final order = mix.editRevision;
    final filling = (generation, order);
    if (!_isCurrent(generation) ||
        isDirect ||
        mode != PlaybackMode.audio ||
        _queue.isEmpty ||
        isUpdatingQueue ||
        _fillingGeneration == filling) {
      return;
    }
    _fillingGeneration = filling;
    try {
      while (_isCurrent(generation) &&
          order == mix.editRevision &&
          !isUpdatingQueue &&
          _queue.length - _queueIndex < _readyWindowSize) {
        if (_nextCandidate >= mix.items.length) {
          await _extendOnce(generation);
          if (!_isCurrent(generation) ||
              order != mix.editRevision ||
              isUpdatingQueue ||
              _nextCandidate >= mix.items.length) {
            break;
          }
        }
        final index = _nextCandidate++;
        final track = mix.items[index];
        final entryId = mix.queueItems[index].entryId;
        try {
          final response = await mix.api.resolveStream(track.videoId);
          if (!_isCurrent(generation) ||
              order != mix.editRevision ||
              isUpdatingQueue) {
            return;
          }
          final media = response.audio;
          final uri = media?.url;
          if (media == null || uri == null) {
            throw const ApiFailure('先読みした曲に音声 URL がありません。');
          }
          final entry = QueueEntry(
            track: track,
            entryId: entryId,
            uri: uri,
            mixIndex: index,
            httpHeaders: media.httpHeaders,
            format: media,
            streamDuration: response.duration,
          );
          await _mutateAudio(generation, () async {
            if (order != mix.editRevision || isUpdatingQueue) return;
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
          if (!_isCurrent(generation) || order != mix.editRevision) return;
          error = '先読みできなかった曲をスキップしました。現在の曲の再生は続きます。';
          _notify();
        }
      }
    } finally {
      if (_fillingGeneration == filling) _fillingGeneration = null;
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
    if (_mixEditRevision != mix.editRevision) {
      _mixEditRevision = mix.editRevision;
      _applyListEdit();
      return;
    }
    if (mix.isLoading || mix.items.isEmpty) {
      _preparedSession = null;
      _preparedApi = null;
      return;
    }
    if (mix.prepareFirstTrackOnLoad &&
        mode == PlaybackMode.audio &&
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

  void _applyListEdit() {
    if (isDirect) return;
    final track = currentTrack;
    if (track == null) {
      final revision = mix.editRevision;
      final stopped = stop();
      unawaited(
        stopped.then((_) {
          if (!_disposed &&
              revision == mix.editRevision &&
              currentTrack == null) {
            _preparedSession = null;
            _onMixChanged();
          }
        }),
      );
      return;
    }
    final oldIndex = currentIndex ?? 0;
    final index = mix.queueItems.indexWhere(
      (item) => item.entryId == currentEntryId,
    );
    final resume = isBusy ? _autoPlayRequested : isPlaying;
    if (index < 0) {
      if (oldIndex < mix.items.length) {
        unawaited(_startTrack(mix.items[oldIndex], oldIndex, autoPlay: resume));
      } else {
        unawaited(stop());
      }
      return;
    }
    currentIndex = index;
    _selection++; // discard a seek preview that referred to the old queue
    if (isBusy) {
      unawaited(_startTrack(track, index, autoPlay: resume));
      return;
    }
    if (mode != PlaybackMode.audio) {
      _notify();
      return;
    }
    final request = ++_editRequest;
    final generation = _generation;
    if (!isUpdatingQueue) _completedDuringEdit = false;
    isUpdatingQueue = true;
    _notify();
    unawaited(_updateEditedQueue(generation, request, currentEntryId!));
  }

  Future<void> _updateEditedQueue(
    int generation,
    int request,
    String anchor,
  ) async {
    bool valid() => _isCurrent(generation) && request == _editRequest;
    try {
      await _mutateAudio(generation, () async {
        if (!valid()) return;
        final start = mix.queueItems.indexWhere(
          (item) => item.entryId == anchor,
        );
        if (start < 0) return;
        // Keep loaded history in the edited order for previous/lock-screen
        // navigation. Move other sources around the active source, never reload
        // or explicitly move that active source.
        final desired =
            mix.queueItems
                .take(start)
                .where(
                  (item) =>
                      _queue.any((entry) => entry.entryId == item.entryId),
                )
                .map((item) => item.entryId)
                .toList();
        final prefixLength = desired.length;
        // Retain only a contiguous ready window. A missing next source must
        // never let a later cached source jump ahead while its URL resolves.
        for (final item in mix.queueItems.skip(start).take(_readyWindowSize)) {
          if (!_queue.any((entry) => entry.entryId == item.entryId)) {
            break;
          }
          desired.add(item.entryId);
        }
        if (desired.length == prefixLength) {
          throw StateError('Missing active source');
        }
        for (
          var queueIndex = _queue.length - 1;
          queueIndex >= 0;
          queueIndex--
        ) {
          if (!valid()) return;
          if (!desired.contains(_queue[queueIndex].entryId)) {
            await _audio.removeAt(queueIndex);
            if (!_isCurrent(generation)) return;
            _queue.removeAt(queueIndex);
          }
        }
        for (var targetIndex = 0; targetIndex < desired.length; targetIndex++) {
          if (!valid()) return;
          if (desired[targetIndex] == anchor) continue;
          final from = _queue.indexWhere(
            (entry) => entry.entryId == desired[targetIndex],
          );
          if (from != targetIndex) {
            await _audio.move(from, targetIndex);
            if (!_isCurrent(generation)) return;
            _queue.insert(targetIndex, _queue.removeAt(from));
          }
        }
        for (var queueIndex = 0; queueIndex < _queue.length; queueIndex++) {
          final entry = _queue[queueIndex];
          final listIndex = mix.queueItems.indexWhere(
            (item) => item.entryId == entry.entryId,
          );
          _queue[queueIndex] = entry.withListItem(
            mix.queueItems[listIndex],
            listIndex,
          );
        }
        _queueIndex = prefixLength;
        _nextCandidate = start + _queue.length - prefixLength;
        _attemptedExtendLength = null;
        final actual = _audio.snapshot.index;
        if (actual != null &&
            actual < _queue.length &&
            _queue[actual].entryId != anchor) {
          _completedDuringEdit = true;
        }
      });
    } catch (_) {
      if (valid()) {
        await stop();
        error = '再生キューを更新できませんでした。曲を選び直してください。';
        _notify();
      }
    } finally {
      if (valid()) {
        isUpdatingQueue = false;
        if (_completedDuringEdit) {
          unawaited(next());
        } else {
          _syncAudioProgress();
          unawaited(_fillQueue(generation));
        }
        _notify();
      }
    }
  }

  Future<bool> _prepareFirstTrack(int generation, ApiClient api) async {
    final track = mix.items.first;
    final entryId = mix.queueItems.first.entryId;
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
              entryId: entryId,
              uri: uri,
              mixIndex: 0,
              httpHeaders: media.httpHeaders,
              format: media,
              streamDuration: response.duration,
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
    final tracks = mix.items.skip(1).take(_upcomingLimit);
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
    if (mode != PlaybackMode.audio ||
        isBusy ||
        isUpdatingQueue ||
        currentTrack == null) {
      return;
    }
    final snapshot = _audio.snapshot;
    final index = snapshot.index;
    if (index == null || index < 0 || index >= _queue.length) {
      return;
    }
    final entry = _queue[index];
    final changed =
        currentEntryId != entry.entryId || currentTrack != entry.track;
    _queueIndex = index;
    currentTrack = entry.track;
    currentEntryId = entry.entryId;
    currentIndex = entry.mixIndex;
    _currentMedia = entry.format;
    _streamDuration = entry.streamDuration;
    duration = _trackDuration(snapshot.duration);
    position = _nonNegativePosition(snapshot.position);
    _recordFirstProgress();
    if (changed) {
      _completedGeneration = null;
      _canRefreshCurrent = true;
    }
    _notify();
    if (changed && !isDirect) unawaited(_fillQueue(_generation));
  }

  void _onAudioState(AudioStatus state) {
    if (mode != PlaybackMode.audio || currentTrack == null) return;
    if (isUpdatingQueue) {
      if (state.phase == AudioPhase.completed) _completedDuringEdit = true;
      return;
    }
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
      _playbackFailed = true;
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

  /// 再生指示だけでは発音と見なさず、位置が進んだ最初の通知で待ち時間を一度記録する。
  void _recordFirstProgress() {
    final stopwatch = _startupProgress;
    if (stopwatch == null || !isPlaying || position <= Duration.zero) return;
    _startupProgress = null;
    recordStartupTiming('tap_to_progress', stopwatch);
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
    if (mode == PlaybackMode.audio &&
        !isUpdatingQueue &&
        _queueIndex + 1 < _queue.length) {
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
    final entryId = currentEntryId;
    final requestedMode = mode;
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
          final index = _queueIndex;
          if (isCurrent() &&
              _audio.snapshot.index == index &&
              index < _queue.length &&
              _queue[index].entryId == entryId) {
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
    } catch (_) {
      if (isCurrent()) {
        error = '再生位置を変更できません。';
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
    } catch (_) {
      error = '動画の一時停止に失敗しました。';
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
    _editRequest++;
    isUpdatingQueue = false;
    final generation = ++_generation;
    _startupProgress = null;
    _selection++;
    _firstPreparation = null;
    _pendingAudioError = null;
    _canRefreshCurrent = false;
    _playbackFailed = false;
    _queue.clear();
    _currentMedia = null;
    _streamDuration = null;
    currentTrack = null;
    currentEntryId = null;
    currentIndex = null;
    isDirect = false;
    _isYoutubeSingle = false;
    _autoPlayRequested = false;
    isPlaying = false;
    isBusy = false;
    isResolvingUrl = false;
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
    _completeQueueReadiness();
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

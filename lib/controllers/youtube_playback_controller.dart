import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/youtube_video_page.dart';
import '../services/api_client.dart';
import 'mix_controller.dart';
import 'playback_controller.dart';

/// Coordinates committed browser pages and the one shared native player.
/// Player-driven page changes are acknowledged without resolving media again.
class YoutubePlaybackController extends ChangeNotifier {
  YoutubePlaybackController({required this.mix, required this.playback}) {
    _api = mix.isConfigured ? mix.api : null;
    playback.addListener(_onPlaybackChanged);
    mix.addListener(_onMixChanged);
  }

  final MixController mix;
  final PlaybackController playback;
  Uri pageUri = YoutubeVideoPage.home;
  Uri? pageToLoad;
  int pageRevision = 0;
  bool isSelecting = false;
  String? error;
  bool _visible = false;
  bool _foreground = true;
  bool _disposed = false;
  int _selectionRevision = 0;
  ApiClient? _api;
  (String, String?)? _handledPage;
  (String, String?)? _expectedFollow;
  YoutubeVideoPage? _lastSelection;
  String? _mixId;
  int? _mixRevision;
  String? _singleVideoId;
  String? _lastPlayerVideo;

  bool get canRetry => _lastSelection != null && !isSelecting;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void setVisible(bool value) {
    _visible = value;
    if (value) _syncPlayerPage(force: true);
  }

  void setForeground(bool value) {
    _foreground = value;
    if (value) _syncPlayerPage(force: true);
  }

  void navigationStarted(Uri uri) {
    final page = YoutubeVideoPage.fromUri(uri);
    if (page != null && page.key != _expectedFollow) _expectedFollow = null;
  }

  Future<void> pageCommitted(Uri uri) async {
    if (_disposed ||
        uri.scheme != 'https' ||
        !YoutubeVideoPage.allowsNavigation(uri)) {
      return;
    }
    pageUri = uri;
    final page = YoutubeVideoPage.fromUri(uri);
    if (page == null) {
      _handledPage = null;
      // Consent/login redirects are not a new video selection. Preserve the
      // player-follow acknowledgement until a video page is reached.
      _notify();
      return;
    }
    _lastSelection = page;
    if (page.key == _expectedFollow) {
      _expectedFollow = null;
      _handledPage = page.key;
      _notify();
      return;
    }
    _expectedFollow = null;
    if (_handledPage == page.key) return;
    _handledPage = page.key;
    await _select(page);
  }

  Future<void> retry() async {
    final page = _lastSelection;
    if (page != null && !isSelecting) await _select(page);
  }

  void cancelSelection() {
    if (!isSelecting) return;
    _selectionRevision++;
    isSelecting = false;
    _handledPage = null;
    mix.cancelLoading();
    unawaited(playback.stop());
    _notify();
  }

  /// A new source or API connection must not resume a previous browser choice.
  void reset() {
    cancelSelection();
    _selectionRevision++;
    _mixId = null;
    _mixRevision = null;
    _singleVideoId = null;
    _handledPage = null;
    _expectedFollow = null;
    _lastSelection = null;
    _lastPlayerVideo = null;
    error = null;
    pageUri = YoutubeVideoPage.home;
    pageToLoad = null;
    _notify();
  }

  bool _isCurrent(int revision, ApiClient api) =>
      !_disposed &&
      revision == _selectionRevision &&
      mix.isConfigured &&
      identical(mix.api, api);

  Future<void> _select(YoutubeVideoPage page) async {
    final revision = ++_selectionRevision;
    if (!mix.isConfigured) {
      error = 'APIサーバー設定を保存してから動画を選択してください。';
      _notify();
      return;
    }
    final api = mix.api;
    isSelecting = true;
    error = null;
    _notify();
    try {
      if (!page.isMix) {
        _mixId = null;
        _mixRevision = null;
        _singleVideoId = page.videoId;
        mix.cancelLoading();
        await playback.playYoutubeVideo(page.videoId);
      } else {
        var index =
            _mixId == page.mixId && _mixRevision == mix.revision
                ? mix.items.indexWhere((track) => track.videoId == page.videoId)
                : -1;
        _singleVideoId = null;
        if (index < 0) {
          _mixId = null;
          // Stop and fetch concurrently. Suppress preparation of a different
          // first track: the selected video may be in the middle of the Mix.
          final stopped = playback.stop();
          final loaded = mix.load(
            page.uri.toString(),
            prepareFirstTrack: false,
          );
          final result = await loaded;
          await stopped;
          if (!_isCurrent(revision, api)) return;
          if (!result) throw ApiFailure(mix.error ?? 'Mixを取得できませんでした。');
          index = mix.items.indexWhere(
            (track) => track.videoId == page.videoId,
          );
          if (index < 0) {
            throw const ApiFailure('選択した動画がMixに含まれていません。再試行してください。');
          }
        }
        if (!_isCurrent(revision, api)) return;
        _mixId = page.mixId;
        _mixRevision = mix.revision;
        await playback.playTrack(index);
      }
      if (_isCurrent(revision, api)) error = playback.error;
    } catch (failure) {
      if (_isCurrent(revision, api)) error = describeFailure(failure);
    } finally {
      if (_isCurrent(revision, api)) {
        isSelecting = false;
        _syncPlayerPage(force: true);
        _notify();
      }
    }
  }

  void _onMixChanged() {
    final api = mix.isConfigured ? mix.api : null;
    if (identical(api, _api)) return;
    _api = api;
    reset();
  }

  void _onPlaybackChanged() => _syncPlayerPage();

  void _syncPlayerPage({bool force = false}) {
    if (_disposed || isSelecting) return;
    final track = playback.currentTrack;
    final id = track?.videoId;
    if (!force && id == _lastPlayerVideo) return;
    _lastPlayerVideo = id;
    if (!_visible ||
        !_foreground ||
        id == null ||
        !YoutubeVideoPage.isVideoId(id)) {
      return;
    }
    YoutubeVideoPage? target;
    if (_mixId != null && _mixRevision == mix.revision && !playback.isDirect) {
      target = YoutubeVideoPage(videoId: id, mixId: _mixId);
    } else if (_singleVideoId == id && playback.isDirect) {
      target = YoutubeVideoPage(videoId: id);
    }
    if (target == null ||
        YoutubeVideoPage.fromUri(pageUri)?.key == target.key) {
      return;
    }
    _expectedFollow = target.key;
    _handledPage = target.key;
    _lastSelection = target;
    pageUri = target.uri;
    pageToLoad = target.uri;
    pageRevision++;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _selectionRevision++;
    playback.removeListener(_onPlaybackChanged);
    mix.removeListener(_onMixChanged);
    super.dispose();
  }
}

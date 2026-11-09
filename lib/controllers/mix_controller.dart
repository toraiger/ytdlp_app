import 'package:flutter/foundation.dart';

import '../models/api_models.dart';
import '../services/api_client.dart';

class RemovedMixTrack {
  const RemovedMixTrack(this.track, this.index, this.revision);
  final MixTrack track;
  final int index;
  final int revision;
}

class MixController extends ChangeNotifier {
  ApiClient? _api;
  MixResponse? _session;
  List<MixTrack> _items = [];
  int _generation = 0;
  int editRevision = 0;
  int _extensionRevision = 0;
  final _removedIds = <String>{};
  RemovedMixTrack? _lastRemoved;
  bool _disposed = false;
  bool prepareFirstTrackOnLoad = true;
  bool isLoading = false;
  bool isExtending = false;
  String? error;
  int? lastExtensionAdded;

  List<MixTrack> get items => List.unmodifiable(_items);
  String? get sessionId => _session?.sessionId;
  String get title => _session?.playlistTitle ?? 'Your Mix';
  DateTime? get expiresAt => _session?.expiresAt;
  bool get isConfigured => _api != null;

  /// 設定変更とMix再取得を識別する世代。追加取得では変わらず、URL準備の失効に使う。
  int get revision => _generation;

  ApiClient get api => _api ?? (throw const ApiFailure('API サーバー設定を保存してください。'));

  void configure(ApiClient client) {
    _generation++;
    _api?.close();
    _api = client;
    _session = null;
    _items = [];
    _removedIds.clear();
    _lastRemoved = null;
    isLoading = false;
    isExtending = false;
    error = null;
    lastExtensionAdded = null;
    notifyListeners();
  }

  /// Invalidate an outstanding load without allowing its response to replace
  /// the list after a different YouTube video has been selected.
  void cancelLoading() {
    if (!isLoading && !isExtending) return;
    prepareFirstTrackOnLoad = false;
    _generation++;
    isLoading = false;
    isExtending = false;
    notifyListeners();
  }

  Future<bool> load(String url, {bool prepareFirstTrack = true}) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        !{
          'youtube.com',
          'www.youtube.com',
          'm.youtube.com',
          'music.youtube.com',
        }.contains(uri.host) ||
        (uri.queryParameters['list'] ?? '').isEmpty) {
      error = 'list パラメーターを含む HTTPS の YouTube Mix URL を入力してください。';
      notifyListeners();
      return false;
    }
    final generation = ++_generation;
    prepareFirstTrackOnLoad = prepareFirstTrack;
    isLoading = true;
    isExtending = false;
    error = null;
    lastExtensionAdded = null;
    notifyListeners();
    try {
      final result = await api.fetchMix(url.trim());
      if (!_isCurrent(generation)) return false;
      if (result.items.isEmpty) {
        throw const ApiFailure('Mix に曲がありません。別の Mix URL をお試しください。');
      }
      _session = result;
      _items = mergeTracks([], result.items);
      _removedIds.clear();
      _lastRemoved = null;
      return true;
    } catch (e) {
      if (_isCurrent(generation)) error = describeFailure(e);
      return false;
    } finally {
      if (_isCurrent(generation)) {
        isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<int> extend() async {
    if (_session == null || isLoading || isExtending) return 0;
    final generation = _generation;
    final session = _session!;
    final extension = ++_extensionRevision;
    isExtending = true;
    error = null;
    notifyListeners();
    try {
      final result = await api.extendMix(session.sessionId);
      if (!_isCurrent(generation) || extension != _extensionRevision) return 0;
      final merged = mergeTracks(
        _items,
        result.items.where((track) => !_removedIds.contains(track.videoId)),
      );
      final added = merged.length - _items.length;
      _items = merged;
      _session = result;
      lastExtensionAdded = added;
      return added;
    } catch (e) {
      if (_isCurrent(generation) && extension == _extensionRevision) {
        error = describeFailure(e);
      }
      return 0;
    } finally {
      if (_isCurrent(generation) && extension == _extensionRevision) {
        isExtending = false;
        notifyListeners();
      }
    }
  }

  bool moveTrack(String videoId, int toIndex) {
    if (isLoading) return false;
    final from = _items.indexWhere((track) => track.videoId == videoId);
    if (from < 0 ||
        toIndex < 0 ||
        toIndex >= _items.length ||
        from == toIndex) {
      return false;
    }
    final track = _items.removeAt(from);
    _items.insert(toIndex, track);
    editRevision++;
    notifyListeners();
    return true;
  }

  RemovedMixTrack? removeTrack(String videoId) {
    if (isLoading) return null;
    final index = _items.indexWhere((track) => track.videoId == videoId);
    if (index < 0) return null;
    final removed = RemovedMixTrack(_items.removeAt(index), index, revision);
    _removedIds.add(videoId);
    _lastRemoved = removed;
    if (_items.isEmpty) {
      // Do not repopulate an emptied list from an already pending extension.
      _extensionRevision++;
      isExtending = false;
    }
    editRevision++;
    notifyListeners();
    return removed;
  }

  bool restoreTrack(RemovedMixTrack removed) {
    if (isLoading ||
        !identical(removed, _lastRemoved) ||
        removed.revision != revision) {
      return false;
    }
    _lastRemoved = null;
    _removedIds.remove(removed.track.videoId);
    _items.insert(removed.index.clamp(0, _items.length), removed.track);
    editRevision++;
    notifyListeners();
    return true;
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _api?.close();
    super.dispose();
  }
}

String describeFailure(Object error) =>
    error is ApiFailure ? error.message : '処理に失敗しました。接続状態を確認して再度お試しください。';

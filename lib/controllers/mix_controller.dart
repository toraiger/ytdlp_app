import 'package:flutter/foundation.dart';

import '../models/api_models.dart';
import '../services/api_client.dart';

class MixController extends ChangeNotifier {
  ApiClient? _api;
  MixResponse? _session;
  List<MixTrack> _items = [];
  int _generation = 0;
  bool _disposed = false;
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
    isLoading = false;
    isExtending = false;
    error = null;
    lastExtensionAdded = null;
    notifyListeners();
  }

  Future<bool> load(String url) async {
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
    isExtending = true;
    error = null;
    notifyListeners();
    try {
      final result = await api.extendMix(session.sessionId);
      if (!_isCurrent(generation)) return 0;
      final merged = mergeTracks(_items, result.items);
      final added = merged.length - _items.length;
      _items = merged;
      _session = result;
      lastExtensionAdded = added;
      return added;
    } catch (e) {
      if (_isCurrent(generation)) error = describeFailure(e);
      return 0;
    } finally {
      if (_isCurrent(generation)) {
        isExtending = false;
        notifyListeners();
      }
    }
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

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mix_player_app/services/api_client.dart';
import 'package:mix_player_app/services/app_settings.dart';
import 'package:mix_player_app/services/playback_engines.dart';
import 'package:video_player/video_player.dart';

Map<String, dynamic> trackJson(String id) => {
  'video_id': id,
  'title': 'Track $id',
  'channel': 'Artist $id',
  'index': 1,
  'duration': 120,
};
Map<String, dynamic> mixJson(
  List<String> ids, {
  String session = 'session-1',
}) => {
  'session_id': session,
  'playlist_title': 'Test Mix',
  'playlist_id': 'RD-test',
  'items': ids.map(trackJson).toList(),
  'expires_at': '2026-10-13T05:00:00Z',
};
Map<String, dynamic> streamJson(String id) => {
  'video_id': id,
  'title': 'Track $id',
  'audio': {
    'url': 'https://media.example.test/$id.m4a',
    'ext': 'm4a',
    'http_headers': {
      'User-Agent': 'audio-$id',
      'Referer': 'https://youtube.com/',
    },
  },
  'video_audio': {
    'url': 'https://media.example.test/$id.mp4',
    'ext': 'mp4',
    'http_headers': {
      'User-Agent': 'video-$id',
      'Referer': 'https://youtube.com/',
    },
  },
};
http.Response jsonResponse(Object value, {int status = 200}) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);
ApiClient mockApi(FutureOr<http.Response> Function(http.Request) handler) =>
    ApiClient(
      serverUrl: 'https://api.example.test',
      apiKey: 'test-key',
      client: MockClient((request) async => handler(request)),
    );
Future<void> drain() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class FakeAudioEngine implements AudioEngine {
  FakeAudioEngine() {
    indexEvents.stream.listen((value) => _index = value);
    positionEvents.stream.listen((value) => _position = value);
    durationEvents.stream.listen((value) => _duration = value);
  }

  final stateEvents = StreamController<AudioStatus>.broadcast(sync: true);
  final positionEvents = StreamController<Duration>.broadcast(sync: true);
  final durationEvents = StreamController<Duration?>.broadcast(sync: true);
  final indexEvents = StreamController<int?>.broadcast(sync: true);
  final errorEvents = StreamController<String>.broadcast(sync: true);
  final entries = <QueueEntry>[];
  int loadCount = 0;
  Duration? lastSeek;
  bool playing = false;
  FutureOr<void> Function(QueueEntry entry)? onAppend;
  int? _index;
  Duration _position = Duration.zero;
  Duration? _duration;
  @override
  AudioSnapshot get snapshot =>
      AudioSnapshot(index: _index, position: _position, duration: _duration);
  @override
  Stream<AudioStatus> get states => stateEvents.stream;
  @override
  Stream<Duration> get positions => positionEvents.stream;
  @override
  Stream<Duration?> get durations => durationEvents.stream;
  @override
  Stream<int?> get indexes => indexEvents.stream;
  @override
  Stream<String> get errors => errorEvents.stream;
  @override
  Future<void> load(QueueEntry entry) async {
    loadCount++;
    _position = Duration.zero;
    _duration = null;
    entries
      ..clear()
      ..add(entry);
    indexEvents.add(0);
    durationEvents.add(const Duration(seconds: 120));
    stateEvents.add(const AudioStatus(false, AudioPhase.ready));
  }

  @override
  Future<void> append(QueueEntry entry) async {
    entries.add(entry);
    final callback = onAppend;
    if (callback != null) await callback(entry);
  }

  @override
  Future<void> play() async {
    playing = true;
    stateEvents.add(const AudioStatus(true, AudioPhase.ready));
  }

  @override
  Future<void> pause() async {
    playing = false;
    stateEvents.add(const AudioStatus(false, AudioPhase.ready));
  }

  @override
  Future<void> stop() async {
    entries.clear();
    playing = false;
    _index = null;
    _position = Duration.zero;
    _duration = null;
    stateEvents.add(const AudioStatus(false, AudioPhase.idle));
  }

  @override
  Future<void> seek(Duration position, {int? index}) async {
    lastSeek = position;
    if (index != null) indexEvents.add(index);
    positionEvents.add(position);
  }

  void advance(int index, {Duration? duration}) {
    _position = Duration.zero;
    _duration = duration ?? entries[index].track.duration;
    indexEvents.add(index);
  }

  @override
  Future<void> dispose() async {
    await Future.wait([
      stateEvents.close(),
      positionEvents.close(),
      durationEvents.close(),
      indexEvents.close(),
      errorEvents.close(),
    ]);
  }
}

class FakeVideoEngine implements VideoEngine {
  @override
  VideoPlayerController? get controller => null;
  @override
  VideoStatus value = const VideoStatus();
  final listeners = <void Function()>[];
  bool disposed = false;
  @override
  void addListener(void Function() listener) => listeners.add(listener);
  @override
  void removeListener(void Function() listener) => listeners.remove(listener);
  void emit(VideoStatus status) {
    value = status;
    for (final listener in List.of(listeners)) {
      listener();
    }
  }

  @override
  Future<void> initialize() async {
    value = const VideoStatus(
      initialized: true,
      duration: Duration(seconds: 120),
    );
  }

  @override
  Future<void> play() async {
    emit(
      const VideoStatus(
        initialized: true,
        playing: true,
        duration: Duration(seconds: 120),
      ),
    );
  }

  @override
  Future<void> pause() async {
    emit(
      const VideoStatus(initialized: true, duration: Duration(seconds: 120)),
    );
  }

  @override
  Future<void> seek(Duration position) async {
    emit(
      VideoStatus(
        initialized: true,
        position: position,
        duration: const Duration(seconds: 120),
      ),
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class MemorySettings implements SettingsStore {
  SettingsSnapshot snapshot = const SettingsSnapshot();
  String? savedMix;
  bool failWrites = false;
  @override
  Future<SettingsSnapshot> load() async => snapshot;
  @override
  Future<void> saveConnection({
    required String serverUrl,
    required String apiKey,
  }) async {
    if (failWrites) throw StateError('Storage unavailable');
    snapshot = SettingsSnapshot(serverUrl: serverUrl, apiKey: apiKey);
  }

  @override
  Future<void> saveLastMix(String url) async {
    savedMix = url;
  }
}

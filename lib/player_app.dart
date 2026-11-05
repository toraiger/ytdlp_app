import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'build_info.dart';
import 'controllers/mix_controller.dart';
import 'controllers/playback_controller.dart';
import 'controllers/youtube_playback_controller.dart';
import 'models/api_models.dart';
import 'models/api_timing.dart';
import 'models/native_playback_timing.dart';
import 'models/playback_diagnostics.dart';
import 'screens/youtube_cookies_screen.dart';
import 'screens/youtube_browser_screen.dart';
import 'widgets/youtube_webview.dart';
import 'services/api_client.dart';
import 'services/app_settings.dart';
import 'services/playback_engines.dart';
import 'services/youtube_cookie_source.dart';

typedef ApiClientFactory = ApiClient Function(String url, String key);
const _accent = Color(0xFF80E5CE);
const _muted = Color(0xFF99A9BB);
const _surface = Color(0xFF132234);
const _background = Color(0xFF091422);

class PlayerApp extends StatelessWidget {
  const PlayerApp({
    super.key,
    required this.settings,
    this.audioEngine,
    this.apiFactory,
    this.youtubeCookieSource,
    this.youtubeBrowserBuilder,
  });
  final SettingsStore settings;
  final AudioEngine? audioEngine;
  final ApiClientFactory? apiFactory;
  final YoutubeCookieSource? youtubeCookieSource;
  final YoutubeBrowserBuilder? youtubeBrowserBuilder;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Mix Player',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'NotoSansJP',
      colorScheme: ColorScheme.fromSeed(
        seedColor: _accent,
        brightness: Brightness.dark,
        surface: _surface,
      ),
      scaffoldBackgroundColor: _background,
      appBarTheme: const AppBarTheme(
        backgroundColor: _background,
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _background,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF2D4055)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
          backgroundColor: _accent,
          foregroundColor: _background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    ),
    home: _PlayerScreen(
      settings: settings,
      audioEngine: audioEngine,
      apiFactory:
          apiFactory ?? (url, key) => ApiClient(serverUrl: url, apiKey: key),
      youtubeCookieSource: youtubeCookieSource,
      youtubeBrowserBuilder: youtubeBrowserBuilder,
    ),
  );
}

class _PlayerScreen extends StatefulWidget {
  const _PlayerScreen({
    required this.settings,
    required this.apiFactory,
    this.audioEngine,
    this.youtubeCookieSource,
    this.youtubeBrowserBuilder,
  });
  final SettingsStore settings;
  final ApiClientFactory apiFactory;
  final AudioEngine? audioEngine;
  final YoutubeCookieSource? youtubeCookieSource;
  final YoutubeBrowserBuilder? youtubeBrowserBuilder;
  @override
  State<_PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<_PlayerScreen>
    with WidgetsBindingObserver {
  final _url = TextEditingController(text: defaultMixUrl);
  final _mix = MixController();
  late final PlaybackController _playback;
  late final YoutubePlaybackController _youtube;
  SettingsSnapshot _settings = const SettingsSnapshot();
  bool _initializing = true;
  String? _settingsError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _playback = PlaybackController(
      mix: _mix,
      audio: widget.audioEngine ?? JustAudioEngine(),
    );
    _youtube = YoutubePlaybackController(mix: _mix, playback: _playback);
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    try {
      final settings = await widget.settings.load();
      if (!mounted) return;
      _settings = settings;
      _url.text = settings.lastMix;
      if (settings.serverUrl.isNotEmpty) {
        _mix.configure(widget.apiFactory(settings.serverUrl, settings.apiKey));
      }
    } catch (_) {
      _settingsError = '設定を読み込めませんでした。API サーバー設定を確認してください。';
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(_playback.pauseVideoForBackground());
    } else {
      _playback.resumeForeground();
    }
  }

  Future<void> _showSettings() async {
    final youtube = await showDialog<bool>(
      context: context,
      builder:
          (_) => _ConnectionDialog(
            initial: _settings,
            playback: _playback,
            api: _mix.isConfigured ? _mix.api : null,
            onSave: (url, key) async {
              ApiClient.validateServerUrl(url);
              await widget.settings.saveConnection(serverUrl: url, apiKey: key);
              _youtube.cancelSelection();
              await _playback.stop();
              if (!mounted) return;
              _mix.configure(widget.apiFactory(url, key));
              setState(() {
                _settings = SettingsSnapshot(
                  serverUrl: url,
                  apiKey: key,
                  lastMix: _url.text,
                );
                _settingsError = null;
              });
            },
          ),
    );
    if (youtube == true && mounted && _mix.isConfigured) {
      final registered = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder:
              (_) => YoutubeCookiesScreen(
                api: _mix.api,
                source:
                    widget.youtubeCookieSource ?? NativeYoutubeCookieSource(),
              ),
        ),
      );
      if (registered == true && mounted) {
        await _playback.stop();
        if (!mounted) return;
        _mix.configure(
          widget.apiFactory(_settings.serverUrl, _settings.apiKey),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cookieを登録しました。Mixを取得し直してください。')),
        );
      }
    }
  }

  Future<void> _showYoutube() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder:
            (_) => YoutubeBrowserScreen(
              controller: _youtube,
              playback: _playback,
              playerControlsBuilder: (_) => _MiniPlayer(playback: _playback),
              browserBuilder: widget.youtubeBrowserBuilder,
            ),
      ),
    );
  }

  Future<void> _load() async {
    _youtube.reset();
    FocusManager.instance.primaryFocus?.unfocus();
    await _playback.stop();
    final loaded = await _mix.load(_url.text);
    if (loaded && mounted) {
      // 音声の自動準備と共有し、動画モードではURLだけ準備する。
      _playback.prepareFirstTrack();
      try {
        await widget.settings.saveLastMix(_url.text.trim());
      } catch (_) {
        if (mounted) setState(() => _settingsError = 'Mix URL を保存できませんでした。');
      }
    }
  }

  Future<void> _direct() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => const _DirectDialog(),
    );
    if (result != null && mounted) {
      _youtube.reset();
      await _playback.playDirect(result);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _url.dispose();
    _youtube.dispose();
    _playback.dispose();
    _mix.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_mix, _playback]),
    builder: (context, _) {
      final tracks = _mix.items;
      final trackCount = tracks.length;
      final video = _playback.videoController;
      return Scaffold(
        appBar: AppBar(
          toolbarHeight: 76,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _accent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.graphic_eq_rounded, color: _background),
              ),
              const SizedBox(width: 12),
              const Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Mix Player',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      appVersionLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: _muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'API サーバー設定',
              onPressed: _initializing ? null : _showSettings,
              icon: const Icon(Icons.tune_rounded),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: SafeArea(
          bottom: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                    sliver: SliverList.list(
                      children: [
                        const Text(
                          'A LITTLE DISCOVERY, EVERY DAY',
                          style: TextStyle(
                            color: _accent,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'いつもの曲から、\n新しい一曲へ。',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          '好きな YouTube Mix を、あなたのプレーヤーで。',
                          style: TextStyle(color: _muted, fontSize: 13),
                        ),
                        const SizedBox(height: 24),
                        if (_initializing)
                          const LinearProgressIndicator()
                        else if (!_mix.isConfigured)
                          _Notice(
                            icon: Icons.cloud_outlined,
                            text:
                                '最初に API サーバーを設定してください。\n直接 URL テストは設定なしでも使えます。',
                            action: TextButton(
                              onPressed: _showSettings,
                              child: const Text('設定する'),
                            ),
                          ),
                        const SizedBox(height: 12),
                        _sourceCard(),
                        const SizedBox(height: 20),
                        if (_settingsError != null)
                          _Notice(
                            icon: Icons.info_outline,
                            text: _settingsError!,
                          ),
                        if (_mix.error != null)
                          _Notice(
                            icon: Icons.error_outline,
                            text: _mix.error!,
                            isError: true,
                          ),
                        if (_playback.error != null)
                          _Notice(
                            icon: Icons.error_outline,
                            text: _playback.error!,
                            isError: true,
                          ),
                        if (_playback.mode == PlaybackMode.video &&
                            video != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 20),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: AspectRatio(
                                aspectRatio:
                                    video.value.isInitialized
                                        ? video.value.aspectRatio
                                        : 16 / 9,
                                child:
                                    video.value.isInitialized
                                        ? VideoPlayer(video)
                                        : const ColoredBox(
                                          color: Colors.black,
                                          child: Center(
                                            child: CircularProgressIndicator(),
                                          ),
                                        ),
                              ),
                            ),
                          ),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                tracks.isEmpty ? 'YOUR MIX' : _mix.title,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '$trackCount 曲',
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (tracks.isEmpty && !_mix.isLoading)
                          const _EmptyMix(),
                        if (_mix.isLoading)
                          const Padding(
                            padding: EdgeInsets.all(36),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                      ],
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    sliver: SliverList.builder(
                      itemCount: tracks.length,
                      itemBuilder:
                          (_, index) => _TrackTile(
                            track: tracks[index],
                            number: index + 1,
                            selected:
                                !_playback.isDirect &&
                                _playback.currentIndex == index,
                            playing: _playback.isPlaying,
                            onTap:
                                _mix.isLoading
                                    ? null
                                    : () => _playback.playTrack(index),
                          ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                    sliver: SliverToBoxAdapter(
                      child:
                          tracks.isEmpty
                              ? const SizedBox.shrink()
                              : Column(
                                children: [
                                  OutlinedButton.icon(
                                    onPressed:
                                        _mix.isExtending || _mix.isLoading
                                            ? null
                                            : _mix.extend,
                                    icon:
                                        _mix.isExtending
                                            ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                            : const Icon(
                                              Icons.add_rounded,
                                              size: 20,
                                            ),
                                    label: Text(
                                      _mix.isExtending ? '曲を取得中…' : '曲を追加取得',
                                    ),
                                  ),
                                  if (_mix.lastExtensionAdded == 0 &&
                                      _mix.error == null)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 8),
                                      child: Text(
                                        '新しい曲はありませんでした。',
                                        style: TextStyle(
                                          color: _muted,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        bottomNavigationBar: _MiniPlayer(playback: _playback),
      );
    },
  );

  Widget _sourceCard() => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: _surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFF263B50)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Mix をはじめる', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'YouTube Mix URL',
            prefixIcon: Icon(Icons.link_rounded),
          ),
          onSubmitted:
              _mix.isLoading || !_mix.isConfigured ? null : (_) => _load(),
        ),
        const SizedBox(height: 14),
        SegmentedButton<PlaybackMode>(
          segments: const [
            ButtonSegment(
              value: PlaybackMode.audio,
              icon: Icon(Icons.headphones_rounded, size: 18),
              label: Text('音声のみ'),
            ),
            ButtonSegment(
              value: PlaybackMode.video,
              icon: Icon(Icons.videocam_outlined, size: 18),
              label: Text('動画＋音声'),
            ),
          ],
          selected: {_playback.mode},
          onSelectionChanged:
              _playback.isBusy
                  ? null
                  : (selection) {
                    _youtube.cancelSelection();
                    unawaited(_playback.setMode(selection.first));
                  },
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
        ),
        const SizedBox(height: 6),
        Text(
          _playback.mode == PlaybackMode.audio
              ? '音声モードはバックグラウンド再生に対応'
              : '動画はこの画面を開いている間に再生',
          style: const TextStyle(color: _muted, fontSize: 11),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed:
                  _initializing || !_mix.isConfigured || _mix.isLoading
                      ? null
                      : _load,
              icon: const Icon(Icons.playlist_play_rounded, size: 20),
              label: Text(_mix.isLoading ? 'Mix を取得中…' : 'Mix を20曲取得'),
            ),
            if (!kIsWeb &&
                const [
                  TargetPlatform.iOS,
                  TargetPlatform.android,
                ].contains(defaultTargetPlatform))
              OutlinedButton.icon(
                onPressed:
                    _initializing || !_mix.isConfigured ? null : _showYoutube,
                icon: const Icon(Icons.ondemand_video_rounded, size: 18),
                label: const Text('YouTubeを開く'),
              ),
            TextButton.icon(
              onPressed: _initializing ? null : _direct,
              icon: const Icon(Icons.science_outlined, size: 17),
              label: const Text(
                '直接 URL で再生テスト',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.text,
    this.action,
    this.isError = false,
  });
  final IconData icon;
  final String text;
  final Widget? action;
  final bool isError;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: isError ? const Color(0xFF38222B) : _surface,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Icon(
          icon,
          size: 20,
          color: isError ? const Color(0xFFFFB4AB) : _accent,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 12, height: 1.6)),
        ),
        if (action != null) action!,
      ],
    ),
  );
}

class _EmptyMix extends StatelessWidget {
  const _EmptyMix();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
    decoration: BoxDecoration(
      color: _surface.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
    ),
    child: const Column(
      children: [
        Icon(Icons.queue_music_rounded, size: 44, color: _muted),
        SizedBox(height: 14),
        Text('ここに、あなたの Mix が並びます。', style: TextStyle(fontSize: 14)),
        SizedBox(height: 8),
        Text(
          'YouTube の Mix URL を貼り付けて\n「Mix を20曲取得」をタップしてください。',
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted, fontSize: 12, height: 1.7),
        ),
      ],
    ),
  );
}

class _Artwork extends StatelessWidget {
  const _Artwork({this.uri, this.size = 52});
  final Uri? uri;
  final double size;
  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: const Color(0xFF223C49),
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          color: _accent,
          size: size * 0.45,
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox.square(
        dimension: size,
        child:
            uri == null
                ? fallback
                : Image.network(
                  uri.toString(),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => fallback,
                ),
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.track,
    required this.number,
    required this.selected,
    required this.playing,
    this.onTap,
  });
  final MixTrack track;
  final int number;
  final bool selected;
  final bool playing;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Material(
      color: selected ? const Color(0xFF173B3B) : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                child:
                    selected && playing
                        ? const Icon(
                          Icons.graphic_eq_rounded,
                          size: 18,
                          color: _accent,
                        )
                        : Text(
                          '$number',
                          style: const TextStyle(color: _muted, fontSize: 11),
                        ),
              ),
              _Artwork(uri: track.thumbnail),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: selected ? _accent : null,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      track.channel.isEmpty ? 'YouTube' : track.channel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatTime(track.duration),
                style: const TextStyle(color: _muted, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

String formatTime(Duration? duration) {
  if (duration == null) return '—';
  final seconds = duration.inSeconds.clamp(0, 864000);
  final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
  final remainder = (seconds % 60).toString().padLeft(2, '0');
  return '$minutes:$remainder';
}

class _MiniPlayer extends StatefulWidget {
  const _MiniPlayer({required this.playback});
  final PlaybackController playback;
  @override
  State<_MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<_MiniPlayer> {
  PlaybackController get playback => widget.playback;
  Duration? _seekPreview;
  MixTrack? _previewTrack;
  int? _previewRevision;
  PlaybackMode? _previewMode;
  int _previewRequest = 0;

  bool get _previewIsCurrent =>
      identical(_previewTrack, playback.currentTrack) &&
      _previewRevision == playback.playbackRevision &&
      _previewMode == playback.mode &&
      !playback.isBusy;

  @override
  void didUpdateWidget(covariant _MiniPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_seekPreview != null && !_previewIsCurrent) {
      _seekPreview = null;
      _previewRequest++;
    }
  }

  void _beginSeek(double value) {
    _previewRequest++;
    setState(() {
      _previewTrack = playback.currentTrack;
      _previewRevision = playback.playbackRevision;
      _previewMode = playback.mode;
      _seekPreview = Duration(milliseconds: value.round());
    });
  }

  void _previewSeek(double value) {
    if (!_previewIsCurrent) return;
    setState(() => _seekPreview = Duration(milliseconds: value.round()));
  }

  Future<void> _commitSeek(double value) async {
    if (_seekPreview == null || !_previewIsCurrent) return;
    final request = _previewRequest;
    await playback.seek(Duration(milliseconds: value.round()));
    if (mounted && request == _previewRequest) {
      setState(() => _seekPreview = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = playback.currentTrack;
    final enabled = track != null && !playback.isBusy;
    final duration = playback.duration.inMilliseconds.toDouble();
    final shownPosition = _seekPreview ?? playback.position;
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF101F30),
        border: Border(top: BorderSide(color: Color(0xFF2A3C4E))),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      _Artwork(uri: track?.thumbnail, size: 40),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track?.title ?? '再生する曲を選択',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              playback.isBusy
                                  ? playback.isResolvingUrl
                                      ? '再生 URL を取得中…'
                                      : 'メディアを読み込み中…'
                                  : track?.channel ?? 'あなたの Mix を待っています',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        playback.mode == PlaybackMode.audio
                            ? Icons.headphones_rounded
                            : Icons.videocam_outlined,
                        size: 18,
                        color: _muted,
                      ),
                    ],
                  ),
                  SizedBox(
                    height: 32,
                    child: Slider(
                      value:
                          duration <= 0
                              ? 0
                              : shownPosition.inMilliseconds.toDouble().clamp(
                                0,
                                duration,
                              ),
                      max: duration <= 0 ? 1 : duration,
                      onChangeStart:
                          enabled && duration > 0 ? _beginSeek : null,
                      onChanged: enabled && duration > 0 ? _previewSeek : null,
                      onChangeEnd:
                          enabled && duration > 0
                              ? (value) => unawaited(_commitSeek(value))
                              : null,
                      semanticFormatterCallback:
                          (value) =>
                              formatTime(Duration(milliseconds: value.round())),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: '前の曲',
                        onPressed: enabled ? playback.previous : null,
                        icon: const Icon(Icons.skip_previous_rounded),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: playback.isPlaying ? '一時停止' : '再生',
                        style: IconButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: _background,
                        ),
                        onPressed: enabled ? playback.togglePlay : null,
                        icon:
                            playback.isBusy
                                ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : Icon(
                                  playback.isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: '次の曲',
                        onPressed:
                            enabled && !playback.isDirect
                                ? playback.next
                                : null,
                        icon: const Icon(Icons.skip_next_rounded),
                      ),
                      IconButton(
                        tooltip: '停止',
                        onPressed: track != null ? playback.stop : null,
                        icon: const Icon(Icons.stop_rounded, size: 20),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        formatTime(shownPosition),
                        style: const TextStyle(color: _muted, fontSize: 10),
                      ),
                      Text(
                        formatTime(playback.duration),
                        style: const TextStyle(color: _muted, fontSize: 10),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionDialog extends StatefulWidget {
  const _ConnectionDialog({
    required this.initial,
    required this.playback,
    required this.onSave,
    this.api,
  });
  final SettingsSnapshot initial;
  final PlaybackController playback;
  final ApiClient? api;
  final Future<void> Function(String url, String key) onSave;
  @override
  State<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<_ConnectionDialog> {
  final _form = GlobalKey<FormState>();
  late final _server = TextEditingController(text: widget.initial.serverUrl);
  late final _key = TextEditingController(text: widget.initial.apiKey);
  bool _saving = false;
  String? _error;
  bool get _canUseYoutube =>
      !_saving &&
      widget.api?.hasApiKey == true &&
      _server.text.trim() == widget.initial.serverUrl.trim() &&
      _key.text.trim() == widget.initial.apiKey.trim();
  @override
  void dispose() {
    _server.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(_server.text.trim(), _key.text.trim());
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '設定を保存できませんでした。安全なストレージが利用可能か確認してください。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: const Text('API サーバー設定'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _form,
          onChanged: () => setState(() {}),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'バージョン $appVersionLabel',
                  style: TextStyle(color: _muted, fontSize: 12),
                ),
                if (appRevision.isNotEmpty)
                  const Text(
                    'コミット $appRevision',
                    style: TextStyle(color: _muted, fontSize: 11),
                  ),
                const SizedBox(height: 12),
                const Text(
                  'HTTPS の接続先と API キーを設定します。\nAPI キーは安全なストレージに保存されます。',
                  style: TextStyle(color: _muted, fontSize: 12, height: 1.6),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _server,
                  enabled: !_saving,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'HTTPS API URL',
                    hintText: 'https://api.example.com',
                  ),
                  validator: (value) {
                    try {
                      ApiClient.validateServerUrl(value ?? '');
                      return null;
                    } on ApiFailure {
                      return '認証情報・クエリを含まない HTTPS URL を指定してください。';
                    }
                  },
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _key,
                  enabled: !_saving,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'X-API-Key'),
                ),
                if (widget.api != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: ValueListenableBuilder<ApiTiming?>(
                      valueListenable: widget.api!.lastTiming,
                      builder:
                          (_, timing, __) => Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('直近の API 通信時間'),
                              Text(
                                timing == null
                                    ? 'まだ計測していません。'
                                    : '${timing.operation.label}: '
                                        '${(timing.total.inMicroseconds / 1000000).toStringAsFixed(3)}秒'
                                        '（${timing.statusLabel}）',
                                style: const TextStyle(fontSize: 12),
                              ),
                              const Text(
                                'サーバーの処理時間を含みます。',
                                style: TextStyle(fontSize: 11, color: _muted),
                              ),
                            ],
                          ),
                    ),
                  ),
                const SizedBox(height: 12),
                _PlaybackDetails(playback: widget.playback),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed:
                      _canUseYoutube
                          ? () => Navigator.pop(context, true)
                          : null,
                  icon: const Icon(Icons.account_circle_outlined),
                  label: const Text('YouTube連携'),
                ),
                const Text(
                  'API URLとAPIキーを保存してから利用できます。',
                  style: TextStyle(fontSize: 12),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text(_error!, style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    ),
  );
}

String _playbackReport(PlaybackDiagnostics info) {
  final report = [
    'Mix Player $appVersionLabel',
    if (appRevision.isNotEmpty) 'コミット $appRevision',
    '再生方式: ${info.mode == PlaybackMode.audio ? '音声' : '動画'}',
    '一覧の曲番号: ${info.listIndex == null ? '—' : info.listIndex! + 1}',
    'プレーヤー内の曲番号: ${info.playerIndex == null ? '—' : info.playerIndex! + 1}',
    'キュー内の曲数: ${info.queueLength}',
    '一覧の長さ: ${formatTime(info.listDuration)}',
    '再生URL取得時の長さ: ${formatTime(info.apiDuration)}',
    'メディアの長さ: ${formatTime(info.mediaDuration)}',
    'メディアの経過時間: ${formatTime(info.mediaPosition)}',
    '形式: ${info.formatId ?? '—'} / ${info.mediaExtension ?? '—'}',
    '配信方式: ${info.mediaProtocol ?? '—'}',
    '音声コーデック: ${info.audioCodec ?? '—'}',
  ];
  String time(Duration? value) =>
      value == null
          ? '—'
          : '${formatTime(value)}.${(value.inMilliseconds % 1000).toString().padLeft(3, '0')}';
  String index(int? value) => value == null ? '—' : '${value + 1}';
  for (final timing in info.nativeTiming) {
    final phase = switch (timing.phase) {
      NativeTimingPhase.load => '初回読込後',
      NativeTimingPhase.append => '先読み追加後',
      NativeTimingPhase.seek => 'シーク後',
      NativeTimingPhase.inspect => '表示時',
    };
    final source = switch (timing.durationSource) {
      NativeDurationSource.item => '曲データ',
      NativeDurationSource.seekable => 'シーク範囲',
      NativeDurationSource.unknown => '不明',
    };
    report.addAll([
      '[iOS $phase] 実曲:${index(timing.actualIndex)} 内部:${index(timing.storedIndex)} '
          'キュー:${timing.queueLength} ソース:${timing.sourceCount}',
      '項目の長さ: ${time(timing.itemDuration)} / 音源の長さ: ${time(timing.assetDuration)}',
      'シーク範囲の開始: ${time(timing.seekableStart)} / 長さ: ${time(timing.seekableDuration)}',
      'iOS現在位置: ${time(timing.position)} / 長さの取得元: $source',
      if (timing.m4aHeaderFields != null)
        'M4A初期ヘッダーの正規化: ${timing.m4aHeaderFields}か所',
    ]);
  }
  return report.join('\n');
}

class _PlaybackDetails extends StatelessWidget {
  const _PlaybackDetails({required this.playback});
  final PlaybackController playback;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: playback,
    builder: (context, _) {
      final info = playback.diagnostics;
      final report = _playbackReport(info);
      return ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('再生情報', style: TextStyle(fontSize: 13)),
        onExpansionChanged: (expanded) {
          if (expanded) unawaited(playback.refreshNativeTiming());
        },
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              report,
              style: const TextStyle(color: _muted, fontSize: 12, height: 1.6),
            ),
          ),
          TextButton.icon(
            onPressed: () async {
              await playback.refreshNativeTiming();
              await Clipboard.setData(
                ClipboardData(text: _playbackReport(playback.diagnostics)),
              );
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('再生情報をコピー'),
          ),
        ],
      );
    },
  );
}

class _DirectDialog extends StatefulWidget {
  const _DirectDialog();
  @override
  State<_DirectDialog> createState() => _DirectDialogState();
}

class _DirectDialogState extends State<_DirectDialog> {
  final _form = GlobalKey<FormState>();
  final _url = TextEditingController();
  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('直接 URL で再生テスト'),
    content: SizedBox(
      width: 400,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '現在の再生モードで M4A / MP4 を再生します。\nこの URL は保存されません。',
              style: TextStyle(color: _muted, fontSize: 12, height: 1.6),
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: _url,
              autofocus: true,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'HTTPS メディア URL'),
              validator:
                  (value) =>
                      playableUri(value) == null
                          ? 'HTTPS の URL を入力してください。'
                          : null,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('キャンセル'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(context, _url.text.trim());
          }
        },
        child: const Text('再生'),
      ),
    ],
  );
}

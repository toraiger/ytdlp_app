import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'controllers/mix_controller.dart';
import 'controllers/playback_controller.dart';
import 'models/api_models.dart';
import 'models/api_timing.dart';
import 'services/api_client.dart';
import 'services/app_settings.dart';
import 'services/playback_engines.dart';

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
  });
  final SettingsStore settings;
  final AudioEngine? audioEngine;
  final ApiClientFactory? apiFactory;

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
    ),
  );
}

class _PlayerScreen extends StatefulWidget {
  const _PlayerScreen({
    required this.settings,
    required this.apiFactory,
    this.audioEngine,
  });
  final SettingsStore settings;
  final ApiClientFactory apiFactory;
  final AudioEngine? audioEngine;
  @override
  State<_PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<_PlayerScreen>
    with WidgetsBindingObserver {
  final _url = TextEditingController(text: defaultMixUrl);
  final _mix = MixController();
  late final PlaybackController _playback;
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
    await showDialog<void>(
      context: context,
      builder:
          (_) => _ConnectionDialog(
            initial: _settings,
            api: _mix.isConfigured ? _mix.api : null,
            onSave: (url, key) async {
              ApiClient.validateServerUrl(url);
              await widget.settings.saveConnection(serverUrl: url, apiKey: key);
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
  }

  Future<void> _load() async {
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
    if (result != null && mounted) await _playback.playDirect(result);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _url.dispose();
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
                child: Text(
                  'Mix Player',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
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
                  : (selection) => _playback.setMode(selection.first),
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

class _MiniPlayer extends StatelessWidget {
  const _MiniPlayer({required this.playback});
  final PlaybackController playback;
  @override
  Widget build(BuildContext context) {
    final track = playback.currentTrack;
    final enabled = track != null && !playback.isBusy;
    final duration = playback.duration.inMilliseconds.toDouble();
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
                              : playback.position.inMilliseconds
                                  .toDouble()
                                  .clamp(0, duration),
                      max: duration <= 0 ? 1 : duration,
                      onChanged:
                          enabled && duration > 0
                              ? (value) => playback.seek(
                                Duration(milliseconds: value.round()),
                              )
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
                        formatTime(playback.position),
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
    required this.onSave,
    this.api,
  });
  final SettingsSnapshot initial;
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
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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

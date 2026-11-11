import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../controllers/playback_controller.dart';
import "../controllers/mix_controller.dart";
import '../controllers/youtube_playback_controller.dart';
import "../models/mix_queue_item.dart";
import '../models/youtube_video_page.dart';
import '../widgets/youtube_webview.dart';

class YoutubeBrowserScreen extends StatefulWidget {
  const YoutubeBrowserScreen({
    super.key,
    required this.controller,
    required this.playback,
    required this.playerControlsBuilder,
    this.browserBuilder,
  });
  final YoutubePlaybackController controller;
  final PlaybackController playback;
  final WidgetBuilder playerControlsBuilder;
  final YoutubeBrowserBuilder? browserBuilder;
  @override
  State<YoutubeBrowserScreen> createState() => _YoutubeBrowserScreenState();
}

class _YoutubeBrowserScreenState extends State<YoutubeBrowserScreen>
    with WidgetsBindingObserver {
  YoutubeBrowserHandle? _browser;
  late final Uri _initialUri;
  late int _appliedPageRevision;
  bool _loading = true;
  bool _canBack = false;
  bool _canForward = false;
  bool _browserFailed = false;
  int _historyRevision = 0;
  bool _menuOpen = false;

  Future<void> _showVideoMenu(YoutubeVideoTarget target) async {
    if (!mounted || _menuOpen) return;
    _menuOpen = true;
    QueueInsertPosition? placement;
    try {
      placement = await showModalBottomSheet<QueueInsertPosition>(
        context: context,
        useSafeArea: true,
        builder:
            (sheetContext) => AnimatedBuilder(
              animation: Listenable.merge([widget.controller, widget.playback]),
              builder:
                  (context, child) => SafeArea(
                    top: false,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            title: Text(
                              target.title ?? target.page.videoId,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          for (final position in QueueInsertPosition.values)
                            ListTile(
                              leading: Icon(
                                position == QueueInsertPosition.next
                                    ? Icons.playlist_play
                                    : Icons.playlist_add,
                              ),
                              title: Text(
                                position == QueueInsertPosition.next
                                    ? "次に再生"
                                    : "キューの最後に追加",
                              ),
                              enabled: widget.controller.canAddToQueue,
                              onTap:
                                  widget.controller.canAddToQueue
                                      ? () =>
                                          Navigator.pop(sheetContext, position)
                                      : null,
                            ),
                          if (!widget.controller.canAddToQueue)
                            const ListTile(
                              title: Text("再生の準備・Mixの取得中や、直接URLの再生中は追加できません。"),
                            ),
                        ],
                      ),
                    ),
                  ),
            ),
      );
    } finally {
      _menuOpen = false;
    }
    if (!mounted || placement == null) return;
    try {
      final added = await widget.controller.addToQueue(target, placement);
      if (mounted && added) _showAdditionMessage("キューに追加しました。");
    } catch (failure) {
      if (mounted) _showAdditionMessage(describeFailure(failure));
    }
  }

  void _showAdditionMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showCurrentVideoMenu() {
    final track = widget.playback.currentTrack;
    if (track == null || !YoutubeVideoPage.isVideoId(track.videoId)) return;
    unawaited(
      _showVideoMenu(
        YoutubeVideoTarget(
          page: YoutubeVideoPage(videoId: track.videoId),
          title: track.title,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.setVisible(true);
    widget.controller.setForeground(
      WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    _initialUri = widget.controller.pageUri;
    _appliedPageRevision = widget.controller.pageRevision;
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.controller.setForeground(state == AppLifecycleState.resumed);
  }

  void _onControllerChanged() {
    if (!mounted) return;
    unawaited(_followPlayer());
  }

  Future<void> _followPlayer() async {
    final browser = _browser;
    final uri = widget.controller.pageToLoad;
    if (browser == null ||
        uri == null ||
        _appliedPageRevision == widget.controller.pageRevision) {
      return;
    }
    _appliedPageRevision = widget.controller.pageRevision;
    await _navigate(() => browser.load(uri));
  }

  Future<void> _navigate(Future<void> Function() action) async {
    try {
      await action();
      await _refreshHistory();
    } catch (_) {
      if (mounted) setState(() => _browserFailed = true);
    }
  }

  Future<void> _refreshHistory() async {
    final browser = _browser;
    if (browser == null) return;
    final revision = ++_historyRevision;
    try {
      final back = await browser.canGoBack();
      final forward = await browser.canGoForward();
      if (mounted && revision == _historyRevision) {
        setState(() {
          _canBack = back;
          _canForward = forward;
        });
      }
    } catch (_) {
      // History availability does not affect native playback.
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    widget.controller.setVisible(false);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final callbacks = YoutubeBrowserCallbacks(
      onVideoLongPress: (target) => unawaited(_showVideoMenu(target)),
      onCreated: (browser) {
        if (!mounted) return;
        setState(() => _browser = browser);
        unawaited(_followPlayer());
        unawaited(_refreshHistory());
      },
      onStarted: (uri) {
        if (!mounted) return;
        widget.controller.navigationStarted(uri);
        setState(() => _browserFailed = false);
      },
      onCommitted: (uri) {
        if (!mounted) return;
        unawaited(widget.controller.pageCommitted(uri));
        unawaited(_refreshHistory());
      },
      onLoading: (value) {
        if (mounted) setState(() => _loading = value);
      },
      onFailure: () {
        if (mounted) {
          setState(() {
            _loading = false;
            _browserFailed = true;
          });
        }
      },
    );
    // Keep the same platform view while playback positions change.
    final browserView =
        widget.browserBuilder?.call(context, _initialUri, callbacks) ??
        YoutubeWebView(initialUri: _initialUri, callbacks: callbacks);
    return AnimatedBuilder(
      animation: Listenable.merge([widget.controller, widget.playback]),
      child: browserView,
      builder: (context, child) {
        final error = widget.controller.error ?? widget.playback.error;
        final video = widget.playback.videoController;
        return Scaffold(
          appBar: AppBar(
            title: const Text('YouTube'),
            actions: [
              IconButton(
                tooltip: 'Mix Playerに戻る',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'ページを戻る',
                      onPressed:
                          _canBack
                              ? () => unawaited(_navigate(_browser!.back))
                              : null,
                      icon: const Icon(Icons.arrow_back),
                    ),
                    IconButton(
                      tooltip: 'ページを進む',
                      onPressed:
                          _canForward
                              ? () => unawaited(_navigate(_browser!.forward))
                              : null,
                      icon: const Icon(Icons.arrow_forward),
                    ),
                    IconButton(
                      tooltip: 'YouTubeホーム',
                      onPressed:
                          _browser == null
                              ? null
                              : () => unawaited(
                                _navigate(
                                  () => _browser!.load(YoutubeVideoPage.home),
                                ),
                              ),
                      icon: const Icon(Icons.home_outlined),
                    ),
                    IconButton(
                      tooltip: 'ページを再読込',
                      onPressed:
                          _browser == null
                              ? null
                              : () => unawaited(_navigate(_browser!.reload)),
                      icon: const Icon(Icons.refresh),
                    ),
                    const Expanded(
                      child: Text(
                        '再生は下の操作バーで操作',
                        style: TextStyle(fontSize: 10),
                      ),
                    ),
                  ],
                ),
                if (_loading) const LinearProgressIndicator(minHeight: 2),
                if (_browserFailed)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Text(
                      'ページを読み込めませんでした。再読込してください。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                if (widget.controller.isSelecting)
                  Row(
                    children: [
                      const SizedBox(width: 16),
                      const Expanded(
                        child: Text('動画を準備中…', style: TextStyle(fontSize: 12)),
                      ),
                      TextButton(
                        onPressed: widget.controller.cancelSelection,
                        child: const Text('キャンセル'),
                      ),
                    ],
                  ),
                if (error == null &&
                    widget.playback.currentTrack == null &&
                    widget.controller.canRetry &&
                    YoutubeVideoPage.fromUri(widget.controller.pageUri) != null)
                  TextButton(
                    onPressed: widget.controller.retry,
                    child: const Text('この動画を再生'),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            error,
                            maxLines: 3,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        TextButton(
                          onPressed:
                              widget.controller.canRetry
                                  ? widget.controller.retry
                                  : null,
                          child: const Text('再試行'),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder:
                        (context, constraints) => Column(
                          children: [
                            if (video != null)
                              GestureDetector(
                                onLongPress: _showCurrentVideoMenu,
                                child: SizedBox(
                                  height: math.min(
                                    constraints.maxHeight * .4,
                                    210,
                                  ),
                                  width: double.infinity,
                                  child: ColoredBox(
                                    color: Colors.black,
                                    child: Center(
                                      child: AspectRatio(
                                        aspectRatio:
                                            video.value.isInitialized
                                                ? video.value.aspectRatio
                                                : 16 / 9,
                                        child:
                                            video.value.isInitialized
                                                ? VideoPlayer(video)
                                                : const Center(
                                                  child:
                                                      CircularProgressIndicator(),
                                                ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            Expanded(child: child!),
                          ],
                        ),
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: widget.playerControlsBuilder(context),
        );
      },
    );
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mix_player_app/player_app.dart';
import 'package:mix_player_app/services/app_settings.dart';
import 'package:mix_player_app/widgets/youtube_webview.dart';
import "package:mix_player_app/models/youtube_video_page.dart";

import 'support/fakes.dart';
import 'youtube_playback_controller_test.dart' show a, b, c, d, videoPage;

class FakeBrowser implements YoutubeBrowserHandle {
  late YoutubeBrowserCallbacks callbacks;
  final current = ValueNotifier<Uri>(Uri.https('www.youtube.com', '/'));
  final loads = <Uri>[];
  void start(Uri uri) {
    callbacks.onStarted(uri);
    callbacks.onLoading(true);
  }

  void commit(Uri uri) {
    current.value = uri;
    callbacks.onLoading(false);
    callbacks.onCommitted(uri);
  }

  @override
  Future<void> load(Uri uri) async {
    loads.add(uri);
    start(uri);
    commit(uri);
  }

  @override
  Future<void> back() => load(Uri.https('www.youtube.com', '/'));
  @override
  Future<void> forward() async {}
  @override
  Future<void> reload() => load(current.value);
  @override
  Future<bool> canGoBack() async => current.value.path != '/';
  @override
  Future<bool> canGoForward() async => false;
  Widget build(
    BuildContext context,
    Uri initial,
    YoutubeBrowserCallbacks events,
  ) => FakeBrowserView(browser: this, initial: initial, callbacks: events);
}

class FakeBrowserView extends StatefulWidget {
  const FakeBrowserView({
    super.key,
    required this.browser,
    required this.initial,
    required this.callbacks,
  });
  final FakeBrowser browser;
  final Uri initial;
  final YoutubeBrowserCallbacks callbacks;
  @override
  State<FakeBrowserView> createState() => _FakeBrowserViewState();
}

class _FakeBrowserViewState extends State<FakeBrowserView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.browser.callbacks = widget.callbacks;
      widget.callbacks.onCreated(widget.browser);
      widget.browser.commit(widget.initial);
    });
  }

  @override
  Widget build(BuildContext context) => Center(
    child: ValueListenableBuilder<Uri>(
      valueListenable: widget.browser.current,
      builder:
          (_, uri, __) => Text(
            'Synthetic YouTube page: ${uri.path} ${uri.queryParameters['v'] ?? ''}',
          ),
    ),
  );
}

void main() {
  late FakeBrowser browser;
  late FakeAudioEngine audio;
  late List<http.Request> requests;
  FutureOr<http.Response> Function(http.Request)? handler;
  setUp(() {
    browser = FakeBrowser();
    audio = FakeAudioEngine();
    requests = [];
    handler = null;
  });
  Future<void> launch(WidgetTester tester, {bool configured = true}) async {
    final settings = MemorySettings();
    if (configured) {
      settings.snapshot = const SettingsSnapshot(
        serverUrl: 'https://api.example.test',
        apiKey: 'dummy-api-key',
      );
    }
    await tester.pumpWidget(
      PlayerApp(
        settings: settings,
        audioEngine: audio,
        youtubeBrowserBuilder: browser.build,
        apiFactory:
            (_, __) => mockApi((request) {
              requests.add(request);
              return handler?.call(request) ??
                  jsonResponse(
                    request.url.path == '/stream'
                        ? streamJson(
                          jsonDecode(request.body)['video_id'] as String,
                        )
                        : mixJson([a, b, c, d]),
                  );
            }),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.ensureVisible(find.text('YouTubeを開く'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('YouTubeを開く'));
    await tester.pumpAndSettle();
  }

  testWidgets('YouTube entry requires saved API settings', (tester) async {
    await launch(tester, configured: false);
    final button = find.ancestor(
      of: find.text('YouTubeを開く'),
      matching: find.byWidgetPredicate((w) => w is OutlinedButton),
    );
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
  });

  testWidgets(
    "Long press opens one cancellable menu without navigation or API requests",
    (tester) async {
      await launch(tester);
      await open(tester);
      final target = YoutubeVideoTarget(
        page: YoutubeVideoPage(videoId: b),
        title: "Long pressed video",
      );
      browser.callbacks.onVideoLongPress!(target);
      browser.callbacks.onVideoLongPress!(target);
      await tester.pumpAndSettle();
      expect(find.text("Long pressed video"), findsOneWidget);
      expect(find.text("次に再生"), findsOneWidget);
      expect(find.text("キューの最後に追加"), findsOneWidget);
      expect(requests, isEmpty);
      expect(browser.loads, isEmpty);
      await tester.tapAt(const Offset(20, 100));
      await tester.pumpAndSettle();
      expect(find.text("次に再生"), findsNothing);
      expect(requests, isEmpty);
      expect(audio.playing, isFalse);
    },
  );

  for (final action in ["次に再生", "キューの最後に追加"]) {
    testWidgets("Long press $action adds a repeated video and keeps playback", (
      tester,
    ) async {
      await launch(tester);
      await open(tester);
      browser.commit(videoPage(a, list: "RD$a"));
      await tester.pumpAndSettle();
      final loadCount = audio.loadCount;
      final currentPage = browser.current.value;
      browser.callbacks.onVideoLongPress!(
        YoutubeVideoTarget(
          page: YoutubeVideoPage(videoId: a),
          title: "Repeated video",
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(find.text("キューに追加しました。"), findsOneWidget);
      expect(audio.loadCount, loadCount);
      expect(audio.playing, isTrue);
      expect(browser.current.value, currentPage);
      await tester.tap(find.byTooltip("Mix Playerに戻る"));
      await tester.pumpAndSettle();
      expect(find.text("5 曲"), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets("Adding from the menu while idle does not start playback", (
    tester,
  ) async {
    await launch(tester);
    await open(tester);
    browser.callbacks.onVideoLongPress!(
      YoutubeVideoTarget(page: YoutubeVideoPage(videoId: b)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text("次に再生"));
    await tester.pumpAndSettle();
    expect(audio.playing, isFalse);
    expect(browser.loads, isEmpty);
    expect(find.text("キューに追加しました。"), findsOneWidget);
    await tester.tap(find.byTooltip("Mix Playerに戻る"));
    await tester.pumpAndSettle();
    expect(find.text("1 曲"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    "Failed menu addition reports failure and keeps the current video",
    (tester) async {
      await launch(tester);
      await open(tester);
      browser.commit(videoPage(a));
      await tester.pumpAndSettle();
      handler = (request) => http.Response("", 503);
      browser.callbacks.onVideoLongPress!(
        YoutubeVideoTarget(page: YoutubeVideoPage(videoId: b)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text("キューの最後に追加"));
      await tester.pumpAndSettle();
      expect(find.textContaining("HTTP 503"), findsOneWidget);
      expect(audio.playing, isTrue);
      expect(browser.current.value, videoPage(a));
    },
  );

  testWidgets(
    'Opening pages precedes API playback; closing retains the same player',
    (tester) async {
      await launch(tester);
      await open(tester);
      browser.start(videoPage(a));
      await tester.pump();
      expect(requests, isEmpty);
      browser.commit(videoPage(a));
      await tester.pumpAndSettle();
      expect(find.text('Track $a'), findsOneWidget);
      expect(
        find.textContaining('Synthetic YouTube page: /watch $a'),
        findsOneWidget,
      );
      expect(find.byTooltip('一時停止'), findsOneWidget);
      expect(audio.playing, isTrue);
      await tester.tap(find.byTooltip('Mix Playerに戻る'));
      await tester.pumpAndSettle();
      expect(audio.playing, isTrue);
      final loads = audio.loadCount;
      await open(tester);
      expect(audio.loadCount, loads);
      expect(requests, hasLength(1));
      expect(find.text('Track $a'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Automatic Mix advance updates page, title and time without restarting',
    (tester) async {
      await launch(tester);
      await open(tester);
      browser.commit(videoPage(a, list: 'RD$a'));
      await tester.pumpAndSettle();
      final loads = audio.loadCount;
      audio.advance(1, duration: const Duration(seconds: 123));
      await tester.pumpAndSettle();
      expect(browser.loads.last, videoPage(b, list: 'RD$a'));
      expect(find.text('Track $b'), findsOneWidget);
      expect(find.text('00:00'), findsOneWidget);
      expect(find.text('02:03'), findsOneWidget);
      expect(audio.loadCount, loads);
      expect(requests.where((r) => r.url.path == '/mix'), hasLength(1));
      await tester.tap(find.byTooltip('一時停止'));
      await tester.pumpAndSettle();
      expect(audio.playing, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Stopped video can be restarted from its retained page', (
    tester,
  ) async {
    await launch(tester);
    await open(tester);
    browser.commit(videoPage(a));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('停止'));
    await tester.pumpAndSettle();
    expect(audio.playing, isFalse);
    await tester.tap(find.text('この動画を再生'));
    await tester.pumpAndSettle();
    expect(audio.playing, isTrue);
    expect(requests, hasLength(1));
  });

  testWidgets('Failure leaves the page and offers a working retry', (
    tester,
  ) async {
    handler = (_) => http.Response('dummy-private-body', 403);
    await launch(tester);
    await open(tester);
    browser.commit(videoPage(a));
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTP 403'), findsOneWidget);
    expect(find.textContaining('dummy-private-body'), findsNothing);
    expect(
      find.textContaining('Synthetic YouTube page: /watch $a'),
      findsOneWidget,
    );
    handler = null;
    await tester.tap(find.text('再試行'));
    await tester.pumpAndSettle();
    expect(audio.playing, isTrue);
    expect(find.textContaining('HTTP 403'), findsNothing);
  });

  testWidgets(
    'Compact screen supports browser errors and cancelling Mix preparation',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final response = Completer<http.Response>();
      handler = (_) => response.future;
      await launch(tester);
      await open(tester);
      browser.commit(videoPage(a, list: 'RD$a'));
      await tester.pump();
      browser.callbacks.onFailure();
      await tester.pump();
      expect(find.textContaining('ページを読み込めません'), findsOneWidget);
      await tester.tap(find.text('キャンセル'));
      await tester.pumpAndSettle();
      response.complete(jsonResponse(mixJson([a, b, c])));
      await tester.pumpAndSettle();
      expect(audio.playing, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

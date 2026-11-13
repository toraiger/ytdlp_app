import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mix_player_app/models/native_playback_timing.dart';
import "package:mix_player_app/models/audio_transport_diagnostics.dart";
import 'package:mix_player_app/player_app.dart';
import 'package:mix_player_app/services/app_settings.dart';
import "package:mix_player_app/services/error_report.dart";
import "package:mix_player_app/widgets/error_copy_button.dart";
import "package:mix_player_app/services/playback_engines.dart";
import 'support/fakes.dart';

void main() {
  Future<void> launch(
    WidgetTester tester,
    MemorySettings settings, {
    FakeAudioEngine? audio,
    FutureOr<http.Response> Function(http.Request)? handler,
    Map<String, dynamic> Function(String)? streamResponse,
  }) async {
    await tester.pumpWidget(
      PlayerApp(
        settings: settings,
        audioEngine: audio ?? FakeAudioEngine(),
        apiFactory:
            (serverUrl, apiKey) => mockApi(
              handler ??
                  (request) {
                    if (request.url.path == "/stream") {
                      final videoId =
                          jsonDecode(request.body)["video_id"] as String;
                      return jsonResponse(
                        (streamResponse ?? streamJson)(videoId),
                      );
                    }
                    return jsonResponse(mixJson(["a", "b"]));
                  },
            ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void captureClipboard(
    WidgetTester tester,
    void Function(String) onCopy, {
    bool unavailable = false,
  }) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == "Clipboard.setData") {
          if (unavailable) throw PlatformException(code: "unavailable");
          onCopy((call.arguments as Map)["text"] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('Unconfigured app guides setup and disables Mix fetching', (
    tester,
  ) async {
    await launch(tester, MemorySettings());
    expect(find.text('Mix Player'), findsOneWidget);
    expect(find.textContaining('最初に API サーバー'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Mix を20曲取得'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Settings reject HTTP and save HTTPS with an obscured key', (
    tester,
  ) async {
    final settings = MemorySettings();
    await launch(tester, settings);
    await tester.tap(find.byTooltip('API サーバー設定'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'http://api.example.test');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTPS URL を指定'), findsOneWidget);
    await tester.enterText(fields.at(0), 'https://api.example.test');
    await tester.enterText(fields.at(1), 'test-key');
    final keyField = tester.widget<TextField>(
      find.descendant(of: fields.at(1), matching: find.byType(TextField)),
    );
    expect(keyField.obscureText, isTrue);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(settings.snapshot.serverUrl, 'https://api.example.test');
    expect(find.textContaining('最初に API サーバー'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Loading renders response tracks and remembers the Mix URL', (
    tester,
  ) async {
    final settings =
        MemorySettings()
          ..snapshot = const SettingsSnapshot(
            serverUrl: 'https://api.example.test',
            apiKey: 'test',
          );
    await launch(tester, settings);
    await tester.ensureVisible(find.text('Mix を20曲取得'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mix を20曲取得'));
    await tester.pumpAndSettle();
    expect(find.text('Track a'), findsOneWidget);
    expect(find.text('Track b'), findsOneWidget);
    expect(settings.savedMix, defaultMixUrl);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Direct playback dialog rejects HTTP media', (tester) async {
    await launch(tester, MemorySettings());
    await tester.ensureVisible(find.text('直接 URL で再生テスト'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('直接 URL で再生テスト'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField),
      'http://media.example.test/a',
    );
    await tester.tap(find.widgetWithText(FilledButton, '再生'));
    await tester.pumpAndSettle();
    expect(find.text('HTTPS の URL を入力してください。'), findsOneWidget);
  });
  // URL準備を待つpumpAndSettleは使わず、要求が未完了でも一覧が表示されることを確認する。
  testWidgets(
    'Mix list stays usable while first URL is prepared without autoplay',
    (tester) async {
      final response = Completer<http.Response>();
      final audio = FakeAudioEngine();
      final requests = <String>[];
      final settings =
          MemorySettings()
            ..snapshot = const SettingsSnapshot(
              serverUrl: 'https://api.example.test',
              apiKey: 'test',
            );
      await tester.pumpWidget(
        PlayerApp(
          settings: settings,
          audioEngine: audio,
          apiFactory:
              (_, __) => mockApi((request) {
                if (request.url.path == '/stream') {
                  requests.add(jsonDecode(request.body)['video_id'] as String);
                  return response.future;
                }
                return jsonResponse(mixJson(['a']));
              }),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Mix を20曲取得'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mix を20曲取得'));
      await tester.pumpAndSettle();
      expect(find.text('Track a'), findsOneWidget);
      expect(settings.savedMix, defaultMixUrl);
      expect(requests, ['a']);
      expect(audio.loadCount, 0);
      await tester.ensureVisible(find.text('Track a'));
      await tester.tap(find.text('Track a'));
      await tester.pump();
      expect(requests, ['a']);
      expect(audio.playing, isFalse);
      response.complete(jsonResponse(streamJson('a')));
      await tester.pumpAndSettle();
      expect(audio.playing, isTrue);
      expect(requests, ['a']);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Automatic audio transition updates title and resets the clock', (
    tester,
  ) async {
    final audio = FakeAudioEngine();
    final settings =
        MemorySettings()
          ..snapshot = const SettingsSnapshot(
            serverUrl: 'https://api.example.test',
            apiKey: 'test',
          );
    await tester.pumpWidget(
      PlayerApp(
        settings: settings,
        audioEngine: audio,
        apiFactory:
            (_, __) => mockApi((request) {
              if (request.url.path == '/stream') {
                final id = jsonDecode(request.body)['video_id'] as String;
                return jsonResponse(streamJson(id));
              }
              return jsonResponse({
                ...mixJson(['a', 'b']),
                'items': [
                  {...trackJson('a'), 'duration': 264},
                  {...trackJson('b'), 'duration': 263},
                ],
              });
            }),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Mix を20曲取得'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mix を20曲取得'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Track a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Track a'));
    await tester.pumpAndSettle();

    final player = find.ancestor(
      of: find.byTooltip('次の曲'),
      matching: find.byType(SafeArea),
    );
    audio.durationEvents.add(const Duration(seconds: 264));
    audio.positionEvents.add(const Duration(seconds: 264));
    await tester.pump();
    expect(
      find.descendant(of: player, matching: find.text('04:24')),
      findsNWidgets(2),
    );

    audio.advance(1, duration: const Duration(seconds: 263));
    await tester.pumpAndSettle();

    for (final text in ['Track b', '00:00', '04:23']) {
      expect(
        find.descendant(of: player, matching: find.text(text)),
        findsOneWidget,
      );
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets('Compact phone layout does not overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await launch(tester, MemorySettings());
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Dragging previews time and seeks only when the thumb is released',
    (tester) async {
      final audio = FakeAudioEngine();
      final settings =
          MemorySettings()
            ..snapshot = const SettingsSnapshot(
              serverUrl: 'https://api.example.test',
              apiKey: 'test',
            );
      await launch(tester, settings, audio: audio);
      await tester.ensureVisible(find.text('Mix を20曲取得'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mix を20曲取得'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Track a'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Track a'));
      await tester.pumpAndSettle();
      var seeks = 0;
      audio.onSeek = (_) => seeks++;
      final slider = find.byType(Slider);
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(seeks, 0);
      final preview = tester.widget<Slider>(slider).value;
      expect(preview, greaterThan(20000));
      audio.positionEvents.add(const Duration(seconds: 20));
      await tester.pump();
      expect(tester.widget<Slider>(slider).value, preview);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(seeks, 1);
      expect(audio.lastSeek!.inMilliseconds, preview.round());
      seeks = 0;
      final interrupted = await tester.startGesture(tester.getCenter(slider));
      await interrupted.moveBy(const Offset(20, 0));
      await tester.pump();
      audio.advance(1);
      await tester.pump();
      await interrupted.up();
      await tester.pumpAndSettle();
      expect(seeks, 0);
      expect(audio.snapshot.index, 0);
      expect(audio.entries.first.track.videoId, "b");
      expect(tester.widget<Slider>(slider).value, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Playback report refreshes native timing and keeps all sources free of secrets',
    (tester) async {
      String? copied;
      captureClipboard(tester, (text) => copied = text);
      final audio = _DiagnosticAudioEngine();
      final settings =
          MemorySettings()
            ..snapshot = const SettingsSnapshot(
              serverUrl: 'https://api.example.test',
              apiKey: 'do-not-copy-api-key',
            );
      await launch(
        tester,
        settings,
        audio: audio,
        streamResponse: (id) {
          final result = streamJson(id)..['duration'] = 237.125;
          (result['audio'] as Map<String, dynamic>).addAll(<String, Object>{
            'format_id': '140',
            'protocol': 'https',
            'acodec': 'mp4a.40.2',
          });
          return result;
        },
      );
      await tester.ensureVisible(find.text('Mix を20曲取得'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mix を20曲取得'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Track a'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Track a'));
      await tester.pumpAndSettle();
      audio.durationEvents.add(const Duration(seconds: 427));
      audio.positionEvents.add(const Duration(seconds: 320));
      await tester.pump();
      await tester.tap(find.byTooltip('API サーバー設定'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('再生情報'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('再生情報'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('再生情報をコピー'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('再生情報をコピー'));
      await tester.pumpAndSettle();
      expect(copied, contains('一覧の長さ: 02:00'));
      expect(copied, contains('再生URL取得時の長さ: 03:57'));
      expect(copied, contains('メディアの長さ: 07:07'));
      expect(copied, contains('メディアの経過時間: 05:20'));
      expect(copied, contains('プレーヤー内の曲番号: 1'));
      expect(copied, contains('形式: 140 / m4a'));
      expect(copied, contains('配信方式: https'));
      expect(copied, contains('音声コーデック: mp4a.40.2'));
      expect(audio.refreshCount, 2);
      expect(copied, contains('[iOS 表示時] 実曲:1 内部:1 キュー:2 ソース:3'));
      expect(copied, contains('項目の長さ: 03:57.000 / 音源の長さ: 03:57.000'));
      expect(copied, contains('シーク範囲の開始: 00:00.000 / 長さ: 07:53.000'));
      expect(copied, contains('長さの取得元: 曲データ'));
      expect(copied, contains("M4A初期ヘッダーの正規化: 3か所"));
      expect(copied, contains("M4A判定: 適用済み"));
      expect(copied, contains("編集リスト: あり"));
      expect(copied, contains("編集開始位置: 00:00.036 / 区間の長さ: 03:57.000"));
      expect(copied, isNot(contains('do-not-copy-video-id')));
      expect(copied, isNot(contains('do-not-copy-api-key')));
      expect(copied, isNot(contains('https://')));
      expect(copied, isNot(contains('Track a')));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets("Playback error details can be copied on a narrow screen", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? copied;
    captureClipboard(tester, (text) => copied = text);
    final audio = FakeAudioEngine();
    final settings =
        MemorySettings()
          ..snapshot = const SettingsSnapshot(
            serverUrl: "https://api.example.test",
            apiKey: "private-key",
          );
    await launch(tester, settings, audio: audio);
    await tapVisible(tester, find.text("Mix を20曲取得"));
    await tapVisible(tester, find.text("Track a"));
    audio.emitError("Initial failure");
    await tester.pumpAndSettle();
    const failurePosition = Duration(seconds: 37);
    audio.positionEvents.add(failurePosition);
    audio.transportDiagnostics = const AudioTransportDiagnostics(
      route: AudioTransportRoute.m4aLoopback,
      reset: TransportResetState.completed,
      proxyGeneration: 2,
      proxyListening: true,
      localRequestCount: 1,
      upstream: MediaTransferDiagnostics(
        attempts: 1,
        stage: MediaTransferStage.prefix,
        failure: MediaTransferFailure.connection,
      ),
    );
    audio.emitError(
      "音声を再生できません。",
      details: const FailureDetails(
        type: "PlayerException",
        nativeCode: -1009,
        sourceIndex: 0,
      ),
    );
    await tester.pumpAndSettle();
    // コピー直前の通知では、エラー発生時の位置を上書きしない。
    audio.positionEvents.add(Duration.zero);
    audio.transportDiagnostics = const AudioTransportDiagnostics();
    await tapVisible(tester, find.byTooltip("エラー詳細をコピー"));

    expect(copied, contains("ネイティブエラーコード: -1009"));
    expect(copied, contains("音声経路: m4aLoopback"));
    expect(copied, contains("通信経路の再構築: completed"));
    expect(copied, contains("配信元取得の失敗種別: connection"));
    expect(
      copied,
      contains("メディアの経過時間(ms): ${failurePosition.inMilliseconds}"),
    );
    expect(copied, contains("発生時刻(UTC):"));
    expect(copied, contains("プレーヤー稼働時間(ms):"));
    expect(copied, contains("URL再取得後: はい"));
    expect(copied, isNot(contains("private-key")));
    expect(copied, isNot(contains("https://")));
    expect(copied, isNot(contains("Track a")));
    expect(find.text("エラー詳細をコピーしました。"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets("Mix HTTP error details can be copied from the error banner", (
    tester,
  ) async {
    String? copied;
    captureClipboard(tester, (text) => copied = text);
    final settings =
        MemorySettings()
          ..snapshot = const SettingsSnapshot(
            serverUrl: "https://api.example.test",
            apiKey: "private-key",
          );
    await launch(
      tester,
      settings,
      handler: (request) => http.Response("private-response", 503),
    );
    await tapVisible(tester, find.text("Mix を20曲取得"));
    await tapVisible(tester, find.byTooltip("エラー詳細をコピー"));

    expect(copied, contains("処理: Mix取得"));
    expect(copied, contains("HTTPステータス: 503"));
    expect(copied, isNot(contains("private")));
    expect(tester.takeException(), isNull);
  });
  testWidgets("Clipboard failure displays feedback without an uncaught error", (
    tester,
  ) async {
    captureClipboard(
      tester,
      (text) => fail("Unexpected copy"),
      unavailable: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ErrorCopyButton(
            report: ErrorReport.capture(operation: "再生", message: "再生できません。"),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip("エラー詳細をコピー"));
    await tester.pumpAndSettle();

    expect(find.textContaining("コピーできませんでした"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _DiagnosticAudioEngine extends FakeAudioEngine
    implements NativeAudioTimingProvider {
  int refreshCount = 0;
  final recorder = NativeTimingRecorder(
    () async => {
      'itemDurationUs': 237000000,
      'assetDurationUs': 237000000,
      'seekableStartUs': 0,
      'seekableDurationUs': 473000000,
      'positionUs': 4000000,
      'actualIndex': 0,
      'storedIndex': 0,
      'queueLength': 2,
      'sourceCount': 3,
      'durationSource': 'item',
      "m4aHeaderFields": 3,
      "m4aHeaderOutcome": "normalized",
      "m4aHasEditList": true,
      "m4aEditVersion": 0,
      "m4aEditEntryCount": 1,
      "m4aEditStartUs": 36281,
      "m4aEditDurationUs": 237000000,
      'url': 'https://must-not-be-copied.test/private',
      'videoId': 'do-not-copy-video-id',
      'headers': {'X-API-Key': 'do-not-copy-api-key'},
    },
  );

  @override
  List<NativePlaybackTiming> get nativeTimingHistory => recorder.history;

  @override
  Future<void> refreshNativeTiming() async {
    refreshCount++;
    await recorder.capture(NativeTimingPhase.inspect);
  }
}

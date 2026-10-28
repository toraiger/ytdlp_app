import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mix_player_app/player_app.dart';
import 'package:mix_player_app/services/app_settings.dart';
import 'support/fakes.dart';

void main() {
  Future<void> launch(WidgetTester tester, MemorySettings settings) async {
    await tester.pumpWidget(
      PlayerApp(
        settings: settings,
        audioEngine: FakeAudioEngine(),
        apiFactory:
            (_, __) => mockApi((_) => jsonResponse(mixJson(['a', 'b']))),
      ),
    );
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
}

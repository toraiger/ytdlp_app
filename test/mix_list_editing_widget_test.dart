import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mix_player_app/player_app.dart';
import 'package:mix_player_app/services/app_settings.dart';

import 'support/fakes.dart';

void main() {
  late FakeAudioEngine audio;
  Future<void> tap(WidgetTester tester, String text) async {
    if (find.text(text).evaluate().isEmpty) {
      final scroll =
          find
              .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable),
              )
              .first;
      await tester.scrollUntilVisible(
        find.text(text),
        text == '編集' ? -160 : 160,
        scrollable: scroll,
      );
    }
    await tester.ensureVisible(find.text(text));
    await tester.pumpAndSettle();
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  Future<void> launch(WidgetTester tester) async {
    audio = FakeAudioEngine();
    final settings =
        MemorySettings()
          ..snapshot = const SettingsSnapshot(
            serverUrl: 'https://api.test',
            apiKey: 'dummy',
          );
    await tester.pumpWidget(
      PlayerApp(
        settings: settings,
        audioEngine: audio,
        apiFactory:
            (_, __) => mockApi(
              (r) => jsonResponse(
                r.url.path == '/stream'
                    ? streamJson(jsonDecode(r.body)['video_id'] as String)
                    : mixJson(['a', 'b', 'c', 'd']),
              ),
            ),
      ),
    );
    await tester.pumpAndSettle();
    await tap(tester, 'Mix を20曲取得');
  }

  testWidgets('Edit mode disables row playback, supports delete and undo', (
    tester,
  ) async {
    await launch(tester);
    await tap(tester, '編集');
    await tap(tester, 'Track a');
    expect(audio.playing, isFalse);
    await tester.tap(find.byTooltip('Track aを削除'));
    await tester.pumpAndSettle();
    expect(find.text('Track a'), findsNothing);
    expect(find.text('3 曲'), findsOneWidget);
    await tester.tap(find.text('元に戻す'));
    await tester.pumpAndSettle();
    expect(find.text('Track a'), findsOneWidget);
    expect(find.text('4 曲'), findsOneWidget);
    await tap(tester, '完了');
    await tap(tester, 'Track a');
    expect(audio.playing, isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Dragging the handle changes the visible order while current time continues',
    (tester) async {
      await launch(tester);
      await tap(tester, 'Track a');
      audio.positionEvents.add(const Duration(seconds: 25));
      await tester.pump();
      await tap(tester, '編集');
      await tester.ensureVisible(find.byTooltip('Track cを移動'));
      await tester.pumpAndSettle();
      final start = tester.getCenter(find.byTooltip('Track cを移動'));
      final end = tester.getCenter(find.byKey(const ValueKey('a')));
      final gesture = await tester.startGesture(start);
      await gesture.moveTo(Offset(start.dx, end.dy - 10));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('c'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('b'))).dy),
      );
      expect(audio.snapshot.position, const Duration(seconds: 25));
      expect(audio.playing, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Compact layout and deleting the current song preserve a usable player',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await launch(tester);
      await tap(tester, 'Track a');
      await tap(tester, '編集');
      await tester.tap(find.byTooltip('Track aを削除'));
      await tester.pumpAndSettle();
      expect(audio.entries.first.track.videoId, 'b');
      expect(audio.playing, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

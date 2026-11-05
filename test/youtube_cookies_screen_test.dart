import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mix_player_app/models/api_models.dart';
import 'package:mix_player_app/models/youtube_cookies.dart';
import 'package:mix_player_app/player_app.dart';
import 'package:mix_player_app/screens/youtube_cookies_screen.dart';
import 'package:mix_player_app/services/api_client.dart';
import 'package:mix_player_app/services/app_settings.dart';
import 'package:mix_player_app/services/youtube_cookie_source.dart';

import 'support/fakes.dart';
import 'youtube_cookies_test.dart' show dummyCookieFile;

class FakeCookieSource implements YoutubeCookieSource {
  @override
  bool supportsWebLogin = false;
  Object? failure;
  bool cancelled = false;
  int clears = 0;
  @override
  Future<YoutubeCookies?> pickFile() async {
    if (failure != null) throw failure!;
    return cancelled ? null : YoutubeCookies.fromNetscape(dummyCookieFile);
  }

  @override
  Future<YoutubeCookies> readWebCookies() async =>
      YoutubeCookies.fromNetscape(dummyCookieFile);
  @override
  Future<void> clearWebLogin() async {
    clears++;
  }
}

void main() {
  Future<void> visibleTap(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.pumpAndSettle();
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  Future<void> launchScreen(
    WidgetTester tester,
    ApiClient api,
    FakeCookieSource source,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: YoutubeCookiesScreen(api: api, source: source)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'GET displays storage state and file selection never displays values',
    (tester) async {
      final api = mockApi((_) => jsonResponse({'configured': true}));
      addTearDown(api.close);
      await launchScreen(tester, api, FakeCookieSource());
      expect(find.text('サーバー保存状態: 保存済み'), findsOneWidget);
      expect(find.textContaining('現在もログインが有効'), findsOneWidget);
      expect(find.text('YouTubeにログイン'), findsNothing);
      await visibleTap(tester, 'Cookieファイルを選択');
      expect(find.text('送信対象: 2件のYouTube Cookie'), findsOneWidget);
      expect(find.textContaining('dummy-login'), findsNothing);
      expect(find.textContaining('dummy-sapisid'), findsNothing);
      await visibleTap(tester, '選択を取り消す');
      expect(find.text('このサーバーにCookieを登録'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Cancelled file picking and private platform errors do not upload',
    (tester) async {
      final requests = <String>[];
      final api = mockApi((request) {
        requests.add(request.method);
        return jsonResponse({'configured': false});
      });
      addTearDown(api.close);
      final source = FakeCookieSource()..cancelled = true;
      await launchScreen(tester, api, source);
      await visibleTap(tester, 'Cookieファイルを選択');
      expect(find.text('このサーバーにCookieを登録'), findsNothing);
      source.failure = StateError('dummy-private-cookie');
      await visibleTap(tester, 'Cookieファイルを選択');
      expect(find.textContaining('もう一度お試しください'), findsOneWidget);
      expect(find.textContaining('dummy-private-cookie'), findsNothing);
      expect(requests, ['GET']);
    },
  );

  testWidgets(
    'Failed PUT keeps selection for retry and returns success only after PUT',
    (tester) async {
      var uploads = 0;
      bool? registered;
      final api = mockApi((request) {
        if (request.method == 'PUT' && ++uploads == 1) {
          return http.Response('dummy-private-cookie', 403);
        }
        return jsonResponse({'configured': request.method == 'PUT'});
      });
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      registered = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(
                          builder:
                              (_) => YoutubeCookiesScreen(
                                api: api,
                                source: FakeCookieSource(),
                              ),
                        ),
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
          ),
        ),
      );
      await visibleTap(tester, 'open');
      await visibleTap(tester, 'Cookieファイルを選択');
      await visibleTap(tester, 'このサーバーにCookieを登録');
      expect(registered, isNull);
      expect(find.textContaining('403'), findsOneWidget);
      expect(find.textContaining('dummy-private-cookie'), findsNothing);
      expect(find.text('送信対象: 2件のYouTube Cookie'), findsOneWidget);
      await visibleTap(tester, 'このサーバーにCookieを登録');
      expect(registered, isTrue);
      expect(uploads, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Local login clear does not delete cookies on the server', (
    tester,
  ) async {
    final requests = <String>[];
    final api = mockApi((request) {
      requests.add(request.method);
      return jsonResponse({'configured': true});
    });
    addTearDown(api.close);
    final source = FakeCookieSource()..supportsWebLogin = true;
    await launchScreen(tester, api, source);
    await visibleTap(tester, 'Cookieファイルを選択');
    await visibleTap(tester, '端末のWebViewログインを消去');
    expect(source.clears, 1);
    expect(requests, ['GET']);
    expect(find.textContaining('サーバーに登録したCookieは保持されます'), findsOneWidget);
    expect(find.text('サーバー保存状態: 保存済み'), findsOneWidget);
    expect(find.text('このサーバーにCookieを登録'), findsNothing);
  });

  testWidgets(
    'Saved settings gate YouTube access while the server is being edited',
    (tester) async {
      final settings =
          MemorySettings()
            ..snapshot = const SettingsSnapshot(
              serverUrl: 'https://api.example.test',
              apiKey: 'test-key',
            );
      await tester.pumpWidget(
        PlayerApp(
          settings: settings,
          audioEngine: FakeAudioEngine(),
          apiFactory: (_, __) => mockApi((_) => jsonResponse(mixJson(['a']))),
          youtubeCookieSource: FakeCookieSource(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('API サーバー設定'));
      await tester.pumpAndSettle();
      final button = find.ancestor(
        of: find.text('YouTube連携'),
        matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
      );
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
      final url = find.byType(TextFormField).first;
      await tester.enterText(url, 'https://other.example.test');
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      await tester.enterText(url, 'https://api.example.test');
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Registering cookies stops playback and discards old Mix and stream caches',
    (tester) async {
      final settings =
          MemorySettings()
            ..snapshot = const SettingsSnapshot(
              serverUrl: 'https://api.example.test',
              apiKey: 'test-key',
            );
      final audio = FakeAudioEngine();
      final clients = <ApiClient>[];
      final streamGenerations = <int>[];
      await tester.pumpWidget(
        PlayerApp(
          settings: settings,
          audioEngine: audio,
          youtubeCookieSource: FakeCookieSource(),
          apiFactory: (_, __) {
            final generation = clients.length;
            final api = mockApi((request) {
              if (request.url.path == '/youtube/cookies') {
                return jsonResponse({'configured': request.method == 'PUT'});
              }
              if (request.url.path == '/stream') {
                streamGenerations.add(generation);
                return jsonResponse(
                  streamJson(jsonDecode(request.body)['video_id'] as String),
                );
              }
              return jsonResponse(mixJson(['a']));
            });
            clients.add(api);
            return api;
          },
        ),
      );
      await tester.pumpAndSettle();
      await visibleTap(tester, 'Mix を20曲取得');
      await visibleTap(tester, 'Track a');
      expect(audio.playing, isTrue);
      expect(clients.single.cachedMedia('a', PlaybackMode.audio), isNotNull);
      await tester.tap(find.byTooltip('API サーバー設定'));
      await tester.pumpAndSettle();
      await visibleTap(tester, 'YouTube連携');
      await visibleTap(tester, 'Cookieファイルを選択');
      await visibleTap(tester, 'このサーバーにCookieを登録');
      expect(audio.playing, isFalse);
      expect(audio.entries, isEmpty);
      expect(find.text('Track a'), findsNothing);
      expect(clients, hasLength(2));
      expect(clients.first.cachedMedia('a', PlaybackMode.audio), isNull);
      await visibleTap(tester, 'Mix を20曲取得');
      expect(streamGenerations, [0, 1]);
      expect(tester.takeException(), isNull);
    },
  );
}

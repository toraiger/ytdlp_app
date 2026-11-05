import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/youtube_cookies.dart';
import '../services/youtube_cookie_source.dart';

class YoutubeLoginScreen extends StatefulWidget {
  const YoutubeLoginScreen({super.key, required this.source, this.windowId});
  final YoutubeCookieSource source;
  final int? windowId;
  @override
  State<YoutubeLoginScreen> createState() => _YoutubeLoginScreenState();
}

class _YoutubeLoginScreenState extends State<YoutubeLoginScreen> {
  bool _reading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
  }

  Future<void> _readCookies() async {
    setState(() {
      _reading = true;
      _error = null;
    });
    try {
      final cookies = await widget.source.readWebCookies();
      if (mounted) Navigator.pop(context, cookies);
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error =
                  error is CookieImportFailure
                      ? error.message
                      : 'Cookieを取得できませんでした。戻ってファイル取込も利用できます。',
        );
      }
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  bool _allowed(Uri uri) {
    if (uri.toString() == 'about:blank') return true;
    if (uri.scheme != 'https') return false;
    return const [
      'youtube.com',
      'google.com',
      'google.co.jp',
    ].any((domain) => uri.host == domain || uri.host.endsWith('.$domain'));
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_reading,
    child: Scaffold(
      appBar: AppBar(title: const Text('YouTubeにログイン')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'ログイン後に「Cookieを取得」を押してください。ログインが拒否された場合は、戻ってcookies.txtを取り込めます。',
              style: TextStyle(fontSize: 12),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(fontSize: 12)),
            ),
          Expanded(
            child: InAppWebView(
              windowId: widget.windowId,
              initialUrlRequest:
                  widget.windowId == null
                      ? URLRequest(url: WebUri('https://www.youtube.com/'))
                      : null,
              initialSettings: InAppWebViewSettings(
                incognito: false,
                isInspectable: false,
                useShouldOverrideUrlLoading: true,
                supportMultipleWindows: true,
                javaScriptCanOpenWindowsAutomatically: true,
              ),
              shouldOverrideUrlLoading:
                  (_, action) async =>
                      action.request.url != null &&
                              _allowed(action.request.url!)
                          ? NavigationActionPolicy.ALLOW
                          : NavigationActionPolicy.CANCEL,
              onCreateWindow: (_, action) async {
                unawaited(
                  Navigator.of(context)
                      .push<YoutubeCookies>(
                        MaterialPageRoute(
                          builder:
                              (_) => YoutubeLoginScreen(
                                source: widget.source,
                                windowId: action.windowId,
                              ),
                        ),
                      )
                      .then((cookies) {
                        if (context.mounted && cookies != null) {
                          Navigator.pop(context, cookies);
                        }
                      }),
                );
                return true;
              },
              onReceivedError: (_, request, error) {
                if (request.isForMainFrame == true && mounted) {
                  setState(
                    () => _error = 'ページを読み込めませんでした。戻ってファイル取込を利用することもできます。',
                  );
                }
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton(
                onPressed: _reading ? null : _readCookies,
                child: Text(_reading ? '取得中…' : 'Cookieを取得'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

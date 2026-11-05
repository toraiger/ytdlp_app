import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/youtube_video_page.dart';
import '../services/youtube_media_guard.dart';

abstract interface class YoutubeBrowserHandle {
  Future<void> load(Uri uri);
  Future<void> back();
  Future<void> forward();
  Future<void> reload();
  Future<bool> canGoBack();
  Future<bool> canGoForward();
}

class YoutubeBrowserCallbacks {
  const YoutubeBrowserCallbacks({
    required this.onCreated,
    required this.onStarted,
    required this.onCommitted,
    required this.onLoading,
    required this.onFailure,
  });
  final ValueChanged<YoutubeBrowserHandle> onCreated;
  final ValueChanged<Uri> onStarted;
  final ValueChanged<Uri> onCommitted;
  final ValueChanged<bool> onLoading;
  final VoidCallback onFailure;
}

typedef YoutubeBrowserBuilder =
    Widget Function(
      BuildContext context,
      Uri initialUri,
      YoutubeBrowserCallbacks callbacks,
    );

class YoutubeWebView extends StatefulWidget {
  const YoutubeWebView({
    super.key,
    required this.initialUri,
    required this.callbacks,
  });
  final Uri initialUri;
  final YoutubeBrowserCallbacks callbacks;
  @override
  State<YoutubeWebView> createState() => _YoutubeWebViewState();
}

class _YoutubeWebViewState extends State<YoutubeWebView> {
  bool _loadingDocument = true;
  bool _failed = false;
  int _navigationRevision = 0;

  @override
  void initState() {
    super.initState();
    PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
  }

  Future<void> _commit(
    InAppWebViewController controller,
    WebUri? eventUrl,
  ) async {
    if (_loadingDocument || _failed || eventUrl == null) return;
    final revision = ++_navigationRevision;
    try {
      // History callbacks can race a newer navigation. Only the current top
      // page may request media; subframes and stale URLs are never trusted.
      final current = await controller.getUrl();
      if (!mounted ||
          revision != _navigationRevision ||
          _loadingDocument ||
          _failed ||
          current == null ||
          current.toString() != eventUrl.toString()) {
        return;
      }
      final uri = Uri.tryParse(current.toString());
      if (uri != null && YoutubeVideoPage.allowsNavigation(uri)) {
        widget.callbacks.onCommitted(uri);
      }
    } catch (_) {
      if (mounted) widget.callbacks.onFailure();
    }
  }

  @override
  Widget build(BuildContext context) => InAppWebView(
    initialUrlRequest: URLRequest(url: WebUri.uri(widget.initialUri)),
    initialUserScripts: UnmodifiableListView([
      UserScript(
        source: youtubeMediaGuard,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: false,
      ),
    ]),
    initialSettings: InAppWebViewSettings(
      incognito: false,
      isInspectable: false,
      useShouldOverrideUrlLoading: true,
      allowsInlineMediaPlayback: true,
      mediaPlaybackRequiresUserGesture: true,
      supportMultipleWindows: true,
    ),
    onWebViewCreated: (controller) async {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        try {
          await controller.setAllMediaPlaybackSuspended(suspended: true);
        } catch (_) {
          // The document-start guard also covers systems without this API.
        }
      }
      if (mounted) widget.callbacks.onCreated(_NativeBrowserHandle(controller));
    },
    shouldOverrideUrlLoading: (_, action) async {
      final url = action.request.url;
      return url != null && YoutubeVideoPage.allowsNavigation(url)
          ? NavigationActionPolicy.ALLOW
          : NavigationActionPolicy.CANCEL;
    },
    onCreateWindow: (controller, action) async {
      final url = action.request.url;
      if (url != null &&
          url.toString() != 'about:blank' &&
          YoutubeVideoPage.allowsNavigation(url)) {
        await controller.loadUrl(urlRequest: URLRequest(url: url));
      }
      return false;
    },
    onLoadStart: (_, url) {
      _navigationRevision++;
      _loadingDocument = true;
      _failed = false;
      widget.callbacks.onLoading(true);
      if (url != null) widget.callbacks.onStarted(url);
    },
    onLoadStop: (controller, url) async {
      _loadingDocument = false;
      widget.callbacks.onLoading(false);
      await _commit(controller, url);
    },
    onUpdateVisitedHistory:
        (controller, url, _) => unawaited(_commit(controller, url)),
    onReceivedError: (_, request, _) {
      if (request.isForMainFrame == true) {
        _failed = true;
        widget.callbacks.onLoading(false);
        widget.callbacks.onFailure();
      }
    },
    onReceivedHttpError: (_, request, _) {
      if (request.isForMainFrame == true) {
        _failed = true;
        widget.callbacks.onLoading(false);
        widget.callbacks.onFailure();
      }
    },
    onWebContentProcessDidTerminate: (_) => widget.callbacks.onFailure(),
  );
}

class _NativeBrowserHandle implements YoutubeBrowserHandle {
  _NativeBrowserHandle(this.controller);
  final InAppWebViewController controller;
  @override
  Future<void> load(Uri uri) =>
      controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(uri)));
  @override
  Future<void> back() => controller.goBack();
  @override
  Future<void> forward() => controller.goForward();
  @override
  Future<void> reload() => controller.reload();
  @override
  Future<bool> canGoBack() => controller.canGoBack();
  @override
  Future<bool> canGoForward() => controller.canGoForward();
}

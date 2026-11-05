import 'dart:async';

import 'package:flutter/material.dart';

import '../models/youtube_cookies.dart';
import '../services/api_client.dart';
import '../services/youtube_cookie_source.dart';
import 'youtube_login_screen.dart';

class YoutubeCookiesScreen extends StatefulWidget {
  const YoutubeCookiesScreen({
    super.key,
    required this.api,
    required this.source,
  });
  final ApiClient api;
  final YoutubeCookieSource source;
  @override
  State<YoutubeCookiesScreen> createState() => _YoutubeCookiesScreenState();
}

class _YoutubeCookiesScreenState extends State<YoutubeCookiesScreen> {
  YoutubeCookies? _pending;
  YoutubeCookieStatus? _status;
  String? _error;
  String? _notice;
  bool _busy = false;
  bool _statusLoading = false;
  int _statusRevision = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshStatus());
  }

  String _message(Object error) =>
      error is ApiFailure
          ? error.message
          : error is CookieImportFailure
          ? error.message
          : '操作を完了できませんでした。もう一度お試しください。';

  Future<void> _refreshStatus() async {
    final revision = ++_statusRevision;
    setState(() {
      _statusLoading = true;
      _error = null;
    });
    try {
      final status = await widget.api.youtubeCookieStatus();
      if (mounted && revision == _statusRevision) {
        setState(() => _status = status);
      }
    } catch (error) {
      if (mounted && revision == _statusRevision) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (mounted && revision == _statusRevision) {
        setState(() => _statusLoading = false);
      }
    }
  }

  Future<void> _selectCookies({required bool web}) async {
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final cookies =
          web
              ? await navigator.push<YoutubeCookies>(
                MaterialPageRoute(
                  builder: (_) => YoutubeLoginScreen(source: widget.source),
                ),
              )
              : await widget.source.pickFile();
      if (mounted && cookies != null) setState(() => _pending = cookies);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _upload() async {
    final cookies = _pending;
    if (cookies == null || _busy) return;
    ++_statusRevision;
    setState(() {
      _busy = true;
      _statusLoading = false;
      _error = null;
    });
    try {
      await widget.api.uploadYoutubeCookies(cookies);
      _pending = null;
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearLocal() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.source.clearWebLogin();
      if (mounted) {
        setState(() {
          _pending = null;
          _notice = '端末のWebViewログインを消去しました。サーバーに登録したCookieは保持されます。';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('YouTube連携')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              '送信先: ${widget.api.baseUri}',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            const Text(
              'YouTubeにログインするか、ブラウザーから書き出したNetscape形式のcookies.txtを選択してください。',
            ),
            const SizedBox(height: 8),
            const Text(
              'YouTubeのCookieだけを送信します。登録後はサーバーが保持し、Mix取得時にもログインの有効性を確認します。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 20),
            Text(
              'サーバー保存状態: ${_status == null
                  ? '未確認'
                  : _status!.configured
                  ? '保存済み'
                  : '未登録'}',
            ),
            if (_status?.updatedAt != null)
              Text(
                '更新時刻: ${_status!.updatedAt!.toLocal()}',
                style: const TextStyle(fontSize: 12),
              ),
            const Text(
              '保存状態は、現在もログインが有効であることを示すものではありません。',
              style: TextStyle(fontSize: 12),
            ),
            TextButton(
              onPressed: _busy || _statusLoading ? null : _refreshStatus,
              child: Text(_statusLoading ? '確認中…' : '保存状態を確認'),
            ),
            const Divider(),
            if (widget.source.supportsWebLogin) ...[
              OutlinedButton(
                onPressed: _busy ? null : () => _selectCookies(web: true),
                child: const Text('YouTubeにログイン'),
              ),
              const SizedBox(height: 8),
            ] else
              const Text(
                'WebViewログインはiPhone版で利用できます。Cookieファイルの取込も利用できます。',
                style: TextStyle(fontSize: 12),
              ),
            OutlinedButton(
              onPressed: _busy ? null : () => _selectCookies(web: false),
              child: const Text('Cookieファイルを選択'),
            ),
            if (_pending != null) ...[
              const SizedBox(height: 16),
              Text('送信対象: ${_pending!.count}件のYouTube Cookie'),
              FilledButton(
                onPressed: _busy ? null : _upload,
                child: const Text('このサーバーにCookieを登録'),
              ),
              TextButton(
                onPressed: _busy ? null : () => setState(() => _pending = null),
                child: const Text('選択を取り消す'),
              ),
            ],
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(_error!),
              ),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(_notice!),
              ),
            if (widget.source.supportsWebLogin) ...[
              const SizedBox(height: 24),
              TextButton(
                onPressed: _busy ? null : _clearLocal,
                child: const Text('端末のWebViewログインを消去'),
              ),
              const Text(
                'この操作ではサーバーに保存したCookieは削除されません。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/youtube_cookies.dart';

abstract interface class YoutubeCookieSource {
  bool get supportsWebLogin;
  Future<YoutubeCookies?> pickFile();
  Future<YoutubeCookies> readWebCookies();
  Future<void> clearWebLogin();
}

class NativeYoutubeCookieSource implements YoutubeCookieSource {
  @override
  bool get supportsWebLogin =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Future<YoutubeCookies?> pickFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Cookieファイル',
          extensions: ['txt'],
          mimeTypes: ['text/plain'],
          uniformTypeIdentifiers: ['public.plain-text'],
        ),
      ],
    );
    if (file == null) return null;
    if (await file.length() > YoutubeCookies.maxFileBytes) {
      throw const CookieImportFailure('Cookieファイルは1MB以下で指定してください。');
    }
    try {
      return YoutubeCookies.fromNetscape(utf8.decode(await file.readAsBytes()));
    } on FormatException {
      throw const CookieImportFailure('UTF-8のNetscape形式Cookieファイルを指定してください。');
    }
  }

  @override
  Future<YoutubeCookies> readWebCookies() async {
    if (!supportsWebLogin) {
      throw const CookieImportFailure('WebViewログインはiPhone版で利用できます。');
    }
    final cookies = await CookieManager.instance().getAllCookies();
    return YoutubeCookies.fromRecords(
      cookies
          .where(
            (cookie) =>
                cookie.domain != null &&
                YoutubeCookies.isYoutubeDomain(cookie.domain!),
          )
          .map(
            (cookie) => YoutubeCookie(
              domain: cookie.domain!,
              name: cookie.name,
              value: cookie.value.toString(),
              path: cookie.path ?? '/',
              includeSubdomains: cookie.domain!.startsWith('.'),
              secure: cookie.isSecure ?? true,
              httpOnly: cookie.isHttpOnly ?? false,
              expiresAt:
                  cookie.expiresDate != null && cookie.expiresDate! > 0
                      ? DateTime.fromMillisecondsSinceEpoch(
                        cookie.expiresDate!,
                        isUtc: true,
                      )
                      : null,
            ),
          ),
    );
  }

  @override
  Future<void> clearWebLogin() async {
    if (!supportsWebLogin) return;
    await CookieManager.instance().deleteAllCookies();
    await WebStorageManager.instance().deleteAllData();
  }
}

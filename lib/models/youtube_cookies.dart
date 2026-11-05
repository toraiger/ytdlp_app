import 'dart:convert';

class CookieImportFailure implements Exception {
  const CookieImportFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class YoutubeCookie {
  const YoutubeCookie({
    required this.domain,
    required this.name,
    required this.value,
    this.path = '/',
    this.includeSubdomains = false,
    this.secure = true,
    this.httpOnly = false,
    this.expiresAt,
  });
  final String domain;
  final String name;
  final String value;
  final String path;
  final bool includeSubdomains;
  final bool secure;
  final bool httpOnly;
  final DateTime? expiresAt;
}

class YoutubeCookies {
  YoutubeCookies._(this._cookies);
  final List<YoutubeCookie> _cookies;
  int get count => _cookies.length;
  static const maxFileBytes = 1024 * 1024;

  static bool isYoutubeDomain(String domain) {
    final normalized = domain.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    return (normalized == 'youtube.com' ||
            normalized.endsWith('.youtube.com')) &&
        normalized
            .split('.')
            .every(
              (label) =>
                  RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label),
            );
  }

  factory YoutubeCookies.fromRecords(
    Iterable<YoutubeCookie> records, {
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    final cookies = <(String, String, String), YoutubeCookie>{};
    for (final cookie in records) {
      if (!isYoutubeDomain(cookie.domain)) continue;
      if (cookie.expiresAt != null && !cookie.expiresAt!.isAfter(current)) {
        continue;
      }
      if (cookie.name.isEmpty ||
          cookie.name.contains(RegExp(r'[\s;=]')) ||
          !cookie.path.startsWith('/') ||
          [
            cookie.domain,
            cookie.path,
            cookie.name,
            cookie.value,
          ].any((value) => value.contains(RegExp(r'[\x00-\x1f\x7f]')))) {
        throw const CookieImportFailure('Cookieの形式が正しくありません。');
      }
      final domain = cookie.domain.toLowerCase().replaceFirst(
        RegExp(r'^\.'),
        '',
      );
      cookies[(domain, cookie.path, cookie.name)] = YoutubeCookie(
        domain: domain,
        name: cookie.name,
        value: cookie.value,
        path: cookie.path,
        includeSubdomains: cookie.includeSubdomains,
        secure: cookie.secure,
        httpOnly: cookie.httpOnly,
        expiresAt: cookie.expiresAt,
      );
    }
    final names =
        cookies.values
            .where((cookie) => cookie.value.isNotEmpty)
            .map((cookie) => cookie.name)
            .toSet();
    if (!names.contains('LOGIN_INFO') ||
        !names.any(
          const {'SAPISID', '__Secure-1PAPISID', '__Secure-3PAPISID'}.contains,
        )) {
      throw const CookieImportFailure(
        'YouTubeのログイン用Cookieが見つかりません。ログイン後に取得するか、Cookieファイルを選び直してください。',
      );
    }
    return YoutubeCookies._(List.unmodifiable(cookies.values));
  }

  factory YoutubeCookies.fromNetscape(String text, {DateTime? now}) {
    if (utf8.encode(text).length > maxFileBytes) {
      throw const CookieImportFailure('Cookieファイルは1MB以下で指定してください。');
    }
    final records = <YoutubeCookie>[];
    for (var line in const LineSplitter().convert(
      text.replaceFirst(RegExp('^\uFEFF'), ''),
    )) {
      if (line.trim().isEmpty) continue;
      final httpOnly = line.startsWith('#HttpOnly_');
      if (httpOnly) {
        line = line.substring('#HttpOnly_'.length);
      } else if (line.startsWith('#')) {
        continue;
      }
      final fields = line.split('\t');
      if (fields.length != 7) {
        throw const CookieImportFailure('Netscape形式のcookies.txtを指定してください。');
      }
      if (!isYoutubeDomain(fields[0])) continue;
      final seconds = int.tryParse(fields[4]);
      if (seconds == null ||
          seconds < 0 ||
          seconds > 8640000000000 ||
          !const ['TRUE', 'FALSE'].contains(fields[1].toUpperCase()) ||
          !const ['TRUE', 'FALSE'].contains(fields[3].toUpperCase())) {
        throw const CookieImportFailure('Cookieの属性が正しくありません。');
      }
      records.add(
        YoutubeCookie(
          domain: fields[0],
          includeSubdomains: fields[1].toUpperCase() == 'TRUE',
          path: fields[2],
          secure: fields[3].toUpperCase() == 'TRUE',
          expiresAt:
              seconds == 0
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(
                    seconds * 1000,
                    isUtc: true,
                  ),
          name: fields[5],
          value: fields[6],
          httpOnly: httpOnly,
        ),
      );
    }
    return YoutubeCookies.fromRecords(records, now: now);
  }

  String toNetscape() {
    final rows = _cookies
        .map(
          (cookie) => [
            '${cookie.httpOnly ? '#HttpOnly_' : ''}${cookie.includeSubdomains ? '.' : ''}${cookie.domain}',
            cookie.includeSubdomains ? 'TRUE' : 'FALSE',
            cookie.path,
            cookie.secure ? 'TRUE' : 'FALSE',
            '${(cookie.expiresAt?.millisecondsSinceEpoch ?? 0) ~/ 1000}',
            cookie.name,
            cookie.value,
          ].join('\t'),
        )
        .join('\n');
    return '# Netscape HTTP Cookie File\n$rows\n';
  }

  @override
  String toString() => 'YoutubeCookies(count: $count)';
}

class YoutubeCookieStatus {
  const YoutubeCookieStatus({required this.configured, this.updatedAt});
  factory YoutubeCookieStatus.fromJson(Map<String, dynamic> json) {
    if (json['configured'] is! bool) {
      throw const FormatException('Invalid cookie status');
    }
    return YoutubeCookieStatus(
      configured: json['configured'] as bool,
      updatedAt:
          json['updated_at'] is String
              ? DateTime.tryParse(json['updated_at'] as String)
              : null,
    );
  }
  final bool configured;
  final DateTime? updatedAt;
}

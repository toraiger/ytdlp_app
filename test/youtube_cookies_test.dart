import 'package:flutter_test/flutter_test.dart';
import 'package:mix_player_app/models/youtube_cookies.dart';

// Generated examples only. Never use exported account cookies as fixtures.
const dummyCookieFile = '''# Netscape HTTP Cookie File
#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t0\tLOGIN_INFO\tdummy-login
.youtube.com\tTRUE\t/\tTRUE\t0\t__Secure-3PAPISID\tdummy-sapisid
''';

void main() {
  test(
    'Netscape round trip preserves HttpOnly, session and scope attributes',
    () {
      final cookies = YoutubeCookies.fromNetscape('\uFEFF$dummyCookieFile');
      expect(cookies.count, 2);
      expect(cookies.toNetscape(), dummyCookieFile);
      expect(cookies.toString(), 'YoutubeCookies(count: 2)');
      expect(YoutubeCookies.fromNetscape(cookies.toNetscape()).count, 2);
    },
  );

  test('Only YouTube domain boundaries are accepted', () {
    for (final domain in ['youtube.com', '.youtube.com', 'M.YOUTUBE.COM']) {
      expect(YoutubeCookies.isYoutubeDomain(domain), isTrue);
    }
    for (final domain in [
      'google.com',
      'evilyoutube.com',
      'youtube.com.evil.test',
      '..youtube.com',
      'a..youtube.com',
      '-a.youtube.com',
      'youtube.com\n',
    ]) {
      expect(YoutubeCookies.isYoutubeDomain(domain), isFalse, reason: domain);
    }
  });

  test('Filters Google, expired and unrelated cookies and deduplicates', () {
    final now = DateTime.utc(2026, 11, 5);
    final cookies = YoutubeCookies.fromNetscape('''$dummyCookieFile
.google.com\tTRUE\t/\tTRUE\t0\tSID\tdummy-google
.youtube.com.evil.test\tTRUE\t/\tTRUE\t0\tSID\tdummy-evil
.youtube.com\tTRUE\t/\tTRUE\t1\tOLD\tdummy-expired
.youtube.com\tTRUE\t/\tTRUE\t0\t__Secure-3PAPISID\tdummy-new
www.youtube.com\tFALSE\t/path\tFALSE\t2000000000\tPREF\tdummy-pref
''', now: now);
    expect(cookies.count, 3);
    final output = cookies.toNetscape();
    for (final excluded in [
      'dummy-google',
      'dummy-evil',
      'dummy-expired',
      'dummy-sapisid',
    ]) {
      expect(output, isNot(contains(excluded)));
    }
    expect(output, contains('dummy-new'));
    expect(
      output,
      contains('www.youtube.com\tFALSE\t/path\tFALSE\t2000000000'),
    );
  });

  test('Login markers must remain after expiry and domain filtering', () {
    for (final text in [
      '',
      '.youtube.com\tTRUE\t/\tTRUE\t0\tPREF\tdummy',
      dummyCookieFile.replaceAll('dummy-login', ''),
      dummyCookieFile.replaceFirst(
        'TRUE\t0\tLOGIN_INFO',
        'TRUE\t1\tLOGIN_INFO',
      ),
      dummyCookieFile.replaceAll('.youtube.com', '.google.com'),
    ]) {
      expect(
        () => YoutubeCookies.fromNetscape(text),
        throwsA(isA<CookieImportFailure>()),
      );
    }
  });

  test('Malformed and oversized input errors never include values', () {
    for (final text in [
      'dummy-private-value',
      dummyCookieFile.replaceFirst('\t0\t', '\t-1\t'),
      dummyCookieFile.replaceFirst('\t0\t', '\t999999999999999999\t'),
      dummyCookieFile.replaceFirst('\tTRUE\t', '\twrong\t'),
      dummyCookieFile.replaceFirst('\t/\t', '\tinvalid-path\t'),
      dummyCookieFile.replaceFirst('dummy-login', 'dummy-private-value\u0000'),
      'x' * (YoutubeCookies.maxFileBytes + 1),
    ]) {
      expect(
        () => YoutubeCookies.fromNetscape(text),
        throwsA(
          isA<CookieImportFailure>().having(
            (error) => error.message,
            'redacted error',
            isNot(contains('dummy-private-value')),
          ),
        ),
      );
    }
  });

  test('Native records reject control characters before Netscape export', () {
    expect(
      () => YoutubeCookies.fromRecords(const [
        YoutubeCookie(
          domain: 'youtube.com',
          name: 'LOGIN_INFO',
          value: 'dummy\nINJECT',
        ),
        YoutubeCookie(domain: 'youtube.com', name: 'SAPISID', value: 'dummy'),
      ]),
      throwsA(isA<CookieImportFailure>()),
    );
  });

  test('Configured is required; updated_at is optional metadata', () {
    expect(
      YoutubeCookieStatus.fromJson({'configured': false}).configured,
      isFalse,
    );
    expect(
      YoutubeCookieStatus.fromJson({
        'configured': true,
        'updated_at': '2026-11-05T03:00:00Z',
      }).updatedAt,
      DateTime.utc(2026, 11, 5, 3),
    );
    expect(
      YoutubeCookieStatus.fromJson({
        'configured': true,
        'updated_at': 'unknown',
      }).updatedAt,
      isNull,
    );
    expect(
      () => YoutubeCookieStatus.fromJson({'configured': 'true'}),
      throwsFormatException,
    );
  });
}

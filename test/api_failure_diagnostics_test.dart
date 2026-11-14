import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mix_player_app/models/api_failure_diagnostics.dart';
import 'package:mix_player_app/models/api_timing.dart';
import 'package:mix_player_app/models/youtube_cookies.dart';
import 'package:mix_player_app/services/api_client.dart';
import 'package:mix_player_app/services/diagnostic_redactor.dart';
import 'package:mix_player_app/services/error_report.dart';
import 'package:mix_player_app/services/request_scope.dart';

import 'support/fakes.dart';

Future<ApiFailure> failureOf(Future<Object?> pending) async {
  try {
    await pending;
  } on ApiFailure catch (failure) {
    return failure;
  }
  throw StateError('Expected an API failure');
}

void main() {
  test(
    'Redaction covers credentials, encoded URLs, headers and local paths',
    () {
      final redactor = DiagnosticRedactor(
        secrets: ['standalone-key', 'api.test'],
      );
      final text = redactor.message(r'''
Connection failed at https://user:password@api.test/a?signature=url-token
escaped https:\/\/media.test/b?secret=escaped-token
X-API-Key: header-key
Authorization=Bearer bearer-token
Cookie: SID=cookie-token
Set-Cookie: another-cookie
"authorization": "json-token"
\"X-API-Key\": \"escaped-json-key\"
Proxy-Authorization: proxy-token
 folded-token
plain standalone-key on api.test
/home/private-user/app.dart:4:5
C:\Users\private-user\app.dart:4:5
''');
      for (final secret in [
        'password',
        'url-token',
        'escaped-token',
        'header-key',
        'bearer-token',
        'cookie-token',
        'another-cookie',
        'json-token',
        'escaped-json-key',
        'proxy-token',
        'folded-token',
        'standalone-key',
        'api.test',
        'private-user',
      ]) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      expect(text, contains('Connection failed'));
      expect(text, contains('[URL]'));
      expect(text, contains('[PATH]'));
      expect(text, contains('[REDACTED]'));
    },
  );

  test(
    'Redaction happens before limits and preserves package stack locations',
    () {
      final redactor = DiagnosticRedactor(secrets: ['private-key']);
      final message = redactor.message(
        '${'x' * 1980}https://private.test/${'secret' * 500}',
      );
      expect(message.length, lessThanOrEqualTo(2000));
      expect(message, isNot(contains('private')));
      expect(message, isNot(contains('secret')));
      final stack = redactor.stack(
        StackTrace.fromString(
          List.generate(
            30,
            (i) =>
                '#$i fetch (package:mix_player_app/services/api_client.dart:$i:3)',
          ).join('\n'),
        ),
      );
      expect(
        stack,
        contains('package:mix_player_app/services/api_client.dart:19:3'),
      );
      expect(stack, isNot(contains('#20 ')));
      expect(stack, contains('[以降省略]'));
      expect(redactor.stack(StackTrace.fromString('x' * 10000)).length, 8000);
      expect(redactor.message('x' * 3000).length, 2000);
    },
  );

  test(
    'Connection failures retain redacted originals and request-local context',
    () async {
      final api = mockApi(
        (_) => Error.throwWithStackTrace(
          http.ClientException(
            'Connection lost at https://api.test/a?secret=url-token\nX-API-Key=key-token',
          ),
          StackTrace.fromString(
            '#0 resolve (package:mix_player_app/services/api_client.dart:10:2)\n#1 native (/private/user/private-file.dart:2:3)',
          ),
        ),
      );
      addTearDown(api.close);
      final failure = await failureOf(
        api.resolveStream('private-track', scope: RequestScope(7)),
      );
      final detail = failure.diagnostics!;
      expect(detail.kind, ApiFailureKind.connection);
      expect(detail.stage, ApiFailureStage.waitingHeaders);
      expect(detail.causeType, 'ClientException');
      expect(detail.timing.operation, ApiOperation.stream);
      expect(detail.timing.toHeaders, isNull);
      expect(detail.timing.statusCode, isNull);
      expect(detail.timeout, const Duration(seconds: 20));
      expect(detail.networkGeneration, 7);
      expect(detail.isPrefetch, isTrue);
      expect(detail.retryable, isTrue);
      expect(detail.nativeDomain, isNull);
      expect(detail.nativeCode, isNull);
      final report =
          ErrorReport.capture(
            operation: '次の曲の先読み',
            message: '準備中',
            failure: failure,
          ).toText();
      expect(report, contains('元の例外メッセージ（伏せ字済み）: Connection lost'));
      expect(
        report,
        contains('package:mix_player_app/services/api_client.dart:10:2'),
      );
      for (final secret in [
        'https://',
        'url-token',
        'key-token',
        'private-track',
        '/private/user',
      ]) {
        expect(report, isNot(contains(secret)));
      }
    },
  );

  test(
    'Configured API keys and uploaded Cookie values are redacted before storage',
    () async {
      const key = 'secret/key+value';
      final cookies = YoutubeCookies.fromRecords([
        const YoutubeCookie(
          domain: 'youtube.com',
          name: 'LOGIN_INFO',
          value: 'login-secret',
        ),
        const YoutubeCookie(
          domain: 'youtube.com',
          name: 'SAPISID',
          value: 'sapisid-secret',
        ),
      ]);
      final api = ApiClient(
        serverUrl: 'https://api.test',
        apiKey: key,
        client: MockClient(
          (_) async =>
              throw http.ClientException(
                'failed $key ${Uri.encodeComponent(key)} login-secret sapisid-secret',
              ),
        ),
      );
      addTearDown(api.close);
      final failure = await failureOf(api.uploadYoutubeCookies(cookies));
      final detail = failure.diagnostics!;
      expect(detail.timing.operation, ApiOperation.youtubeCookieUpload);
      expect(detail.timeout, const Duration(seconds: 120));
      for (final secret in [
        key,
        Uri.encodeComponent(key),
        'login-secret',
        'sapisid-secret',
      ]) {
        expect(detail.message, isNot(contains(secret)));
        expect(detail.stack, isNot(contains(secret)));
      }
      expect(detail.message, startsWith('failed '));
      expect(detail.message, contains('[REDACTED]'));
    },
  );

  test(
    'Body failures retain HTTP headers and the original read exception',
    () async {
      final api = ApiClient(
        serverUrl: 'https://api.test',
        apiKey: 'test-key',
        client: MockClient.streaming(
          (_, __) async => http.StreamedResponse(
            Stream<List<int>>.error(
              http.ClientException('Connection lost while reading'),
            ),
            200,
          ),
        ),
      );
      addTearDown(api.close);
      final failure = await failureOf(api.resolveStream('a'));
      expect(failure.statusCode, isNull);
      expect(failure.diagnostics!.timing.statusCode, 200);
      expect(failure.diagnostics!.stage, ApiFailureStage.responseBody);
      expect(failure.diagnostics!.timing.toHeaders, isNotNull);
      expect(failure.diagnostics!.message, 'Connection lost while reading');
    },
  );

  test(
    'Body timeouts preserve the configured limit and ignore a late body',
    () async {
      final body = StreamController<List<int>>();
      final api = ApiClient(
        serverUrl: 'https://api.test',
        apiKey: 'test-key',
        timeout: const Duration(milliseconds: 5),
        client: MockClient.streaming(
          (_, __) async => http.StreamedResponse(body.stream, 200),
        ),
      );
      addTearDown(api.close);
      final failure = await failureOf(api.resolveStream('a'));
      final detail = failure.diagnostics!;
      expect(detail.kind, ApiFailureKind.timeout);
      expect(detail.causeType, 'TimeoutException');
      expect(detail.stage, ApiFailureStage.responseBody);
      expect(detail.timeout, const Duration(milliseconds: 5));
      expect(detail.timing.statusCode, 200);
      body.add([1, 2, 3]);
      await body.close();
      expect(failure.diagnostics, same(detail));
    },
  );

  test(
    'HTTP and parse errors retain diagnostics without copying response bodies',
    () async {
      for (final status in [403, 503, 200]) {
        final api = mockApi(
          (_) => http.Response('private-response-body', status),
        );
        final failure = await failureOf(api.resolveStream('a'));
        expect(failure.diagnostics!.timing.statusCode, status);
        expect(
          failure.diagnostics!.kind,
          status == 200
              ? ApiFailureKind.invalidResponse
              : ApiFailureKind.httpStatus,
        );
        expect(failure.retryable, status == 503);
        expect(
          failure.diagnostics!.toText(),
          isNot(contains('private-response-body')),
        );
        if (status == 200) {
          expect(failure.diagnostics!.stage, ApiFailureStage.decode);
          expect(failure.diagnostics!.causeType, 'FormatException');
        }
        api.close();
      }
      final api = mockApi(
        (_) => jsonResponse({
          'video_id': 'a',
          'audio': {'ext': 12},
        }),
      );
      addTearDown(api.close);
      final failure = await failureOf(api.resolveStream('a'));
      expect(failure.diagnostics!.stage, ApiFailureStage.decode);
      expect(failure.diagnostics!.causeType, contains('TypeError'));
      expect(failure.diagnostics!.timing.succeeded, isFalse);
      expect(failure.message, '再生 URL の応答形式が正しくありません。');
    },
  );

  test(
    'Concurrent requests and later successes cannot replace failure snapshots',
    () async {
      final requests = <Completer<http.Response>>[];
      final api = mockApi((_) {
        final response = Completer<http.Response>();
        requests.add(response);
        return response.future;
      });
      addTearDown(api.close);
      final mixPending = failureOf(
        api.fetchMix('https://youtube.com/?list=private-list'),
      );
      final prefetchPending = failureOf(
        api.resolveStream('b', scope: RequestScope(3)),
      );
      await drain();
      requests[1].completeError(
        http.ClientException('prefetch connection lost'),
      );
      final prefetchFailure = await prefetchPending;
      requests[0].complete(http.Response('', 503));
      final mixFailure = await mixPending;
      final later = api.resolveStream('c');
      await drain();
      requests.last.complete(jsonResponse(streamJson('c')));
      await later;
      final report = ErrorReport.capture(
        operation: '先読み',
        message: '準備中',
        failure: prefetchFailure,
        apiTiming: api.lastTiming.value,
      );
      expect(report.apiTiming, same(prefetchFailure.diagnostics!.timing));
      expect(report.apiTiming!.statusCode, isNull);
      expect(report.toText(), contains('prefetch connection lost'));
      expect(report.toText(), isNot(contains('HTTP 200')));
      expect(mixFailure.diagnostics!.timing.operation, ApiOperation.mix);
      expect(mixFailure.diagnostics!.timing.statusCode, 503);
      expect(prefetchFailure.diagnostics!.networkGeneration, 3);
    },
  );
}

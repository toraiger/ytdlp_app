import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mix_player_app/services/api_client.dart';
import 'package:objective_c/objective_c.dart';

import 'support/fakes.dart';

void main() {
  test(
    'Real NSError domain and code survive the API wrapper on Apple hosts',
    () async {
      for (final entry
          in {
            -1009: 'offline',
            -1005: 'connectionLost',
            -1003: 'dns',
            -1200: 'tls',
          }.entries) {
        final original = NSErrorClientException(
          NSError.errorWithDomain(
            'NSURLErrorDomain'.toNSString(),
            code: entry.key,
          ),
          Uri.parse('https://private.test/?signature=private-token'),
        );
        final api = mockApi((_) => throw original);
        try {
          await api.resolveStream('a');
          fail('Expected native failure');
        } on ApiFailure catch (failure) {
          final detail = failure.diagnostics!;
          expect(detail.causeType, 'NSErrorClientException');
          expect(detail.nativeDomain, 'NSURLErrorDomain');
          expect(detail.nativeCode, entry.key);
          expect(detail.nativeCategory, entry.value);
          expect(detail.message, isNotEmpty);
          expect(detail.toText(), isNot(contains('private-token')));
        } finally {
          api.close();
        }
      }
    },
    skip: !Platform.isMacOS && !Platform.isIOS,
  );
}

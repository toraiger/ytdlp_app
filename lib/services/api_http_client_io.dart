import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:http/http.dart' as http;
import "package:objective_c/objective_c.dart"
    show NSError$Methods, NSStringToString;

// NSError descriptions/userInfo can contain URLs. Keep only the numeric code.
int? nativeHttpErrorCode(Object failure) =>
    failure is NSErrorClientException ? failure.error.code : null;

String? nativeHttpErrorDomain(Object failure) {
  if (failure is! NSErrorClientException) return null;
  final domain = failure.error.domain.toDartString();
  // Domains are identifiers, not descriptions or arbitrary NSError userInfo.
  return const {
        'NSURLErrorDomain',
        'kCFErrorDomainCFNetwork',
        'NSPOSIXErrorDomain',
        'NSOSStatusErrorDomain',
      }.contains(domain)
      ? domain
      : 'other';
}

http.Client createApiHttpClient() {
  if (!Platform.isIOS) return http.Client();

  // One URLSession per API client reuses connections and negotiates HTTP/2
  // when the server supports it, using the iPhone's native VPN networking.
  final configuration =
      URLSessionConfiguration.ephemeralSessionConfiguration()
        ..allowsCellularAccess = true
        ..httpShouldSetCookies = false
        ..cache = null
        ..requestCachePolicy =
            NSURLRequestCachePolicy.NSURLRequestReloadIgnoringLocalCacheData
        ..timeoutIntervalForRequest = const Duration(seconds: 120);
  return CupertinoClient.fromSessionConfiguration(configuration);
}

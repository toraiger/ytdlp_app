import 'dart:io';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:http/http.dart' as http;

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
        ..timeoutIntervalForRequest = const Duration(seconds: 90);
  return CupertinoClient.fromSessionConfiguration(configuration);
}

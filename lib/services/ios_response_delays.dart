import 'package:flutter/foundation.dart';

bool get _isNativeIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

Future<void> delayApiResponse() async {
  if (_isNativeIos) {
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}

Future<void> delayMediaLoad() async {
  if (_isNativeIos) {
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
}

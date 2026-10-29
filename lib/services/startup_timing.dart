import 'package:flutter/foundation.dart';

/// 固定の処理名と所要時間だけを記録する。URL・動画ID・鍵・例外は受け取らない。
void recordStartupTiming(String phase, Stopwatch stopwatch) {
  stopwatch.stop();
  debugPrint(
    'mix_startup phase=$phase elapsed_ms=${stopwatch.elapsedMilliseconds}',
  );
}

/// 処理を実行し、成功・失敗のどちらでも所要時間を記録して結果または例外を返す。
Future<T> measureStartup<T>(String phase, Future<T> Function() action) async {
  final stopwatch = Stopwatch()..start();
  try {
    return await action();
  } finally {
    recordStartupTiming(phase, stopwatch);
  }
}

import 'api_timing.dart';

enum ApiFailureStage { waitingHeaders, responseBody, decode }

enum ApiFailureKind {
  connection,
  timeout,
  interrupted,
  httpStatus,
  invalidResponse,
}

/// A request-local snapshot. Message and stack are already redacted and bounded.
class ApiFailureDiagnostics {
  const ApiFailureDiagnostics({
    required this.occurredAt,
    required this.timing,
    required this.stage,
    required this.kind,
    required this.timeout,
    required this.retryable,
    required this.causeType,
    required this.message,
    required this.stack,
    required this.isPrefetch,
    this.networkGeneration,
    this.nativeDomain,
    this.nativeCode,
  });

  final DateTime occurredAt;
  final ApiTiming timing;
  final ApiFailureStage stage;
  final ApiFailureKind kind;
  final Duration timeout;
  final bool retryable;
  final String causeType;
  final String message;
  final String stack;
  final bool isPrefetch;
  final int? networkGeneration;
  final String? nativeDomain;
  final int? nativeCode;

  String get nativeCategory {
    if (nativeDomain != 'NSURLErrorDomain') return 'unknown';
    return switch (nativeCode ?? 0) {
      -999 => 'cancelled',
      -1001 => 'timeout',
      -1003 || -1006 => 'dns',
      -1004 => 'cannotConnect',
      -1005 => 'connectionLost',
      -1009 => 'offline',
      >= -1206 && <= -1200 => 'tls',
      _ => 'unknown',
    };
  }

  String toText() => [
    '失敗したAPI通信: ${timing.operation.label}',
    'API失敗時刻(UTC): ${occurredAt.toUtc().toIso8601String()}',
    'API失敗種別: ${kind.name}',
    'API失敗段階: ${stage.name}',
    'API先読み: ${isPrefetch ? "はい" : "いいえ"}',
    if (networkGeneration != null) 'API回線世代: $networkGeneration',
    'API再試行可能: ${retryable ? "はい" : "いいえ"}',
    '元の例外の種類: $causeType',
    if (nativeDomain != null) 'APIエラードメイン: $nativeDomain',
    if (nativeCode != null) ...[
      'APIネイティブエラーコード: $nativeCode',
      'APIネイティブエラー分類: $nativeCategory',
    ],
    'API通信結果: ${timing.statusLabel}',
    'API通信時間(ms): ${timing.total.inMilliseconds}',
    'API応答ヘッダーまで(ms): ${timing.toHeaders?.inMilliseconds ?? "未受信"}',
    'APIタイムアウト設定(ms): ${timeout.inMilliseconds}',
    '元の例外メッセージ（伏せ字済み）: $message',
    'Dartスタックトレース（伏せ字済み）:\n$stack',
  ].join('\n');
}

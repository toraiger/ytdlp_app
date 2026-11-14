import 'api_failure_diagnostics.dart';

enum PrefetchStage { url, media, native, ready, retry, offline, failed }

/// Request-local API failure details have already been redacted and bounded.
class PrefetchDiagnostics {
  const PrefetchDiagnostics({
    required this.listIndex,
    required this.stage,
    required this.networkGeneration,
    this.reason = "none",
    this.retryCount = 0,
    this.mediaReady = false,
    this.nativeReady = false,
    this.replacement = "pending",
    this.lastApiFailure,
  });

  final int listIndex;
  final PrefetchStage stage;
  final int networkGeneration;
  final String reason;
  final int retryCount;
  final bool mediaReady;
  final bool nativeReady;
  final String replacement;
  final ApiFailureDiagnostics? lastApiFailure;

  String toText() => [
    "先読み対象の曲番号: ${listIndex + 1}",
    "先読み段階: ${stage.name}",
    "回線世代: $networkGeneration",
    "先読み失敗理由: $reason",
    "先読み再試行回数: $retryCount",
    "先読み音声データ準備完了: $mediaReady",
    "先読みネイティブ準備完了: $nativeReady",
    "先読み差し替え結果: $replacement",
    if (lastApiFailure != null) lastApiFailure!.toText(),
  ].join("\n");
}

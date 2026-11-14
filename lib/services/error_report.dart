import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import "package:just_audio/just_audio.dart";

import "../build_info.dart";
import "../models/api_timing.dart";
import "../models/api_failure_diagnostics.dart";
import "../models/audio_transport_diagnostics.dart";
import "../models/playback_diagnostics.dart";
import "../models/prefetch_diagnostics.dart";
import "api_client.dart";

/// Raw exception text is excluded unless captured by the API's redaction path.
class FailureDetails {
  const FailureDetails({
    required this.type,
    this.nativeCode,
    this.sourceIndex,
    this.httpStatusCode,
    this.apiFailure,
  });

  factory FailureDetails.fromException(Object? failure) {
    if (failure is MediaFailure) return failure.details;
    if (failure is PlayerException) {
      return FailureDetails(
        type: "PlayerException",
        nativeCode: failure.code,
        sourceIndex: failure.index,
      );
    }
    if (failure is ApiFailure) {
      return FailureDetails(
        type: "ApiFailure",
        httpStatusCode: failure.statusCode,
        apiFailure: failure.diagnostics,
      );
    }
    if (failure is PlatformException) {
      // AVFoundationの説明文からも数値のコードだけを取り出す。
      final nativeCode = RegExp(
        r"\bCode=(-?\d+)\b",
      ).firstMatch(failure.message ?? "");
      return FailureDetails(
        type: "PlatformException",
        nativeCode:
            int.tryParse(failure.code) ??
            int.tryParse(nativeCode?.group(1) ?? ""),
      );
    }
    return FailureDetails(
      type: failure?.runtimeType.toString() ?? "ApplicationError",
    );
  }

  final String type;
  final int? nativeCode;
  final int? sourceIndex;
  final int? httpStatusCode;
  final ApiFailureDiagnostics? apiFailure;
}

class MediaFailure implements Exception {
  const MediaFailure(this.message, {required this.details});

  final String message;
  final FailureDetails details;
}

/// コピーするまでに先読みや曲移動が起きても、発生時点の情報を維持する。
class ErrorReport {
  ErrorReport.capture({
    required this.operation,
    required this.message,
    Object? failure,
    this.playback,
    ApiTiming? apiTiming,
    this.uptime,
    this.refreshed,
    this.transport,
    this.prefetch,
  }) : occurredAt = DateTime.now().toUtc(),
       details = FailureDetails.fromException(failure),
       apiTiming =
           (failure is ApiFailure ? failure.diagnostics?.timing : null) ??
           apiTiming;

  ErrorReport.withPrefetch(ErrorReport original, this.prefetch)
    : occurredAt = original.occurredAt,
      operation = original.operation,
      message = original.message,
      details = original.details,
      playback = original.playback,
      apiTiming = original.apiTiming,
      uptime = original.uptime,
      refreshed = original.refreshed,
      transport = original.transport;

  final DateTime occurredAt;
  final String operation;
  final String message;
  final FailureDetails details;
  final PlaybackDiagnostics? playback;
  final ApiTiming? apiTiming;
  final Duration? uptime;
  final bool? refreshed;
  final AudioTransportDiagnostics? transport;
  final List<PrefetchDiagnostics>? prefetch;

  String toText() {
    final player = playback;
    final timing = apiTiming;
    final connection = transport;
    final upstream = connection?.upstream;
    return [
      "Mix Player $appVersionLabel",
      if (appRevision.isNotEmpty) "コミット: $appRevision",
      "実行環境: ${kIsWeb ? "web" : defaultTargetPlatform.name}",
      "発生時刻(UTC): ${occurredAt.toIso8601String()}",
      if (uptime != null) "プレーヤー稼働時間(ms): ${uptime!.inMilliseconds}",
      "処理: $operation",
      "エラー: $message",
      "例外の種類: ${details.type}",
      if (details.nativeCode != null) "ネイティブエラーコード: ${details.nativeCode}",
      if (details.sourceIndex != null) "エラー音源の番号: ${details.sourceIndex! + 1}",
      if (details.httpStatusCode != null)
        "HTTPステータス: ${details.httpStatusCode}",
      if (refreshed != null) "URL再取得後: ${refreshed! ? "はい" : "いいえ"}",
      if (connection != null) ...[
        "音声経路: ${connection.route.name}",
        "通信経路の再構築: ${connection.reset.name}",
        if (connection.route == AudioTransportRoute.m4aLoopback) ...[
          "ローカル配信の世代: ${connection.proxyGeneration}",
          "ローカル配信の起動完了: ${connection.proxyListening}",
          "ローカル要求の到達数: ${connection.localRequestCount}",
        ],
      ],
      if (upstream != null) ...[
        "配信元への要求数: ${upstream.attempts}",
        "配信元取得の段階: ${upstream.stage.name}",
        "配信元取得の失敗種別: ${upstream.failure.name}",
        if (upstream.httpStatus != null) "配信元HTTPステータス: ${upstream.httpStatus}",
        if (upstream.nativeCode != null)
          "配信元ネイティブエラーコード: ${upstream.nativeCode}",
      ],
      if (player != null) ...[
        "再生方式: ${player.mode.name}",
        "一覧の曲番号: ${_trackNumber(player.listIndex)}",
        "プレーヤー内の曲番号: ${_trackNumber(player.playerIndex)}",
        "キュー内の曲数: ${player.queueLength}",
        "一覧の長さ(ms): ${player.listDuration?.inMilliseconds ?? "不明"}",
        "メディアの長さ(ms): ${player.mediaDuration?.inMilliseconds ?? "不明"}",
        "メディアの経過時間(ms): ${player.mediaPosition.inMilliseconds}",
      ],
      if (details.apiFailure != null)
        details.apiFailure!.toText()
      else if (timing != null) ...[
        "直近のAPI通信（先読みを含む）: ${timing.operation.label}",
        "API通信結果: ${timing.statusLabel}",
        "API通信時間(ms): ${timing.total.inMilliseconds}",
      ],
      for (final preparation in prefetch ?? player?.prefetch ?? const [])
        preparation.toText(),
    ].join("\n");
  }

  String _trackNumber(int? index) => index == null ? "不明" : "${index + 1}";
}
